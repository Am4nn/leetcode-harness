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
        [IO.File]::WriteAllText($src, "class Solution {`npublic:`n    void rotate(vector<int>& nums, int k) {`n        cout << `"dbg-print`" << endl;`n        nums[nums.size()] = k;`n    }`n};`n", $utf8)
        $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -LogRun -JourneyRoot $journey -CasesRoot $cases $src 2>&1 | Out-String
        Assert-Match $out 'dbg-print'  # still reaches the terminal
        $logs = Get-Logs
        Assert-Equal $logs.Count 50 'runlog: kept runs'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runs '20000101-000000-000-old-alt-f7.cpp'))) 'runlog: oldest source copy left behind'
        $log = $logs[-1]
        Assert-Match $log.Name '^\d{8}-\d{6}-\d{3}-rotate-array-alt-f7\.log$'
        $text = [IO.File]::ReadAllText($log.FullName)
        Assert-Match $text '(?m)^key: Alt\+F7$'
        Assert-Match $text ('(?m)^file: ' + [regex]::Escape($src) + '$')
        Assert-Match $text 'dbg-print'
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

        # Edited after the run: the context says so and shows the change
        [IO.File]::WriteAllText($src, ([IO.File]::ReadAllText($src) -replace 'nums\[nums\.size\(\)\] = k;', 'nums[0] = k;'), $utf8)
        $ctx = Invoke-Ctx
        Assert-Match $ctx '\(edited since the run\)'
        Assert-Match $ctx '(?m)^-\s+nums\[nums\.size\(\)\] = k;'
        Assert-Match $ctx '(?m)^\+\s+nums\[0\] = k;'

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
