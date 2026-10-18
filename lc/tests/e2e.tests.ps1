# End-to-end tests for .zed/lc.ps1 (LeetCode test task), run on a temp copy of lc/selftest.
# Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $lcPs1 = Join-Path $repo '.zed\lc.ps1'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path $env:TEMP 'lc self test'  # the space is deliberate
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
    Copy-Item -Recurse (Join-Path $repo 'lc\selftest') $tmp
    $journey = Join-Path $tmp 'journey'
    # The temp copy is a git repo, so the solve commit can be checked (all other runs pass -NoCommit).
    $git = (Get-Command git -ErrorAction Stop).Source
    & $git -C $tmp init -q 2>$null
    & $git -C $tmp config user.email lc@example.com
    & $git -C $tmp config user.name lc
    & $git -C $tmp add -A 2>$null
    & $git -C $tmp commit -q -m init
    # Every run writes its journey under $tmp; the real dsa/journey is never touched.
    $realEvents = Join-Path $repo 'journey\events.jsonl'
    $realEventsTime = $null
    if (Test-Path -LiteralPath $realEvents) { $realEventsTime = (Get-Item -LiteralPath $realEvents).LastWriteTimeUtc }
    . (Join-Path $repo '.zed\common.ps1')
    . (Join-Path $repo '.zed\lc\info.ps1')
    . (Join-Path $repo '.zed\lc\build.ps1')
    . (Join-Path $repo '.zed\lc\journey.ps1')
    # R27: builds go to a build root of their own, so self-tests never touch the user's build/ caches.
    $oldBuildRoot = $env:LC_BUILD_ROOT
    $env:LC_BUILD_ROOT = Join-Path $env:TEMP 'lc-e2e-build'
    $userGch = Join-Path $repo 'build\pch\test\lc-all.h.gch'
    $userGchTime = $null
    if (Test-Path -LiteralPath $userGch) { $userGchTime = (Get-Item -LiteralPath $userGch).LastWriteTimeUtc }

    # -Wait drops -NoWait (closing prompts read stdin); -Commit drops -NoCommit.
    function Invoke-Lc([string]$File, [string[]]$Extra = @(), [string]$Stdin = '', [switch]$Wait, [switch]$Commit, [string]$Mode = 'test') {
        $flags = @('-NoOpen', '-Offline')
        if (-not $Wait) { $flags += '-NoWait' }
        if (-not $Commit) { $flags += '-NoCommit' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = $Stdin | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode $Mode @flags -JourneyRoot $journey @Extra $File 2>&1 | Out-String
        $code = $LASTEXITCODE
        $sw.Stop()
        return @{ Out = $out; Code = $code; Ms = $sw.ElapsedMilliseconds }
    }

    try {
        # Make the first two-sum run compile even when an earlier suite run left a matching stamp.
        $twoSum = Join-Path $tmp 'two-sum.cpp'
        [IO.File]::AppendAllText($twoSum, "// $([guid]::NewGuid())`n", $utf8)

        $titles = @{
            'two-sum' = 'Two Sum'; 'concatenation-of-array' = 'Concatenation of Array'; 'rotate-array' = 'Rotate Array'
            'maximum-depth-of-binary-tree' = 'Maximum Depth of Binary Tree'; 'reverse-linked-list' = 'Reverse Linked List'
            'lru-cache' = 'LRU Cache'; 'climbing-stairs' = 'Climbing Stairs'
        }
        $firstTwoSum = $null
        foreach ($slug in 'two-sum', 'concatenation-of-array', 'rotate-array', 'maximum-depth-of-binary-tree',
                          'reverse-linked-list', 'lru-cache', 'climbing-stairs') {
            $r = Invoke-Lc (Join-Path $tmp "$slug.cpp")
            Assert-Equal $r.Code 0 "e2e: $slug exit code`n$($r.Out)"
            Assert-Match $r.Out '\d+/\d+ passed'
            Assert-True ($r.Out -notmatch '(?m)^\s*FAIL\b') "e2e: $slug has FAIL lines`n$($r.Out)"
            Assert-True ($r.Out -notmatch '(?m)warning:|^warning ') "e2e: $slug printed warnings`n$($r.Out)"
            $tf = Join-Path $tmp "tests\$slug.txt"
            Assert-True (Test-Path -LiteralPath $tf) "e2e: tests/$slug.txt not created"
            Assert-True ([IO.File]::ReadAllText($tf).StartsWith("# $($titles[$slug]) (#")) "e2e: tests/$slug.txt header"
            if ($slug -eq 'two-sum') { $firstTwoSum = $r }
            Assert-True ($r.Out -notmatch 'Note \(') "e2e: $slug -NoWait prompted for a note`n$($r.Out)"
            if ($slug -eq 'concatenation-of-array') {
                # e2e: debug prints don't break results
                Assert-Match $r.Out 'debug!'
                Assert-Match $r.Out '2/2 passed'
                Assert-Match $r.Out '(?m)^concatenation-of-array  \(#1929 Easy - Array, Simulation\)\s*$'
            }
        }

        # e2e: journey events for the runs above (written silently; -NoCommit made no commit)
        $ev = @(Read-LcEvents $journey)
        foreach ($slug in $titles.Keys) {
            $mine = @($ev | Where-Object { $_.slug -eq $slug })
            Assert-Equal @($mine | Where-Object { $_.event -eq 'test_run' }).Count 1 "e2e: $slug test_run events"
            Assert-Equal @($mine | Where-Object { $_.event -eq 'solved' }).Count 1 "e2e: $slug solved events"
            Assert-Equal $mine[0].file "$slug.cpp"
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $journey "snapshots\$slug") -Filter *.cpp).Count 1 "e2e: $slug snapshot"
        }
        $tr = @($ev | Where-Object { $_.slug -eq 'two-sum' -and $_.event -eq 'test_run' })[0]
        Assert-True ($tr.compile_ok -eq $true -and $tr.passed -eq 3 -and $tr.failed -eq 0 -and $tr.printed -eq 0) "e2e: two-sum test_run $($tr | ConvertTo-Json -Compress)"
        Assert-True (@($tr.PSObject.Properties.Name) -notcontains 'mismatch') 'e2e: a normal test_run has no mismatch field'
        Assert-Equal (@($tr.cases | ForEach-Object { "$($_.n):$($_.status)" }) -join ',') '1:pass,2:pass,3:pass'
        Assert-Equal $tr.src_hash (Get-LcSrcHash $twoSum)
        $sv = @($ev | Where-Object { $_.slug -eq 'two-sum' -and $_.event -eq 'solved' })[0]
        Assert-True ($sv.attempts -eq 1 -and $null -ne $sv.max_ms) "e2e: two-sum solved $($sv | ConvertTo-Json -Compress)"
        Assert-Match ([IO.File]::ReadAllText((Join-Path $journey 'journey.md'))) '\| 1 \| \[Two Sum\]\(https://leetcode\.com/problems/two-sum/\) \| Easy \|'
        Assert-Equal ((& $git -C $tmp rev-list --count HEAD) -join '') '1' 'e2e: a -NoCommit run committed'

        # e2e: rerun skips compile
        $twoSumDir = Get-LcBuildDir $twoSum
        Assert-Match $twoSumDir '\\lc-e2e-build\\lc\\two-sum-[0-9a-f]{8}$'
        $exe = Join-Path $twoSumDir 'test.exe'
        $mtime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        # R31: an events.jsonl newer than journey.md (e.g. after a pull) gets a full regeneration,
        # so a row missing from journey.md comes back on the next run of another problem.
        $jmd = Join-Path $journey 'journey.md'
        $fullMd = [IO.File]::ReadAllText($jmd)
        [IO.File]::WriteAllText($jmd, (($fullMd -split "`n" | Where-Object { $_ -notmatch 'rotate-array' }) -join "`n"), $utf8)
        (Get-Item -LiteralPath (Join-Path $journey 'events.jsonl')).LastWriteTimeUtc = (Get-Item -LiteralPath $jmd).LastWriteTimeUtc.AddSeconds(2)
        $r = Invoke-Lc $twoSum
        Assert-Equal $r.Code 0 "e2e: two-sum rerun`n$($r.Out)"
        Assert-Match ([IO.File]::ReadAllText($jmd)) '\[Rotate Array\]' 'e2e: stale journey.md not regenerated'
        Assert-Equal (Get-Item -LiteralPath $exe).LastWriteTimeUtc $mtime 'e2e: rerun must not rebuild the exe'
        Assert-True ($r.Ms -lt $firstTwoSum.Ms) "e2e: rerun $($r.Ms) ms not faster than first run $($firstTwoSum.Ms) ms"

        # e2e: editing the solution recompiles only the user TU
        $mtimes = { @('test-harness.o', 'test-harness.stamp', 'test-user.o') | ForEach-Object { (Get-Item -LiteralPath (Join-Path $twoSumDir $_)).LastWriteTimeUtc } }
        $before = & $mtimes
        $harnessStamp = [IO.File]::ReadAllText((Join-Path $twoSumDir 'test-harness.stamp'))
        [IO.File]::AppendAllText($twoSum, "// edited`n", $utf8)
        $r = Invoke-Lc $twoSum
        Assert-Equal $r.Code 0 "e2e: two-sum after edit`n$($r.Out)"
        $after = & $mtimes
        Assert-Equal $after[0] $before[0] 'e2e: an edit must not rebuild the harness object'
        Assert-Equal $after[1] $before[1] 'e2e: an edit must not rewrite the harness stamp'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $twoSumDir 'test-harness.stamp'))) $harnessStamp
        Assert-True ($after[2] -gt $before[2]) 'e2e: an edit must rebuild the user object'

        # e2e: touching lc/lc.h rebuilds the harness (the original mtime is restored, so the user's own
        # PCH, built after it, stays valid)
        $lcH = Get-Item -LiteralPath (Join-Path $repo 'lc\lc.h')
        $lcHTime = $lcH.LastWriteTimeUtc
        try {
            $lcH.LastWriteTimeUtc = [DateTime]::UtcNow
            $r = Invoke-Lc $twoSum
        } finally {
            $lcH.LastWriteTimeUtc = $lcHTime
        }
        Assert-Equal $r.Code 0 "e2e: two-sum after touching lc.h`n$($r.Out)"
        Assert-True ((& $mtimes)[0] -gt $after[0]) 'e2e: touching lc.h must rebuild the harness object'

        # e2e: design gen names the real class; allocations in the user TU are counted
        $lruExe = Join-Path (Get-LcBuildDir (Join-Path $tmp 'lru-cache.cpp')) 'test.exe'
        $spec = Join-Path $tmp 'lru.spec.txt'
        [IO.File]::WriteAllText($spec, "calls 2000`nparam capacity val 3000 3000`nparam key val 0 1000000`nparam value val 0 9`n", $utf8)
        $genOut = Join-Path $tmp 'lru.gen.txt'
        & $lruExe gen $spec $genOut --count 1 --max-n 4 --seed 1 | Out-Null
        Assert-Match ([IO.File]::ReadAllText($genOut)) '(?m)^ops \["LRUCache",'
        $benchOut = Join-Path $tmp 'lru.bench.txt'
        & $lruExe bench $spec $benchOut --seed 1 --max-ms 200 | Out-Null
        $last = @([IO.File]::ReadAllLines($benchOut))[-1]
        Assert-True ($last -match '"alloc":\{"count":(\d+)' -and [int]$Matches[1] -ge 100) "e2e: bench alloc line $last"

        # Build-LcExe reports Skipped on an unchanged rebuild.
        & {
            $scratch = Join-Path $tmp 'my-scratch.cpp'
            $si = Get-LcInfoFromSource ([IO.File]::ReadAllText($scratch))
            $h = New-LcHarnessText -Info $si
            $u = New-LcUserText -SrcPath $scratch -Info $si
            $b1 = Build-LcExe -SrcPath $scratch -HarnessText $h -UserText $u -Flavor test -Name 'unit'
            Assert-True $b1.Ok "Build-LcExe failed: $($b1.Errors)"
            $b2 = Build-LcExe -SrcPath $scratch -HarnessText $h -UserText $u -Flavor test -Name 'unit'
            Assert-True ($b2.Ok -and $b2.Skipped) 'second Build-LcExe must be Skipped'
            Assert-True (Test-Path -LiteralPath $b2.Exe) 'skipped build keeps the exe'
            $pch = Initialize-LcPch -Flavor test
            Assert-Match ([IO.File]::ReadAllText($pch)) 'lc-prelude\.h'
            # A compile error in the solution comes back as g++'s output for that file.
            $bad = Join-Path $tmp 'odd\broken.cpp'
            [IO.File]::WriteAllText($bad, "class Solution {`npublic:`n    int add(int a, int b) { return a + undefined_name; }`n};`n", $utf8)
            $b3 = Build-LcExe -SrcPath $bad -HarnessText $h -UserText (New-LcUserText -SrcPath $bad -Info $si) -Flavor test
            Assert-True (-not $b3.Ok) 'a broken solution must fail to build'
            Assert-Match $b3.Errors "broken\.cpp:3:\d+: error: 'undefined_name' was not declared"
        }

        # e2e: method mismatch
        $mm = Join-Path $tmp 'mismatch'
        New-Item -ItemType Directory -Force (Join-Path $mm 'tests\.meta') | Out-Null
        Copy-Item (Join-Path $repo 'leetcode-solves\concatenation-of-array.cpp') $mm
        Copy-Item (Join-Path $tmp 'tests\.meta\concatenation-of-array.json') (Join-Path $mm 'tests\.meta')
        $r = Invoke-Lc (Join-Path $mm 'concatenation-of-array.cpp')
        Assert-True $r.Out.Contains("`n! LeetCode expects getConcatenation(nums), your Solution has shuffle(nums, n)") "e2e: method mismatch`n$($r.Out)"
        # Analyze: the label-column layout - header and mismatch, g++ warnings, results, one blank line between
        [IO.File]::WriteAllText((Join-Path $mm 'concatenation-of-array.cpp'), ("class Solution {`npublic:`n    vector<int> shuffle(vector<int>& nums, int n) {`n" +
            "        n = min<int>(n, nums.size() / 2);`n        vector<int> ans(2 * n);`n        for (size_t i = 0; i < n; ++i) {`n" +
            "            ans[2 * i] = nums[i];`n            ans[2 * i + 1] = nums[i + n];`n        }`n        return ans;`n    }`n};`n"), $utf8)
        $r = Invoke-Lc (Join-Path $mm 'concatenation-of-array.cpp') -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze mismatch exit code`n$($r.Out)"
        $outLines = @($r.Out.TrimEnd() -split '\r?\n')
        Assert-Equal $outLines.Count 11 "e2e: analyze layout lines`n$($r.Out)"
        Assert-Equal $outLines[0] 'concatenation-of-array  (#1929 Easy - Array, Simulation)'
        Assert-Equal $outLines[1] '! LeetCode expects getConcatenation(nums), your Solution has shuffle(nums, n)'
        Assert-Equal $outLines[2] ''
        Assert-Equal $outLines[3] "warning  line 6: comparison of integer expressions of different signedness: 'size_t' and 'int'"
        Assert-Equal $outLines[4] '             for (size_t i = 0; i < n; ++i) {'
        Assert-Equal $outLines[5] ''
        Assert-Match $outLines[6] '^growth   looks O\(.+\)   \(random inputs; worst case may differ\)$'
        Assert-Match $outLines[7] '^         n     \d+( +\d+){4}$'
        Assert-Match $outLines[8] '^         time  [0-9.]+(us|ms|s)( +[0-9.]+(us|ms|s)){4}$'
        Assert-Match $outLines[9] '^TLE      est\. [0-9.]+ [mu]?s at n = 100000 -> ok$'
        Assert-Match $outLines[10] '^memory   1 alloc, [0-9.]+ [KM]?B total, peak [0-9.]+ [KM]?B at n = 100000$'
        $a = @(Read-LcEvents $journey)[-1]
        Assert-True ($a.event -eq 'analyze_run' -and @($a.points).Count -gt 5) "e2e: analyze_run keeps every point $($a | ConvertTo-Json -Compress)"

        # e2e: timeout names the running case
        $r = Invoke-Lc (Join-Path $tmp 'slow\climbing-stairs.cpp') @('-TimeoutMs', '2000')
        Assert-Match $r.Out 'TIMEOUT 1: still running after 2 s'
        Assert-Equal $r.Code 1 "e2e: timeout exit code`n$($r.Out)"
        Assert-Equal (@(Read-LcEvents $journey)[-1].crash.cause) 'timeout'
        Assert-True ($r.Ms -lt 15000) "e2e: timeout run took $($r.Ms) ms"

        # e2e: crash line
        $crashSrc = Join-Path $tmp 'crash\rotate-array.cpp'
        $line = (Select-String -LiteralPath $crashSrc -Pattern 'nums\[nums\.size\(\)\]').LineNumber
        $r = Invoke-Lc $crashSrc
        Assert-Match $r.Out 'CRASH 1'
        Assert-Match $r.Out "crashed at\s+line $line\b"
        Assert-Equal $r.Code 1 'e2e: crash exit code'
        $tr = @(Read-LcEvents $journey)[-1]
        Assert-True ($tr.event -eq 'test_run' -and $tr.file -eq 'crash/rotate-array.cpp') "e2e: crash test_run $($tr | ConvertTo-Json -Compress)"
        Assert-True ($tr.crash.code -ne 0 -and $tr.crash.cause -and $tr.crash.line -eq $line) "e2e: crash fields $($tr.crash | ConvertTo-Json -Compress)"
        Assert-Equal (@($tr.cases)[-1].status) 'crash'

        # e2e: typed input - an empty answer for a later parameter stops without running or saving
        $r = Invoke-Lc (Join-Path $tmp 'my-scratch.cpp') -Stdin "7`n`n"
        Assert-Equal $r.Code 0 "e2e: partial typed input`n$($r.Out)"
        Assert-True ($r.Out -notmatch '----') "e2e: partial typed input ran a case`n$($r.Out)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp 'tests\my-scratch.txt'))) 'e2e: partial typed input saved a case'

        # e2e: a cached "not a LeetCode problem" marker gives one short line on every run (no network);
        # R30: a typed run where no case ran writes no event and no snapshot
        $evCount = @(Read-LcEvents $journey).Count
        $none = Join-Path $tmp 'tests\.meta\my-scratch.none'
        [IO.File]::WriteAllText($none, '', $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'my-scratch.cpp')
        Remove-Item -LiteralPath $none
        Assert-Equal (@($r.Out.Trim() -split '\r?\n')[0..1] -join '|') 'my-scratch|(not a LeetCode problem: my-scratch)' "e2e: not a problem`n$($r.Out)"
        Assert-Equal @(Read-LcEvents $journey).Count $evCount 'e2e: typed runs without a case wrote events'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $journey 'snapshots\my-scratch'))) 'e2e: typed runs without a case took a snapshot'

        # e2e: a typed case that crashes is still saved
        $typed = Join-Path $tmp 'typed'
        New-Item -ItemType Directory -Force $typed | Out-Null
        [IO.File]::WriteAllText((Join-Path $typed 'boom.cpp'),
            "class Solution {`npublic:`n    int at(int i) {`n        vector<int> v(2);`n        return v[i];`n    }`n};`n", $utf8)
        $r = Invoke-Lc (Join-Path $typed 'boom.cpp') -Stdin "5`n"
        Assert-Match $r.Out 'CRASH 1'
        Assert-Match ([IO.File]::ReadAllText((Join-Path $typed 'tests\boom.txt'))) '(?m)^Input: i = 5\s*$'

        # e2e: typed input
        $r = Invoke-Lc (Join-Path $tmp 'my-scratch.cpp') -Stdin "2`n3`n`n"
        Assert-True $r.Out.Contains('----  1  5') "e2e: typed input`n$($r.Out)"
        Assert-Match ([IO.File]::ReadAllText((Join-Path $tmp 'tests\my-scratch.txt'))) '(?m)^Input: a = 2, b = 3\s*$'
        $ev = @(Read-LcEvents $journey)
        Assert-Equal "$($ev[-2].event)|$($ev[-2].input)" 'typed_case|Input: a = 2, b = 3'
        Assert-Equal "$($ev[-1].event)|$($ev[-1].printed)|$(@($ev[-1].cases).Count)" 'test_run|1|1'

        # e2e: unsupported type
        $r = Invoke-Lc (Join-Path $tmp 'odd\my-map.cpp')
        Assert-Match $r.Out "parameter type the harness doesn't support"
        Assert-True ($r.Out -notmatch 'required from') "e2e: unsupported type shows the template dump`n$($r.Out)"
        Assert-Equal $r.Code 1 'e2e: unsupported type exit code'
        # A type only the solution defines is unknown to the harness TU.
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\own-type.cpp'), "struct Node { int v; };`nclass Solution {`npublic:`n    int f(Node* n) { return n ? n->v : 0; }`n};`n", $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'odd\own-type.cpp')
        Assert-True $r.Out.Contains("This problem uses a parameter type the harness doesn't support yet: Node") "e2e: own type`n$($r.Out)"
        Assert-Equal $r.Code 1 'e2e: own type exit code'

        # e2e: aliases in a source-only signature are spelled out for the harness (R24)
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\aliases.cpp'), ("#define VI vector<int>`nusing ll = long long;`ntypedef vector<ll> vll;`n" +
            "class Solution {`npublic:`n    ll total(vll& a, VI& b) {`n        ll s = 0;`n        for (ll x : a) s += x;`n" +
            "        for (int x : b) s += x;`n        return s;`n    }`n};`n"), $utf8)
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\tests\aliases.txt'), "Input: a = [1,2,3], b = [4]`nOutput: 10`n", $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'odd\aliases.cpp')
        Assert-Equal $r.Code 0 "e2e: aliases`n$($r.Out)"
        Assert-Match $r.Out '1/1 passed'

        # e2e: g++'s warnings for a solution that builds are printed above the results, as F7 does, also on a
        # rerun that skips the compile
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\warn.cpp'), "class Solution {`npublic:`n    int same(int a) {`n        int unused = 0;`n        return a;`n    }`n};`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\tests\warn.txt'), "Input: a = 4`nOutput: 4`n", $utf8)
        foreach ($k in 1, 2) {
            $r = Invoke-Lc (Join-Path $tmp 'odd\warn.cpp')
            Assert-Equal $r.Code 0 "e2e: warnings run $k`n$($r.Out)"
            Assert-Match $r.Out "^warn\r?\n\r?\nwarning  line 4: unused variable 'unused'\r?\n {13}int unused = 0;\r?\n\r?\n  PASS  1  4 .*\r?\n1/1 passed\s*$"
            Assert-True ($r.Out -notmatch '-user\.cpp|warn\.cpp|\[-W') "e2e: warnings show a path or flag`n$($r.Out)"
        }

        # e2e: an auto return type gets one line, not a compile
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\auto-ret.cpp'), "class Solution {`npublic:`n    auto f(int a) { return a; }`n};`n", $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'odd\auto-ret.cpp')
        $outLines = @($r.Out.Trim() -split '\r?\n')
        Assert-Equal ($outLines -join '|') 'auto-ret|Spell the full type in the method signature (found: auto).' "e2e: auto return`n$($r.Out)"
        Assert-Equal $r.Code 1 'e2e: auto return exit code'

        # e2e: a class Solution without a public method is not taken for a design problem
        [IO.File]::WriteAllText((Join-Path $tmp 'odd\private-only.cpp'), "class Solution {`n    int f(int a) { return a; }`n};`n", $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'odd\private-only.cpp')
        Assert-True $r.Out.Contains('No class Solution with a public method in private-only.cpp.') "e2e: private-only`n$($r.Out)"
        Assert-True (-not $r.Out.Contains('Design problems')) 'e2e: private-only got the design message'

        # e2e: long values are truncated on ---- lines too
        $tf = Join-Path $tmp 'tests\concatenation-of-array.txt'
        [IO.File]::AppendAllText($tf, "`nInput: nums = [$((1..40) -join ',')]`n", $utf8)
        $r = Invoke-Lc (Join-Path $tmp 'concatenation-of-array.cpp')
        Assert-Match $r.Out '(?m)^\s+----\s+3\s+\[1,2,3[0-9,]*\.\.\.\s'
        Assert-True ($r.Out -notmatch '40\]') "e2e: ---- line not truncated`n$($r.Out)"

        # e2e: a compile error is still a test_run (compile_ok false), with a snapshot of the broken source
        $snaps = Join-Path $journey 'snapshots\two-sum'
        $snapCount = @(Get-ChildItem -LiteralPath $snaps -Filter *.cpp).Count
        $good = [IO.File]::ReadAllText($twoSum)
        [IO.File]::AppendAllText($twoSum, "int broken = undefined_name;`n", $utf8)
        $r = Invoke-Lc $twoSum
        Assert-Equal $r.Code 1 "e2e: compile error exit code`n$($r.Out)"
        Assert-Match $r.Out "^two-sum  \(#1 Easy - Array, Hash Table\)\r?\n\r?\nerror    line \d+: 'undefined_name' was not declared in this scope\r?\n {13}int broken = undefined_name;\s*$"
        Assert-True ($r.Out -notmatch '-user\.cpp') "e2e: compile error names the generated user TU`n$($r.Out)"
        $tr = @(Read-LcEvents $journey)[-1]
        Assert-True ($tr.event -eq 'test_run' -and $tr.compile_ok -eq $false -and @($tr.cases).Count -eq 0) "e2e: compile error test_run $($tr | ConvertTo-Json -Compress)"
        Assert-Equal @(Get-ChildItem -LiteralPath $snaps -Filter *.cpp).Count ($snapCount + 1) 'e2e: compile error snapshot'
        # A failed analyze build is an analyze_run with status build_error (same source: no new snapshot)
        $r = Invoke-Lc $twoSum -Mode analyze
        Assert-Equal $r.Code 1 "e2e: analyze build error exit code`n$($r.Out)"
        Assert-True ($r.Out -notmatch '-user\.cpp') "e2e: analyze build error names the generated user TU`n$($r.Out)"
        Assert-Match $r.Out "^two-sum  \(#1 Easy - Array, Hash Table\)\r?\n\r?\nerror    line \d+: 'undefined_name' was not declared in this scope\r?\n {13}int broken = undefined_name;\s*$"
        $a = @(Read-LcEvents $journey)[-1]
        Assert-True ($a.event -eq 'analyze_run' -and $a.status -eq 'build_error' -and $null -eq $a.complexity -and $null -eq $a.points -and
            $null -eq $a.tle_risk -and $null -eq $a.alloc -and $null -eq $a.calls) "e2e: analyze build_error $($a | ConvertTo-Json -Compress)"

        # e2e: note prompt and solve commit - without -NoWait/-NoCommit, stdin answers the note
        [IO.File]::WriteAllText($twoSum, $good + "// solved again`n", $utf8)
        $r = Invoke-Lc $twoSum -Wait -Commit -Stdin "two pointers next`n"
        Assert-Equal $r.Code 0 "e2e: note run`n$($r.Out)"
        Assert-True $r.Out.Contains('Note (Enter to skip): ') "e2e: note prompt`n$($r.Out)"
        Assert-True ($r.Out -notmatch 'Press Enter|not committed') "e2e: note run output`n$($r.Out)"
        $h = Get-LcSrcHash $twoSum
        $mine = @(Read-LcEvents $journey | Where-Object { $_.slug -eq 'two-sum' -and $_.src_hash -eq $h })
        Assert-Equal (($mine | ForEach-Object { $_.event }) -join ',') 'test_run,solved,note'
        Assert-Equal $mine[2].text 'two pointers next'
        # runs since the edited version's solve: the lc.h-touch rerun, the compile error, this one
        Assert-Equal $mine[1].attempts 3 'e2e: attempts since the last solve'
        Assert-Match ([IO.File]::ReadAllText((Join-Path $journey 'journey.md'))) '(?m)^\| [0-9-]+ \| 1 \| \[Two Sum\]\(https://leetcode\.com/problems/two-sum/\) \| Easy \| Array, Hash Table \|  \| [0-9.]+ ms \| 1 \| two pointers next \|$'
        Assert-Equal ((& $git -C $tmp log -1 --format=%s) -join '') 'solve: two-sum (Easy)'
        Assert-Equal ((& $git -C $tmp rev-list --count HEAD) -join '') '2'
        $files = @(& $git -C $tmp show --name-only --format= HEAD)
        foreach ($p in 'two-sum.cpp', 'tests/two-sum.txt', 'journey/events.jsonl', 'journey/journey.md') {
            Assert-True ($files -contains $p) "e2e: solve commit lacks $p ($($files -join ', '))"
        }
        Assert-True (-not ($files -match '^(tests/rotate-array\.txt|odd/)')) "e2e: solve commit took other files ($($files -join ', '))"
        Assert-Match ((& $git -C $tmp show HEAD:journey/events.jsonl) -join "`n") '"event":"note".*"text":"two pointers next"'

        # e2e: a failed solve commit prints one line and waits (Press Enter), instead of vanishing
        $hook = Join-Path $tmp '.git\hooks\pre-commit'
        [IO.File]::WriteAllText($hook, "#!/bin/sh`necho 'hook says no' >&2`nexit 1`n")
        try {
            [IO.File]::AppendAllText($twoSum, "// blocked`n", $utf8)
            $r = Invoke-Lc $twoSum -Wait -Commit -Stdin "`n"
        } finally { Remove-Item -LiteralPath $hook }
        Assert-Equal $r.Code 0 "e2e: failed commit exit code`n$($r.Out)"
        Assert-Match $r.Out '\(not committed: hook says no\)\s+Press Enter to close'
        Assert-Equal ((& $git -C $tmp rev-list --count HEAD) -join '') '2' 'e2e: blocked commit committed'

        # e2e: method-name mismatch - all compared cases pass: note prompt and note, but no solved and no commit
        $mm2 = Join-Path $tmp 'mismatch2'
        New-Item -ItemType Directory -Force (Join-Path $mm2 'tests\.meta') | Out-Null
        Copy-Item (Join-Path $tmp 'tests\.meta\two-sum.json') (Join-Path $mm2 'tests\.meta')
        [IO.File]::WriteAllText((Join-Path $mm2 'two-sum.cpp'), ([IO.File]::ReadAllText($twoSum) -replace '\btwoSum\(', 'pairSum('), $utf8)
        $r = Invoke-Lc (Join-Path $mm2 'two-sum.cpp') -Wait -Commit -Stdin "renamed it`n"
        Assert-Equal $r.Code 0 "e2e: mismatch run`n$($r.Out)"
        Assert-Match $r.Out 'LeetCode expects twoSum\('
        Assert-True $r.Out.Contains('Note (Enter to skip): ') "e2e: mismatch note prompt`n$($r.Out)"
        $mine = @(Read-LcEvents $journey | Where-Object { $_.file -eq 'mismatch2/two-sum.cpp' })
        Assert-Equal (($mine | ForEach-Object { $_.event }) -join ',') 'test_run,note' 'e2e: mismatch events'
        Assert-True ($mine[0].mismatch -eq $true) "e2e: mismatch test_run $($mine[0] | ConvertTo-Json -Compress)"
        Assert-Equal $mine[1].text 'renamed it'
        Assert-Equal ((& $git -C $tmp rev-list --count HEAD) -join '') '2' 'e2e: mismatch run committed'

        # e2e: analyze (Alt+F8). R6: the O(n^2) variant's own test file allows n up to 10^5.
        $evBefore = @(Read-LcEvents $journey | Where-Object { $_.event -eq 'analyze_run' }).Count
        $r = Invoke-Lc (Join-Path $tmp 'variants\two-sum.cpp') -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze variant exit code`n$($r.Out)"
        Assert-Match $r.Out 'looks O\(n\^2\)'
        Assert-Match $r.Out '(?m)^TLE      est\. .* at n = 100000 -> likely TLE\s*$'
        $r = Invoke-Lc $twoSum -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze two-sum exit code`n$($r.Out)"
        $outLines = @($r.Out.TrimEnd() -split '\r?\n')
        Assert-Equal $outLines.Count 7 "e2e: analyze output lines`n$($r.Out)"
        Assert-Equal $outLines[0] 'two-sum  (#1 Easy - Array, Hash Table)'
        Assert-Equal $outLines[1] ''
        Assert-Match $outLines[2] '^growth   looks O\(n( log n)?\)   \(random inputs; worst case may differ\)$'
        Assert-Match $outLines[3] '^         n     \d+( +\d+){1,4}$'
        Assert-Match $outLines[4] '^         time  [0-9.]+(us|ms|s)( +[0-9.]+(us|ms|s)){1,4}$'
        Assert-Match $outLines[5] '^TLE      est\. [0-9.]+ [mu]?s at n = 10000 -> ok$'
        Assert-Match $outLines[6] '^memory   \d+ allocs, [0-9.]+ [KM]?B total, peak [0-9.]+ [KM]?B at n = 10000$'
        # R40: no Calls line when every function ran once; the event still has the counts
        $a = @(Read-LcEvents $journey | Where-Object { $_.event -eq 'analyze_run' })[-1]
        Assert-True ($a.calls.twoSum.count -eq 1 -and $a.calls.twoSum.depth -eq 1) "e2e: two-sum analyze_run calls $($a | ConvertTo-Json -Compress)"
        # Task 13: a correct brute force next to the naive recursion agrees on every random case
        Copy-Item (Join-Path $tmp 'bugged\tests\climbing-stairs.brute.cpp') (Join-Path $tmp 'tests')
        $r = Invoke-Lc (Join-Path $tmp 'climbing-stairs.cpp') -Mode analyze
        Assert-Match $r.Out '(?m)^brute    200 random cases agree\s*$'
        Assert-Match $r.Out '(?m)^growth   looks O\(2\^n\)'
        Assert-Match $r.Out '(?m)^memory   no allocations at n = 45\s*$'
        # Results: growth, its table, TLE, memory, calls, brute - in that order, one group
        Assert-Match $r.Out '(?s)\r?\n\r?\ngrowth .*\r?\n {9}n .*\r?\n {9}time .*\r?\nTLE .*\r?\nmemory .*\r?\ncalls .*\r?\nbrute .*$'
        # Task 12: call counts and recursion depth (profile build) at the largest size timed under 20 ms (R38)
        Assert-True ($r.Out -match '(?m)^calls    climbStairs: [0-9,]+ calls, max depth \d+ at n = (\d+)\s*$') "e2e: climbing-stairs calls line`n$($r.Out)"
        $callsN = [long]$Matches[1]
        $a = @(Read-LcEvents $journey | Where-Object { $_.event -eq 'analyze_run' })[-1]
        $under = @(@($a.points) | Where-Object { [double]$_.ms -lt 20 } | ForEach-Object { [long]$_.n })
        Assert-Equal $callsN ($under | Measure-Object -Maximum).Maximum "e2e: calls n is the largest size under 20 ms`n$($r.Out)"
        Assert-True ($a.calls.climbStairs.count -gt 1000 -and $a.calls.climbStairs.depth -gt 10) "e2e: analyze_run calls $($a | ConvertTo-Json -Compress)"
        $r = Invoke-Lc (Join-Path $tmp 'lru-cache.cpp') -Mode analyze
        Assert-Match $r.Out '(?m)^growth   looks O\(1\) per call   \(random inputs; worst case may differ\)'
        Assert-Match $r.Out '(?m)^ {9}n {9}\d+( +\d+)+\s*$'
        Assert-Match $r.Out '(?m)^ {9}per call  [0-9.]+us( +[0-9.]+us)+\s*$'
        Assert-Match $r.Out '(?m)^TLE      est\. .* at n = 200000 -> '
        $an = @(Read-LcEvents $journey | Where-Object { $_.event -eq 'analyze_run' })
        Assert-Equal ($an.Count - $evBefore) 4 'e2e: analyze_run events'
        $a = $an[-1]
        Assert-True ($a.slug -eq 'lru-cache' -and $a.complexity -eq 'O(1) per call' -and $a.tle_risk -eq 'ok') "e2e: lru analyze_run $($a | ConvertTo-Json -Compress)"
        Assert-True (@($a.points).Count -ge 3 -and $null -ne @($a.points)[0].n -and $null -ne @($a.points)[0].ms -and @($a.points)[0].per_call_us -gt 0) "e2e: analyze_run points $($a | ConvertTo-Json -Compress)"
        Assert-True ($a.alloc.count -gt 0 -and $a.alloc.bytes -gt 0 -and $null -ne $a.alloc.peak) "e2e: analyze_run alloc $($a | ConvertTo-Json -Compress)"
        # journey.md's Complexity comes from the latest analyze_run (the hash-map two-sum ran after the variant)
        Assert-Match ([IO.File]::ReadAllText((Join-Path $journey 'journey.md'))) '\[Two Sum\]\(https://leetcode\.com/problems/two-sum/\) \| Easy \| Array, Hash Table \| O\(n( log n)?\) \|'
        Assert-Equal ((& $git -C $tmp rev-list --count HEAD) -join '') '2' 'e2e: analyze committed'

        # e2e: a fast O(n) solution (about 0.1 ms at n = 10^5) is timed in batches, so its few-microsecond
        # calls aren't noise: it looks O(n) every time, not O(log n) or O(1).
        for ($i = 1; $i -le 3; $i++) {
            $r = Invoke-Lc (Join-Path $tmp 'shuffle-the-array.cpp') -Mode analyze
            Assert-Equal $r.Code 0 "e2e: analyze shuffle-the-array exit code`n$($r.Out)"
            Assert-Match $r.Out 'looks O\(n\)'
        }

        # e2e: Task 13 - the brute force finds the bugged memo version's first wrong case (n % 7 == 0)
        $r = Invoke-Lc (Join-Path $tmp 'bugged\climbing-stairs.cpp') -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze bugged exit code`n$($r.Out)"
        Assert-Match $r.Out '(?m)^brute    MISMATCH\r?\n {9}Input: n = (7|14|21|28|35|42)\r?\n {9}yours: \d+   brute: \d+\s*$'
        $a = @(Read-LcEvents $journey | Where-Object { $_.event -eq 'analyze_run' })[-1]
        Assert-True ($a.brute.cases -eq 200 -and $a.brute.mismatch_input -match '^Input: n = (7|14|21|28|35|42)$') "e2e: analyze_run brute $($a | ConvertTo-Json -Compress)"

        # e2e: analyze crash - the line, then the exact random input (gen --n N --seed S); missing constraints are noted
        $an = Join-Path $tmp 'analyze'
        New-Item -ItemType Directory -Force $an | Out-Null
        [IO.File]::WriteAllText((Join-Path $an 'big-crash.cpp'), ("class Solution {`npublic:`n    int first(vector<int>& nums) {`n" +
            "        if (nums.size() > 1000) { int* volatile p = nullptr; *p = 1; }`n        return nums[0];`n    }`n};`n"), $utf8)
        $r = Invoke-Lc (Join-Path $an 'big-crash.cpp') -Mode analyze
        Assert-Equal $r.Code 1 "e2e: analyze crash exit code`n$($r.Out)"
        $outLines = @($r.Out.TrimEnd() -split '\r?\n')
        Assert-Equal ($outLines[0..1] -join '|') 'big-crash|'
        Assert-Equal $outLines[2] 'growth   Your solution crashed on a random input of size 1562 (random inputs only follow ranges, sorted and distinct, so they may break other promises).'
        Assert-True ($outLines[3] -match '^ {9}Input: nums = \[(-?\d+,){1561}-?\d+\]$') "e2e: crash input`n$($outLines[3].Substring(0, [Math]::Min(200, $outLines[3].Length)))"
        Assert-Equal $outLines[4] 'note     assumed: no constraint found for nums'
        # A crashed analyze is an analyze_run with status crash: the sizes timed before it, null for the rest
        $a = @(Read-LcEvents $journey)[-1]
        Assert-True ($a.event -eq 'analyze_run' -and $a.status -eq 'crash' -and @($a.points).Count -ge 3 -and $null -eq $a.complexity -and
            $null -eq $a.tle_risk -and $null -eq $a.alloc -and $null -eq $a.calls) "e2e: analyze crash event $($a | ConvertTo-Json -Compress)"
        # R35c: an exception thrown by the solution shows its text after the crash line
        [IO.File]::WriteAllText((Join-Path $an 'big-throw.cpp'), ("class Solution {`npublic:`n    int first(vector<int>& nums) {`n" +
            "        if (nums.size() > 1000) throw runtime_error(`"boom`");`n        return nums[0];`n    }`n};`n"), $utf8)
        $r = Invoke-Lc (Join-Path $an 'big-throw.cpp') -Mode analyze
        Assert-Equal $r.Code 1 "e2e: analyze exception exit code`n$($r.Out)"
        $outLines = @($r.Out.TrimEnd() -split '\r?\n')
        Assert-Match $outLines[2] '^growth   Your solution crashed on a random input of size 1562 '
        Assert-Equal $outLines[3] '         exception: boom'
        Assert-True ($outLines[4] -match '^ {9}Input: nums = \[(-?\d+,){1561}-?\d+\]$') "e2e: exception input"

        # e2e: R5 backstop - a run still going after the timeout is killed and reported as a cap
        [IO.File]::WriteAllText((Join-Path $an 'hang.cpp'), ("class Solution {`npublic:`n    int spin(vector<int>& nums) {`n" +
            "        volatile int x = 0;`n        if (nums.size() > 1000) while (true) x++;`n        for (int v : nums) x += v;`n        return x;`n    }`n};`n"), $utf8)
        $r = Invoke-Lc (Join-Path $an 'hang.cpp') @('-TimeoutMs', '3000') -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze backstop exit code`n$($r.Out)"
        Assert-Match $r.Out '(?m)^ {9}stopped at n = 1562: still running after 3 s\s*$'
        Assert-True ($r.Ms -lt 20000) "e2e: analyze backstop took $($r.Ms) ms"
        $a = @(Read-LcEvents $journey)[-1]
        Assert-True ($a.event -eq 'analyze_run' -and @($a.PSObject.Properties.Name) -contains 'alloc' -and $null -eq $a.alloc) "e2e: analyze_run alloc null $($a | ConvertTo-Json -Compress)"

        # e2e: R16 - a grid's n is its cells, so the estimate is at len_max^2 = 40000 cells, not 200 rows
        New-Item -ItemType Directory -Force (Join-Path $an 'tests') | Out-Null
        [IO.File]::WriteAllText((Join-Path $an 'grid-sum.cpp'), ("class Solution {`npublic:`n    long long gridSum(vector<vector<int>>& grid) {`n" +
            "        long long s = 0;`n        for (auto& row : grid) for (int v : row) s += v;`n        return s;`n    }`n};`n"), $utf8)
        [IO.File]::WriteAllText((Join-Path $an 'tests\grid-sum.txt'), "Constraints:`n1 <= grid.length <= 200`n-100 <= grid[i][j] <= 100`n`nInput: grid = [[1,2],[3,4]]`nOutput: 10`n", $utf8)
        $r = Invoke-Lc (Join-Path $an 'grid-sum.cpp') -Mode analyze
        Assert-Equal $r.Code 0 "e2e: analyze grid exit code`n$($r.Out)"
        Assert-Match $r.Out '(?m)^TLE      est\. .* at n = 40000 -> '
        $ns = @(@(@(Read-LcEvents $journey)[-1].points) | ForEach-Object { [long]$_.n })
        Assert-True ($ns.Count -ge 3 -and ($ns | Measure-Object -Maximum).Maximum -gt 10000) "e2e: grid points are cells`n$($r.Out)"

        # e2e: the real dsa/journey was never written
        if ($null -eq $realEventsTime) { Assert-True (-not (Test-Path -LiteralPath $realEvents)) 'e2e: wrote the real journey' }
        else { Assert-Equal (Get-Item -LiteralPath $realEvents).LastWriteTimeUtc $realEventsTime 'e2e: wrote the real journey' }

        # e2e: the user's own build cache was left alone
        if ($null -ne $userGchTime) {
            Assert-Equal (Get-Item -LiteralPath $userGch).LastWriteTimeUtc $userGchTime 'e2e: touched the user build/pch'
        }
    } finally {
        $env:LC_BUILD_ROOT = $oldBuildRoot
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
