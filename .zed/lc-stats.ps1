# Weak spots from my own history (docs/2026-10-18-coach-design.md), computed from journey/events.jsonl:
# problems per tag by status with the Alt+F7 runs it took to pass, mistakes grouped (wrong answers, crash
# causes, compile errors), problems whose complexity changed, and the review score trend. It rebuilds
# journey.md first, so time-based statuses (failed after 7 days) are current. Never commits or pushes.
#   (no args)           everything, as compact text: one line per row, sections without data left out
#   -Since 2026-10-12   only problems and events from that day on
#   -Json               one JSON object: { problems, tags, mistakes, complexity, reviews }
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Since = '',        # yyyy-MM-dd
    [switch]$Json,
    [string]$JourneyRoot = '',  # default <dsa>/journey
    [string]$Now = ''           # self-tests: the time to act at (ISO 8601); default now
)

. (Join-Path $PSScriptRoot 'lc\journey.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
$inv = [Globalization.CultureInfo]::InvariantCulture
$nowDt = Get-Date
if ($Now) {
    try { $nowDt = [datetime]::Parse($Now, $inv) } catch { [Console]::Error.WriteLine("bad -Now: $Now"); exit 1 }
}
$sinceDt = $null
if ($Since) {
    try { $sinceDt = [datetime]::ParseExact($Since, 'yyyy-MM-dd', $inv) } catch { [Console]::Error.WriteLine('-Since must be yyyy-MM-dd'); exit 1 }
}

$all = @(Read-LcEvents $JourneyRoot)
$tracked = Test-LcAcceptsTracked (Get-LcUserFile)
Update-LcJourneyFile -Root $JourneyRoot -Events $all -AcceptsTracked $tracked -Now $nowDt

# The events inside the window.
$ev = @(foreach ($e in $all) {
    $t = $null
    try { $t = [DateTimeOffset]::Parse([string]$e.ts, $inv).LocalDateTime } catch { }
    if ($sinceDt -and (-not $t -or $t -lt $sinceDt)) { continue }
    $e
})
$state = Get-LcJourneyState $all
$inWindow = @{}
foreach ($e in $ev) { $inWindow[[string]$e.slug] = $true }

# Tags per slug: the fetch event's, else the problem file's (same sources as the journey.md row).
function Get-StatsTags($St, [string]$Slug) {
    if ($St.Fetch -and $St.Fetch.tags) { return @($St.Fetch.tags) }
    $mp = Join-Path (Join-Path $JourneyRoot 'problems') "$Slug.json"
    if (-not [IO.File]::Exists($mp)) { return @() }
    try {
        $j = [IO.File]::ReadAllText($mp, (New-LcUtf8)) | ConvertFrom-Json
        if ($j.data -and $j.data.question) { $j = $j.data.question }
        return @($j.topicTags | ForEach-Object { if ($_.name) { $_.name } else { $_ } })
    } catch { return @() }
}

# Problems: every slug with a run (as in journey.md) and an event in the window.
$counts = [ordered]@{ 'accepted' = 0; 'accepted with hints' = 0; 'passed locally' = 0; 'attempted' = 0; 'failed' = 0 }
$total = 0
$byTag = @{}
foreach ($slug in @($state.Keys)) {
    $st = $state[$slug]
    if (-not $st.Runs -or -not $inWindow[$slug]) { continue }
    $status = Get-LcProblemStatus $st $tracked $nowDt
    $total++
    $counts[$status]++
    foreach ($tag in (Get-StatsTags $st $slug)) {
        $t = $byTag[$tag]
        if (-not $t) { $t = @{ Tag = $tag; Counts = @{}; Runs = @() }; $byTag[$tag] = $t }
        $t.Counts[$status] = 1 + [int]$t.Counts[$status]
        if ($st.Solved -and $null -ne $st.Solved.attempts) { $t.Runs += [double]$st.Solved.attempts }
    }
}
function Get-StatsMean($List) {
    $l = @($List)
    if (-not $l.Count) { return $null }
    return [Math]::Round((($l | Measure-Object -Sum).Sum) / $l.Count, 1)
}
# Weakest first: the most problems not yet accepted.
$tags = @(foreach ($t in $byTag.Values) {
    $c = $t.Counts
    [pscustomobject][ordered]@{
        tag = $t.Tag
        problems = [int]$c['accepted'] + [int]$c['accepted with hints'] + [int]$c['passed locally'] + [int]$c['attempted'] + [int]$c['failed']
        accepted = [int]$c['accepted']; with_hints = [int]$c['accepted with hints']; passed_locally = [int]$c['passed locally']
        attempted = [int]$c['attempted']; failed = [int]$c['failed']; avg_runs_to_pass = (Get-StatsMean $t.Runs)
    }
}) | Sort-Object @{ e = { $_.problems - $_.accepted - $_.with_hints }; Descending = $true }, @{ e = { $_.tag } }

# Mistakes: one record per bad run, grouped by what went wrong; examples are the 3 most recent.
$wrong = @(); $crash = @(); $compile = @()
foreach ($e in $ev) {
    if ([string]$e.event -ne 'test_run') { continue }
    $slug = [string]$e.slug
    if ($e.compile_error) {
        $msg = [string]$e.compile_error
        $compile += , @{ Key = ($msg -replace '^line \d+:\s*', ''); Detail = "${slug}: $msg" }
    } elseif ($e.crash) {
        $cause = [string]$e.crash.cause
        if (-not $cause) { $cause = 'crash (no cause recorded)' }
        $crash += , @{ Key = $cause; Detail = "${slug}: $cause" }
    } elseif ([int]$e.failed -gt 0) {
        $in = ''
        foreach ($c in @($e.cases)) { if ($c.status -eq 'fail' -and $c.input) { $in = [string]$c.input; break } }
        if (-not $in) { $in = '(no input recorded)' }
        $wrong += , @{ Key = 'wrong'; Detail = "${slug}: $in" }
    }
}
function Group-StatsMistakes($Rows) {
    $g = [ordered]@{}
    foreach ($r in $Rows) {
        if (-not $g.Contains($r.Key)) { $g[$r.Key] = New-Object Collections.ArrayList }
        [void]$g[$r.Key].Add($r.Detail)
    }
    return @(foreach ($k in $g.Keys) {
        $l = @($g[$k])
        [pscustomobject][ordered]@{ key = $k; count = $l.Count; examples = @($l[($l.Count - 1)..0] | Select-Object -First 3) }
    }) | Sort-Object @{ e = { $_.count }; Descending = $true }
}
$wrongG = @(Group-StatsMistakes $wrong)
$mistakes = [ordered]@{
    wrong = [pscustomobject][ordered]@{ count = $wrong.Count; examples = @(if ($wrongG.Count) { $wrongG[0].examples }) }
    crash = @(Group-StatsMistakes $crash | ForEach-Object { [pscustomobject][ordered]@{ cause = $_.key; count = $_.count; examples = $_.examples } })
    compile = @(Group-StatsMistakes $compile | ForEach-Object { [pscustomobject][ordered]@{ message = $_.key; count = $_.count; examples = $_.examples } })
}

# Complexity: first vs latest label of a slug's analyze runs, when they differ.
$cx = [ordered]@{}
foreach ($e in $ev) {
    if ([string]$e.event -ne 'analyze_run' -or -not $e.complexity) { continue }
    $s = [string]$e.slug
    if (-not $cx.Contains($s)) { $cx[$s] = @{ first = [string]$e.complexity; latest = ''; n = 0 } }
    $cx[$s].latest = [string]$e.complexity
    $cx[$s].n++
}
$complexity = @(foreach ($s in $cx.Keys) {
    if ($cx[$s].n -ge 2 -and $cx[$s].first -ne $cx[$s].latest) { [pscustomobject][ordered]@{ slug = $s; first = $cx[$s].first; latest = $cx[$s].latest } }
})

# Reviews: the mean, and the last 5 scores against the 5 before them.
$scores = @(foreach ($e in $ev) { if ([string]$e.event -eq 'review' -and $null -ne $e.score) { [double]$e.score } })
$last5 = @($scores | Select-Object -Last 5)
$prev5 = @()
if ($scores.Count -gt 5) { $prev5 = @($scores | Select-Object -First ($scores.Count - 5) | Select-Object -Last 5) }
$reviews = [pscustomobject][ordered]@{ count = $scores.Count; mean = (Get-StatsMean $scores); last5 = (Get-StatsMean $last5); prev5 = (Get-StatsMean $prev5) }

if ($Json) {
    $o = [ordered]@{
        problems = [ordered]@{ total = $total; accepted = $counts['accepted']; with_hints = $counts['accepted with hints']
                               passed_locally = $counts['passed locally']; attempted = $counts['attempted']; failed = $counts['failed'] }
        tags = @($tags); mistakes = $mistakes; complexity = @($complexity); reviews = $reviews
    }
    ConvertTo-Json -InputObject $o -Depth 8
    exit 0
}

$cut = { param($s) Limit-LcText (([string]$s) -replace '\s+', ' ') 90 }
$recent = { param($list) 'recent: ' + ((@($list) | ForEach-Object { & $cut $_ }) -join ' | ') }
"problems: $total (accepted $($counts['accepted']), with hints $($counts['accepted with hints']), passed locally $($counts['passed locally']), attempted $($counts['attempted']), failed $($counts['failed']))"
if ($tags.Count) {
    '== By tag'
    foreach ($t in $tags) {
        $avg = ''
        if ($null -ne $t.avg_runs_to_pass) { $avg = ", avg runs to pass $($t.avg_runs_to_pass)" }
        "$($t.tag): $($t.problems) problems, accepted $($t.accepted), with hints $($t.with_hints), passed locally $($t.passed_locally), attempted $($t.attempted), failed $($t.failed)$avg"
    }
}
if ($wrong.Count -or $crash.Count -or $compile.Count) {
    '== Mistakes'
    if ($wrong.Count) { "wrong answer x$($wrong.Count); $(& $recent $mistakes.wrong.examples)" }
    foreach ($g in $mistakes.crash) { "crash x$($g.count): $(& $cut $g.cause); $(& $recent $g.examples)" }
    foreach ($g in $mistakes.compile) { "compile x$($g.count): $(& $cut $g.message); $(& $recent $g.examples)" }
}
if ($complexity.Count) {
    '== Complexity'
    foreach ($c in $complexity) { "$($c.slug): $($c.first) -> $($c.latest)" }
}
if ($reviews.count) {
    '== Reviews'
    $line = "$($reviews.count) reviews, mean $($reviews.mean), last 5 $($reviews.last5)"
    if ($null -ne $reviews.prev5) { $line += ", 5 before $($reviews.prev5)" }
    $line
}
