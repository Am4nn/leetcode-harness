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
    Assert-True (Get-LcComplexity (& $pts 1000, 2000, 4000, 8000 { param($n) 1e-6 * $n })).TooFast

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
}
