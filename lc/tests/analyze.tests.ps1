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
}
