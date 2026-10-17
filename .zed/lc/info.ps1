# Problem info (from LeetCode metaData or solution source), C++ type mapping, harness and user TU text.
# Function library: dot-source it. No side effects.

function ConvertTo-LcCppType([string]$t) {
    $t = $t.Trim()
    if ($t.EndsWith('[]')) { return 'vector<' + (ConvertTo-LcCppType $t.Substring(0, $t.Length - 2)) + '>' }
    if ($t -match '^list<(.+)>$') { return 'vector<' + (ConvertTo-LcCppType $Matches[1]) + '>' }
    switch ($t) {
        'integer'   { return 'int' }
        'long'      { return 'long long' }
        'double'    { return 'double' }
        'boolean'   { return 'bool' }
        'character' { return 'char' }
        'string'    { return 'string' }
        'TreeNode'  { return 'TreeNode*' }
        'ListNode'  { return 'ListNode*' }
    }
    throw "unsupported LeetCode type: $t"
}

function ConvertTo-LcReturnType($ret) {
    if (-not $ret -or -not $ret.type -or $ret.type -eq 'void') { return 'void' }
    return ConvertTo-LcCppType $ret.type
}

# $srcText (optional) settles the output parameter of a void method when the metadata doesn't name it.
function Get-LcInfoFromMeta([string]$metaDataJson, [string]$srcText = '') {
    $m = $metaDataJson | ConvertFrom-Json
    if ($m.classname -or $m.systemdesign) {
        $ctor = @()
        if ($m.constructor -and $m.constructor.params) { $ctor = @($m.constructor.params) }
        $methods = @()
        foreach ($x in @($m.methods)) {
            $ps = @(); if ($x.params) { $ps = @($x.params) }
            $methods += [pscustomobject]@{
                Name       = [string]$x.name
                ParamNames = [string[]]@($ps | ForEach-Object { [string]$_.name })
                ParamTypes = [string[]]@($ps | ForEach-Object { ConvertTo-LcCppType $_.type })
                ReturnType = ConvertTo-LcReturnType $x.return
            }
        }
        return [pscustomobject]@{
            Kind      = 'design'
            Class     = [string]$m.classname
            CtorNames = [string[]]@($ctor | ForEach-Object { [string]$_.name })
            CtorTypes = [string[]]@($ctor | ForEach-Object { ConvertTo-LcCppType $_.type })
            Methods   = $methods
        }
    }
    $ps = @(); if ($m.params) { $ps = @($m.params) }
    $ret = ConvertTo-LcReturnType $m.return
    $out = -1
    if ($m.output -and $null -ne $m.output.paramindex) { $out = [int]$m.output.paramindex }
    elseif ($ret -eq 'void') {
        # The proxy takes every parameter by reference, so name the output: the source's first
        # non-const reference parameter, else the first parameter.
        $out = 0
        $si = $null
        if ($srcText) { $si = Get-LcInfoFromSource $srcText }
        if ($si) { foreach ($x in $si.AllMethods) { if ($x.Name -eq $m.name) { $out = [Math]::Max(0, $x.OutParam); break } } }
    }
    return [pscustomobject]@{
        Kind       = 'function'
        Method     = [string]$m.name
        ParamNames = [string[]]@($ps | ForEach-Object { [string]$_.name })
        ParamTypes = [string[]]@($ps | ForEach-Object { ConvertTo-LcCppType $_.type })
        ReturnType = $ret
        OutParam   = $out
    }
}

function Split-LcTopLevel([string]$s) {
    $parts = @(); $depth = 0; $cur = ''
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '<' -or $c -eq '(') { $depth++ }
        elseif ($c -eq '>' -or $c -eq ')') { $depth-- }
        if ($c -eq ',' -and $depth -eq 0) { $parts += $cur; $cur = '' } else { $cur += $c }
    }
    if ($cur.Trim()) { $parts += $cur }
    return $parts
}

function ConvertTo-LcParam([string]$p) {
    $p = ($p -replace '=.*$', '').Trim()
    if ($p -notmatch '^(.*?)(\w+)\s*$') { return $null }
    $type = $Matches[1]; $name = $Matches[2]
    $mutRef = $type -match '[^&]&\s*$' -and $type -notmatch '\bconst\b'
    return [pscustomobject]@{ Name = $name; Type = (ConvertTo-LcTypeText $type); MutRef = $mutRef }
}

# A declared type without const, references or decorative spacing: 'const vector<int> &' -> 'vector<int>'.
function ConvertTo-LcTypeText([string]$type) {
    $type = $type -replace '\bconst\b', '' -replace '&', ''
    $type = ($type -replace '\s+', ' ').Trim()
    return $type -replace '\s*([<>,*])\s*', '$1'
}

# Simple type aliases in the (comment-free) solution text, name -> type text (case-sensitive):
# `using X = T;` (not alias templates), `typedef T X;` and object-like `#define X T`.
function Get-LcTypeAliases([string]$text) {
    $aliases = New-Object 'Collections.Generic.Dictionary[string,string]'
    foreach ($m in [regex]::Matches($text, '(template\s*<[^;{}]*?>\s*)?\busing\s+(\w+)\s*=\s*([^;{}]+);')) {
        if (-not $m.Groups[1].Success) { $aliases[$m.Groups[2].Value] = $m.Groups[3].Value }
    }
    foreach ($m in [regex]::Matches($text, '\btypedef\s+([^;{}()]+?)\s+(\w+)\s*;')) {
        $aliases[$m.Groups[2].Value] = $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($text, '(?m)^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+([\w \t<>,:*&]+?)[ \t]*\r?$')) {
        $aliases[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $aliases
}

# Substitutes aliases into a type (repeatedly, for aliases of aliases), then normalizes it.
function Resolve-LcTypeAliases([string]$type, $aliases) {
    for ($n = 0; $n -lt 10 -and $aliases.Count; $n++) {
        $before = $type
        foreach ($k in $aliases.Keys) {
            $type = [regex]::Replace($type, '(?<![\w:])' + [regex]::Escape($k) + '(?!\w)', $aliases[$k].Replace('$', '$$'))
        }
        if ($type -ceq $before) { break }
    }
    return ConvertTo-LcTypeText $type
}

# For source-derived info: a line explaining why the harness TU can't compile its types (an identifier
# that isn't a C++ builtin, a std name, TreeNode or ListNode; or an auto return type), else $null.
function Get-LcSourceTypeProblem($Info, [string]$SrcText) {
    $known = @(
        'void', 'bool', 'char', 'wchar_t', 'char8_t', 'char16_t', 'char32_t', 'short', 'int', 'long', 'signed', 'unsigned',
        'float', 'double', '__int128', 'size_t', 'ptrdiff_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t', 'uint8_t',
        'uint16_t', 'uint32_t', 'uint64_t', 'intmax_t', 'uintmax_t', 'string', 'wstring', 'u16string', 'u32string',
        'string_view', 'vector', 'array', 'deque', 'list', 'forward_list', 'map', 'multimap', 'set', 'multiset',
        'unordered_map', 'unordered_multimap', 'unordered_set', 'unordered_multiset', 'pair', 'tuple', 'optional',
        'variant', 'bitset', 'stack', 'queue', 'priority_queue', 'function', 'less', 'greater', 'hash', 'complex',
        'valarray', 'span', 'any', 'TreeNode', 'ListNode')
    foreach ($t in @($Info.ReturnType) + @($Info.ParamTypes)) {
        foreach ($m in [regex]::Matches(($t -replace '\bstd::', ''), '[A-Za-z_]\w*')) {
            $w = $m.Value
            if ($known -ccontains $w) { continue }
            if ($SrcText -cmatch "\b(struct|class|enum|union)\s+$w\b") {
                return "This problem uses a parameter type the harness doesn't support yet: $w"
            }
            return "Spell the full type in the method signature (found: $w)."
        }
    }
    return $null
}

function Get-LcInfoFromSource([string]$srcText) {
    $text = $srcText -replace '(?s)/\*.*?\*/', ' ' -replace '//[^\r\n]*', ' '
    $mt = [regex]::Match($text, '\bclass\s+Solution\b[^{;]*\{')
    if (-not $mt.Success) { return $null }
    # Keep only depth-0 class members; nested braces collapse to {}.
    $flat = New-Object Text.StringBuilder
    $depth = 0
    for ($i = $mt.Index + $mt.Length; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($c -eq '{') { if ($depth -eq 0) { [void]$flat.Append('{') }; $depth++; continue }
        if ($c -eq '}') {
            if ($depth -eq 0) { break }
            $depth--
            if ($depth -eq 0) { [void]$flat.Append('}') }
            continue
        }
        if ($depth -eq 0) { [void]$flat.Append($c) }
    }
    $aliases = Get-LcTypeAliases $text
    $public = $false
    $methods = @()
    foreach ($chunk in ($flat.ToString() -split '[;}]')) {
        $c = $chunk
        while ($c -match '(?s)^\s*(public|private|protected)\s*:(.*)$') {
            $public = ($Matches[1] -eq 'public'); $c = $Matches[2]
        }
        if (-not $public) { continue }
        $dm = [regex]::Match($c, '(?s)^\s*([^(=]*?)\b(\w+)\s*\(([^()]*)\)')
        if (-not $dm.Success) { continue }
        $ret = $dm.Groups[1].Value.Trim()
        $nm = $dm.Groups[2].Value
        # Skips constructors (no return type), the destructor (~Solution), operators and type aliases.
        if (-not $ret -or $nm -eq 'operator' -or $ret.EndsWith('~') -or $ret -match '^(using|typedef)\b') { continue }
        $params = @(Split-LcTopLevel $dm.Groups[3].Value | ForEach-Object { ConvertTo-LcParam $_ } | Where-Object { $_ })
        # The harness TU never sees the solution, so its aliases are spelled out.
        foreach ($p in $params) { $p.Type = Resolve-LcTypeAliases $p.Type $aliases }
        $retType = Resolve-LcTypeAliases ($ret -replace '\b(static|inline|virtual|constexpr)\b', '') $aliases
        # A void method's output: its first non-const reference parameter, else the first parameter.
        $out = -1
        if ($retType -eq 'void') {
            $out = 0
            for ($k = 0; $k -lt $params.Count; $k++) { if ($params[$k].MutRef) { $out = $k; break } }
        }
        $methods += [pscustomobject]@{
            Name       = $nm
            ParamNames = [string[]]@($params | ForEach-Object { $_.Name })
            ParamTypes = [string[]]@($params | ForEach-Object { $_.Type })
            ReturnType = $retType
            OutParam   = $out
        }
    }
    if ($methods.Count -eq 0) { return $null }
    $first = $methods[0]
    return [pscustomobject]@{
        Kind       = 'function'
        Method     = $first.Name
        ParamNames = $first.ParamNames
        ParamTypes = $first.ParamTypes
        ReturnType = $first.ReturnType
        OutParam   = $first.OutParam
        AllMethods = @($methods | ForEach-Object { @{ Name = $_.Name; ParamNames = $_.ParamNames; OutParam = $_.OutParam } })
    }
}

function Test-LcMethodMatch($metaInfo, [string]$srcText) {
    if ($metaInfo.Kind -eq 'design') {
        if ($srcText -match "\b(class|struct)\s+$([regex]::Escape($metaInfo.Class))\b") { return $null }
        return "LeetCode expects class $($metaInfo.Class) but your file doesn't define it"
    }
    $expected = "$($metaInfo.Method)($($metaInfo.ParamNames -join ', '))"
    $si = Get-LcInfoFromSource $srcText
    if (-not $si) { return "LeetCode expects $expected but your file has no class Solution with a public method" }
    foreach ($m in $si.AllMethods) { if ($m.Name -eq $metaInfo.Method) { return $null } }
    return "LeetCode expects $expected but your Solution has $($si.Method)($($si.ParamNames -join ', '))"
}

function New-LcNameList([string[]]$names) {
    return '{' + ((@($names) | ForEach-Object { '"' + $_ + '"' }) -join ',') + '}'
}

# "T1&, T2&" (Prefix empty) or "T1& a0, T2& a1": the hook and proxy parameters, all non-const references.
function New-LcRefParams([string[]]$Types, [string]$Prefix = '') {
    $i = 0
    return (@($Types) | ForEach-Object {
        if ($Prefix) { "$_& $Prefix$i" } else { "$_&" }
        $i++
    }) -join ', '
}

function New-LcArgNames([int]$Count, [string]$Prefix) {
    if ($Count -le 0) { return '' }
    return (@(0..($Count - 1)) | ForEach-Object { "$Prefix$_" }) -join ', '
}

# Joins a leading argument with an argument list that may be empty.
function Join-LcArgs([string]$first, [string]$rest) {
    if ($rest) { return "$first, $rest" }
    return $first
}

# The harness TU (compiled with lc.h, cached per signature): hook declarations, the LcProxy class that
# forwards to them, and main() running lc-run.h on LcProxy. LcProxy owns the solution object (a Solution,
# or the design class), so the runner constructs it outside the timed call. ClassName (default
# Info.Class) is what design cases call the class (ops[0]).
function New-LcHarnessText {
    param([Parameter(Mandatory)]$Info, [string]$ClassName = '')
    $design = $Info.Kind -eq 'design'
    if ($design) {
        $ctorTypes = @($Info.CtorTypes)
        $new = 'lc_user_new'; $delete = 'lc_user_delete'
        $methods = @($Info.Methods | ForEach-Object { @{ Name = $_.Name; Hook = "lc_user_m_$($_.Name)"; Types = $_.ParamTypes; Ret = $_.ReturnType } })
    } else {
        $ctorTypes = @()
        $new = 'lc_user_new_solution'; $delete = 'lc_user_delete_solution'
        $methods = @(@{ Name = 'call'; Hook = 'lc_user_call'; Types = $Info.ParamTypes; Ret = $Info.ReturnType })
    }
    $lines = @("void* $new($(New-LcRefParams $ctorTypes));", "void $delete(void*);")
    foreach ($m in $methods) { $lines += "$($m.Ret) $($m.Hook)($(Join-LcArgs 'void*' (New-LcRefParams $m.Types)));" }
    $lines += 'struct LcProxy {'
    $lines += '    void* lc_self_;'
    $lines += "    LcProxy($(New-LcRefParams $ctorTypes 'c')) : lc_self_($new($(New-LcArgNames $ctorTypes.Count 'c'))) {}"
    $lines += "    ~LcProxy() { $delete(lc_self_); }"
    $lines += '    LcProxy(const LcProxy&) = delete;'
    $lines += '    LcProxy& operator=(const LcProxy&) = delete;'
    foreach ($m in $methods) {
        $call = "$($m.Hook)($(Join-LcArgs 'lc_self_' (New-LcArgNames @($m.Types).Count 'a')))"
        if ($m.Ret -ne 'void') { $call = "return $call" }
        $lines += "    $($m.Ret) $($m.Name)($(New-LcRefParams $m.Types 'a')) { $call; }"
    }
    $lines += '};'
    if ($design) {
        if (-not $ClassName) { $ClassName = $Info.Class }
        $lines += 'namespace lc { template <> struct DesignName<LcProxy> { static std::string get() { return "' + $ClassName + '"; } }; }'
        $targs = (@('LcProxy') + $ctorTypes) -join ', '
        $ms = @($Info.Methods | ForEach-Object {
            '{"' + $_.Name + '", lc::method(&LcProxy::' + $_.Name + ', ' + (New-LcNameList $_.ParamNames) + ')}'
        }) -join ', '
        $lines += "int main(int argc, char** argv) { return lc::run_design<$targs>(argc, argv, $(New-LcNameList $Info.CtorNames), {$ms}); }"
    } else {
        $lines += "int main(int argc, char** argv) { return lc::run_function(argc, argv, &LcProxy::call, $(New-LcNameList $Info.ParamNames), $($Info.OutParam)); }"
    }
    return ($lines -join "`n") + "`n"
}

# The user TU (recompiled on every edit): the solution file and the hook definitions that call into it.
function New-LcUserText {
    param([Parameter(Mandatory)][string]$SrcPath, [Parameter(Mandatory)]$Info)
    $lines = @('#include "' + ($SrcPath -replace '\\', '/') + '"')
    if ($Info.Kind -eq 'design') {
        $cls = $Info.Class
        $ctorTypes = @($Info.CtorTypes)
        $lines += "void* lc_user_new($(New-LcRefParams $ctorTypes 'c')) { return new $cls($(New-LcArgNames $ctorTypes.Count 'c')); }"
        $lines += "void lc_user_delete(void* lc_self) { delete static_cast<$cls*>(lc_self); }"
        $methods = @($Info.Methods | ForEach-Object { @{ Name = $_.Name; Hook = "lc_user_m_$($_.Name)"; Types = $_.ParamTypes; Ret = $_.ReturnType } })
    } else {
        $cls = 'Solution'
        # Default-initialized, like a local `Solution s;`.
        $lines += 'void* lc_user_new_solution() { return new Solution; }'
        $lines += 'void lc_user_delete_solution(void* lc_self) { delete static_cast<Solution*>(lc_self); }'
        $methods = @(@{ Name = $Info.Method; Hook = 'lc_user_call'; Types = $Info.ParamTypes; Ret = $Info.ReturnType })
    }
    foreach ($m in $methods) {
        $call = "static_cast<$cls*>(lc_self)->$($m.Name)($(New-LcArgNames @($m.Types).Count 'a'))"
        if ($m.Ret -ne 'void') { $call = "return $call" }
        $lines += "$($m.Ret) $($m.Hook)($(Join-LcArgs 'void* lc_self' (New-LcRefParams $m.Types 'a'))) { $call; }"
    }
    return ($lines -join "`n") + "`n"
}
