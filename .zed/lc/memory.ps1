# Coach memory (docs/2026-10-18-coach-design.md): the local fact store in <journey>/local/ and the
# lc-coach.ps1 commands that use it. Function library: dot-source it after journey.ps1. No side effects.
# Facts are ordered hashtables: id, kind, text, evidence (@{slug; ref}), status, source, created, updated,
# last_seen, until (optional).
# Several processes use the store at once (parallel coach commands, lc-context, the journey view), so every
# read takes local/memory.lock shared and every read-modify-write takes it exclusive, and files are
# replaced whole (written to a temp file first), never rewritten in place.

$script:LcMemoryKinds = @('habit', 'strength', 'style', 'goal', 'preference', 'context')
$script:LcMemoryStatuses = @('active', 'improving', 'resolved', 'dismissed')

# Timestamps and dates are always written in the invariant culture (a Thai or Finnish locale would
# otherwise write a Buddhist year or dots for colons, which nothing can parse back).
function Format-LcStamp([datetime]$T) { $T.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture) }

# Two facts are the same fact when this matches: the kind, plus the text in lower case without quotes,
# punctuation that ends a word, hyphens between words or spaces next to symbols. Operators stay, so
# "i <= n" and "i < n" differ, and so do "a*b" and "a+b".
function Get-LcMemoryKey([string]$Kind, [string]$Text) {
    $t = $Text.ToLowerInvariant()
    $t = [regex]::Replace($t, '(?<=\p{L}{2})-(?=\p{L}{2})', ' ')
    $t = [regex]::Replace($t, '["`]|(?<!\S)''|''(?!\S)', ' ')
    $t = [regex]::Replace($t, '(?<=[\p{L}\p{Nd})\]])[.,;:!?]+(?=\s|$)', ' ')
    $t = [regex]::Replace($t, '\s*([^\p{L}\p{Nd}\s])\s*', '$1')
    return $Kind + '|' + ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function ConvertTo-LcFact($O) {
    if ($O -isnot [pscustomobject] -or -not $O.id -or -not $O.text) { return $null }
    if ([string]$O.kind -notin $script:LcMemoryKinds -or [string]$O.status -notin $script:LcMemoryStatuses) { return $null }
    $ev = New-Object Collections.ArrayList
    foreach ($e in @($O.evidence)) { if ($e) { [void]$ev.Add([ordered]@{ slug = [string]$e.slug; ref = [string]$e.ref }) } }
    $created = [string]$O.created
    $updated = if ($O.updated) { [string]$O.updated } else { $created }
    $f = [ordered]@{
        id = [string]$O.id; kind = [string]$O.kind; text = [string]$O.text; evidence = $ev.ToArray()
        status = [string]$O.status; source = [string]$O.source; created = $created; updated = $updated
        last_seen = $(if ($O.last_seen) { [string]$O.last_seen } else { $updated })
    }
    if ($O.until) { $f['until'] = [string]$O.until }
    return $f
}

function ConvertTo-LcDate([string]$S) {
    try { return [DateTimeOffset]::Parse($S, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

# Habits go improving after 14 days unseen and resolved after 28; any fact past its until date is resolved.
# Returns whether anything changed.
function Update-LcMemoryAge($Facts, [datetime]$Now) {
    $changed = $false
    $stamp = Format-LcStamp $Now
    foreach ($f in @($Facts)) {
        if ($f.status -notin @('active', 'improving')) { continue }
        $to = ''
        if ($f.Contains('until')) {
            $u = $null
            try { $u = [datetime]::ParseExact([string]$f['until'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { }
            if ($u -and $Now.Date -gt $u.Date) { $to = 'resolved' }
        }
        if (-not $to -and $f.kind -eq 'habit') {
            $seen = ConvertTo-LcDate $f.last_seen
            if ($seen) {
                $days = ($Now - $seen).TotalDays
                if ($days -gt 28) { $to = 'resolved' } elseif ($days -gt 14 -and $f.status -eq 'active') { $to = 'improving' }
            }
        }
        if ($to) { $f.status = $to; $f.updated = $stamp; $changed = $true }
    }
    return $changed
}

# The .NET exception behind an error record. A method call wraps it in MethodInvocationException, and
# once PS 5.1 compiles a loop (after about 16 passes) a typed catch no longer looks inside, so the retry
# loops below catch everything and test the type themselves.
function Get-LcException($ErrorRecord) {
    $e = $ErrorRecord.Exception
    if ($e -is [Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    return $e
}

# Another process has the file open (sharing or lock violation), or created it a moment ago: worth a retry.
function Test-LcSharingViolation($E) {
    return ($E -is [IO.IOException]) -and (($E.HResult -band 0xFFFF) -in @(32, 33, 80, 183))
}

# Opens <LocalDir>/memory.lock: -Shared lets other readers in, else nobody else. Retries while another
# process holds it and throws after 10 s. Dispose the result to release it. A shared lock that can't be
# created (a read-only folder, where nobody can write either) returns $null: read without it.
function Enter-LcMemoryLock([string]$LocalDir, [switch]$Shared) {
    if (-not $Shared -and -not [IO.Directory]::Exists($LocalDir)) { New-Item -ItemType Directory -Force $LocalDir | Out-Null }
    $p = Join-Path $LocalDir 'memory.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try {
            if ($Shared) { return [IO.File]::Open($p, 'OpenOrCreate', 'Read', 'Read') }
            return [IO.File]::Open($p, 'OpenOrCreate', 'ReadWrite', 'None')
        } catch {
            $e = Get-LcException $_
            if ($e -is [UnauthorizedAccessException] -and $Shared) { return $null }
            if (-not (Test-LcSharingViolation $e)) { throw }
            if ([DateTime]::UtcNow -gt $deadline) { throw "memory is locked by another process ($p)" }
        }
        Start-Sleep -Milliseconds 20
    }
}

# Replaces a file whole: a reader or a crash sees the old text or the new, never half of it. A replace
# that something else briefly blocks (a virus scanner) is retried.
function Write-LcFileAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-LcUtf8))
    try {
        for ($i = 0; ; $i++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
                return
            } catch {
                if ($i -ge 50 -or -not (Test-LcSharingViolation (Get-LcException $_))) { throw }
                Start-Sleep -Milliseconds 20
            }
        }
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

# The store as it is on disk: Facts (an ArrayList) and Keep, the lines that aren't facts this version
# understands (cut short by a crash, edited by hand, an unknown kind or status). Keep goes back unchanged
# on every save. Takes no lock: the caller holds one.
function Read-LcMemoryStore([string]$LocalDir) {
    $store = @{ Facts = (New-Object Collections.ArrayList); Keep = (New-Object Collections.Generic.List[string]) }
    $p = Join-Path $LocalDir 'memory.jsonl'
    if (-not [IO.File]::Exists($p)) { return $store }
    foreach ($l in [IO.File]::ReadAllLines($p, (New-LcUtf8))) {
        if (-not $l.Trim()) { continue }
        $f = $null
        try { $f = ConvertTo-LcFact ($l | ConvertFrom-Json) } catch { }
        if ($f) { [void]$store.Facts.Add($f) } else { $store.Keep.Add($l) }
    }
    return $store
}

# Writes the whole store (one compact JSON object per line), then the kept lines. The caller holds the
# exclusive lock.
function Save-LcMemory([string]$LocalDir, $Facts, $Keep = @()) {
    if (-not [IO.Directory]::Exists($LocalDir)) { New-Item -ItemType Directory -Force $LocalDir | Out-Null }
    $sb = New-Object Text.StringBuilder
    foreach ($f in @($Facts)) { [void]$sb.Append((ConvertTo-Json $f -Compress -Depth 6)).Append("`n") }
    foreach ($l in @($Keep)) { if ($null -ne $l) { [void]$sb.Append($l).Append("`n") } }
    Write-LcFileAtomic (Join-Path $LocalDir 'memory.jsonl') $sb.ToString()
}

# Every fact in the store, aged. When ageing changed something it saves that, unless -NoSave (a read-only
# caller such as the journey view). Ageing is worked out from the facts alone, so a save that fails is
# skipped and done by a later read. Lines that aren't facts are left out here and kept on disk.
function Read-LcMemory([string]$LocalDir, [datetime]$Now = (Get-Date), [switch]$NoSave) {
    if (-not [IO.File]::Exists((Join-Path $LocalDir 'memory.jsonl'))) { return @() }
    $lk = $null
    try { $lk = Enter-LcMemoryLock $LocalDir -Shared } catch { }
    try { $store = Read-LcMemoryStore $LocalDir } finally { if ($lk) { $lk.Dispose() } }
    $out = $store.Facts.ToArray()
    $aged = Update-LcMemoryAge $out $Now
    if ($NoSave -or -not $aged) { return @($out) }
    try {
        $lk = Enter-LcMemoryLock $LocalDir
        try {
            # Read again: another process may have saved between the two locks.
            $store = Read-LcMemoryStore $LocalDir
            $fresh = $store.Facts.ToArray()
            if (Update-LcMemoryAge $fresh $Now) { Save-LcMemory $LocalDir $fresh $store.Keep }
            $out = $fresh
        } finally { $lk.Dispose() }
    } catch { }
    return @($out)
}

function New-LcMemoryId($Facts) {
    $used = @{}
    foreach ($f in @($Facts)) { $used[$f.id] = $true }
    do { $id = 'm' + ([Guid]::NewGuid().ToString('N').Substring(0, 6)) } while ($used.ContainsKey($id))
    return $id
}

# 'slug:ref' -> @{ slug; ref }; no colon means a slug seen in chat.
function ConvertTo-LcEvidence([string]$S) {
    $i = $S.IndexOf(':')
    if ($i -lt 0) { return [ordered]@{ slug = $S.Trim(); ref = 'chat' } }
    return [ordered]@{ slug = $S.Substring(0, $i).Trim(); ref = $S.Substring($i + 1).Trim() }
}

# Saves a fact into $Facts (the caller saves the store). Result: saved, seen (a live fact of this kind has
# this text: evidence added, status back to active, -Until set when given) or dismissed-before (nothing
# changed). A dismissed fact comes back as active (saved) only when the user asks: -Source user.
# -Replaces resolves the old fact, unless it is the fact being saved.
function Add-LcMemoryFact($Facts, [string]$Kind, [string]$Text, [string[]]$Evidence, [string]$Source, [string]$Until, [string]$Replaces, [datetime]$Now) {
    $stamp = Format-LcStamp $Now
    $Text = ($Text -replace '\s+', ' ').Trim()
    $key = Get-LcMemoryKey $Kind $Text
    $ev = @(foreach ($e in @($Evidence)) { if ($e -and $e.Trim()) { ConvertTo-LcEvidence $e } })
    if (-not $ev.Count) { $ev = @([ordered]@{ slug = ''; ref = 'chat' }) }
    $list = New-Object Collections.ArrayList
    foreach ($f in @($Facts)) { [void]$list.Add($f) }
    $live = $null; $dismissed = $null
    foreach ($f in $list) {
        if ((Get-LcMemoryKey $f.kind $f.text) -ne $key) { continue }
        if ($f.status -in @('active', 'improving')) { $live = $f } elseif ($f.status -eq 'dismissed') { $dismissed = $f }
    }
    $f = $live; $result = 'seen'
    if (-not $f -and $dismissed) {
        if ($Source -ne 'user') { return @{ Facts = $list.ToArray(); Result = 'dismissed-before'; Id = $dismissed.id } }
        $f = $dismissed; $result = 'saved'
        $f.text = $Text; $f.source = 'user'; $f.evidence = @()
    }
    if ($f) {
        $f.evidence = @(@($f.evidence) + $ev | Select-Object -Last 20)
        $f.last_seen = $stamp; $f.updated = $stamp; $f.status = 'active'
        if ($Until) { $f['until'] = $Until }
    } else {
        $result = 'saved'
        $f = [ordered]@{
            id = New-LcMemoryId $list; kind = $Kind; text = $Text; evidence = @($ev | Select-Object -Last 20)
            status = 'active'; source = $Source; created = $stamp; updated = $stamp; last_seen = $stamp
        }
        if ($Until) { $f['until'] = $Until }
        [void]$list.Add($f)
    }
    if ($Replaces) {
        foreach ($o in $list) { if ($o.id -eq $Replaces -and $o.id -ne $f.id) { $o.status = 'resolved'; $o.updated = $stamp } }
    }
    return @{ Facts = $list.ToArray(); Result = $result; Id = $f.id }
}

# The live facts, grouped by kind: active first, then improving ones.
function Format-LcMemory($Facts) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($k in $script:LcMemoryKinds) {
        $mine = @(@($Facts | Where-Object { $_.kind -eq $k -and $_.status -eq 'active' }) + @($Facts | Where-Object { $_.kind -eq $k -and $_.status -eq 'improving' }))
        if (-not $mine.Count) { continue }
        $lines.Add("${k}:")
        foreach ($f in $mine) {
            $s = "- [$($f.id)] $($f.text)"
            if ($f.status -eq 'improving') { $s += ' (improving)' }
            if ($f.Contains('until')) { $s += " (until $($f['until']))" }
            $lines.Add($s)
        }
    }
    return [string[]]$lines.ToArray()
}

function Get-LcCoachStatePath([string]$LocalDir) { Join-Path $LocalDir 'coach-state.json' }

# slug -> src_hash the coach has read, from coach-state.json (empty when missing or unreadable). No lock.
function Read-LcCoachStateFile([string]$LocalDir) {
    $read = [ordered]@{}
    $p = Get-LcCoachStatePath $LocalDir
    if (-not [IO.File]::Exists($p)) { return $read }
    try {
        $o = [IO.File]::ReadAllText($p, (New-LcUtf8)) | ConvertFrom-Json
        if ($o.read) { foreach ($m in $o.read.PSObject.Properties) { $read[$m.Name] = [string]$m.Value } }
    } catch { }
    return $read
}

# Read-LcCoachStateFile under the shared lock.
function Get-LcCoachRead([string]$LocalDir) {
    if (-not [IO.File]::Exists((Get-LcCoachStatePath $LocalDir))) { return [ordered]@{} }
    $lk = $null
    try { $lk = Enter-LcMemoryLock $LocalDir -Shared } catch { }
    try { return Read-LcCoachStateFile $LocalDir } finally { if ($lk) { $lk.Dispose() } }
}

# slug -> src_hash of its latest solved event. Only the solved lines are parsed, so the cost stays small.
function Get-LcLatestSolved([string]$JourneyRoot) {
    $p = Join-Path $JourneyRoot 'events.jsonl'
    $res = [ordered]@{}
    if (-not [IO.File]::Exists($p)) { return $res }
    foreach ($l in [IO.File]::ReadAllLines($p, (New-LcUtf8))) {
        if (-not $l.Contains('"event":"solved"')) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o.event -eq 'solved' -and $o.slug) { $res[[string]$o.slug] = [string]$o.src_hash }
    }
    return $res
}

# Slugs whose latest solved version the coach hasn't read.
function Get-LcUnreadSolves([string]$JourneyRoot) {
    $read = Get-LcCoachRead (Join-Path $JourneyRoot 'local')
    $solved = Get-LcLatestSolved $JourneyRoot
    return @(foreach ($s in $solved.Keys) { if ($read[$s] -ne $solved[$s]) { $s } })
}

function Find-LcFact($Facts, [string]$Id) {
    foreach ($f in @($Facts)) { if ($f.id -eq $Id) { return $f } }
    return $null
}

# Runs one memory command from lc-coach.ps1's $A; returns the exit code. A write that fails throws (the
# caller prints it and exits 1), so a confirmation line is printed only after the file is saved.
function Invoke-LcCoachMemory([hashtable]$A) {
    $local = Join-Path $A.JourneyRoot 'local'
    $now = $A.Now
    $stamp = Format-LcStamp $now
    switch ($A.Command) {
        'remember' {
            $text = ($A.Text -replace '\s+', ' ').Trim()
            if ($A.Kind -notin $script:LcMemoryKinds) { Write-Host "Kind must be one of: $($script:LcMemoryKinds -join ', ')"; return 1 }
            if ($text.Length -lt 1 -or $text.Length -gt 300) { Write-Host 'Text must be 1-300 characters'; return 1 }
            if ($A.Until) {
                $u = [datetime]::MinValue
                if ($A.Until -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($A.Until, 'yyyy-MM-dd',
                        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$u)) {
                    Write-Host 'Until must be a real date, yyyy-MM-dd'; return 1
                }
            }
            $ev = @(foreach ($e in @($A.Evidence)) { foreach ($p in ([string]$e).Split(',')) { if ($p.Trim()) { $p.Trim() } } })
            $lk = Enter-LcMemoryLock $local
            try {
                $store = Read-LcMemoryStore $local
                $facts = $store.Facts.ToArray()
                $aged = Update-LcMemoryAge $facts $now
                if ($A.Replaces -and -not (Find-LcFact $facts $A.Replaces)) { Write-Host "No fact $($A.Replaces)"; return 1 }
                $r = Add-LcMemoryFact $facts $A.Kind $text $ev $A.Source $A.Until $A.Replaces $now
                if ($r.Result -eq 'dismissed-before') {
                    if ($aged) { Save-LcMemory $local $facts $store.Keep }
                    Write-Host "dismissed before: $($r.Id) (not saved)"; return 0
                }
                Save-LcMemory $local $r.Facts $store.Keep
            } finally { $lk.Dispose() }
            Write-Host "$($r.Result) $($r.Id)"
            return 0
        }
        { $_ -in @('forget', 'edit', 'resolve') } {
            if ($A.Command -eq 'edit') {
                $text = ($A.Text -replace '\s+', ' ').Trim()
                if ($text.Length -lt 1 -or $text.Length -gt 300) { Write-Host 'Text must be 1-300 characters'; return 1 }
            }
            $lk = Enter-LcMemoryLock $local
            try {
                $store = Read-LcMemoryStore $local
                $facts = $store.Facts.ToArray()
                [void](Update-LcMemoryAge $facts $now)
                $f = Find-LcFact $facts $A.Id
                if (-not $f) { Write-Host "No fact '$($A.Id)'"; return 1 }
                if ($A.Command -eq 'forget') { $f.status = 'dismissed'; $f.evidence = @(); $f.updated = $stamp; $msg = 'forgot' }
                elseif ($A.Command -eq 'resolve') { $f.status = 'resolved'; $f.updated = $stamp; $msg = 'resolved' }
                else {
                    # last_seen too, or the next read ages an old habit straight back to improving or resolved.
                    $f.text = $text; $f.source = 'user'; $f.status = 'active'; $f.updated = $stamp; $f.last_seen = $stamp
                    $f.Remove('until'); $msg = 'edited'
                }
                Save-LcMemory $local $facts $store.Keep
            } finally { $lk.Dispose() }
            Write-Host "$msg $($f.id)"
            return 0
        }
        'memory' {
            $lines = @(Format-LcMemory (Read-LcMemory $local $now))
            if ($lines.Count) { $lines | ForEach-Object { Write-Host $_ } } else { Write-Host 'no live facts' }
            return 0
        }
        'read' {
            if (-not $A.Slug) { Write-Host 'read needs -Slug'; return 1 }
            $solved = @(Read-LcEvents $A.JourneyRoot -Slug $A.Slug | Where-Object { $_.event -eq 'solved' })
            if (-not $solved.Count) { Write-Host "No solved event for $($A.Slug)"; return 1 }
            $lk = Enter-LcMemoryLock $local
            try {
                $read = Read-LcCoachStateFile $local
                $read[$A.Slug] = [string]$solved[-1].src_hash
                Write-LcFileAtomic (Get-LcCoachStatePath $local) (ConvertTo-Json ([ordered]@{ read = $read }) -Compress -Depth 4)
            } finally { $lk.Dispose() }
            Write-Host "recorded read: $($A.Slug)"
            return 0
        }
        'weekly' {
            if (-not $A.Text.Trim()) { Write-Host 'weekly needs -Text'; return 1 }
            $monday = $now.Date.AddDays(-((([int]$now.DayOfWeek) + 6) % 7))
            $dir = Join-Path $local 'weekly'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $name = $monday.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            Write-LcFileAtomic (Join-Path $dir "$name.md") $A.Text
            Write-Host "saved weekly: $name"
            return 0
        }
    }
    Write-Host "Unknown command: $($A.Command)"
    return 1
}
