# LeetCode harness for the file open in Zed (leetcode-solves/<slug>.cpp).
#   -Mode test     run the cases in tests/<slug>.txt; the first run fetches the problem and writes that file
#   -Mode analyze  complexity / TLE report (not implemented yet)
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('test', 'analyze')][string]$Mode = 'test',
    [switch]$NoWait,      # exit without the closing prompt ("Press Enter to close" / "Note") (self-tests)
    [switch]$NoOpen,      # don't open a newly created test file in Zed
    [switch]$Offline,     # never contact LeetCode; use the .meta cache only
    [switch]$NoCommit,    # no auto-commit on solve
    [string]$JourneyRoot = '',   # event log, snapshots, journey.md (default <dsa>/journey)
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
$utf8 = New-Object Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---- journey (silent): events, snapshot, journey.md, solve commit ----
$events = $null   # this slug's events, read once on the first new event
$jRun = $null     # this run's test_run, from the build on: @{ CompileOk; CompileMs; Cases; Crash; Clean; MaxMs }

function Add-LcEvent([string]$Name, [Collections.IDictionary]$Data = @{}) {
    if ($null -eq $script:events) { $script:events = [Collections.ArrayList]@(Read-LcEvents $JourneyRoot -Slug $slug) }
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

# Writes test_run (+ solved), the snapshot and journey.md; asks for a note after a clean run; commits a solve.
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
    Add-LcEvent 'test_run' $data
    [void](Save-LcSnapshot -Root $JourneyRoot -Slug $slug -SrcPath $src -SrcHash $srcHash)
    $solved = $false
    if ($r.Clean -and -not (Test-LcSolvedBefore $script:events $slug $srcHash)) {
        Add-LcEvent 'solved' ([ordered]@{ attempts = (Get-LcAttempts $script:events $slug); max_ms = $r.MaxMs })
        $solved = $true
    }
    if ($r.Clean -and -not $NoWait) {
        Write-Host "`nNote (Enter to skip): " -NoNewline
        $note = [Console]::ReadLine()
        if ($note -and $note.Trim()) { Add-LcEvent 'note' @{ text = $note.Trim() } }
    }
    Update-LcJourneyFile -Root $JourneyRoot -MetaDir (Join-Path $testsDir '.meta') -Slug $slug -Events $script:events
    if ($solved -and -not $NoCommit) {
        $msg = "solve: $slug"
        if ($q -and $q.difficulty) { $msg += " ($($q.difficulty))" }
        $paths = @($src, $testFile, (Join-Path (Join-Path $testsDir '.meta') "$slug.json"), $JourneyRoot)
        [void](Invoke-LcSolveCommit -RepoDir (Split-Path -Parent $src) -Paths $paths -Message $msg)
    }
    if ($r.Clean -or $NoWait) { exit $code }
    Finish $code
}

function Exit-Lc([int]$code) {
    if ($null -ne $script:jRun) { Complete-LcJourney $code }
    if ($NoWait) { exit $code }
    Finish $code
}

$src = ($Rest -join ' ').Trim('"')
if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Host "No such file: '$src'" -ForegroundColor Red; Exit-Lc 1 }
$src = (Resolve-Path -LiteralPath $src).ProviderPath
if ([IO.Path]::GetExtension($src) -ne '.cpp') { Write-Host "Not a .cpp file: $src" -ForegroundColor Red; Exit-Lc 1 }
if ($Mode -eq 'analyze') { Write-Host 'analyze: not implemented yet'; Exit-Lc 1 }

$slug = [IO.Path]::GetFileNameWithoutExtension($src)
$testsDir = Join-Path (Split-Path -Parent $src) 'tests'
$testFile = Join-Path $testsDir "$slug.txt"
$srcText = [IO.File]::ReadAllText($src)
$srcHash = Get-LcSrcHash $src
# Event "file": relative to the folder holding the journey (the dsa root by default), else the full path.
$jBase = (Split-Path -Parent $JourneyRoot).TrimEnd('\') + '\'
$relFile = $src.Replace('\', '/')
if ($src.StartsWith($jBase, [StringComparison]::OrdinalIgnoreCase)) { $relFile = $src.Substring($jBase.Length).Replace('\', '/') }

# ---- problem info: LeetCode metadata (cached), else the source ----
$fetch = Get-LcCachedQuestion -TestsDir $testsDir -Slug $slug -Offline:$Offline
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
    if ($fetch.Tried) { Write-Host "Couldn't fetch $slug from LeetCode ($LcFetchError)." -ForegroundColor DarkGray }
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
        New-Item -ItemType Directory -Force $testsDir | Out-Null
        [IO.File]::WriteAllText($testFile, (New-LcTestFileText -Question $q -Info $info) + "`n", $utf8)
        $zed = Join-Path $env:LOCALAPPDATA 'Programs\Zed\bin\zed.exe'
        if (-not $NoOpen -and (Test-Path -LiteralPath $zed)) { & $zed $testFile }
    }
    $mismatch = Test-LcMethodMatch $info $srcText
    if ($mismatch) {
        Write-Host $mismatch -ForegroundColor Yellow
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
$jRun = @{ CompileOk = $false; CompileMs = 0; Cases = New-Object Collections.ArrayList; Crash = $null; Clean = $false; MaxMs = 0 }
$build = Build-LcExe -SrcPath $src -HarnessText $harnessText -UserText $userText -Flavor test
$jRun.CompileOk = [bool]$build.Ok
$jRun.CompileMs = $build.Ms
if (-not $build.Ok) {
    $t = $null
    if ($build.Stage -eq 'harness') {
        # The harness only sees the signature's types: a type lc.h can't read, or one only the solution defines.
        # An undeclared type comes first: g++ then goes on with int in its place.
        if ($build.Errors -match "error: '(\w+)' (was not declared|does not name a type|has not been declared)") { $t = $Matches[1] }
        elseif ($build.Errors -match "always_false<(.+?) ?>' evaluates") { $t = $Matches[1] }
        elseif ($build.Errors -match '\[with T = ([^;\]]+)') { $t = $Matches[1] }
        elseif ($build.Errors -match 'lc: unsupported parameter type') { $t = '?' }
    }
    if ($t) {
        Write-Host "This problem uses a parameter type the harness doesn't support yet: $t" -ForegroundColor Red
    } else {
        Write-Host $build.Errors
    }
    Exit-Lc 1
}

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
            New-Item -ItemType Directory -Force $testsDir | Out-Null
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
# Clean: every compared case passed (at least one), against LeetCode's own method name.
$jRun.Clean = $allPassed -and $compared -gt 0 -and -not $mismatch
if ($jRun.Clean) { $jRun.MaxMs = [double](@($run.Results | ForEach-Object { [double]$_.ms }) | Measure-Object -Maximum).Maximum }
Exit-Lc $(if ($allPassed) { 0 } else { 1 })
