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
    . (Join-Path $repo '.zed\common.ps1')
    . (Join-Path $repo '.zed\lc\info.ps1')
    . (Join-Path $repo '.zed\lc\build.ps1')
    # R27: builds go to a build root of their own, so self-tests never touch the user's build/ caches.
    $oldBuildRoot = $env:LC_BUILD_ROOT
    $env:LC_BUILD_ROOT = Join-Path $env:TEMP 'lc-e2e-build'
    $userGch = Join-Path $repo 'build\pch\test\lc-all.h.gch'
    $userGchTime = $null
    if (Test-Path -LiteralPath $userGch) { $userGchTime = (Get-Item -LiteralPath $userGch).LastWriteTimeUtc }

    function Invoke-Lc([string]$File, [string[]]$Extra = @(), [string]$Stdin = '') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = $Stdin | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -JourneyRoot $journey @Extra $File 2>&1 | Out-String
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
            $tf = Join-Path $tmp "tests\$slug.txt"
            Assert-True (Test-Path -LiteralPath $tf) "e2e: tests/$slug.txt not created"
            Assert-True ([IO.File]::ReadAllText($tf).StartsWith("# $($titles[$slug]) (#")) "e2e: tests/$slug.txt header"
            if ($slug -eq 'two-sum') { $firstTwoSum = $r }
            if ($slug -eq 'concatenation-of-array') {
                # e2e: debug prints don't break results
                Assert-Match $r.Out 'debug!'
                Assert-Match $r.Out '2/2 passed'
                Assert-Match $r.Out '(?m)^concatenation-of-array  \(#1929 Easy - Array, Simulation\)\s*$'
            }
        }

        # e2e: rerun skips compile
        $twoSumDir = Get-LcBuildDir $twoSum
        Assert-Match $twoSumDir '\\lc-e2e-build\\lc\\two-sum-[0-9a-f]{8}$'
        $exe = Join-Path $twoSumDir 'test.exe'
        $mtime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $r = Invoke-Lc $twoSum
        Assert-Equal $r.Code 0 "e2e: two-sum rerun`n$($r.Out)"
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
        Assert-True $r.Out.Contains('LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)') "e2e: method mismatch`n$($r.Out)"

        # e2e: timeout names the running case
        $r = Invoke-Lc (Join-Path $tmp 'slow\climbing-stairs.cpp') @('-TimeoutMs', '2000')
        Assert-Match $r.Out 'TIMEOUT 1: still running after 2 s'
        Assert-Equal $r.Code 1 "e2e: timeout exit code`n$($r.Out)"
        Assert-True ($r.Ms -lt 15000) "e2e: timeout run took $($r.Ms) ms"

        # e2e: crash line
        $crashSrc = Join-Path $tmp 'crash\rotate-array.cpp'
        $line = (Select-String -LiteralPath $crashSrc -Pattern 'nums\[nums\.size\(\)\]').LineNumber
        $r = Invoke-Lc $crashSrc
        Assert-Match $r.Out 'CRASH 1'
        Assert-Match $r.Out "crashed at\s+line $line\b"
        Assert-Equal $r.Code 1 'e2e: crash exit code'

        # e2e: typed input - an empty answer for a later parameter stops without running or saving
        $r = Invoke-Lc (Join-Path $tmp 'my-scratch.cpp') -Stdin "7`n`n"
        Assert-Equal $r.Code 0 "e2e: partial typed input`n$($r.Out)"
        Assert-True ($r.Out -notmatch '----') "e2e: partial typed input ran a case`n$($r.Out)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp 'tests\my-scratch.txt'))) 'e2e: partial typed input saved a case'

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

        # e2e: the user's own build cache was left alone
        if ($null -ne $userGchTime) {
            Assert-Equal (Get-Item -LiteralPath $userGch).LastWriteTimeUtc $userGchTime 'e2e: touched the user build/pch'
        }
    } finally {
        $env:LC_BUILD_ROOT = $oldBuildRoot
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
