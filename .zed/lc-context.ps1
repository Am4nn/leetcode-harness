# What a coding agent needs before answering about my code: a logged run (.zed/lc/runlog.ps1) with its
# key, file and terminal output, the file's source now with line numbers and what changed since that run,
# the problem's cases and its journey, plus the coach's memory and the solves it hasn't read. Changes nothing
# except that reading memory writes back facts that have aged (habits unseen for 14+ days, passed until dates).
#   (no args)      the file I'm working on: the newest .cpp I saved, when that's newer than the latest run
#                  (with its own latest run, if it has one); else the latest run
#   -Run 2         the run before it (1 = latest)
#   -File <slug>   only runs of that file (a path or a slug)
#   -List 10       the newest 10 runs, one line each
#   -Full          the whole output (by default a long one keeps its first 40 and last 80 lines)
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Run = 1,
    [string]$File = '',
    [int]$List = 0,
    [switch]$Full,
    [string]$JourneyRoot = '',  # default <dsa>/journey
    [string]$CasesRoot = '',    # default <dsa>/cases
    [string]$UserRoot = ''      # where my .cpp files are looked for (default <dsa>; self-tests use a temp folder)
)

. (Join-Path $PSScriptRoot 'lc\journey.ps1')
. (Join-Path $PSScriptRoot 'lc\runlog.ps1')
. (Join-Path $PSScriptRoot 'lc\memory.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
if (-not $CasesRoot) { $CasesRoot = Join-Path $dsaRoot 'cases' }
if (-not $UserRoot) { $UserRoot = $dsaRoot }
$utf8 = New-Object Text.UTF8Encoding $false
# An agent reads this through a pipe, which PowerShell would encode in the OEM code page (a console gets
# Unicode either way, and setting it there would change the console's code page after we exit).
if ([Console]::IsOutputRedirected) { try { [Console]::OutputEncoding = $utf8 } catch {} }  # throws with no console
$keys = 'f7|shift-f7|ctrl-f7|alt-f7|alt-f8'

# A log's lines. Shared read: the run's terminal holds its log open for writing until it closes.
function Read-LcRunLines([string]$Path, [switch]$HeadOnly) {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $sr = New-Object IO.StreamReader($fs, $utf8)
    try {
        while ($null -ne ($l = $sr.ReadLine())) {
            $l
            if ($HeadOnly -and $l -eq '----') { break }
        }
    } finally { $sr.Dispose() }
}

# A run log as @{ Path; Head = @{ time; key; file; source; command }; Body = [string[]] }.
# -HeadOnly: just the header (Body is empty).
function Read-LcRun([string]$Path, [switch]$HeadOnly) {
    $head = @{}
    $body = New-Object Collections.Generic.List[string]
    $inBody = $false
    foreach ($l in @(Read-LcRunLines $Path -HeadOnly:$HeadOnly)) {
        if ($inBody) { $body.Add($l.TrimEnd("`r")) }
        elseif ($l -eq '----') { $inBody = $true }
        elseif ($l -match '^(\w+): (.*)$') { $head[$Matches[1]] = $Matches[2] }
    }
    return @{ Path = $Path; Head = $head; Body = [string[]]$body.ToArray() }
}

# The line that sums a run up: its last line that isn't a closing prompt.
function Get-LcRunResult($R) {
    for ($i = $R.Body.Count - 1; $i -ge 0; $i--) {
        $l = $R.Body[$i].Trim()
        if ($l -and $l -notmatch '^(Press Enter to close|Note \(Enter to skip\):|LeetCode accepted:)') { return $l }
    }
    return '(no output)'
}

function Format-LcAgo([datetime]$T) {
    $m = [int]((Get-Date) - $T).TotalMinutes
    if ($m -lt 1) { return 'just now' }
    if ($m -lt 60) { return "$m min ago" }
    if ($m -lt 48 * 60) { return "$([int]($m / 60)) h ago" }
    return "$([int]($m / 1440)) days ago"
}

function Get-LcRunTime($R) { return [datetime]::Parse($R.Head.time, [Globalization.CultureInfo]::InvariantCulture) }

# When the run started, to the millisecond (from its id), to compare with file save times.
function Get-LcRunStart($R) {
    return [datetime]::ParseExact((Split-Path -Leaf $R.Path).Substring(0, 19), 'yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-LcRunFile([string]$Name) {
    if ([IO.Path]::IsPathRooted($Name)) { return $Name }
    return Join-Path $dsaRoot $Name
}

# My .cpp files, newest saved first: the ones directly in $UserRoot and in folders under it, minus the
# harness's own folders and hidden ones (.claude holds agents' worktrees, with copies of my files).
function Get-LcUserCpp {
    $skip = @('build', 'journey', 'lc', 'cases', 'docs')
    $runsDir = $runsRoot.TrimEnd('\') + '\'
    $top = @(Get-ChildItem -LiteralPath $UserRoot -Filter '*.cpp' -File -ErrorAction SilentlyContinue)
    $inDirs = @(Get-ChildItem -LiteralPath $UserRoot -Directory | Where-Object { $_.Name -notin $skip -and -not $_.Name.StartsWith('.') } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter '*.cpp' -File -ErrorAction SilentlyContinue })
    return @(@($top) + @($inDirs) | Where-Object { -not $_.FullName.StartsWith($runsDir, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object LastWriteTime -Descending)
}

# The runs of files named <slug>.cpp. The log name alone is ambiguous (<stamp>-a-shift-f7 is a Shift+F7 run
# of a.cpp or an F7 run of a-shift.cpp), so the header's file decides.
function Get-LcSlugLogs($Logs, [string]$Slug) {
    $named = @($Logs | Where-Object { $_.Name -match ('^\d{8}-\d{6}-\d{3}-' + [regex]::Escape($Slug) + "-($keys)\.log$") })
    return @($named | Where-Object {
        $f = (Read-LcRun $_.FullName -HeadOnly).Head.file
        $f -and [IO.Path]::GetFileNameWithoutExtension($f) -eq $Slug
    })
}

function Write-LcNumbered([string]$Text) {
    $n = 0
    foreach ($l in $Text.Replace("`r", '').Split("`n")) { $n++; '{0,4}  {1}' -f $n, $l }
}

# The run's header and output.
function Write-LcRun($R, [string]$Title) {
    $t = Get-LcRunTime $R
    "== ${Title}: $($R.Head.key) on $($R.Head.file), $($t.ToString('yyyy-MM-dd HH:mm:ss')) ($(Format-LcAgo $t))"
    "command: $($R.Head.command)"
    ''
    '== Output (line numbers in it refer to the source as it was run)'
    $n = $R.Body.Count
    while ($n -gt 0 -and -not $R.Body[$n - 1].Trim()) { $n-- }  # trailing blank lines
    $body = if ($n) { @($R.Body[0..($n - 1)]) } else { @() }
    if (-not $Full -and $body.Count -gt 130) {
        $body[0..39]
        "... ($($body.Count - 120) lines cut; -Full shows them) ..."
        $body[($body.Count - 80)..($body.Count - 1)]
    } else { $body }
    ''
}

# The source now with line numbers; with $R, whether and how it changed since that run.
function Write-LcSource([string]$SrcPath, $R) {
    $name = Get-LcRunFileName $SrcPath
    $runCopy = if ($R) { Join-Path $runsRoot $R.Head.source } else { $null }
    if (-not (Test-Path -LiteralPath $SrcPath)) {
        "== $name no longer exists. The source as it was run:"
        if ($runCopy -and (Test-Path -LiteralPath $runCopy)) { Write-LcNumbered ([IO.File]::ReadAllText($runCopy)) }
        return
    }
    $now = [IO.File]::ReadAllText($SrcPath)
    if (-not $R) { "== Source now: $name"; Write-LcNumbered $now; return }
    $then = if (Test-Path -LiteralPath $runCopy) { [IO.File]::ReadAllText($runCopy) } else { $null }
    $state = if ($null -eq $then) { 'the copy from the run is gone' } elseif ($now -eq $then) { 'unchanged since the run' } else { 'edited since the run' }
    "== Source now: $name ($state)"
    Write-LcNumbered $now
    if ($null -ne $then -and $now -ne $then) {
        ''
        '== Changes since the run (- as run, + now)'
        # git prints the files' UTF-8 as is; PowerShell decodes it with [Console]::OutputEncoding.
        $enc = [Console]::OutputEncoding
        try {
            try { [Console]::OutputEncoding = $utf8 } catch {}
            $diff = & git -c core.autocrlf=false diff --no-index --no-color -U1 -- $runCopy $SrcPath 2>$null
        } finally { try { [Console]::OutputEncoding = $enc } catch {} }
        @($diff) | Where-Object { $_ -notmatch '^(diff --git|index |--- |\+\+\+ |old mode|new mode)' }
    }
}

function Write-LcProblem([string]$Slug) {
    ''
    $meta = Join-Path $JourneyRoot "problems\$Slug.json"
    if (Test-Path -LiteralPath $meta) {
        try {
            $q = [IO.File]::ReadAllText($meta, $utf8) | ConvertFrom-Json
            if ($q.data.question) { $q = $q.data.question }
            "== Problem: #$($q.questionFrontendId) $($q.title) ($($q.difficulty)); tags: $(@($q.topicTags | ForEach-Object { $_.name }) -join ', ')"
        } catch { "== Problem: $Slug" }
        "statement: $(Get-LcRunFileName $meta)"
    } else {
        "== Problem: https://leetcode.com/problems/$Slug/ (going by the file name; not fetched yet, Alt+F7 fetches it)"
    }
}

function Write-LcCases([string]$Slug) {
    $casesFile = Join-Path (Join-Path $CasesRoot $Slug) 'cases.txt'
    if (-not (Test-Path -LiteralPath $casesFile)) { return }
    ''
    "== Cases: $(Get-LcRunFileName $casesFile)"
    $c = @([IO.File]::ReadAllLines($casesFile, $utf8))
    if (-not $Full -and $c.Count -gt 60) { $c[0..59]; "... ($($c.Count - 60) more lines; -Full shows them)" } else { $c }
    $brute = Join-Path (Join-Path $CasesRoot $Slug) 'brute.cpp'
    if (Test-Path -LiteralPath $brute) { "(brute force: $(Get-LcRunFileName $brute))" }
}

function Write-LcJourney([string]$Slug) {
    $events = @(Read-LcEvents $JourneyRoot -Slug $Slug)
    if (-not $events.Count) { return }
    ''
    "== Journey: $Slug"
    $status = if (@($events | Where-Object { $_.event -eq 'accepted' }).Count) { 'accepted on LeetCode' }
              elseif (@($events | Where-Object { $_.event -eq 'solved' }).Count) { 'passed locally, not seen accepted on LeetCode' }
              else { 'attempted, never passed locally' }
    "status: $status; Alt+F7 runs: $(@($events | Where-Object { $_.event -eq 'test_run' }).Count)"
    $notes = @($events | Where-Object { $_.event -eq 'note' } | ForEach-Object { $_.text })
    if ($notes.Count) { "notes: $($notes -join ' | ')" }
    'last events:'
    foreach ($e in @($events | Select-Object -Last 6)) {
        $rest = [ordered]@{}
        foreach ($p in $e.PSObject.Properties) { if ($p.Name -notin @('ts', 'event', 'slug', 'file', 'src_hash', 'points')) { $rest[$p.Name] = $p.Value } }
        "  $($e.ts)  $($e.event)  $(ConvertTo-Json $rest -Compress -Depth 6)"
    }
}

$runsRoot = Get-LcRunsRoot
$allLogs = @()
if (Test-Path -LiteralPath $runsRoot) { $allLogs = @(Get-ChildItem -LiteralPath $runsRoot -Filter '*.log' | Sort-Object Name -Descending) }
$logs = $allLogs
if ($File) { $logs = Get-LcSlugLogs $allLogs ([IO.Path]::GetFileNameWithoutExtension($File)) }

if ($List -gt 0) {
    $i = 0
    foreach ($f in @($logs | Select-Object -First $List)) {
        $i++
        $r = Read-LcRun $f.FullName
        '{0,3}  {1}  {2,-8}  {3}  {4}' -f $i, ((Get-LcRunTime $r).ToString('yyyy-MM-dd HH:mm')), $r.Head.key, $r.Head.file, (Get-LcRunResult $r)
    }
    if ($i -eq 0) { 'No logged runs.' }
    exit 0
}

# With no -Run or -File: the newest .cpp I saved counts as what I'm working on when it's newer than the
# latest run and isn't that run's file (a new problem, not run yet, or an older one I went back to).
$working = $null
$latest = if ($allLogs.Count) { Read-LcRun $allLogs[0].FullName } else { $null }
if (-not $File -and -not $PSBoundParameters.ContainsKey('Run')) {
    $newest = @(Get-LcUserCpp | Select-Object -First 1)
    if ($newest.Count) {
        $f = $newest[0]
        if (-not $latest -or ($f.LastWriteTime -gt (Get-LcRunStart $latest) -and $f.FullName -ne (Resolve-LcRunFile $latest.Head.file))) { $working = $f }
    }
}

$r = $null
if ($working) {
    $slug = [IO.Path]::GetFileNameWithoutExtension($working.FullName)
    $mine = Get-LcSlugLogs $allLogs $slug
    "== Working on: $(Get-LcRunFileName $working.FullName) (the newest file I saved, at $($working.LastWriteTime.ToString('HH:mm')); newer than my latest run)"
    if ($latest) { "(latest run: $($latest.Head.key) on $($latest.Head.file); -Run 1 shows it)" }
    ''
    if ($mine.Count) {
        $r = Read-LcRun $mine[0].FullName
        Write-LcRun $r 'Its latest run'
    } else { 'Never run.'; '' }
    Write-LcSource $working.FullName $r
} else {
    if ($logs.Count -lt $Run) {
        if ($logs.Count -eq 0) { 'No logged runs yet. The Zed tasks (F7, Shift+F7, Ctrl+F7, Alt+F7, Alt+F8) log each run.' }
        else { "Only $($logs.Count) logged runs." }
        exit 0
    }
    $r = Read-LcRun $logs[$Run - 1].FullName
    Write-LcRun $r "Run $Run of $($logs.Count)"
    $srcPath = Resolve-LcRunFile $r.Head.file
    $slug = [IO.Path]::GetFileNameWithoutExtension($srcPath)
    Write-LcSource $srcPath $r
    # A .cpp saved after this run, other than the run's file: the question may be about that one.
    $t = Get-LcRunStart $r
    $newer = @(Get-LcUserCpp | Where-Object { $_.LastWriteTime -gt $t -and $_.FullName -ne $srcPath })
    if ($newer.Count) {
        ''
        "Note: saved after this run: $(($newer | Select-Object -First 3 | ForEach-Object { "$(Get-LcRunFileName $_.FullName) ($($_.LastWriteTime.ToString('HH:mm')))" }) -join ', ')"
    }
}

Write-LcProblem $slug
Write-LcCases $slug
Write-LcJourney $slug

$memLines = @(Format-LcMemory (Read-LcMemory (Join-Path $JourneyRoot 'local')))
if ($memLines.Count) {
    ''
    '== Memory'
    $memLines
}
$unread = @(Get-LcUnreadSolves $JourneyRoot)
if ($unread.Count) {
    ''
    "== Solves the coach hasn't read"
    foreach ($s in $unread) { "  $s" }
}

$others = @($allLogs | Select-Object -First 6 | Where-Object { -not $r -or $_.FullName -ne $r.Path } | Select-Object -First 5)
if ($others.Count) {
    ''
    '== Other recent runs (-Run N or -List shows more)'
    foreach ($f in $others) {
        $o = Read-LcRun $f.FullName
        '  {0}  {1,-8}  {2}  {3}' -f ((Get-LcRunTime $o).ToString('MM-dd HH:mm')), $o.Head.key, $o.Head.file, (Get-LcRunResult $o)
    }
}

