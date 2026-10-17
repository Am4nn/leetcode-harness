# Tests for .zed/lc/info.ps1 (dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact).
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repo '.zed\lc\info.ps1')

    $rotateMeta = '{"name":"rotate","params":[{"name":"nums","type":"integer[]"},{"name":"k","type":"integer"}],"return":{"type":"void"},"output":{"paramindex":0}}'
    $twoSumMeta = '{"name":"twoSum","params":[{"name":"nums","type":"integer[]"},{"name":"target","type":"integer"}],"return":{"type":"integer[]","size":2},"manual":false}'
    $lruMeta = '{"classname":"LRUCache","constructor":{"params":[{"name":"capacity","type":"integer"}]},"methods":[{"name":"get","params":[{"name":"key","type":"integer"}],"return":{"type":"integer"}},{"name":"put","params":[{"name":"key","type":"integer"},{"name":"value","type":"integer"}],"return":{"type":"void"}}],"systemdesign":true}'
    $concatMeta = '{"name":"getConcatenation","params":[{"name":"nums","type":"integer[]"}],"return":{"type":"integer[]"}}'

    $rot = Get-LcInfoFromMeta $rotateMeta
    Assert-Equal $rot.Kind 'function'
    Assert-Equal $rot.Method 'rotate'
    Assert-Equal $rot.OutParam 0
    Assert-Equal ($rot.ParamNames -join ',') 'nums,k'
    Assert-Equal ($rot.ParamTypes -join ',') 'vector<int>,int'

    $two = Get-LcInfoFromMeta $twoSumMeta
    Assert-Equal $two.OutParam -1

    $lru = Get-LcInfoFromMeta $lruMeta
    Assert-Equal $lru.Kind 'design'
    Assert-Equal $lru.Class 'LRUCache'
    Assert-Equal ($lru.CtorTypes -join ',') 'int'
    Assert-Equal ($lru.CtorNames -join ',') 'capacity'
    $put = $lru.Methods | Where-Object { $_.Name -eq 'put' }
    Assert-Equal ($put.ParamNames -join ',') 'key,value'

    Assert-Equal (ConvertTo-LcCppType 'integer[][]') 'vector<vector<int>>'
    Assert-Equal (ConvertTo-LcCppType 'list<list<string>>') 'vector<vector<string>>'
    Assert-Equal (ConvertTo-LcCppType 'TreeNode') 'TreeNode*'
    $threw = ''
    try { ConvertTo-LcCppType 'Node' | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-Equal $threw 'unsupported LeetCode type: Node'

    $src = [IO.File]::ReadAllText((Join-Path $repo 'leetcode-solves\concatenation-of-array.cpp'))
    $si = Get-LcInfoFromSource $src
    Assert-Equal $si.Method 'shuffle'
    Assert-Equal ($si.ParamNames -join ',') 'nums,n'
    Assert-Equal ($si.ParamTypes -join ',') 'vector<int>,int'
    Assert-Equal $si.OutParam -1

    $tricky = "class Solution {`nint helper(int z) { return z; }`npublic:`n Solution() {}`n int f(const vector<int> &nums, string s) { if (s.empty()) { return 1; } return 2; }`nprivate:`n int g(int q);`n};"
    $ti = Get-LcInfoFromSource $tricky
    Assert-Equal $ti.Method 'f'
    Assert-Equal ($ti.ParamNames -join ',') 'nums,s'
    Assert-Equal ($ti.ParamTypes -join ',') 'vector<int>,string'
    Assert-Equal @($ti.AllMethods).Count 1
    Assert-True ($null -eq (Get-LcInfoFromSource 'int main() {}'))

    $msg = Test-LcMethodMatch (Get-LcInfoFromMeta $concatMeta) $src
    Assert-Equal $msg "LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)"
    Assert-True ($null -eq (Test-LcMethodMatch $rot "class Solution { public: void rotate(vector<int>& nums, int k) {} };"))
    Assert-Equal (Test-LcMethodMatch $lru $src) "LeetCode expects class LRUCache but your file doesn't define it"
    Assert-True ($null -eq (Test-LcMethodMatch $lru "class LRUCache { public: LRUCache(int c) {} };"))

    $w = New-LcWrapperText -SrcPath 'C:/x/rotate.cpp' -Info $rot
    Assert-Match $w ([regex]::Escape('#include "C:/x/rotate.cpp"'))
    Assert-Match $w ([regex]::Escape('&Solution::rotate, {"nums","k"}, 0'))
    $wl = New-LcWrapperText -SrcPath 'C:/x/lru.cpp' -Info $lru
    Assert-Match $wl ([regex]::Escape('lc::run_design<LRUCache, int>'))
    Assert-Match $wl ([regex]::Escape('{"capacity"}, {{"get", lc::method(&LRUCache::get, {"key"})}, {"put", lc::method(&LRUCache::put, {"key","value"})}}'))
}
