# Run log (.zed/lc/runlog.ps1) and the agent's context command (.zed/lc-context.ps1), end to end.
# Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $lcPs1 = Join-Path $repo '.zed\lc.ps1'
    $runCpp = Join-Path $repo '.zed\run-cpp.ps1'
    $ctxPs1 = Join-Path $repo '.zed\lc-context.ps1'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path $env:TEMP 'lc runlog test'  # the space is deliberate
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $journey = Join-Path $tmp 'journey'
    $cases = Join-Path $tmp 'cases'
    $runs = Join-Path $tmp 'runs'
    New-Item -ItemType Directory -Force (Join-Path $journey 'problems'), $runs | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'lc\selftest\problems\rotate-array.json') -Destination (Join-Path $journey 'problems')

    $oldRuns = $env:LC_RUNS_ROOT; $oldBuildRoot = $env:LC_BUILD_ROOT
    $env:LC_RUNS_ROOT = $runs
    $env:LC_BUILD_ROOT = Join-Path $env:TEMP 'lc-e2e-build'  # shared with e2e: its PCHs are reused

    function Invoke-Ctx([string[]]$Extra = @()) {
        return (powershell -NoProfile -ExecutionPolicy Bypass -File $ctxPs1 -JourneyRoot $journey -CasesRoot $cases -UserRoot $tmp @Extra 2>&1 | Out-String)
    }
    function Get-Logs { return @(Get-ChildItem -LiteralPath $runs -Filter '*.log' | Sort-Object Name) }
    # powershell -File with a time limit, so a hang fails the test instead of stalling the suite. Stdin is
    # empty; stdout is read as UTF-8. Its own console starts at the OEM code page, as an agent's does
    # (this one may already be at UTF-8). Returns @{ Out; TimedOut }.
    function Invoke-PsTimed([string[]]$PsArgs, [int]$TimeoutMs = 60000) {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $PsArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $utf8
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
            return @{ Out = ''; TimedOut = $true }
        }
        return @{ Out = $o.Result + $e.Result; TimedOut = $false }
    }
    function Invoke-CtxTimed([string[]]$Extra = @()) {
        $r = Invoke-PsTimed (@($ctxPs1, '-JourneyRoot', $journey, '-CasesRoot', $cases, '-UserRoot', $tmp) + $Extra) 30000
        Assert-True (-not $r.TimedOut) "runlog: lc-context $($Extra -join ' ') hung"
        return $r.Out
    }
    # A made-up log, newer than every real one (remove it after).
    function New-FakeLog([string]$Id, [string]$Key, [string]$File, [string]$Body) {
        $path = Join-Path $runs "$Id.log"
        [IO.File]::WriteAllText($path, "time: 2999-01-01T00:00:00+00:00`nkey: $Key`nfile: $File`nsource: $Id.cpp`ncommand: x`n----`n$Body", $utf8)
        return $path
    }

    try {
        # Before any run
        Assert-Match (Invoke-Ctx) 'No logged runs yet'

        # 50 old runs already there: a new one pushes the oldest out
        for ($i = 0; $i -lt 50; $i++) {
            $id = '20000101-0000{0:00}-000-old-alt-f7' -f $i
            [IO.File]::WriteAllText((Join-Path $runs "$id.log"), "time: 2000-01-01T00:00:00+00:00`nkey: Alt+F7`nfile: old.cpp`nsource: $id.cpp`n----`nold`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $runs "$id.cpp"), "// old`n", $utf8)
        }

        # A crash after a debug print: the print (piped stdout), the crash and its line are all in the log
        $solves = Join-Path $tmp 'solves'
        New-Item -ItemType Directory -Force $solves | Out-Null
        $src = Join-Path $solves 'rotate-array.cpp'
        [IO.File]::WriteAllText($src, "class Solution {`npublic:`n    void rotate(vector<int>& nums, int k) {`n        cerr << `"dbg-err`" << endl; cout << `"dbg-print`" << endl;`n        nums[nums.size()] = k;`n    }`n};`n", $utf8)
        $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -LogRun -JourneyRoot $journey -CasesRoot $cases $src 2>&1 | Out-String
        Assert-Match $out 'dbg-err\r?\ndbg-print'  # still reaches the terminal, in the order printed
        $logs = Get-Logs
        Assert-Equal $logs.Count 50 'runlog: kept runs'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runs '20000101-000000-000-old-alt-f7.cpp'))) 'runlog: oldest source copy left behind'
        $log = $logs[-1]
        Assert-Match $log.Name '^\d{8}-\d{6}-\d{3}-rotate-array-alt-f7\.log$'
        $text = [IO.File]::ReadAllText($log.FullName)
        Assert-Match $text '(?m)^key: Alt\+F7$'
        Assert-Match $text ('(?m)^file: ' + [regex]::Escape($src) + '$')
        Assert-Match $text 'dbg-err\r?\ndbg-print'  # cerr merged into stdout's pipe keeps the order
        Assert-Match $text 'CRASH 1'
        Assert-Match $text 'crashed at\s+line 5\b'
        Assert-Equal ([IO.File]::ReadAllText(($log.FullName -replace '\.log$', '.cpp'))) ([IO.File]::ReadAllText($src)) 'runlog: source copy'

        # The context: run, output, numbered source, cases and journey
        $ctx = Invoke-Ctx
        Assert-Match $ctx '== Run 1 of 50: Alt\+F7 on '
        Assert-Match $ctx 'crashed at\s+line 5\b'
        Assert-Match $ctx '\(unchanged since the run\)'
        Assert-Match $ctx '(?m)^   5          nums\[nums\.size\(\)\] = k;'
        Assert-Match $ctx '== Cases: '
        Assert-Match $ctx '== Journey: rotate-array'
        Assert-Match $ctx 'status: attempted, never passed locally; Alt\+F7 runs: 1'
        Assert-Match $ctx '== Other recent runs'
        Assert-True ($ctx -notmatch "== Memory|== Solves the coach hasn't read") "runlog: empty memory sections shown`n$ctx"

        # A run whose terminal is still open (at "Press Enter to close") holds its log open for writing
        $held = New-Object IO.FileStream($log.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $ctx = Invoke-CtxTimed
            Assert-Match $ctx '== Run 1 of 50: Alt\+F7 on '
            Assert-Match $ctx 'crashed at\s+line 5\b'
            Assert-True ($ctx -notmatch 'being used by another process') "runlog: open log not read`n$ctx"
            Assert-Match (Invoke-CtxTimed @('-List', '1')) 'Alt\+F7\s+.*rotate-array\.cpp'
        } finally { $held.Dispose() }

        # Output of only blank lines (a run killed after a blank line) ends the trim
        $fake = New-FakeLog '29990101-000000-000-blank-f7' 'F7' 'blank.cpp' "`n`n"
        $ctx = Invoke-CtxTimed @('-Run', '1')
        Assert-Match $ctx '== Run 1 of 51: F7 on blank\.cpp'
        Remove-Item -LiteralPath $fake

        # -File a-shift: <stamp>-a-shift-f7.log is a Shift+F7 run of a.cpp or an F7 run of a-shift.cpp
        $fakes = @(
            New-FakeLog '29990101-000000-000-a-shift-f7' 'F7' 'a-shift.cpp' "from a-shift`n"
            New-FakeLog '29990101-000001-000-a-shift-f7' 'Shift+F7' 'a.cpp' "from a`n"
        )
        $ctx = Invoke-CtxTimed @('-File', 'a-shift')
        Assert-Match $ctx '== Run 1 of 1: F7 on a-shift\.cpp'
        Assert-Match $ctx 'from a-shift'
        $ctx = Invoke-CtxTimed @('-File', 'a')
        Assert-Match $ctx '== Run 1 of 1: Shift\+F7 on a\.cpp'
        Remove-Item -LiteralPath $fakes

        # Memory and the solves the coach hasn't read
        $coachPs1 = Join-Path $repo '.zed\lc-coach.ps1'
        $null = powershell -NoProfile -ExecutionPolicy Bypass -File $coachPs1 remember -Kind habit -Text 'Loop bound off by one' -JourneyRoot $journey 2>&1 | Out-String
        . (Join-Path $repo '.zed\lc\journey.ps1')
        Write-LcEvent -Root $journey -Event solved -Slug 'rotate-array' -File 'solves\rotate-array.cpp' -SrcHash 'abc123abc123'
        $ctx = Invoke-Ctx
        Assert-Match $ctx '(?m)^== Memory\r?\nhabit:\r?\n- \[m[0-9a-f]{6}\] Loop bound off by one'
        Assert-Match $ctx "(?m)^== Solves the coach hasn't read\r?\n\s+rotate-array\b"
        Assert-True ($ctx.IndexOf('== Memory') -lt $ctx.IndexOf('== Other recent runs')) 'runlog: memory after the journey, before other runs'
        $null = powershell -NoProfile -ExecutionPolicy Bypass -File $coachPs1 read -Slug rotate-array -JourneyRoot $journey 2>&1 | Out-String
        $ctx = Invoke-Ctx
        Assert-True ($ctx -notmatch "== Solves the coach hasn't read") "runlog: read solve still listed`n$ctx"
        Assert-Match $ctx '== Memory'
        # A newer solved version is unread again
        Write-LcEvent -Root $journey -Event solved -Slug 'rotate-array' -File 'solves\rotate-array.cpp' -SrcHash 'def456def456'
        Assert-Match (Invoke-Ctx) "== Solves the coach hasn't read"

        # Edited after the run: the context says so and shows the change
        [IO.File]::WriteAllText($src, ([IO.File]::ReadAllText($src) -replace 'nums\[nums\.size\(\)\] = k;', 'nums[0] = k;'), $utf8)
        $ctx = Invoke-Ctx
        Assert-Match $ctx '\(edited since the run\)'
        Assert-Match $ctx '(?m)^-\s+nums\[nums\.size\(\)\] = k;'
        Assert-Match $ctx '(?m)^\+\s+nums\[0\] = k;'
        # Non-ASCII in the source and the diff reaches a piped reader as UTF-8
        $na = ' // dp ' + [char]0x2192 + ' caf' + [char]0xE9
        [IO.File]::WriteAllText($src, ([IO.File]::ReadAllText($src) -replace 'nums\[0\] = k;', "nums[0] = k;$na"), $utf8)
        $ctx = Invoke-CtxTimed
        Assert-Match $ctx ('(?m)^   5          nums\[0\] = k;' + [regex]::Escape($na))
        Assert-Match $ctx ('(?m)^\+\s+nums\[0\] = k;' + [regex]::Escape($na))

        # A new file saved after the latest run counts as what I'm working on, run or not
        $newSrc = Join-Path $solves 'two-sum.cpp'
        [IO.File]::WriteAllText($newSrc, "class Solution {`npublic:`n    vector<int> twoSum(vector<int>& nums, int target) {`n    }`n};`n", $utf8)
        $ctx = Invoke-Ctx
        Assert-Match $ctx '(?m)^== Working on: .*two-sum\.cpp \(the newest file I saved'
        Assert-Match $ctx '\(latest run: Alt\+F7 on .*rotate-array\.cpp; -Run 1 shows it\)'
        Assert-Match $ctx '(?m)^Never run\.'
        Assert-Match $ctx '(?m)^   3      vector<int> twoSum'
        Assert-Match $ctx '== Problem: https://leetcode\.com/problems/two-sum/'
        Assert-True ($ctx -notmatch '== Journey') "runlog: journey for a never-run file`n$ctx"
        # -Run 1 still shows the latest run, and names the newer file
        $ctx = Invoke-Ctx @('-Run', '1')
        Assert-Match $ctx '== Run 1 of 50: Alt\+F7 on .*rotate-array\.cpp'
        Assert-Match $ctx 'Note: saved after this run: .*two-sum\.cpp'
        Assert-Match $ctx '== Problem: #189 Rotate Array'
        # Going back to the older file (saved last) shows its own latest run
        [IO.File]::AppendAllText($src, "// back`n", $utf8)
        $ctx = Invoke-Ctx
        Assert-Match $ctx '== Run 1 of 50: Alt\+F7 on .*rotate-array\.cpp'
        Remove-Item -LiteralPath $newSrc
        # A .cpp directly in the dsa root counts too
        $rootSrc = Join-Path $tmp 'scratch.cpp'
        [IO.File]::WriteAllText($rootSrc, "int main() {}`n", $utf8)
        Assert-Match (Invoke-Ctx) '(?m)^== Working on: .*scratch\.cpp \(the newest file I saved'
        Assert-Match (Invoke-Ctx @('-Run', '1')) 'Note: saved after this run: .*scratch\.cpp'
        Remove-Item -LiteralPath $rootSrc

        # -List, -File, -Run
        $list = @((Invoke-Ctx @('-List', '3')).Trim() -split "`r?`n")
        Assert-Equal $list.Count 3 'runlog: -List 3'
        Assert-Match $list[0] '^\s*1\s+\S+ \S+\s+Alt\+F7\s+.*rotate-array\.cpp'
        Assert-Match (Invoke-Ctx @('-File', 'two-sum')) 'No logged runs yet'
        Assert-Match (Invoke-Ctx @('-Run', '2')) '== Run 2 of 50: Alt\+F7 on old\.cpp'

        # A run without -LogRun (an agent's check) is not logged
        $null = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -JourneyRoot $journey -CasesRoot $cases $src 2>&1 | Out-String
        Assert-Equal (Get-Logs).Count 50 'runlog: an unlogged run wrote a log'
        Assert-Equal (Get-Logs)[-1].Name $log.Name 'runlog: an unlogged run replaced the latest'

        # Shift+F7 (run-cpp.ps1): the compile, the program's output and the summary
        $prog = Join-Path $tmp 'prog'
        New-Item -ItemType Directory -Force $prog | Out-Null
        $progSrc = Join-Path $prog 'lc-runlog-twice.cpp'
        [IO.File]::WriteAllText($progSrc, "#include <cstdio>`nint main() { int x; if (scanf(`"%d`", &x) == 1) printf(`"twice=%d\n`", 2 * x); }`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $prog 'input.txt'), "21`n", $utf8)
        $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $runCpp -Mode input -LogRun $progSrc 2>&1 | Out-String
        Assert-Match $out 'twice=42'
        $log = (Get-Logs)[-1]
        Assert-Match $log.Name '-lc-runlog-twice-shift-f7\.log$'
        $text = [IO.File]::ReadAllText($log.FullName)
        Assert-Match $text 'Compiling lc-runlog-twice\.cpp'
        Assert-Match $text 'twice=42'
        Assert-Match $text 'finished: exit code 0'

        # A big input.txt read by a program that prints as it reads: stdin is copied while stdout is pumped
        [IO.File]::WriteAllText($progSrc, "#include <cstdio>`nint main() { int x; long long s = 0; while (scanf(`"%d`", &x) == 1) { printf(`"%d\n`", 2 * x); s += x; } printf(`"sum=%lld\n`", s); }`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $prog 'input.txt'), ((1..20000) -join "`n") + "`n", $utf8)
        $r = Invoke-PsTimed @($runCpp, '-Mode', 'input', '-LogRun', $progSrc) 60000
        Assert-True (-not $r.TimedOut) 'runlog: Shift+F7 with a big input.txt hung'
        Assert-Match $r.Out 'sum=200010000'
        Assert-Match ([IO.File]::ReadAllText((Get-Logs)[-1].FullName)) '(?m)^40000\r?\nsum=200010000'

        # cout and cerr lines stay in the order printed, in the terminal and the log
        [IO.File]::WriteAllText($progSrc, "#include <iostream>`nint main() { for (int i = 0; i < 3; i++) { std::cout << `"out `" << i << '\n'; std::cerr << `"err `" << i << '\n'; } }`n", $utf8)
        $r = Invoke-PsTimed @($runCpp, '-Mode', 'input', '-LogRun', $progSrc) 60000
        $order = 'out 0\r?\nerr 0\r?\nout 1\r?\nerr 1\r?\nout 2\r?\nerr 2'
        Assert-Match $r.Out $order
        Assert-Match ([IO.File]::ReadAllText((Get-Logs)[-1].FullName)) $order

        # Ctrl+F7: g++ errors are logged
        [IO.File]::WriteAllText($progSrc, "int main() { return undefined_name; }`n", $utf8)
        $null = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $runCpp -Mode check -LogRun $progSrc 2>&1 | Out-String
        $log = (Get-Logs)[-1]
        Assert-Match $log.Name '-lc-runlog-twice-ctrl-f7\.log$'
        Assert-Match ([IO.File]::ReadAllText($log.FullName)) "error: 'undefined_name' was not declared"
    } finally {
        $env:LC_RUNS_ROOT = $oldRuns; $env:LC_BUILD_ROOT = $oldBuildRoot
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
        Remove-Item -Force -LiteralPath (Join-Path $repo 'build\lc-runlog-twice.exe') -ErrorAction SilentlyContinue
    }
}
