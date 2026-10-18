# Coach memory (docs/2026-10-18-coach-design.md): the local fact store in <journey>/local/ and the
# lc-coach.ps1 commands that use it. Function library: dot-source it after journey.ps1. No side effects.
# Facts are ordered hashtables: id, kind, text, evidence (@{slug; ref}), status, source, created, updated,
# last_seen, until (optional).

$script:LcMemoryKinds = @('habit', 'strength', 'style', 'goal', 'preference', 'context')
$script:LcMemoryStatuses = @('active', 'improving', 'resolved', 'dismissed')

function Get-LcMemoryKey([string]$Text) {
    return ([regex]::Replace($Text.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', ' ')).Trim()
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
    $stamp = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
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

# Writes the whole store (one compact JSON object per line).
function Save-LcMemory([string]$LocalDir, $Facts) {
    if (-not [IO.Directory]::Exists($LocalDir)) { New-Item -ItemType Directory -Force $LocalDir | Out-Null }
    $sb = New-Object Text.StringBuilder
    foreach ($f in @($Facts)) { [void]$sb.Append((ConvertTo-Json $f -Compress -Depth 6)).Append("`n") }
    [IO.File]::WriteAllText((Join-Path $LocalDir 'memory.jsonl'), $sb.ToString(), (New-LcUtf8))
}

# Every fact in the store, aged; saves when ageing changed something. A malformed line is skipped.
function Read-LcMemory([string]$LocalDir, [datetime]$Now = (Get-Date)) {
    $p = Join-Path $LocalDir 'memory.jsonl'
    if (-not [IO.File]::Exists($p)) { return @() }
    $facts = New-Object Collections.ArrayList
    foreach ($l in [IO.File]::ReadAllLines($p, (New-LcUtf8))) {
        if (-not $l.Trim()) { continue }
        $o = $null
        try { $o = $l | ConvertFrom-Json } catch { continue }
        $f = ConvertTo-LcFact $o
        if ($f) { [void]$facts.Add($f) }
    }
    $out = $facts.ToArray()
    if (Update-LcMemoryAge $out $Now) { Save-LcMemory $LocalDir $out }
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

# Saves a fact into $Facts (the caller saves the store). Result: saved, seen (a live fact has this text:
# evidence added, status back to active) or dismissed-before (nothing changed). -Replaces resolves the old fact.
function Add-LcMemoryFact($Facts, [string]$Kind, [string]$Text, [string[]]$Evidence, [string]$Source, [string]$Until, [string]$Replaces, [datetime]$Now) {
    $stamp = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $Text = ($Text -replace '\s+', ' ').Trim()
    $key = Get-LcMemoryKey $Text
    $ev = @(foreach ($e in @($Evidence)) { if ($e -and $e.Trim()) { ConvertTo-LcEvidence $e } })
    if (-not $ev.Count) { $ev = @([ordered]@{ slug = ''; ref = 'chat' }) }
    $list = New-Object Collections.ArrayList
    foreach ($f in @($Facts)) { [void]$list.Add($f) }
    $live = $null; $dismissed = $null
    foreach ($f in $list) {
        if ((Get-LcMemoryKey $f.text) -ne $key) { continue }
        if ($f.status -in @('active', 'improving')) { $live = $f } elseif ($f.status -eq 'dismissed') { $dismissed = $f }
    }
    if ($live) {
        $live.evidence = @(@($live.evidence) + $ev | Select-Object -Last 20)
        $live.last_seen = $stamp; $live.updated = $stamp; $live.status = 'active'
        return @{ Facts = $list.ToArray(); Result = 'seen'; Id = $live.id }
    }
    if ($dismissed) { return @{ Facts = $list.ToArray(); Result = 'dismissed-before'; Id = $dismissed.id } }
    $f = [ordered]@{
        id = New-LcMemoryId $list; kind = $Kind; text = $Text; evidence = @($ev | Select-Object -Last 20)
        status = 'active'; source = $Source; created = $stamp; updated = $stamp; last_seen = $stamp
    }
    if ($Until) { $f['until'] = $Until }
    if ($Replaces) {
        foreach ($o in $list) { if ($o.id -eq $Replaces) { $o.status = 'resolved'; $o.updated = $stamp } }
    }
    [void]$list.Add($f)
    return @{ Facts = $list.ToArray(); Result = 'saved'; Id = $f.id }
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

# slug -> src_hash the coach has read, from coach-state.json (empty when missing or unreadable).
function Get-LcCoachRead([string]$LocalDir) {
    $read = [ordered]@{}
    $p = Get-LcCoachStatePath $LocalDir
    if (-not [IO.File]::Exists($p)) { return $read }
    try {
        $o = [IO.File]::ReadAllText($p, (New-LcUtf8)) | ConvertFrom-Json
        if ($o.read) { foreach ($m in $o.read.PSObject.Properties) { $read[$m.Name] = [string]$m.Value } }
    } catch { }
    return $read
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

# Runs one memory command from lc-coach.ps1's $A; returns the exit code.
function Invoke-LcCoachMemory([hashtable]$A) {
    $local = Join-Path $A.JourneyRoot 'local'
    $now = $A.Now
    $stamp = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    switch ($A.Command) {
        'remember' {
            $text = ($A.Text -replace '\s+', ' ').Trim()
            if ($A.Kind -notin $script:LcMemoryKinds) { Write-Host "Kind must be one of: $($script:LcMemoryKinds -join ', ')"; return 1 }
            if ($text.Length -lt 1 -or $text.Length -gt 300) { Write-Host 'Text must be 1-300 characters'; return 1 }
            if ($A.Until -and $A.Until -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host 'Until must be yyyy-MM-dd'; return 1 }
            $facts = @(Read-LcMemory $local $now)
            if ($A.Replaces -and -not (Find-LcFact $facts $A.Replaces)) { Write-Host "No fact $($A.Replaces)"; return 1 }
            $ev = @(foreach ($e in @($A.Evidence)) { foreach ($p in ([string]$e).Split(',')) { if ($p.Trim()) { $p.Trim() } } })
            $r = Add-LcMemoryFact $facts $A.Kind $text $ev $A.Source $A.Until $A.Replaces $now
            if ($r.Result -eq 'dismissed-before') { Write-Host "dismissed before: $($r.Id) (not saved)"; return 0 }
            Save-LcMemory $local $r.Facts
            Write-Host "$($r.Result) $($r.Id)"
            return 0
        }
        { $_ -in @('forget', 'edit', 'resolve') } {
            $facts = @(Read-LcMemory $local $now)
            $f = Find-LcFact $facts $A.Id
            if (-not $f) { Write-Host "No fact '$($A.Id)'"; return 1 }
            if ($A.Command -eq 'forget') { $f.status = 'dismissed'; $f.evidence = @(); $f.updated = $stamp; $msg = 'forgot' }
            elseif ($A.Command -eq 'resolve') { $f.status = 'resolved'; $f.updated = $stamp; $msg = 'resolved' }
            else {
                $text = ($A.Text -replace '\s+', ' ').Trim()
                if ($text.Length -lt 1 -or $text.Length -gt 300) { Write-Host 'Text must be 1-300 characters'; return 1 }
                $f.text = $text; $f.source = 'user'; $f.status = 'active'; $f.updated = $stamp; $f.Remove('until'); $msg = 'edited'
            }
            Save-LcMemory $local $facts
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
            $read = Get-LcCoachRead $local
            $read[$A.Slug] = [string]$solved[-1].src_hash
            if (-not [IO.Directory]::Exists($local)) { New-Item -ItemType Directory -Force $local | Out-Null }
            [IO.File]::WriteAllText((Get-LcCoachStatePath $local), (ConvertTo-Json ([ordered]@{ read = $read }) -Compress -Depth 4), (New-LcUtf8))
            Write-Host "recorded read: $($A.Slug)"
            return 0
        }
        'weekly' {
            if (-not $A.Text.Trim()) { Write-Host 'weekly needs -Text'; return 1 }
            $monday = $now.Date.AddDays(-((([int]$now.DayOfWeek) + 6) % 7))
            $dir = Join-Path $local 'weekly'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $name = $monday.ToString('yyyy-MM-dd')
            [IO.File]::WriteAllText((Join-Path $dir "$name.md"), $A.Text, (New-LcUtf8))
            Write-Host "saved weekly: $name"
            return 0
        }
    }
    Write-Host "Unknown command: $($A.Command)"
    return 1
}
