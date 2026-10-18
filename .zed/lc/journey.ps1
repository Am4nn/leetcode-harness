# Journey: event log, attempts, snapshots, journey.md, solve commit.
# Function library: dot-source it. No side effects, no output.

function New-LcUtf8 { New-Object Text.UTF8Encoding $false }

function Get-LcNow { Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz' }

function Get-LcSrcHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
    return [BitConverter]::ToString($bytes, 0, 6).Replace('-', '').ToLowerInvariant()
}

# -PassThru returns the event as an object shaped like Read-LcEvents' (callers can keep a list in memory).
function Write-LcEvent([string]$Root, [string]$Event, [string]$Slug, [string]$File, [string]$SrcHash,
                       [Collections.IDictionary]$Data = @{}, [string]$Ts = '', [switch]$PassThru) {
    if (-not $Ts) { $Ts = Get-LcNow }
    $o = [ordered]@{ ts = $Ts; event = $Event; slug = $Slug; file = $File; src_hash = $SrcHash }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    $line = ($o | ConvertTo-Json -Compress -Depth 8) + "`n"
    if (-not [IO.Directory]::Exists($Root)) { New-Item -ItemType Directory -Force $Root | Out-Null }
    $p = Join-Path $Root 'events.jsonl'
    if ([IO.File]::Exists($p)) {
        # A line cut short by a crash must not swallow this one.
        $fs = [IO.File]::OpenRead($p)
        try { if ($fs.Length -gt 0) { [void]$fs.Seek(-1, 'End'); if ($fs.ReadByte() -ne 10) { $line = "`n" + $line } } }
        finally { $fs.Dispose() }
    }
    [IO.File]::AppendAllText($p, $line, (New-LcUtf8))
    if ($PassThru) { return [pscustomobject]$o }
}

# -Slug: only that slug's events. A plain text search picks its lines first, so a run's cost stays
# small as the log grows. Parsing is one ConvertFrom-Json call; if any line is malformed (a write cut
# short by a crash), it parses line by line and skips the bad ones.
function Read-LcEvents([string]$Root, [string]$Slug = '') {
    $p = Join-Path $Root 'events.jsonl'
    if (-not [IO.File]::Exists($p)) { return @() }
    $text = [IO.File]::ReadAllText($p, (New-LcUtf8))
    if ($Slug) {
        # The field as the writer encodes it (ConvertTo-Json only for names it would escape).
        if ($Slug -match '^[A-Za-z0-9 ._-]+$') { $needle = '"slug":"' + $Slug + '",' }
        else { $needle = '"slug":' + (ConvertTo-Json $Slug -Compress) + ',' }
        $lines = New-Object Collections.Generic.List[string]
        $i = $text.IndexOf($needle, [StringComparison]::Ordinal)
        while ($i -ge 0) {
            $start = $text.LastIndexOf("`n", $i) + 1
            $end = $text.IndexOf("`n", $i)
            if ($end -lt 0) { $end = $text.Length }
            $lines.Add($text.Substring($start, $end - $start).Trim())
            $i = $text.IndexOf($needle, $end, [StringComparison]::Ordinal)
        }
        $lines = @($lines.ToArray())
    } else {
        $lines = @(foreach ($l in $text.Split("`n")) { $t = $l.Trim(); if ($t) { $t } })
    }
    if (-not $lines.Count) { return @() }
    $out = $null
    try { $out = ('[' + ($lines -join ',') + ']') | ConvertFrom-Json } catch { }
    if ($null -eq $out) {
        $out = foreach ($l in $lines) {
            try { $o = $l | ConvertFrom-Json } catch { continue }
            if ($o -is [pscustomobject]) { $o }
        }
    }
    if ($Slug) { $out = foreach ($o in @($out)) { if ($o.slug -eq $Slug) { $o } } }
    return @($out)
}

# The fetch event's fields from a LeetCode question object.
function Get-LcFetchEventData($Question) {
    return [ordered]@{
        ok = $true; id = $Question.questionFrontendId; title = $Question.title; difficulty = $Question.difficulty
        tags = @($Question.topicTags | ForEach-Object { $_.name }); paid_only = [bool]$Question.isPaidOnly
    }
}

function Get-LcAttempts($Events, [string]$Slug) {
    $n = 0
    foreach ($e in @($Events)) {
        if ($e.slug -ne $Slug) { continue }
        if ($e.event -eq 'solved') { $n = 0 }
        elseif ($e.event -eq 'test_run') { $n++ }
    }
    return $n
}

function Test-LcSolvedBefore($Events, [string]$Slug, [string]$SrcHash) {
    foreach ($e in @($Events)) {
        if ($e.slug -eq $Slug -and $e.event -eq 'solved' -and $e.src_hash -eq $SrcHash) { return $true }
    }
    return $false
}

# Writes an accepted event for each of LeetCode's accepts ($List: @{ Slug; Time } with Time in unix
# seconds) when the slug already has events, the accept is at or after its first event, and no accepted
# event has the same submitted_at. file and src_hash come from the slug's latest event.
# Returns the new events (shaped like Read-LcEvents').
function Add-LcAcceptedEvents([string]$Root, $List) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $bySlug = [ordered]@{}
    foreach ($a in @($List | Sort-Object { [long]$_.Time })) {
        if (-not $a -or -not $a.Slug) { continue }
        if (-not $bySlug.Contains($a.Slug)) { $bySlug[$a.Slug] = New-Object Collections.ArrayList }
        [void]$bySlug[$a.Slug].Add([long]$a.Time)
    }
    $new = New-Object Collections.ArrayList
    foreach ($slug in @($bySlug.Keys)) {
        $mine = @(Read-LcEvents $Root -Slug $slug)
        if (-not $mine.Count) { continue }
        try { $first = [DateTimeOffset]::Parse([string]$mine[0].ts, $inv).ToUnixTimeSeconds() } catch { continue }
        $have = New-Object Collections.Generic.HashSet[long]
        foreach ($e in $mine) {
            if ($e.event -ne 'accepted' -or -not $e.submitted_at) { continue }
            try { [void]$have.Add([DateTimeOffset]::Parse([string]$e.submitted_at, $inv).ToUnixTimeSeconds()) } catch { }
        }
        $last = $mine[-1]
        foreach ($t in $bySlug[$slug]) {
            if ($t -lt $first -or -not $have.Add($t)) { continue }
            $at = [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString('yyyy-MM-ddTHH:mm:sszzz', $inv)
            [void]$new.Add((Write-LcEvent -Root $Root -Event accepted -Slug $slug -File ([string]$last.file) -SrcHash ([string]$last.src_hash) `
                -Data ([ordered]@{ submitted_at = $at }) -PassThru))
        }
    }
    return @($new.ToArray())
}

function Save-LcSnapshot([string]$Root, [string]$Slug, [string]$SrcPath, [string]$SrcHash, [string]$Ts = '') {
    if (-not $Ts) { $Ts = Get-LcNow }
    $dir = Join-Path (Join-Path $Root 'snapshots') $Slug
    $lastFile = Join-Path $dir '.last-hash'
    if ((Test-Path -LiteralPath $lastFile) -and
        ([IO.File]::ReadAllText($lastFile).Trim() -eq $SrcHash)) { return $null }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $stamp = ($Ts.Substring(0, [Math]::Min(19, $Ts.Length)) -replace '[-:]', '') -replace 'T', '-'
    $dest = Join-Path $dir "$stamp.cpp"
    Copy-Item -LiteralPath $SrcPath -Destination $dest -Force
    [IO.File]::WriteAllText($lastFile, $SrcHash, (New-LcUtf8))
    return $dest
}

# One pass over the events: per slug (in order of first event), what its journey.md row needs.
function Get-LcJourneyState($Events) {
    $by = [ordered]@{}
    foreach ($e in @($Events)) {
        $slug = [string]$e.slug
        $r = $by[$slug]
        if ($null -eq $r) { $r = @{ Runs = 0; Since = 0; Solved = $null; Accepted = $false; Cx = ''; Note = ''; Fetch = $null }; $by[$slug] = $r }
        switch ([string]$e.event) {
            'test_run'    { $r.Runs++; $r.Since++ }
            'solved'      { $r.Since = 0; if ($null -eq $r.Solved) { $r.Solved = $e } }
            'accepted'    { $r.Accepted = $true }
            'analyze_run' { if ($e.complexity) { $r.Cx = [string]$e.complexity } }  # a failed analyze has none
            'note'        { $r.Note = [string]$e.text }
            'fetch'       { if ($e.ok -eq $true) { $r.Fetch = $e } }
        }
    }
    return $by
}

# One journey.md row, or $null for a slug without a test_run.
function Format-LcJourneyRow([string]$Slug, $State, [string]$MetaDir) {
    $r = $State
    if (-not $r -or -not $r.Runs) { return $null }
    $date = '-'; $maxTime = ''; $attempts = $r.Since
    if ($r.Solved) {
        $date = ([string]$r.Solved.ts).Substring(0, 10)
        $attempts = $r.Solved.attempts
        $maxTime = ('{0} ms' -f ([double]$r.Solved.max_ms).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture))
    }
    $id = ''; $title = $Slug; $diff = ''; $tags = ''
    $q = $r.Fetch
    if (-not $q) {
        $mp = Join-Path $MetaDir "$Slug.json"
        if ([IO.File]::Exists($mp)) {
            try {
                $j = [IO.File]::ReadAllText($mp, (New-LcUtf8)) | ConvertFrom-Json
                if ($j.data -and $j.data.question) { $j = $j.data.question }
                $q = [pscustomobject]@{
                    id = $j.questionFrontendId; title = $j.title; difficulty = $j.difficulty
                    tags = @($j.topicTags | ForEach-Object { if ($_.name) { $_.name } else { $_ } })
                }
            } catch { $q = $null }
        }
    }
    if ($q) {
        if ($q.id) { $id = [string]$q.id }
        if ($q.title) { $title = [string]$q.title }
        if ($q.difficulty) { $diff = [string]$q.difficulty }
        if ($q.tags) { $tags = (@($q.tags) -join ', ') }
    }
    $esc = { param($s) ([string]$s) -replace '\|', '\|' -replace "[\r\n]+", ' ' }
    # Status: LeetCode accepted it, else every local case passed once, else only tried.
    $status = 'attempted'
    if ($r.Accepted) { $status = 'accepted' } elseif ($r.Solved) { $status = 'passed locally' }
    return '| {0} | {1} | [{2}](https://leetcode.com/problems/{3}/) | {4} | {5} | {6} | {7} | {8} | {9} | {10} |' -f `
        $date, $id, (& $esc $title), $Slug, $status, $diff, (& $esc $tags), (& $esc $r.Cx), $maxTime, $attempts, (& $esc $r.Note)
}

# Regenerates journey.md from the events (-Events: the list when the caller already has it).
# -Slug: only that slug's events changed, so only its row is rebuilt (in place, or appended when new);
# -Events then needs only that slug's events. With no usable journey.md yet, it regenerates everything.
function Update-LcJourneyFile([string]$Root, [string]$MetaDir = '', $Events = $null, [string]$Slug = '') {
    if (-not $MetaDir) { $MetaDir = Join-Path $Root 'problems' }
    $header = @('| Date | # | Problem | Status | Difficulty | Tags | Complexity | Max time | Attempts | Note |',
                '|---|---|---|---|---|---|---|---|---|---|')
    $md = Join-Path $Root 'journey.md'
    $lines = New-Object Collections.Generic.List[string]
    $old = $null
    if ($Slug -and [IO.File]::Exists($md)) { $old = [IO.File]::ReadAllLines($md, (New-LcUtf8)) }
    if ($old -and $old.Count -ge 2 -and $old[0] -eq $header[0] -and $old[1] -eq $header[1]) {
        if ($null -eq $Events) { $Events = Read-LcEvents $Root -Slug $Slug }
        $mine = @(foreach ($e in @($Events)) { if ($e.slug -eq $Slug) { $e } })
        $st = Get-LcJourneyState $mine
        $row = Format-LcJourneyRow $Slug $st[$Slug] $MetaDir
        $link = "](https://leetcode.com/problems/$Slug/) |"
        $placed = $false
        foreach ($l in $old) {
            if (-not $l.Contains($link)) { $lines.Add($l); continue }
            if ($row -and -not $placed) { $lines.Add($row); $placed = $true }
        }
        if ($row -and -not $placed) { $lines.Add($row) }
    } else {
        if ($null -eq $Events -or $Slug) { $Events = Read-LcEvents $Root }
        foreach ($h in $header) { $lines.Add($h) }
        $state = Get-LcJourneyState $Events
        foreach ($s in @($state.Keys)) {
            $row = Format-LcJourneyRow $s $state[$s] $MetaDir
            if ($row) { $lines.Add($row) }
        }
    }
    if (-not [IO.Directory]::Exists($Root)) { New-Item -ItemType Directory -Force $Root | Out-Null }
    [IO.File]::WriteAllText($md, (($lines -join "`n") + "`n"), (New-LcUtf8))
}

# git's first meaningful output line. "$_" gives a stderr record's bare text (Out-String would add
# PS 5.1's "git.exe : " and position lines); warning:/hint: lines are skipped.
function Get-LcGitReason($Output) {
    foreach ($l in @($Output | ForEach-Object { "$_" -split '\r?\n' })) {
        $t = ($l -replace '^git(\.exe)?\s*:\s*', '').Trim()
        if ($t -and $t -notmatch '^(warning|hint):') { return $t }
    }
    return 'git failed'
}

# Commits only the given paths (inside the repo holding RepoDir); never pushes. Prints nothing.
# Returns $true when it committed, $false when there was nothing to commit, and the reason
# (a string) when it could not commit: not a git repo, or git failed.
function Invoke-LcSolveCommit([string]$RepoDir, [string[]]$Paths, [string]$Message) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $top = (& git -C $RepoDir rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $top) { return 'not a git repo' }
        $topFull = [IO.Path]::GetFullPath($top.Replace('/', '\')).TrimEnd('\') + '\'
        $inside = @()
        foreach ($p in $Paths) {
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
            $full = [IO.Path]::GetFullPath($p)
            if (($full.TrimEnd('\') + '\').StartsWith($topFull, [StringComparison]::OrdinalIgnoreCase)) { $inside += $full }
        }
        if (-not $inside.Count) { return $false }
        $r = @(& git -C $top add -- @inside 2>&1)
        if ($LASTEXITCODE -ne 0) { return [string](Get-LcGitReason $r) }
        & git -C $top diff --cached --quiet -- @inside 2>$null
        if ($LASTEXITCODE -eq 0) { return $false }
        $r = @(& git -C $top commit -m $Message -- @inside 2>&1)
        if ($LASTEXITCODE -ne 0) { return [string](Get-LcGitReason $r) }
        return $true
    } finally { $ErrorActionPreference = $old }
}
