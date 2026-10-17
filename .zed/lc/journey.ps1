# Journey: event log, attempts, snapshots, journey.md, solve commit.
# Function library: dot-source it. No side effects, no output (except Invoke-LcSolveCommit's failure line).

function New-LcUtf8 { New-Object Text.UTF8Encoding $false }

function Get-LcNow { Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz' }

function Get-LcSrcHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

function Write-LcEvent([string]$Root, [string]$Event, [string]$Slug, [string]$File, [string]$SrcHash,
                       [hashtable]$Data = @{}, [string]$Ts = '') {
    if (-not $Ts) { $Ts = Get-LcNow }
    $o = [ordered]@{ ts = $Ts; event = $Event; slug = $Slug; file = $File; src_hash = $SrcHash }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    $line = ($o | ConvertTo-Json -Compress -Depth 8) + "`n"
    New-Item -ItemType Directory -Force $Root | Out-Null
    [IO.File]::AppendAllText((Join-Path $Root 'events.jsonl'), $line, (New-LcUtf8))
}

function Read-LcEvents([string]$Root) {
    $p = Join-Path $Root 'events.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $out = @()
    foreach ($l in [IO.File]::ReadAllLines($p, (New-LcUtf8))) {
        if ($l.Trim()) { $out += ($l | ConvertFrom-Json) }
    }
    return $out
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

function Update-LcJourneyFile([string]$Root, [string]$MetaDir = '') {
    if (-not $MetaDir) { $MetaDir = Join-Path (Split-Path -Parent $Root) 'leetcode-solves\tests\.meta' }
    $events = @(Read-LcEvents $Root)
    $slugs = @()
    foreach ($e in $events) { if ($slugs -notcontains $e.slug) { $slugs += $e.slug } }
    $rows = @()
    foreach ($slug in $slugs) {
        $mine = @($events | Where-Object { $_.slug -eq $slug })
        if (-not ($mine | Where-Object { $_.event -eq 'test_run' })) { continue }
        $solved = @($mine | Where-Object { $_.event -eq 'solved' })
        $date = '-'; $maxTime = ''; $attempts = Get-LcAttempts $events $slug
        if ($solved.Count) {
            $date = ([string]$solved[0].ts).Substring(0, 10)
            $attempts = $solved[0].attempts
            $maxTime = ('{0} ms' -f ([double]$solved[0].max_ms).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture))
        }
        $an = @($mine | Where-Object { $_.event -eq 'analyze_run' })
        $cx = ''; if ($an.Count) { $cx = [string]$an[-1].complexity }
        $notes = @($mine | Where-Object { $_.event -eq 'note' })
        $note = ''; if ($notes.Count) { $note = [string]$notes[-1].text }

        $id = ''; $title = $slug; $diff = ''; $tags = ''
        $fetch = @($mine | Where-Object { $_.event -eq 'fetch' -and $_.ok -eq $true })
        $q = $null
        if ($fetch.Count) { $q = $fetch[-1] }
        else {
            $mp = Join-Path $MetaDir "$slug.json"
            if (Test-Path -LiteralPath $mp) {
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
        $rows += '| {0} | {1} | [{2}](https://leetcode.com/problems/{3}/) | {4} | {5} | {6} | {7} | {8} | {9} |' -f `
            $date, $id, (& $esc $title), $slug, $diff, (& $esc $tags), (& $esc $cx), $maxTime, $attempts, (& $esc $note)
    }
    $lines = @('| Date | # | Problem | Difficulty | Tags | Complexity | Max time | Attempts | Note |',
               '|---|---|---|---|---|---|---|---|---|') + $rows
    New-Item -ItemType Directory -Force $Root | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'journey.md'), (($lines -join "`n") + "`n"), (New-LcUtf8))
}

function Invoke-LcSolveCommit([string]$RepoDir, [string[]]$Paths, [string]$Message) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $top = (& git -C $RepoDir rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $top) { Write-Host '(not committed: not a git repo)'; return $false }
        $topFull = [IO.Path]::GetFullPath($top.Replace('/', '\')).TrimEnd('\') + '\'
        $inside = @()
        foreach ($p in $Paths) {
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
            $full = [IO.Path]::GetFullPath($p)
            if (($full.TrimEnd('\') + '\').StartsWith($topFull, [StringComparison]::OrdinalIgnoreCase)) { $inside += $full }
        }
        if (-not $inside.Count) { return $false }
        $r = (& git -C $top add -- @inside 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { Write-Host ('(not committed: ' + ($r -split "`n")[0].Trim() + ')'); return $false }
        & git -C $top diff --cached --quiet -- @inside 2>$null
        if ($LASTEXITCODE -eq 0) { return $false }
        $r = (& git -C $top commit -m $Message -- @inside 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { Write-Host ('(not committed: ' + ($r -split "`n")[0].Trim() + ')'); return $false }
        return $true
    } finally { $ErrorActionPreference = $old }
}
