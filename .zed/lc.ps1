# LeetCode harness for the file open in Zed (leetcode-solves/<slug>.cpp).
#   -Mode test     run the cases in <dsa>/cases/<slug>/cases.txt; the first run fetches the problem and writes that file
#   -Mode analyze  complexity estimate, TLE verdict and allocations from timed random inputs (bench), then
#                  call counts and recursion depth (profile)
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('test', 'analyze')][string]$Mode = 'test',
    [switch]$NoWait,      # exit without the closing prompt ("Press Enter to close" / "Note") (self-tests)
    [switch]$NoOpen,      # don't open a newly created test file in Zed
    [switch]$Offline,     # never contact LeetCode; use the cached problem data only
    [switch]$NoCommit,    # no auto-commit on solve
    [string]$JourneyRoot = '',   # event log, snapshots, journey.md (default <dsa>/journey)
    [string]$CasesRoot = '',     # <slug>/cases.txt and <slug>/brute.cpp per problem (default <dsa>/cases)
    [int]$TimeoutMs = 30000,
    # The path may arrive split on spaces ("c++ language"), so take all remaining args.
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'lc\info.ps1')
. (Join-Path $PSScriptRoot 'lc\fetch.ps1')
. (Join-Path $PSScriptRoot 'lc\testfile.ps1')
. (Join-Path $PSScriptRoot 'lc\build.ps1')
. (Join-Path $PSScriptRoot 'lc\journey.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
$JourneyRoot = [IO.Path]::GetFullPath($JourneyRoot)
$problemsDir = Join-Path $JourneyRoot 'problems'  # cached LeetCode data: <slug>.json, <slug>.none
if (-not $CasesRoot) { $CasesRoot = Join-Path $dsaRoot 'cases' }
$CasesRoot = [IO.Path]::GetFullPath($CasesRoot)
$utf8 = New-Object Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---- LeetCode accepts: asked for now, read at the end (Complete-LcAccepted), so the run never waits on it ----
# The username is in .zed/leetcode-user.txt (git-ignored). Self-tests set $env:LC_USER_FILE and
# $env:LC_ACCEPTED_RESPONSE (a JSON file used instead of the network).
$acTask = $null
if (-not $Offline) {
    $acUserFile = $env:LC_USER_FILE
    if (-not $acUserFile) { $acUserFile = Join-Path $PSScriptRoot 'leetcode-user.txt' }
    $acTask = Start-LcAcceptedFetch -UserFile $acUserFile -ResponsePath $env:LC_ACCEPTED_RESPONSE
}

# Writes an accepted event for each new LeetCode accept of a problem the journey knows, updates those
# rows of journey.md and prints one line naming them. Silent when there are none or anything fails.
function Complete-LcAccepted {
    $t = $script:acTask
    $script:acTask = $null
    if ($null -eq $t) { return }
    $list = @(Receive-LcAcceptedList $t)
    if (-not $list.Count) { return }
    try {
        # The stale check (R31) before this writes events.jsonl.
        $ev = [IO.FileInfo](Join-Path $JourneyRoot 'events.jsonl')
        $md = [IO.FileInfo](Join-Path $JourneyRoot 'journey.md')
        $stale = $script:jStale -or ($ev.Exists -and $md.Exists -and $ev.LastWriteTimeUtc -gt $md.LastWriteTimeUtc)
        $new = @(Add-LcAcceptedEvents -Root $JourneyRoot -List $list)
        if (-not $new.Count) { return }
        $slugs = @($new | ForEach-Object { $_.slug } | Select-Object -Unique)
        if ($null -ne $script:events) { foreach ($e in $new) { if ($e.slug -eq $slug) { [void]$script:events.Add($e) } } }
        if ($stale) { Update-LcJourneyFile -Root $JourneyRoot -MetaDir $problemsDir }
        else { foreach ($s in $slugs) { Update-LcJourneyFile -Root $JourneyRoot -MetaDir $problemsDir -Slug $s } }
        Write-Host "LeetCode accepted: $($slugs -join ', ')" -ForegroundColor DarkGray
    } catch { }
}

# ---- journey (silent): events, snapshot, journey.md, solve commit ----
$events = $null   # this slug's events, read once on the first new event
$jStale = $false  # events.jsonl was newer than journey.md before this run wrote anything (R31)
$jRun = $null     # this run's test_run, from the build on: @{ CompileOk; CompileMs; Cases; Crash; AllPass; MaxMs }

function Add-LcEvent([string]$Name, [Collections.IDictionary]$Data = @{}) {
    if ($null -eq $script:events) {
        $script:events = [Collections.ArrayList]@(Read-LcEvents $JourneyRoot -Slug $slug)
        $ev = [IO.FileInfo](Join-Path $JourneyRoot 'events.jsonl')
        $md = [IO.FileInfo](Join-Path $JourneyRoot 'journey.md')
        $script:jStale = $ev.Exists -and $md.Exists -and $ev.LastWriteTimeUtc -gt $md.LastWriteTimeUtc
    }
    [void]$script:events.Add((Write-LcEvent -Root $JourneyRoot -Event $Name -Slug $slug -File $relFile -SrcHash $srcHash -Data $Data -PassThru))
}

# Records a run's results (and the case that never finished) in this run's test_run.
function Add-LcRunCases($run, [int]$FirstN = 1) {
    foreach ($r in $run.Results) {
        $c = [ordered]@{ n = $FirstN + [int]$r.n - 1; status = [string]$r.status }
        if ($null -ne $r.ms) { $c.ms = [double]$r.ms }
        [void]$script:jRun.Cases.Add($c)
    }
    if ($null -ne $run.Pending) { [void]$script:jRun.Cases.Add([ordered]@{ n = $FirstN + $run.Pending - 1; status = 'crash' }) }
}

# Writes test_run (+ solved), the snapshot and journey.md; asks for a note after an all-pass run;
# commits a solve. A failed commit prints one line and waits, so it can be read before the task hides.
function Complete-LcJourney([int]$code) {
    $r = $script:jRun
    $cases = @($r.Cases.ToArray())
    $data = [ordered]@{
        compile_ok = $r.CompileOk; compile_ms = $r.CompileMs; cases = $cases
        passed  = @($cases | Where-Object { $_.status -eq 'pass' }).Count
        failed  = @($cases | Where-Object { $_.status -eq 'fail' -or $_.status -eq 'error' }).Count
        printed = @($cases | Where-Object { $_.status -eq 'print' }).Count
    }
    if ($r.Crash) { $data.crash = $r.Crash }
    if ($mismatch) { $data.mismatch = $true }  # the solution's method isn't the problem's
    Add-LcEvent 'test_run' $data
    [void](Save-LcSnapshot -Root $JourneyRoot -Slug $slug -SrcPath $src -SrcHash $srcHash)
    $solved = $false
    # A method-name mismatch never counts as a solve, but still gets the note prompt.
    if ($r.AllPass -and -not $mismatch -and -not (Test-LcSolvedBefore $script:events $slug $srcHash)) {
        Add-LcEvent 'solved' ([ordered]@{ attempts = (Get-LcAttempts $script:events $slug); max_ms = $r.MaxMs })
        $solved = $true
    }
    if ($r.AllPass -and -not $NoWait) {
        Write-Host "`nNote (Enter to skip): " -NoNewline
        $note = [Console]::ReadLine()
        if ($note -and $note.Trim()) { Add-LcEvent 'note' @{ text = $note.Trim() } }
    }
    Update-LcJourney
    if ($solved -and -not $NoCommit) {
        $msg = "solve: $slug"
        if ($q -and $q.difficulty) { $msg += " ($($q.difficulty))" }
        $paths = @($src, $caseDir, $JourneyRoot)  # the journey holds problems/<slug>.json
        $res = Invoke-LcSolveCommit -RepoDir (Split-Path -Parent $src) -Paths $paths -Message $msg
        if ($res -is [string]) {
            Write-Host "(not committed: $res)"
            if (-not $NoWait) { Finish $code }
        }
    }
    if ($r.AllPass -or $NoWait) { exit $code }
    Finish $code
}

# journey.md: this slug's row, or everything when events.jsonl was newer than journey.md (R31).
function Update-LcJourney {
    if ($script:jStale) { Update-LcJourneyFile -Root $JourneyRoot -MetaDir $problemsDir }
    else { Update-LcJourneyFile -Root $JourneyRoot -MetaDir $problemsDir -Slug $slug -Events $script:events }
}

# A failed build: one line for a parameter type the harness can't handle, else g++'s output.
function Write-LcBuildFailure($build) {
    $t = $null
    if ($build.Stage -eq 'harness') {
        # The harness only sees the signature's types: a type lc.h can't read, or one only the solution defines.
        # An undeclared type comes first: g++ then goes on with int in its place.
        if ($build.Errors -match "error: '(\w+)' (was not declared|does not name a type|has not been declared)") { $t = $Matches[1] }
        elseif ($build.Errors -match "always_false<(.+?) ?>' evaluates") { $t = $Matches[1] }
        elseif ($build.Errors -match '\[with T = ([^;\]]+)') { $t = $Matches[1] }
        elseif ($build.Errors -match 'lc: unsupported parameter type') { $t = '?' }
    }
    Write-LcGap
    if ($t) {
        Write-Host "This problem uses a parameter type the harness doesn't support yet: $t" -ForegroundColor Red
    } else {
        Write-LcGppDiagnostics (Remove-LcUserTuLines $build.Errors) $src
    }
}

# g++'s warnings for a solution that built: their own group, before the results.
function Write-LcBuildWarnings($build) {
    if (-not $build.Warnings) { return }
    Write-LcGap
    Write-LcGppDiagnostics (Remove-LcUserTuLines $build.Warnings) $src
}

# Output groups (header and mismatch, g++ diagnostics, results) are separated by exactly one blank line.
# Call it right before a group's first line, and only for a group that prints something.
function Write-LcGap { Write-Host '' }

# g++'s output without "In file included from <build dir>\<name>-user.cpp:1:": the generated user TU
# only includes the solution, so that line names a build file and nothing of the user's.
function Remove-LcUserTuLines([string]$Text) {
    return (@($Text -split '\r?\n' | Where-Object { $_ -notmatch '^In file included from .*-user\.cpp:\d+[:,]$' }) -join "`n")
}

function Exit-Lc([int]$code) {
    Complete-LcAccepted
    if ($null -ne $script:jRun) { Complete-LcJourney $code }
    if ($NoWait) { exit $code }
    Finish $code
}

$src = ($Rest -join ' ').Trim('"')
if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Host "No such file: '$src'" -ForegroundColor Red; Exit-Lc 1 }
$src = (Resolve-Path -LiteralPath $src).ProviderPath
if ([IO.Path]::GetExtension($src) -ne '.cpp') { Write-Host "Not a .cpp file: $src" -ForegroundColor Red; Exit-Lc 1 }

$slug = [IO.Path]::GetFileNameWithoutExtension($src)
# The harness's files live outside the solution's folder: cases/<slug>/, journey/problems/.
$caseDir = Join-Path $CasesRoot $slug
$testFile = Join-Path $caseDir 'cases.txt'
$srcText = [IO.File]::ReadAllText($src)
$srcHash = Get-LcSrcHash $src
# Event "file": relative to the folder holding the journey (the dsa root by default), else the full path.
$jBase = (Split-Path -Parent $JourneyRoot).TrimEnd('\') + '\'
$relFile = $src.Replace('\', '/')
if ($src.StartsWith($jBase, [StringComparison]::OrdinalIgnoreCase)) { $relFile = $src.Substring($jBase.Length).Replace('\', '/') }

# ---- problem info: LeetCode metadata (cached), else the source ----
$fetch = Get-LcCachedQuestion -ProblemsDir $problemsDir -Slug $slug -Offline:$Offline
if ($fetch.Fetched) { Add-LcEvent 'fetch' (Get-LcFetchEventData $fetch.Question) }
$q = $fetch.Question
if ($q -and -not $q.metaData) { $q = $null }
if ($q) {
    $tags = @($q.topicTags | ForEach-Object { $_.name }) -join ', '
    $about = "#$($q.questionFrontendId) $($q.difficulty)"
    if ($tags) { $about += " - $tags" }
    Write-Host "$slug  ($about)" -ForegroundColor Cyan
} else {
    Write-Host $slug -ForegroundColor Cyan
    if ($fetch.NotProblem) { Write-Host "(not a LeetCode problem: $slug)" -ForegroundColor DarkGray }
    elseif ($fetch.Tried) { Write-Host "Couldn't fetch $slug from LeetCode ($LcFetchError)." -ForegroundColor DarkGray }
}

$info = $null
$fromSource = $false
if ($q) {
    try { $info = Get-LcInfoFromMeta $q.metaData $srcText }
    catch {
        $t = $_.Exception.Message -replace '^unsupported LeetCode type: ', ''
        Write-Host "This problem uses a parameter type the harness doesn't support yet: $t" -ForegroundColor Red
        Exit-Lc 1
    }
    if (-not (Test-Path -LiteralPath $testFile)) {
        New-Item -ItemType Directory -Force $caseDir | Out-Null
        [IO.File]::WriteAllText($testFile, (New-LcTestFileText -Question $q -Info $info) + "`n", $utf8)
        $zed = Join-Path $env:LOCALAPPDATA 'Programs\Zed\bin\zed.exe'
        if (-not $NoOpen -and (Test-Path -LiteralPath $zed)) { & $zed $testFile }
    }
    $mismatch = Test-LcMethodMatch $info $srcText
    if ($mismatch) {
        Write-Host "! $mismatch" -ForegroundColor Yellow
        # Run the Solution's own public method anyway (a design class can't be substituted).
        $metaKind = $info.Kind
        $info = $null
        if ($metaKind -eq 'function') { $info = Get-LcInfoFromSource $srcText; $fromSource = $true }
        if (-not $info) { Exit-Lc 1 }
    }
} else {
    $info = Get-LcInfoFromSource $srcText
    $fromSource = $true
    if (-not $info) {
        $noComments = $srcText -replace '(?s)/\*.*?\*/', ' ' -replace '//[^\r\n]*', ' '
        if ($noComments -notmatch '\bclass\s+Solution\b' -and $noComments -match '\b(class|struct)\s+\w+') {
            Write-Host "Design problems need LeetCode's info once: connect to the internet and run again." -ForegroundColor Red
        } else {
            Write-Host "No class Solution with a public method in $slug.cpp." -ForegroundColor Red
        }
        Exit-Lc 1
    }
}

# The harness TU never sees the solution: stop on a source-derived type it can't compile.
if ($fromSource) {
    $problem = Get-LcSourceTypeProblem $info $srcText
    if ($problem) { Write-Host $problem -ForegroundColor Red; Exit-Lc 1 }
}

# ---- analyze: bench on seeded random inputs, complexity fit, TLE verdict, allocations, call counts ----
if ($Mode -eq 'analyze') {
    . (Join-Path $PSScriptRoot 'lc\analyze.ps1')
    $constraints = @()
    if (Test-Path -LiteralPath $testFile) { $constraints = Get-LcConstraints ([IO.File]::ReadAllText($testFile, [Text.Encoding]::UTF8)) }
    $spec = ConvertTo-LcSpec -Constraints $constraints -Info $info
    $harnessText = New-LcHarnessText -Info $info
    $userText = New-LcUserText -SrcPath $src -Info $info
    # The analyze_run points: n and ms, plus the cost per call for a design problem.
    function ConvertTo-LcEventPoints($list) {
        return @(@($list) | ForEach-Object {
            $o = [ordered]@{ n = $_.n; ms = $_.ms }
            if ($null -ne $_.per_call_us) { $o.per_call_us = $_.per_call_us }
            $o
        })
    }
    # A failed analyze is still an analyze_run: its status ('crash' or 'build_error'), the sizes timed before
    # a crash, null for the rest. Then the snapshot and journey.md, as after a report.
    function Exit-LcFailedAnalyze([string]$Status, $Points = $null) {
        $pl = $null
        if ($null -ne $Points) { $pl = @(ConvertTo-LcEventPoints $Points) }
        Add-LcEvent 'analyze_run' ([ordered]@{ status = $Status; complexity = $null; points = $pl; tle_risk = $null; alloc = $null; calls = $null })
        [void](Save-LcSnapshot -Root $JourneyRoot -Slug $slug -SrcPath $src -SrcHash $srcHash)
        Update-LcJourney
        Exit-Lc 1
    }
    # The spec's assumed ranges, last in the results.
    function Write-LcAssumed { foreach ($a in $spec.Assumed) { Write-LcLabeled 'note' $a.Trim('(', ')') } }
    $build = Build-LcExe -SrcPath $src -HarnessText $harnessText -UserText $userText -Flavor bench -Name bench
    if (-not $build.Ok) { Write-LcBuildFailure $build; Exit-LcFailedAnalyze 'build_error' }
    Write-LcBuildWarnings $build
    $buildDir = Split-Path -Parent $build.Exe
    $specPath = Join-Path $buildDir 'bench-spec.txt'
    $resultsPath = Join-Path $buildDir 'bench-results.txt'
    [IO.File]::WriteAllText($specPath, $spec.Text, $utf8)
    Remove-Item -LiteralPath $resultsPath -ErrorAction SilentlyContinue
    # R5 backstop: bench caps itself at ~2 s per size; a run still going after 60 s (-TimeoutMs) is killed.
    $limitMs = 60000
    if ($PSBoundParameters.ContainsKey('TimeoutMs')) { $limitMs = $TimeoutMs }
    $seed = 1
    $capMs = 2000
    $m = Start-Measured -Exe $build.Exe -ArgumentList @('bench', $specPath, $resultsPath, '--seed', "$seed", '--max-ms', "$capMs") -TimeoutMs $limitMs -NoStdout
    $lines = @()
    if (Test-Path -LiteralPath $resultsPath) { $lines = [IO.File]::ReadAllLines($resultsPath) }
    $b = Read-LcBenchResults $lines
    # The largest size that finished below the cap: the one bench reruns for the allocation counts.
    $lastDone = $null
    foreach ($p in @($b.Points)) { if (-not $p.capped) { $lastDone = $p.n } }
    # The results group: every line under a label (Write-LcLabeled), continuation lines under ''.
    Write-LcGap
    $crash = $b.Error
    if (-not $crash -and -not $m.TimedOut -and $m.Code -ne 0) {
        if ($m.Code -eq 2 -and -not $b.Pending) { Exit-Lc 1 }  # the runner printed the problem
        $crash = $b.Pending
        # No size pending: the untimed allocation rerun of the largest finished (not capped) size crashed.
        if (-not $crash -and $lastDone) { $crash = @{ n = $lastDone; seed = $seed } }
        if (-not $crash) { Write-LcLabeled 'growth' "CRASH: $(Explain $m.Code)" 'Red'; Exit-LcFailedAnalyze 'crash' $b.Points }
    }
    if ($crash) {
        Write-LcLabeled 'growth' "Your solution crashed on a random input of size $($crash.n) (random inputs only follow ranges, sorted and distinct, so they may break other promises)." 'Red'
        if ($crash.error) { Write-LcLabeled '' $crash.error 'Red' }  # the solution threw
        # R14: gen at exactly that size and seed rebuilds the input bench used.
        $genPath = Join-Path $buildDir 'bench-crash.txt'
        Remove-Item -LiteralPath $genPath -ErrorAction SilentlyContinue
        & $build.Exe gen $specPath $genPath --count 1 --n $crash.n --seed $crash.seed 2>&1 | Out-Null
        if (Test-Path -LiteralPath $genPath) {
            $vals = @(); $ops = ''; $dargs = ''
            foreach ($l in [IO.File]::ReadAllLines($genPath)) {
                if ($l.StartsWith('arg ')) { $vals += $l.Substring(4) }
                elseif ($l.StartsWith('ops ')) { $ops = $l.Substring(4) }
                elseif ($l.StartsWith('args ')) { $dargs = $l.Substring(5) }
            }
            if ($info.Kind -eq 'design') { foreach ($l in 'Input', $ops, $dargs) { Write-LcLabeled '' $l } }
            else { Write-LcLabeled '' (Format-LcInputLine -Info $info -Values ([string[]]$vals)) }
        }
        Write-LcAssumed
        Exit-LcFailedAnalyze 'crash' $b.Points
    }

    $design = $info.Kind -eq 'design'
    $fit = Get-LcComplexity -Points $b.Points
    $stopped = $m.TimedOut -or $null -ne $b.Capped
    if (-not $fit.TooFast) { $cx = $fit.Label; if ($design) { $cx = Get-LcPerCallLabel $cx }; $what = "looks $cx" }
    elseif ($stopped) { $cx = 'too few sizes to tell'; $what = $cx }
    else { $cx = 'too fast to measure'; $what = $cx }
    if ($design -and -not $fit.TooFast) { $cx += ' per call' }
    $growth = $what
    if ($design -and -not $fit.TooFast) { $growth += ' per call' }
    if (-not $fit.TooFast) { $growth += '   (random inputs; worst case may differ)' }
    Write-LcLabeled 'growth' $growth
    $pts = @($b.Points)
    # Design problems show the cost per call (spec); the fit and the estimate use the totals.
    if ($pts.Count) { foreach ($l in (Format-LcPointsTable $pts -PerCall:$design)) { Write-LcLabeled '' $l } }
    if ($m.TimedOut) {
        # Nothing pending: the allocation rerun of the largest finished size was still running.
        $n = '?'
        if ($b.Pending) { $n = $b.Pending.n } elseif ($lastDone) { $n = $lastDone }
        Write-LcLabeled '' ("stopped at n = {0}: still running after {1} s" -f $n, ($limitMs / 1000))
    } elseif ($b.Capped -and $b.Capped.Predicted) {
        Write-LcLabeled '' "stopped before n = $($b.Capped.n) (est. $(Format-LcDuration $b.Capped.ms), over the $($capMs / 1000) s cap)"
    } elseif ($b.Capped) {
        Write-LcLabeled '' "stopped after n = $($b.Capped.n) (over the $($capMs / 1000) s cap)"
    }

    # The time at the largest n: measured when bench got there, else the fit's estimate; never below a cap.
    $maxN = $spec.MaxN
    $atMax = @($pts | Where-Object { $_.n -ge $maxN })
    if ($atMax.Count) { $est = [double]$atMax[-1].ms }
    elseif ($fit.TooFast) { $est = 0.0; if ($pts.Count) { $est = [double]$pts[-1].ms } }
    else { $est = Get-LcEstimateMs -Fit $fit -N $maxN }
    $prefix = ''
    if ($b.Capped -and $est -lt $b.Capped.ms) { $est = $b.Capped.ms }
    if ($m.TimedOut -and $est -lt $limitMs) { $est = [double]$limitMs; $prefix = '> ' }
    $verdict = Get-LcTleVerdict $est
    $color = switch ($verdict) { 'ok' { 'Green' } 'borderline' { 'Yellow' } default { 'Red' } }
    Write-LcLabeled 'TLE' "est. $prefix$(Format-LcDuration $est) at n = $maxN -> $verdict" $color
    $al = $b.Alloc
    if ($al) {
        if ($al.count -eq 0) { Write-LcLabeled 'memory' "no allocations at n = $($al.n)" }
        else {
            $word = if ($al.count -eq 1) { 'alloc' } else { 'allocs' }
            Write-LcLabeled 'memory' "$($al.count) $word, $(Format-LcBytes $al.bytes) total, peak $(Format-LcBytes $al.peak) at n = $($al.n)"
        }
    }
    # Call counts and recursion depth: one input (same seed) at the largest size bench timed under 20 ms
    # (R38: instrumented runs are ~30x slower), else the smallest size, on the profile build (only the user
    # TU is instrumented). Silent when it can't be had or when every function ran once (R40).
    $prof = @()
    $profN = $null
    if ($pts.Count) { $profN = $pts[0].n }
    foreach ($p in $pts) { if (-not $p.capped -and $p.ms -lt 20) { $profN = $p.n } }
    if ($profN) {
        $pb = Build-LcExe -SrcPath $src -HarnessText $harnessText -UserText $userText -Flavor profile
        $profPath = Join-Path $buildDir 'profile-results.txt'
        Remove-Item -LiteralPath $profPath -ErrorAction SilentlyContinue
        if ($pb.Ok) {
            $pm = Start-Measured -Exe $pb.Exe -ArgumentList @('profile', $specPath, $profPath, '--n', "$profN", '--seed', "$seed") -TimeoutMs $limitMs -NoStdout
            if ($pm.Code -eq 0 -and (Test-Path -LiteralPath $profPath)) {
                $prof = @(Resolve-LcProfile -Exe $pb.Exe -Lines ([IO.File]::ReadAllLines($profPath)))
            }
        }
    }
    if ($prof.Count) {
        $callsLine = Format-LcCallsLine -N $profN -Profile $prof
        if ($callsLine) { Write-LcLabeled 'calls' $callsLine }
    }

    $data = [ordered]@{
        complexity = $cx
        points     = @(ConvertTo-LcEventPoints $pts)
        tle_risk   = $verdict
        alloc      = $null  # no size finished
    }
    if ($al) { $data.alloc = [ordered]@{ count = $al.count; bytes = $al.bytes; peak = $al.peak } }
    $data.calls = $null  # no profile
    if ($prof.Count) {
        # Short names; a second function with the same short name (an overload) keeps its full name.
        $data.calls = [ordered]@{}
        foreach ($p in $prof) {
            $k = Get-LcShortName $p.Name
            if ($data.calls.Contains($k)) { $k = $p.Name }
            $data.calls[$k] = [ordered]@{ count = $p.Calls; depth = $p.Depth }
        }
    }
    # Brute-force check: only when cases/<slug>/brute.cpp exists.
    $bruteFile = Join-Path $caseDir 'brute.cpp'
    if (Test-Path -LiteralPath $bruteFile) {
        # A test file analyze can't read leaves the default (ordered compare).
        $anyOrder = $false
        try { $anyOrder = (Test-Path -LiteralPath $testFile) -and [bool](Read-LcTestFile -Path $testFile -Info $info).AnyOrder } catch {}
        $bc = Invoke-LcBruteCheck -SrcPath $src -BrutePath $bruteFile -Info $info -SpecPath $specPath -AnyOrder:$anyOrder -TimeoutMs $limitMs
        if ($bc.Errors) {
            Write-LcLabeled 'brute' "cases/$slug/brute.cpp doesn't build" 'Red'
            Write-LcGppDiagnostics (Remove-LcUserTuLines $bc.Errors) $bruteFile
        }
        elseif ($null -ne $bc.Crashed) {
            $how = if ($bc.TimedOut) { 'timed out' } else { 'crashed' }
            $at = if ($bc.Crashed -gt 0) { " on case $($bc.Crashed)" } else { '' }  # 0: no case to blame
            Write-LcLabeled 'brute' "brute force $how$at" 'Red'
        } elseif ($bc.Mismatch) {
            Write-LcLabeled 'brute' 'MISMATCH' 'Red'
            foreach ($l in @($bc.Mismatch.Input -split '\r?\n')) { Write-LcLabeled '' $l }
            Write-LcLabeled '' "yours: $($bc.Mismatch.Got)   brute: $($bc.Mismatch.Expected)"
            $data.brute = [ordered]@{ cases = $bc.Cases; mismatch_input = $bc.Mismatch.Input }
        } else {
            Write-LcLabeled 'brute' "$($bc.Cases) random cases agree" 'Green'
            $data.brute = [ordered]@{ cases = $bc.Cases }
        }
    }
    Write-LcAssumed
    Add-LcEvent 'analyze_run' $data
    [void](Save-LcSnapshot -Root $JourneyRoot -Slug $slug -SrcPath $src -SrcHash $srcHash)
    Update-LcJourney
    Exit-Lc 0
}

$cases = @()
$anyOrder = $false
if (Test-Path -LiteralPath $testFile) {
    $tf = Read-LcTestFile -Path $testFile -Info $info
    $cases = @($tf.Cases)
    $anyOrder = $tf.AnyOrder
}
if ($info.Kind -eq 'function' -and $cases.Count -gt 0) {
    $have = ($cases | ForEach-Object { $_.Args.Count } | Measure-Object -Minimum).Minimum
    if ($have -lt $info.ParamNames.Count) {
        $missing = $info.ParamNames[$have..($info.ParamNames.Count - 1)] -join ', '
        Write-Host "The test cases have no value for $missing ($($info.Method) takes $($info.ParamNames -join ', '))." -ForegroundColor Red
        Exit-Lc 1
    }
}

# ---- build ----
$harnessText = New-LcHarnessText -Info $info
$userText = New-LcUserText -SrcPath $src -Info $info
$jRun = @{ CompileOk = $false; CompileMs = 0; Cases = New-Object Collections.ArrayList; Crash = $null; AllPass = $false; MaxMs = 0 }
$build = Build-LcExe -SrcPath $src -HarnessText $harnessText -UserText $userText -Flavor test
$jRun.CompileOk = [bool]$build.Ok
$jRun.CompileMs = $build.Ms
if (-not $build.Ok) { Write-LcBuildFailure $build; Exit-Lc 1 }
Write-LcBuildWarnings $build
Write-LcGap  # the results group

# ---- run ----
$buildDir = Split-Path -Parent $build.Exe
$casesPath = Join-Path $buildDir 'cases.txt'
$resultsPath = Join-Path $buildDir 'results.txt'

# Runs the cases and returns @{ Results = <completed result objects>; Stopped = $true when it crashed or timed out }.
function Invoke-LcCases($list) {
    Write-LcCasesFile -Cases $list -Kind $info.Kind -Path $casesPath
    Remove-Item -LiteralPath $resultsPath -ErrorAction SilentlyContinue
    $argv = @('test', $casesPath, $resultsPath)
    if ($anyOrder) { $argv += '--any-order' }
    $m = Start-Measured -Exe $build.Exe -ArgumentList $argv -TimeoutMs $TimeoutMs
    $done = @()
    $pending = $null
    if (Test-Path -LiteralPath $resultsPath) {
        foreach ($line in [IO.File]::ReadAllLines($resultsPath)) {
            if (-not $line.Trim()) { continue }
            $o = $line | ConvertFrom-Json
            if ($o.status -eq 'start') { $pending = [int]$o.n } else { $done += $o; $pending = $null }
        }
    }
    return @{ Results = $done; Pending = $pending; Run = $m }
}

function Format-LcMs($r) {
    if ($null -eq $r.ms) { return '' }
    return '  ' + [string]::Format($inv, '{0:0.00} ms', [double]$r.ms)
}

# Prints one line per result (plus got/expected/diff for failures). $FirstN renumbers the cases.
function Write-LcResults($results, [int]$FirstN = 1) {
    $rows = foreach ($r in $results) {
        $n = [string]($FirstN + [int]$r.n - 1)
        # Long values are cut in the one-line view; failures show them in full.
        $v = [string]$r.got
        if ($v.Length -gt 60) { $v = $v.Substring(0, 57) + '...' }
        switch ($r.status) {
            'pass'  { @{ R = $r; N = $n; Label = 'PASS'; Color = 'Green'; Text = $v } }
            'fail'  { @{ R = $r; N = $n; Label = 'FAIL'; Color = 'Red'; Text = 'got      ' + $r.got } }
            'print' { @{ R = $r; N = $n; Label = '----'; Color = 'Gray'; Text = $v } }
            default { @{ R = $r; N = $n; Label = 'ERR '; Color = 'Red'; Text = [string]$r.error } }
        }
    }
    $rows = @($rows)
    if ($rows.Count -eq 0) { return }
    $nw = ($rows | ForEach-Object { $_.N.Length } | Measure-Object -Maximum).Maximum
    $timed = @($rows | Where-Object { $null -ne $_.R.ms })
    $w = 0
    if ($timed.Count) { $w = [Math]::Min(60, ($timed | ForEach-Object { $_.Text.Length } | Measure-Object -Maximum).Maximum) }
    foreach ($row in $rows) {
        Write-Host '  ' -NoNewline
        Write-Host $row.Label -ForegroundColor $row.Color -NoNewline
        $text = $row.Text
        if ($null -ne $row.R.ms) { $text = $text.PadRight($w) }
        Write-Host ('  ' + $row.N.PadLeft($nw) + '  ' + $text + (Format-LcMs $row.R))
        if ($row.Label -eq 'FAIL') {
            $pad = ' ' * (10 + $nw)
            Write-Host "${pad}expected $($row.R.expected)"
            if ($row.R.diff) { Write-Host "$pad$($row.R.diff)" }
        }
    }
}

# Explains a crash or timeout of the case that never finished. Returns $true when the run stopped early.
function Write-LcStop($run, [int]$FirstN = 1) {
    $m = $run.Run
    $n = '?'
    if ($null -ne $run.Pending) { $n = [string]($FirstN + $run.Pending - 1) }
    if ($m.TimedOut) {
        Write-Host ("  TIMEOUT {0}: still running after {1} s - infinite loop or far too slow?" -f $n, ($TimeoutMs / 1000)) -ForegroundColor Red
        $script:jRun.Crash = [ordered]@{ code = $null; cause = 'timeout' }
        return $true
    }
    if ($m.Code -eq 0) { return $false }
    if ($null -eq $run.Pending -and $m.Code -eq 2) {  # the runner printed the problem
        $script:jRun.Crash = [ordered]@{ code = 2; cause = 'runner error' }
        return $true
    }
    $cause = Explain $m.Code
    Write-Host "  CRASH ${n}: $cause" -ForegroundColor Red
    $script:jRun.Crash = [ordered]@{ code = $m.Code; cause = $cause }
    if ($m.Code -ne -1073741510) {  # not Ctrl+C
        $debugBuild = { Build-LcExe -SrcPath $script:src -HarnessText $script:harnessText -UserText $script:userText -Flavor debug }
        Show-CrashLine -Build $debugBuild -DebugExe (Join-Path $buildDir 'debug.exe') `
            -GdbRun 'test cases.txt results-debug.txt > NUL 2> NUL' -WorkDir $buildDir -Src $src
        if ($script:LcCrashLine) { $script:jRun.Crash.line = $script:LcCrashLine }
    }
    return $true
}

if ($cases.Count -eq 0) {
    # No cases: ask for each parameter, save the case to the test file, run it. An empty answer stops.
    $names = if ($info.Kind -eq 'design') { @('ops', 'args') } else { @($info.ParamNames) }
    $code = 0
    $k = 0
    while ($true) {
        $vals = @()
        foreach ($name in $names) {
            Write-Host "$name = " -NoNewline
            $a = [Console]::ReadLine()
            if ($null -eq $a -or $a.Trim() -eq '') { $vals = $null; break }
            $vals += $a.Trim()
        }
        if ($null -eq $vals) { break }
        $k++
        if ($names.Count -gt 0) {
            # Saved before running: a case that crashes or hangs is the one most worth keeping.
            $line = if ($info.Kind -eq 'design') { "Input`n" + ($vals -join "`n") } else { Format-LcInputLine -Info $info -Values $vals }
            New-Item -ItemType Directory -Force $caseDir | Out-Null
            $prefix = ''
            if (Test-Path -LiteralPath $testFile) {
                $old = [IO.File]::ReadAllText($testFile)
                if ($old.Length -gt 0) { $prefix = "`n"; if (-not $old.EndsWith("`n")) { $prefix = "`n`n" } }
            }
            [IO.File]::AppendAllText($testFile, "$prefix$line`n", $utf8)
            Add-LcEvent 'typed_case' @{ input = $line }
        }
        $run = Invoke-LcCases @(@{ Args = [string[]]$vals; Expected = $null })
        Add-LcRunCases $run -FirstN $k
        Write-LcResults $run.Results -FirstN $k
        if (@($run.Results | Where-Object { $_.status -eq 'error' }).Count) { $code = 1 }
        if (Write-LcStop $run -FirstN $k) { Exit-Lc 1 }
        if ($names.Count -eq 0) { break }
    }
    if ($k -eq 0) { $jRun = $null }  # R30: no case ran, so no test_run and no snapshot
    Exit-Lc $code
}

$run = Invoke-LcCases $cases
Add-LcRunCases $run
Write-LcResults $run.Results
if (Write-LcStop $run) { Exit-Lc 1 }

$compared = @($cases | Where-Object { $null -ne $_.Expected }).Count
$passed = @($run.Results | Where-Object { $_.status -eq 'pass' }).Count
$printed = @($run.Results | Where-Object { $_.status -eq 'print' }).Count
$errors = @($run.Results | Where-Object { $_.status -eq 'error' }).Count
$parts = @()
if ($compared) { $parts += "$passed/$compared passed" }
if ($printed) { $parts += "$printed printed" }
if ($errors) { $parts += "$errors error" + $(if ($errors -gt 1) { 's' } else { '' }) }
$allPassed = $passed -eq $compared -and $errors -eq 0
$color = if (-not $allPassed) { 'Red' } elseif ($compared) { 'Green' } else { 'Gray' }
Write-Host ($parts -join ' - ') -ForegroundColor $color
# All pass: every compared case passed (at least one) and no case errored.
$jRun.AllPass = $allPassed -and $compared -gt 0
if ($jRun.AllPass) { $jRun.MaxMs = [double](@($run.Results | ForEach-Object { [double]$_.ms }) | Measure-Object -Maximum).Maximum }
Exit-Lc $(if ($allPassed) { 0 } else { 1 })
