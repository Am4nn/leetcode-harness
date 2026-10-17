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

    $tricky = "class Solution {`nint helper(int z) { return z; }`npublic:`n Solution() {}`n ~Solution() {}`n int f(const vector<int> &nums, string s) { if (s.empty()) { return 1; } return 2; }`nprivate:`n int g(int q);`n};"
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

    # Return types and explicit out indexes.
    Assert-Equal $rot.ReturnType 'void'
    Assert-Equal $two.ReturnType 'vector<int>'
    Assert-Equal (($lru.Methods | ForEach-Object { $_.ReturnType }) -join ',') 'int,void'
    Assert-Equal $si.ReturnType 'vector<int>'
    Assert-Equal $ti.ReturnType 'int'
    $noOut = '{"name":"rotate","params":[{"name":"nums","type":"integer[]"},{"name":"k","type":"integer"}],"return":{"type":"void"}}'
    $mutSrc = "class Solution {`npublic:`n    void rotate(const vector<int>& nums, int& k) {}`n};"
    Assert-Equal (Get-LcInfoFromMeta $noOut $mutSrc).OutParam 1
    Assert-Equal (Get-LcInfoFromMeta $noOut 'class Solution { public: void rotate(vector<int> nums, int k) {} };').OutParam 0
    Assert-Equal (Get-LcInfoFromMeta $noOut).OutParam 0
    $vs = Get-LcInfoFromSource "class Solution {`npublic:`n    static inline void sortColors(int n, vector<int>& nums) {}`n};"
    Assert-Equal $vs.ReturnType 'void'
    Assert-Equal $vs.OutParam 1
    Assert-Equal (Get-LcInfoFromSource 'class Solution { public: void f(const string& s) {} };').OutParam 0
    Assert-Equal (Get-LcInfoFromSource 'class Solution { public: const vector<int>& f(int k) {} };').ReturnType 'vector<int>'

    function Assert-Text([string]$actual, [string]$expected) {
        if ($actual -cne $expected) { throw "text differs`n--- expected:`n$expected`n--- actual:`n$actual" }
    }

    Assert-Text (New-LcHarnessText -Info $rot) ((@(
        'void* lc_user_new_solution();'
        'void lc_user_delete_solution(void*);'
        'void lc_user_call(void*, vector<int>&, int&);'
        'struct LcProxy {'
        '    void* lc_self_;'
        '    LcProxy() : lc_self_(lc_user_new_solution()) {}'
        '    ~LcProxy() { lc_user_delete_solution(lc_self_); }'
        '    LcProxy(const LcProxy&) = delete;'
        '    LcProxy& operator=(const LcProxy&) = delete;'
        '    void call(vector<int>& a0, int& a1) { lc_user_call(lc_self_, a0, a1); }'
        '};'
        'int main(int argc, char** argv) { return lc::run_function(argc, argv, &LcProxy::call, {"nums","k"}, 0); }'
    ) -join "`n") + "`n")
    Assert-Text (New-LcUserText -SrcPath 'C:\x\rotate.cpp' -Info $rot) ((@(
        '#include "C:/x/rotate.cpp"'
        'void* lc_user_new_solution() { return new Solution; }'
        'void lc_user_delete_solution(void* lc_self) { delete static_cast<Solution*>(lc_self); }'
        'void lc_user_call(void* lc_self, vector<int>& a0, int& a1) { static_cast<Solution*>(lc_self)->rotate(a0, a1); }'
    ) -join "`n") + "`n")

    Assert-Text (New-LcHarnessText -Info $two) ((@(
        'void* lc_user_new_solution();'
        'void lc_user_delete_solution(void*);'
        'vector<int> lc_user_call(void*, vector<int>&, int&);'
        'struct LcProxy {'
        '    void* lc_self_;'
        '    LcProxy() : lc_self_(lc_user_new_solution()) {}'
        '    ~LcProxy() { lc_user_delete_solution(lc_self_); }'
        '    LcProxy(const LcProxy&) = delete;'
        '    LcProxy& operator=(const LcProxy&) = delete;'
        '    vector<int> call(vector<int>& a0, int& a1) { return lc_user_call(lc_self_, a0, a1); }'
        '};'
        'int main(int argc, char** argv) { return lc::run_function(argc, argv, &LcProxy::call, {"nums","target"}, -1); }'
    ) -join "`n") + "`n")
    Assert-Text (New-LcUserText -SrcPath 'C:/x/two-sum.cpp' -Info $two) ((@(
        '#include "C:/x/two-sum.cpp"'
        'void* lc_user_new_solution() { return new Solution; }'
        'void lc_user_delete_solution(void* lc_self) { delete static_cast<Solution*>(lc_self); }'
        'vector<int> lc_user_call(void* lc_self, vector<int>& a0, int& a1) { return static_cast<Solution*>(lc_self)->twoSum(a0, a1); }'
    ) -join "`n") + "`n")

    Assert-Text (New-LcHarnessText -Info $lru -ClassName 'LRUCache') ((@(
        'void* lc_user_new(int&);'
        'void lc_user_delete(void*);'
        'int lc_user_m_get(void*, int&);'
        'void lc_user_m_put(void*, int&, int&);'
        'struct LcProxy {'
        '    void* lc_self_;'
        '    LcProxy(int& c0) : lc_self_(lc_user_new(c0)) {}'
        '    ~LcProxy() { lc_user_delete(lc_self_); }'
        '    LcProxy(const LcProxy&) = delete;'
        '    LcProxy& operator=(const LcProxy&) = delete;'
        '    int get(int& a0) { return lc_user_m_get(lc_self_, a0); }'
        '    void put(int& a0, int& a1) { lc_user_m_put(lc_self_, a0, a1); }'
        '};'
        'namespace lc { template <> struct DesignName<LcProxy> { static std::string get() { return "LRUCache"; } }; }'
        'int main(int argc, char** argv) { return lc::run_design<LcProxy, int>(argc, argv, {"capacity"}, {{"get", lc::method(&LcProxy::get, {"key"})}, {"put", lc::method(&LcProxy::put, {"key","value"})}}); }'
    ) -join "`n") + "`n")
    Assert-Text (New-LcUserText -SrcPath 'C:/x/lru.cpp' -Info $lru) ((@(
        '#include "C:/x/lru.cpp"'
        'void* lc_user_new(int& c0) { return new LRUCache(c0); }'
        'void lc_user_delete(void* lc_self) { delete static_cast<LRUCache*>(lc_self); }'
        'int lc_user_m_get(void* lc_self, int& a0) { return static_cast<LRUCache*>(lc_self)->get(a0); }'
        'void lc_user_m_put(void* lc_self, int& a0, int& a1) { static_cast<LRUCache*>(lc_self)->put(a0, a1); }'
    ) -join "`n") + "`n")

    # A design class without constructor parameters; ClassName defaults to Info.Class.
    $stackMeta = '{"classname":"MinStack","constructor":{"params":[]},"methods":[{"name":"top","params":[],"return":{"type":"integer"}}],"systemdesign":true}'
    $stack = Get-LcInfoFromMeta $stackMeta
    $hs = New-LcHarnessText -Info $stack
    Assert-True $hs.Contains('    LcProxy() : lc_self_(lc_user_new()) {}') $hs
    Assert-True $hs.Contains('return "MinStack";') $hs
    Assert-True $hs.Contains('lc::run_design<LcProxy>(argc, argv, {}, {{"top", lc::method(&LcProxy::top, {})}})') $hs
    $us = New-LcUserText -SrcPath 'C:/x/min-stack.cpp' -Info $stack
    Assert-True $us.Contains('void* lc_user_new() { return new MinStack(); }') $us
    Assert-True $us.Contains('int lc_user_m_top(void* lc_self) { return static_cast<MinStack*>(lc_self)->top(); }') $us
    # R24: aliases in the solution are resolved; what the harness still can't know is reported, not compiled.
    $alSrc = "#define VI vector<int>`nusing ll = long long;`ntypedef vector<ll> vll;`ntemplate <class T> using V = vector<T>;`nclass Solution {`npublic:`n    ll f(vll& a, VI b) { return 0; }`n    int g(V<int> c) { return 0; }`n};"
    $al = Get-LcInfoFromSource $alSrc
    Assert-Equal ($al.ParamTypes -join ';') 'vector<long long>;vector<int>'
    Assert-Equal $al.ReturnType 'long long'
    Assert-True ($null -eq (Get-LcSourceTypeProblem $al $alSrc))
    $gSrc = $alSrc.Replace('    ll f(vll& a, VI b) { return 0; }', '')
    Assert-Equal (Get-LcSourceTypeProblem (Get-LcInfoFromSource $gSrc) $gSrc) 'Spell the full type in the method signature (found: V).'
    $autoSrc = 'class Solution { public: auto f(int a) { return a; } };'
    Assert-Equal (Get-LcSourceTypeProblem (Get-LcInfoFromSource $autoSrc) $autoSrc) 'Spell the full type in the method signature (found: auto).'
    $nodeSrc = "struct Node { int v; };`nclass Solution { public: int f(Node* n) { return 0; } };"
    Assert-Equal (Get-LcSourceTypeProblem (Get-LcInfoFromSource $nodeSrc) $nodeSrc) "This problem uses a parameter type the harness doesn't support yet: Node"
    $stdSrc = 'class Solution { public: int f(std::vector<std::string>& w, map<int, long long> m, size_t n, TreeNode* t, unsigned int u) { return 0; } };'
    Assert-True ($null -eq (Get-LcSourceTypeProblem (Get-LcInfoFromSource $stdSrc) $stdSrc))
    $defSrc = "#define int long long`nclass Solution { public: int f(vector<int>& a) { return 0; } };"
    $di = Get-LcInfoFromSource $defSrc
    Assert-Equal "$($di.ReturnType);$($di.ParamTypes)" 'long long;vector<long long>'
}
