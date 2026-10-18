# What a coding agent needs before answering about my code: a logged run (.zed/lc/runlog.ps1) with its
# key, file and terminal output, the file's source now with line numbers and what changed since that run,
# the problem's cases and its journey. Read-only.
#   (no args)      the latest run
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
    [string]$CasesRoot = ''     # default <dsa>/cases
)

. (Join-Path $PSScriptRoot 'lc\journey.ps1')
. (Join-Path $PSScriptRoot 'lc\runlog.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
if (-not $CasesRoot) { $CasesRoot = Join-Path $dsaRoot 'cases' }
$utf8 = New-Object Text.UTF8Encoding $false
$keys = 'f7|shift-f7|ctrl-f7|alt-f7|alt-f8'

# A run log as @{ Path; Head = @{ time; key; file; source; command }; Body = [string[]] }.
function Read-LcRun([string]$Path) {
    $head = @{}
    $body = New-Object Collections.Generic.List[string]
    $inBody = $false
    foreach ($l in [IO.File]::ReadAllLines($Path, $utf8)) {
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

function Resolve-LcRunFile([string]$Name) {
    if ([IO.Path]::IsPathRooted($Name)) { return $Name }
    return Join-Path $dsaRoot $Name
}

$runsRoot = Get-LcRunsRoot
$logs = @()
if (Test-Path -LiteralPath $runsRoot) { $logs = @(Get-ChildItem -LiteralPath $runsRoot -Filter '*.log' | Sort-Object Name -Descending) }
if ($File) {
    $want = [IO.Path]::GetFileNameWithoutExtension($File)
    $logs = @($logs | Where-Object { $_.Name -match ('^\d{8}-\d{6}-\d{3}-' + [regex]::Escape($want) + "-($keys)\.log$") })
}

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

if ($logs.Count -lt $Run) {
    if ($logs.Count -eq 0) { 'No logged runs yet. The Zed tasks (F7, Shift+F7, Ctrl+F7, Alt+F7, Alt+F8) log each run.' }
    else { "Only $($logs.Count) logged runs." }
    exit 0
}

# ---- the run ----
$r = Read-LcRun $logs[$Run - 1].FullName
$t = Get-LcRunTime $r
"== Run $Run of $($logs.Count): $($r.Head.key) on $($r.Head.file), $($t.ToString('yyyy-MM-dd HH:mm:ss')) ($(Format-LcAgo $t))"
"command: $($r.Head.command)"
''
'== Output (line numbers in it refer to the source as it was run)'
$body = $r.Body
while ($body.Count -and -not $body[-1].Trim()) { $body = $body[0..($body.Count - 2)] }
if (-not $Full -and $body.Count -gt 130) {
    $body[0..39]
    "... ($($body.Count - 120) lines cut; -Full shows them) ..."
    $body[($body.Count - 80)..($body.Count - 1)]
} else { $body }
''

# ---- the source now ----
$srcPath = Resolve-LcRunFile $r.Head.file
$runCopy = Join-Path $runsRoot $r.Head.source
$slug = [IO.Path]::GetFileNameWithoutExtension($srcPath)
if (Test-Path -LiteralPath $srcPath) {
    $now = [IO.File]::ReadAllText($srcPath)
    $then = if (Test-Path -LiteralPath $runCopy) { [IO.File]::ReadAllText($runCopy) } else { $null }
    $state = if ($null -eq $then) { 'the copy from the run is gone' } elseif ($now -eq $then) { 'unchanged since the run' } else { 'edited since the run' }
    "== Source now: $($r.Head.file) ($state)"
    $n = 0
    foreach ($l in $now.Replace("`r", '').Split("`n")) { $n++; '{0,4}  {1}' -f $n, $l }
    if ($null -ne $then -and $now -ne $then) {
        ''
        '== Changes since the run (- as run, + now)'
        $diff = & git -c core.autocrlf=false diff --no-index --no-color -U1 -- $runCopy $srcPath 2>$null
        @($diff) | Where-Object { $_ -notmatch '^(diff --git|index |--- |\+\+\+ |old mode|new mode)' }
    }
} else {
    "== $($r.Head.file) no longer exists. The source as it was run:"
    if (Test-Path -LiteralPath $runCopy) {
        $n = 0
        foreach ($l in [IO.File]::ReadAllText($runCopy).Replace("`r", '').Split("`n")) { $n++; '{0,4}  {1}' -f $n, $l }
    }
}

# A .cpp saved after this run, other than the run's file: the question may be about that one.
$newer = @(Get-ChildItem -LiteralPath $dsaRoot -Directory | Where-Object { $_.Name -notin @('build', 'journey', 'lc', 'cases', '.git', '.zed', '.superpowers', 'docs') } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter '*.cpp' -File -ErrorAction SilentlyContinue } |
    Where-Object { $_.LastWriteTime -gt $t -and $_.FullName -ne $srcPath } | Sort-Object LastWriteTime -Descending)
if ($newer.Count) {
    ''
    "Note: saved after this run: $(($newer | Select-Object -First 3 | ForEach-Object { "$(Get-LcRunFileName $_.FullName) ($($_.LastWriteTime.ToString('HH:mm')))" }) -join ', ')"
}

# ---- cases ----
$casesFile = Join-Path (Join-Path $CasesRoot $slug) 'cases.txt'
if (Test-Path -LiteralPath $casesFile) {
    ''
    "== Cases: $(Get-LcRunFileName $casesFile)"
    $c = @([IO.File]::ReadAllLines($casesFile, $utf8))
    if (-not $Full -and $c.Count -gt 60) { $c[0..59]; "... ($($c.Count - 60) more lines; -Full shows them)" } else { $c }
    $brute = Join-Path (Join-Path $CasesRoot $slug) 'brute.cpp'
    if (Test-Path -LiteralPath $brute) { "(brute force: $(Get-LcRunFileName $brute))" }
}

# ---- journey ----
$events = @(Read-LcEvents $JourneyRoot -Slug $slug)
if ($events.Count) {
    ''
    "== Journey: $slug"
    $meta = Join-Path $JourneyRoot "problems\$slug.json"
    if (Test-Path -LiteralPath $meta) {
        try {
            $q = [IO.File]::ReadAllText($meta, $utf8) | ConvertFrom-Json
            if ($q.data.question) { $q = $q.data.question }
            "problem: #$($q.questionFrontendId) $($q.title) ($($q.difficulty)); tags: $(@($q.topicTags | ForEach-Object { $_.name }) -join ', ')"
        } catch {}
        "statement: $(Get-LcRunFileName $meta)"
    }
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

# ---- other runs ----
$others = @($logs | Select-Object -First 6 | Where-Object { $_.FullName -ne $r.Path } | Select-Object -First 5)
if ($others.Count) {
    ''
    '== Other recent runs (-Run N or -List shows more)'
    foreach ($f in $others) {
        $o = Read-LcRun $f.FullName
        '  {0}  {1,-8}  {2}  {3}' -f ((Get-LcRunTime $o).ToString('MM-dd HH:mm')), $o.Head.key, $o.Head.file, (Get-LcRunResult $o)
    }
}
