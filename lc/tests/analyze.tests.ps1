# Tests for .zed/lc/analyze.ps1 (dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact).
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repo '.zed\lc\info.ps1')
    . (Join-Path $repo '.zed\lc\analyze.ps1')

    Assert-Equal (ConvertFrom-LcNumber '2 * 10^5') 200000
    Assert-Equal (ConvertFrom-LcNumber '-2^31') (-2147483648)
    Assert-Equal (ConvertFrom-LcNumber '2^31 - 1') 2147483647
    Assert-Equal (ConvertFrom-LcNumber '-10^4') (-10000)
    Assert-Equal (ConvertFrom-LcNumber '42') 42

    $rotate = Get-LcInfoFromMeta '{"name":"rotate","params":[{"name":"nums","type":"integer[]"},{"name":"k","type":"integer"}],"return":{"type":"void"},"output":{"paramindex":0}}'
    $s = ConvertTo-LcSpec -Constraints @('1 <= nums.length <= 10^5', '-2^31 <= nums[i] <= 2^31 - 1', '0 <= k <= 10^5') -Info $rotate
    Assert-Match $s.Text 'param nums len 1 100000 val -2147483648 2147483647'
    Assert-Match $s.Text 'param k val 0 100000'
    Assert-Match $s.Text 'size nums'
    Assert-Equal $s.MaxN 100000
    Assert-Equal $s.Assumed.Count 0

    $tree = Get-LcInfoFromMeta '{"name":"maxDepth","params":[{"name":"root","type":"TreeNode"}],"return":{"type":"integer"}}'
    $s = ConvertTo-LcSpec -Constraints @('The number of nodes in the tree is in the range [0, 10^4].', '-100 <= Node.val <= 100') -Info $tree
    Assert-Match $s.Text 'param root len 0 10000 val -100 100'

    $lru = Get-LcInfoFromMeta '{"classname":"LRUCache","constructor":{"params":[{"name":"capacity","type":"integer"}]},"methods":[{"name":"get","params":[{"name":"key","type":"integer"}],"return":{"type":"integer"}},{"name":"put","params":[{"name":"key","type":"integer"},{"name":"value","type":"integer"}],"return":{"type":"void"}}],"systemdesign":true}'
    $s = ConvertTo-LcSpec -Constraints @('1 <= capacity <= 3000', '0 <= key <= 10^4', '0 <= value <= 10^5', 'At most 2 * 10^5 calls will be made to get and put.') -Info $lru
    Assert-Match $s.Text 'calls 200000'
    Assert-Match $s.Text 'param capacity val 1 3000'
    Assert-Match $s.Text 'param key val 0 10000'

    $bs = Get-LcInfoFromMeta '{"name":"search","params":[{"name":"nums","type":"integer[]"},{"name":"target","type":"integer"}],"return":{"type":"integer"}}'
    $s = ConvertTo-LcSpec -Constraints @('1 <= nums.length <= 10^4', '-10^4 < nums[i], target < 10^4', 'All the integers in nums are unique.', 'nums is sorted in ascending order.') -Info $bs
    Assert-Match $s.Text 'param nums len 1 10000 val -9999 9999 sorted distinct'
    Assert-Match $s.Text 'param target val -9999 9999'

    $s = ConvertTo-LcSpec -Constraints @('1 <= nums.length <= 10^4', 'nums is sorted in non-decreasing order.') -Info $bs
    Assert-Match $s.Text 'param nums .*sorted'
    Assert-True ($s.Text -notmatch 'distinct')
    $s = ConvertTo-LcSpec -Constraints @('nums is sorted in strictly increasing order.') -Info $bs
    Assert-Match $s.Text 'sorted distinct'

    $two = Get-LcInfoFromMeta '{"name":"twoSum","params":[{"name":"nums","type":"integer[]"},{"name":"target","type":"integer"}],"return":{"type":"integer[]","size":2}}'
    $s = ConvertTo-LcSpec -Constraints @() -Info $two
    Assert-True ($s.Assumed -contains '(assumed: no constraint found for nums)')
    Assert-Equal $s.MaxN 100000

    $sc = Get-LcInfoFromMeta '{"name":"f","params":[{"name":"a","type":"integer"},{"name":"b","type":"integer"}],"return":{"type":"integer"}}'
    $s = ConvertTo-LcSpec -Constraints @() -Info $sc
    Assert-Match $s.Text '(?m)^param a val 1 100000\r?$'
    Assert-Match $s.Text '(?m)^param b val -1000000000 1000000000\r?$'
    Assert-True ($s.Assumed -contains '(assumed: no constraint found for b)')

    $pts = { param($ns, $f) @($ns | ForEach-Object { @{ n = $_; ms = (& $f $_) } }) }
    Assert-Equal (Get-LcComplexity (& $pts 1000, 2000, 4000, 8000 { param($n) 1e-6 * $n * $n })).Label 'O(n^2)'
    Assert-Equal (Get-LcComplexity (& $pts 10000, 20000, 40000, 80000 { param($n) 1e-5 * $n })).Label 'O(n)'
    Assert-Equal (Get-LcComplexity (& $pts 10000, 20000, 40000, 80000 { param($n) 1e-6 * $n * [math]::Log($n, 2) })).Label 'O(n log n)'
    Assert-Equal (Get-LcComplexity (& $pts 10, 14, 18, 22, 26, 30 { param($n) 1e-6 * [math]::Pow(2, $n) })).Label 'O(2^n)'
    Assert-True (Get-LcComplexity (& $pts 1000, 2000, 4000, 8000 { param($n) 1e-9 * $n })).TooFast
    # The noise floor is 0.05 us (batched timing): move-zeroes at n <= 1e4 (0.1-4.9 us) gets a fit.
    Assert-Equal (Get-LcComplexity @(@{ n = 78; ms = 0.0001 }, @{ n = 625; ms = 0.0004 }, @{ n = 2500; ms = 0.0012 }, @{ n = 10000; ms = 0.0049 })).Label 'O(n)'
    Assert-Equal (Get-LcComplexity (& $pts 10000, 20000, 40000, 80000 { param($n) 1e-6 * $n })).Label 'O(n)'
    # product-of-array-except-self (O(n)): ~3 ns per element, then ~4.3 ns once its arrays outgrow the cache
    $cache = @(@{ n = 195; ms = 0.000661 }, @{ n = 390; ms = 0.001123 }, @{ n = 781; ms = 0.00217 }, @{ n = 1562; ms = 0.005207 },
        @{ n = 3125; ms = 0.009341 }, @{ n = 6250; ms = 0.019396 }, @{ n = 12500; ms = 0.03785 }, @{ n = 25000; ms = 0.0862 },
        @{ n = 50000; ms = 0.22172 }, @{ n = 100000; ms = 0.4298 })
    $fit = Get-LcComplexity $cache
    Assert-Equal $fit.Label 'O(n)'
    Assert-True ([math]::Abs((Get-LcEstimateMs -Fit $fit -N 100000) - 0.4298) -le 1e-9) 'analyze: estimate from the largest size'
    # lru-cache (O(1) per call): 0.057 us per call rising to 0.082 us over a 512x range of n
    $lru = @(@{ n = 390; ms = 0.0223 }, @{ n = 781; ms = 0.0495 }, @{ n = 1562; ms = 0.1107 }, @{ n = 3125; ms = 0.2219 },
        @{ n = 6250; ms = 0.4499 }, @{ n = 12500; ms = 0.939 }, @{ n = 25000; ms = 1.8763 }, @{ n = 50000; ms = 3.9613 },
        @{ n = 100000; ms = 8.1233 }, @{ n = 200000; ms = 16.4639 })
    Assert-Equal (Get-LcComplexity $lru).Label 'O(n)'
    # A fixed cost per call (bench's doubling sizes): it flattens the small sizes but must not lower the label.
    $sizes = { param([long]$max) $v = @(); for ($n = $max; $v.Count -lt 10 -and $n -ge 8; $n = [long][math]::Floor($n / 2)) { $v = @($n) + $v }; $v }
    Assert-Equal (Get-LcComplexity (& $pts (& $sizes 1000) { param($n) 5e-5 + 1e-6 * $n })).Label 'O(n)' 'O(n) + 50 ns per call'
    # 30x growth with 100 ns per call: O(log n) misses half the O(1) error by a little and O(1), the worst
    # fit of the three, must not win for it.
    Assert-Equal (Get-LcComplexity (& $pts (& $sizes 10000) { param($n) 1e-4 + 3e-7 * $n })).Label 'O(n)' 'O(n) + 100 ns per call'
    $fit = Get-LcComplexity (& $pts @(& $sizes 100000 | Where-Object { $_ -le 25000 }) { param($n) 1 + 1e-6 * $n * $n })
    Assert-Equal $fit.Label 'O(n^2)' 'O(n^2) + a 1 ms table per call, capped at 25000'
    Assert-True ([math]::Abs((Get-LcEstimateMs -Fit $fit -N 100000) - 10016) -le 1) 'analyze: O(n^2) estimate past the cap'
    Assert-Equal (Get-LcComplexity (& $pts (& $sizes 10000) { param($n) 0.1 + 5e-7 * $n * $n })).Label 'O(n^2)' 'design: a 100 us constructor, O(n) per call'
    # A Fibonacci-like recursion (1.6^n) with 50 ns per call, scalar sizes up to 45.
    Assert-Equal (Get-LcComplexity (& $pts 4, 8, 13, 17, 22, 26, 31 { param($n) 5e-5 + 2e-6 * [math]::Pow(1.618, $n) })).Label 'O(2^n)'
    # first-missing-positive (cyclic sort, O(n)), the user's recorded run: 2.1x per doubling, a 4.5x step
    # between 6250 and 12500 (L1), then 2.0x at the top.
    $fmp = @(@{ n = 195; ms = 0.000157 }, @{ n = 390; ms = 0.000335 }, @{ n = 781; ms = 0.00069 }, @{ n = 1562; ms = 0.0015 },
        @{ n = 3125; ms = 0.00318 }, @{ n = 6250; ms = 0.007491 }, @{ n = 12500; ms = 0.033455 }, @{ n = 25000; ms = 0.086258 },
        @{ n = 50000; ms = 0.176617 }, @{ n = 100000; ms = 0.353133 })
    Assert-Equal (Get-LcComplexity $fmp).Label 'O(n)' 'first-missing-positive: O(n) with a cache step'
    # majority-element by std::sort (O(n log n)) on the same machine: a 5.8x step at 3125, then 2.13x at the top.
    $sort = @(@{ n = 195; ms = 0.001065 }, @{ n = 390; ms = 0.002567 }, @{ n = 781; ms = 0.00601 }, @{ n = 1562; ms = 0.014055 },
        @{ n = 3125; ms = 0.0811 }, @{ n = 6250; ms = 0.20218 }, @{ n = 12500; ms = 0.48015 }, @{ n = 25000; ms = 1.0255 },
        @{ n = 50000; ms = 2.2004 }, @{ n = 100000; ms = 4.678 })
    Assert-Equal (Get-LcComplexity $sort).Label 'O(n log n)' 'std::sort: O(n log n) with a cache step'
    # A small maxN gives bench 1 or 2 sizes: slow calls there are too few sizes, not too fast.
    $fit = Get-LcComplexity @(@{ n = 10; ms = 40 })
    Assert-True ($fit.TooFast -and $fit.TooFew -and $fit.Label -eq 'too few sizes to tell') 'one slow size'
    $fit = Get-LcComplexity @(@{ n = 8; ms = 0.2 }, @{ n = 16; ms = 40 })
    Assert-True ($fit.TooFast -and $fit.TooFew) 'two slow sizes'
    Assert-True (-not (Get-LcComplexity (& $pts 1000, 2000, 4000, 8000 { param($n) 1e-9 * $n })).TooFew) 'too fast is not too few'

    $fit = Get-LcComplexity (& $pts 1000, 2000, 4000, 8000 { param($n) 1e-6 * $n * $n })
    $est = Get-LcEstimateMs -Fit $fit -N 100000
    Assert-True ([math]::Abs($est - 10000) -le 100)

    Assert-Equal (Get-LcTleVerdict 400) 'ok'
    Assert-Equal (Get-LcTleVerdict 800) 'borderline'
    Assert-Equal (Get-LcTleVerdict 1500) 'likely TLE'

    # Bench results: completed sizes, a measured cap (a real point) vs a predicted one, alloc, crash.
    $b = Read-LcBenchResults @('{"status":"start","n":8,"seed":1}', '{"n":8,"ms":0.5,"reps":50}',
        '{"status":"start","n":16,"seed":1}', '{"n":16,"ms":1.5,"reps":20}',
        '{"status":"start","n":32,"seed":1}', '{"capped":true,"n":32,"ms":2500}',
        '{"alloc":{"count":3,"bytes":800000,"peak":700000},"n":16}')
    Assert-Equal (@($b.Points | ForEach-Object { "$($_.n):$($_.ms)" }) -join ',') '8:0.5,16:1.5,32:2500'
    Assert-Equal (@($b.Points | ForEach-Object { [bool]$_.capped }) -join ',') 'False,False,True' 'the measured cap point is flagged'
    Assert-True ($b.Capped.n -eq 32 -and -not $b.Capped.Predicted) 'measured cap'
    Assert-True ($null -eq $b.Pending -and $null -eq $b.Error) 'a capped size is not pending'
    Assert-Equal "$($b.Alloc.count)|$($b.Alloc.bytes)|$($b.Alloc.peak)|$($b.Alloc.n)" '3|800000|700000|16'
    $b = Read-LcBenchResults @('{"status":"start","n":8,"seed":7}', '{"n":8,"ms":0.5,"reps":50,"per_call_us":62.5}',
        '{"capped":true,"n":16,"ms":9000,"per_call_us":562500,"predicted":true}')
    Assert-Equal @($b.Points).Count 1
    Assert-Equal $b.Points[0].per_call_us 62.5
    Assert-True ($b.Capped.Predicted -and $b.Capped.n -eq 16) 'predicted cap'
    $b = Read-LcBenchResults @('{"status":"start","n":8,"seed":7}', '{"n":8,"ms":0.5,"reps":50}', '{"status":"start","n":16,"seed":7}')
    Assert-Equal "$($b.Pending.n)|$($b.Pending.seed)" '16|7'
    $b = Read-LcBenchResults @('{"status":"start","n":8,"seed":3}', '{"n":8,"status":"error","error":"exception: boom"}')
    Assert-Equal "$($b.Error.n)|$($b.Error.seed)|$($b.Error.error)" '8|3|exception: boom'

    Assert-Equal (Get-LcPerCallLabel 'O(n)') 'O(1)'
    Assert-Equal (Get-LcPerCallLabel 'O(1)') 'O(1)'
    Assert-Equal (Get-LcPerCallLabel 'O(n log n)') 'O(log n)'
    Assert-Equal (Get-LcPerCallLabel 'O(n^2)') 'O(n)'

    Assert-Equal (Format-LcDuration 0.0123) '0.01 ms'
    Assert-Equal (Format-LcDuration 0.0032) '3.2 us'
    Assert-Equal (Format-LcDuration 12.34) '12.3 ms'
    Assert-Equal (Format-LcDuration 456.7) '457 ms'
    Assert-Equal (Format-LcDuration 4200) '4.2 s'
    Assert-Equal (Format-LcBytes 800000) '0.8 MB'
    Assert-Equal (Format-LcBytes 23720) '23.2 KB'
    Assert-Equal (Format-LcBytes 12) '12 B'
    Assert-Equal (Format-LcPerCallUs 0.080655) '0.08 us/call'
    Assert-Equal (Format-LcPerCallUs 12.34) '12.3 us/call'

    # R16: a grid's size is its cells, so MaxN is len_max^2 (capped at 10^7 like bench), not rows.
    $gi = Get-LcInfoFromMeta '{"name":"numIslands","params":[{"name":"grid","type":"character[][]"}],"return":{"type":"integer"}}'
    Assert-Equal (ConvertTo-LcSpec -Constraints @('1 <= grid.length <= 200') -Info $gi).MaxN 40000
    $gi = Get-LcInfoFromMeta '{"name":"f","params":[{"name":"grid","type":"integer[][]"}],"return":{"type":"integer"}}'
    Assert-Equal (ConvertTo-LcSpec -Constraints @('1 <= grid.length <= 10^5') -Info $gi).MaxN 10000000
    Assert-Equal (ConvertTo-LcSpec -Constraints @() -Info $gi).MaxN 10000000
    # R36: a word list's size is its number of strings, as bench reports it.
    $wi = Get-LcInfoFromMeta '{"name":"f","params":[{"name":"words","type":"string[]"}],"return":{"type":"integer"}}'
    Assert-Equal (ConvertTo-LcSpec -Constraints @('1 <= words.length <= 5000') -Info $wi).MaxN 5000

    # Call counts: short names and the printed line.
    Assert-Equal (Get-LcShortName 'Solution::climbStairs(int)') 'climbStairs'
    Assert-Equal (Get-LcShortName 'Solution::dfs(TreeNode*, std::vector<int, std::allocator<int> >&) const') 'dfs'
    Assert-Equal (Get-LcShortName 'gcd(int, int)') 'gcd'
    Assert-Equal (Get-LcShortName 'Solution::f(int)::{lambda(int)#1}::operator()(int) const') 'lambda in f'
    # Template instances start with their return type; a generic lambda's operator() has template arguments.
    Assert-Equal (Get-LcShortName 'int Solution::f(std::vector<int, std::allocator<int> >&)::{lambda(auto:1&&, int)#1}::operator()<{lambda(auto:1&&, int)#1}&>({lambda(auto:1&&, int)#1}&, int) const') 'lambda in f'
    Assert-Equal (Get-LcShortName 'std::vector<int, std::allocator<int> > Solution::go<int>(int, int)') 'go<int>'
    Assert-Equal (Get-LcShortName 'long long pw<long long>(long long)') 'pw<long long>'
    Assert-Equal (Format-LcCallsLine -N 30 -Profile @(@{ Name = 'Solution::climbStairs(int)'; Calls = 1664079; Depth = 30 })) 'climbStairs: 1,664,079 calls, max depth 30 at n = 30'
    $many = @(@{ Name = 'Solution::a(int)'; Calls = 9; Depth = 3 }, @{ Name = 'Solution::b()'; Calls = 1; Depth = 1 },
        @{ Name = 'Solution::c(int)'; Calls = 5; Depth = 1 }, @{ Name = 'Solution::d(int)'; Calls = 4; Depth = 2 })
    Assert-Equal (Format-LcCallsLine -N 8 -Profile $many) 'a: 9 calls, max depth 3; c: 5 calls, max depth 1; d: 4 calls, max depth 2 at n = 8'
    Assert-Equal (Format-LcCallsLine -N 8 -Profile @(@{ Name = 'Solution::f(int)'; Calls = 1; Depth = 1 }, @{ Name = 'Solution::g(int)'; Calls = 2; Depth = 1 })) 'g: 2 calls, max depth 1 at n = 8'
    # R40: nothing to say when every function ran once (a non-recursive solution).
    Assert-Equal (Format-LcCallsLine -N 8 -Profile @(@{ Name = 'Solution::twoSum(int)'; Calls = 1; Depth = 1 }, @{ Name = 'Solution::Solution()'; Calls = 1; Depth = 1 })) ''
    # R41: a profile run that threw resolves to nothing, so no partial line is printed.
    Assert-Equal @(Resolve-LcProfile -Exe 'unused.exe' -Lines @('{"status":"error","error":"exception: boom"}', '{"fn":"0x140001000","calls":7,"depth":3}')).Count 0

    # Call counts and recursion depth from the profile build: n=20 is 2*fib(21)-1 calls, depth 20 (R7 fixture).
    # Only the user's own functions are counted (no lc_user_* hooks, no STL).
    . (Join-Path $repo '.zed\common.ps1')
    . (Join-Path $repo '.zed\lc\build.ps1')
    $oldBuildRoot = $env:LC_BUILD_ROOT
    $env:LC_BUILD_ROOT = Join-Path $env:TEMP 'lc-analyze-build'
    try {
        $src = Join-Path $repo 'lc\selftest\climbing-stairs.cpp'
        $ci = Get-LcInfoFromMeta '{"name":"climbStairs","params":[{"name":"n","type":"integer"}],"return":{"type":"integer"}}'
        $build = Build-LcExe -SrcPath $src -HarnessText (New-LcHarnessText -Info $ci) -UserText (New-LcUserText -SrcPath $src -Info $ci) -Flavor profile
        Assert-True $build.Ok "profile build`n$($build.Errors)"
        $dir = Split-Path -Parent $build.Exe
        $specPath = Join-Path $dir 'profile-spec.txt'
        $resPath = Join-Path $dir 'profile-results.txt'
        [IO.File]::WriteAllText($specPath, "size n`nparam n val 1 45`n", (New-Object Text.UTF8Encoding $false))
        Remove-Item -LiteralPath $resPath -ErrorAction SilentlyContinue
        & $build.Exe profile $specPath $resPath --n 20 --seed 1
        Assert-Equal $LASTEXITCODE 0 'profile exit code'
        $p = @(Resolve-LcProfile -Exe $build.Exe -Lines ([IO.File]::ReadAllLines($resPath)))
        Assert-Equal (@($p | ForEach-Object { $_.Name }) -join ',') 'Solution::climbStairs(int)' 'profiled functions'
        Assert-Equal $p[0].Calls 21891
        Assert-Equal $p[0].Depth 20

        # R39: only toolchain headers are excluded, so a solution under an include\ folder is still counted,
        # and an STL-heavy solution counts only its own function.
        $profile = {
            param($SrcPath, $MetaJson, $SpecText, [long]$N)
            $i = Get-LcInfoFromMeta $MetaJson
            $b = Build-LcExe -SrcPath $SrcPath -HarnessText (New-LcHarnessText -Info $i) -UserText (New-LcUserText -SrcPath $SrcPath -Info $i) -Flavor profile
            Assert-True $b.Ok "profile build $SrcPath`n$($b.Errors)"
            $d = Split-Path -Parent $b.Exe
            [IO.File]::WriteAllText("$d\profile-spec.txt", $SpecText, (New-Object Text.UTF8Encoding $false))
            Remove-Item -LiteralPath "$d\profile-results.txt" -ErrorAction SilentlyContinue
            & $b.Exe profile "$d\profile-spec.txt" "$d\profile-results.txt" --n $N --seed 1
            return @(Resolve-LcProfile -Exe $b.Exe -Lines ([IO.File]::ReadAllLines("$d\profile-results.txt")))
        }
        $incDir = Join-Path $env:LC_BUILD_ROOT 'include'
        New-Item -ItemType Directory -Force $incDir | Out-Null
        Copy-Item -LiteralPath $src -Destination $incDir -Force
        $p = & $profile (Join-Path $incDir 'climbing-stairs.cpp') '{"name":"climbStairs","params":[{"name":"n","type":"integer"}],"return":{"type":"integer"}}' "size n`nparam n val 1 45`n" 20
        Assert-Equal (@($p | ForEach-Object { "$($_.Name)|$($_.Calls)|$($_.Depth)" }) -join ',') 'Solution::climbStairs(int)|21891|20' 'solution under include\'
        $p = & $profile (Join-Path $repo 'lc\selftest\two-sum.cpp') '{"name":"twoSum","params":[{"name":"nums","type":"integer[]"},{"name":"target","type":"integer"}],"return":{"type":"integer[]","size":2}}' "size nums`nparam nums len 2 1000 val -1000 1000`nparam target val -2000 2000`n" 1000
        Assert-Equal (@($p | ForEach-Object { "$($_.Name)|$($_.Calls)|$($_.Depth)" }) -join ',') 'Solution::twoSum(std::vector<int, std::allocator<int> >&, int)|1|1' 'STL excluded'
    } finally {
        $env:LC_BUILD_ROOT = $oldBuildRoot
    }

    # Task 13: brute-force check. The bugged memo version is off by one when n % 7 == 0; with n in [1, 10]
    # the first such case is n = 7 (21 ways).
    . (Join-Path $repo '.zed\lc\testfile.ps1')
    $env:LC_BUILD_ROOT = Join-Path $env:TEMP 'lc-analyze-build'
    try {
        $brute = Join-Path $repo 'lc\selftest\cases\climbing-stairs\brute.cpp'
        New-Item -ItemType Directory -Force $env:LC_BUILD_ROOT | Out-Null
        $specPath = Join-Path $env:LC_BUILD_ROOT 'brute-spec.txt'
        [IO.File]::WriteAllText($specPath, "size n`nparam n val 1 45`n", (New-Object Text.UTF8Encoding $false))
        $r = Invoke-LcBruteCheck -SrcPath (Join-Path $repo 'lc\selftest\bugged\climbing-stairs.cpp') -BrutePath $brute -Info $ci -SpecPath $specPath
        Assert-True (-not $r.Errors -and -not $r.Crashed) "brute check`n$($r.Errors)"
        Assert-Equal $r.Cases 200
        Assert-Equal $r.Mismatch.Input 'Input: n = 7'
        Assert-Equal $r.Mismatch.Got '22'
        Assert-Equal $r.Mismatch.Expected '21'
        $r = Invoke-LcBruteCheck -SrcPath (Join-Path $repo 'lc\selftest\climbing-stairs.cpp') -BrutePath $brute -Info $ci -SpecPath $specPath
        Assert-Equal $r.Cases 200
        Assert-Equal $r.Mismatch $null 'brute agrees'

        # A brute that crashes, hangs, doesn't build or exits oddly (cached builds after the first run).
        # Crashed is the first case with n = 5, in the gen file's order.
        $fixtures = Join-Path $repo 'lc\selftest\brute'
        $check = {
            param([string]$Fixture, [int]$TimeoutMs = 60000)
            Invoke-LcBruteCheck -SrcPath $src -BrutePath (Join-Path $fixtures $Fixture) -Info $ci -SpecPath $specPath -TimeoutMs $TimeoutMs
        }
        $firstFive = {
            param([string]$Fixture)
            $gen = Join-Path (Get-LcBuildDir (Join-Path $fixtures $Fixture)) 'brute-gen.txt'
            $ns = @([IO.File]::ReadAllLines($gen) | Where-Object { $_.StartsWith('arg ') })
            return [array]::IndexOf($ns, 'arg 5') + 1
        }
        $r = & $check 'crash.brute.cpp'
        Assert-True (-not $r.Errors -and -not $r.TimedOut -and $null -eq $r.Mismatch) "brute crash`n$($r.Errors)"
        Assert-True ($r.Crashed -gt 0) 'brute crash: case'
        Assert-Equal $r.Crashed (& $firstFive 'crash.brute.cpp') 'brute crash: the first n = 5 case'
        $r = & $check 'hang.brute.cpp' 1000
        Assert-True ($r.TimedOut -and $r.Crashed -gt 0) 'brute timeout'
        Assert-Equal $r.Crashed (& $firstFive 'hang.brute.cpp') 'brute timeout: the first n = 5 case'
        $r = & $check 'odd-exit.brute.cpp'
        Assert-True ($r.Crashed -eq 0 -and $null -ne $r.Crashed -and -not $r.TimedOut) "brute odd exit: no case to blame ($($r.Crashed))"
        $r = & $check 'broken.brute.cpp'
        Assert-Match $r.Errors "broken\.brute\.cpp:\d+:\d+: error: 'not_declared' was not declared"
        Assert-True ($null -eq $r.Crashed -and $null -eq $r.Mismatch) 'brute build failure'

        # Any order: the solution sorts up and the brute sorts down, so only -AnyOrder agrees.
        $ai = Get-LcInfoFromMeta '{"name":"arrange","params":[{"name":"nums","type":"integer[]"}],"return":{"type":"integer[]"}}'
        $aSpec = Join-Path $env:LC_BUILD_ROOT 'brute-any-spec.txt'
        [IO.File]::WriteAllText($aSpec, "size nums`nparam nums len 1 10 val 0 9`n", (New-Object Text.UTF8Encoding $false))
        $aArgs = @{ SrcPath = (Join-Path $fixtures 'sort-up.cpp'); BrutePath = (Join-Path $fixtures 'sort-down.brute.cpp'); Info = $ai; SpecPath = $aSpec }
        $r = Invoke-LcBruteCheck @aArgs
        Assert-True (-not $r.Errors -and $null -ne $r.Mismatch) "any order: ordered compare mismatches`n$($r.Errors)"
        $r = Invoke-LcBruteCheck @aArgs -AnyOrder
        Assert-True ($r.Cases -eq 200 -and $null -eq $r.Mismatch -and $null -eq $r.Crashed) 'any order: agrees'
    } finally {
        $env:LC_BUILD_ROOT = $oldBuildRoot
    }
}
