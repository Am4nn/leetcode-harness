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
        if (-not $ret -or $nm -eq 'operator' -or $ret -match '^(using|typedef)\b') { continue }
        $params = @(Split-LcTopLevel $dm.Groups[3].Value | ForEach-Object { ConvertTo-LcParam $_ } | Where-Object { $_ })
        $retType = ConvertTo-LcTypeText ($ret -replace '\b(static|inline|virtual|constexpr)\b', '')
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
# forwards to them, and main() running lc-run.h on LcProxy. ClassName (default Info.Class) is what
# design cases call the class (ops[0]).
function New-LcHarnessText {
    param([Parameter(Mandatory)]$Info, [string]$ClassName = '')
    $lines = @()
    $copy = @('    LcProxy(const LcProxy&) = delete;', '    LcProxy& operator=(const LcProxy&) = delete;')
    if ($Info.Kind -eq 'design') {
        if (-not $ClassName) { $ClassName = $Info.Class }
        $lines += "void* lc_user_new($(New-LcRefParams $Info.CtorTypes));"
        $lines += 'void lc_user_delete(void*);'
        foreach ($m in $Info.Methods) {
            $lines += "$($m.ReturnType) lc_user_m_$($m.Name)($(Join-LcArgs 'void*' (New-LcRefParams $m.ParamTypes)));"
        }
        $lines += 'struct LcProxy {'
        $lines += '    void* p;'
        $lines += "    LcProxy($(New-LcRefParams $Info.CtorTypes 'c')) : p(lc_user_new($(New-LcArgNames @($Info.CtorTypes).Count 'c'))) {}"
        $lines += '    ~LcProxy() { lc_user_delete(p); }'
        $lines += $copy
        foreach ($m in $Info.Methods) {
            $call = "lc_user_m_$($m.Name)($(Join-LcArgs 'p' (New-LcArgNames @($m.ParamTypes).Count 'a')))"
            if ($m.ReturnType -ne 'void') { $call = "return $call" }
            $lines += "    $($m.ReturnType) $($m.Name)($(New-LcRefParams $m.ParamTypes 'a')) { $call; }"
        }
        $lines += '};'
        $lines += 'namespace lc { template <> struct DesignName<LcProxy> { static std::string get() { return "' + $ClassName + '"; } }; }'
        $targs = (@('LcProxy') + @($Info.CtorTypes)) -join ', '
        $ms = @($Info.Methods | ForEach-Object {
            '{"' + $_.Name + '", lc::method(&LcProxy::' + $_.Name + ', ' + (New-LcNameList $_.ParamNames) + ')}'
        }) -join ', '
        $lines += "int main(int argc, char** argv) { return lc::run_design<$targs>(argc, argv, $(New-LcNameList $Info.CtorNames), {$ms}); }"
    } else {
        $ret = $Info.ReturnType
        $lines += "$ret lc_user_call($(New-LcRefParams $Info.ParamTypes));"
        $call = "lc_user_call($(New-LcArgNames @($Info.ParamTypes).Count 'a'))"
        if ($ret -ne 'void') { $call = "return $call" }
        $lines += 'struct LcProxy {'
        $lines += '    LcProxy() = default;'
        $lines += $copy
        $lines += "    $ret call($(New-LcRefParams $Info.ParamTypes 'a')) { $call; }"
        $lines += '};'
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
        $lines += "void* lc_user_new($(New-LcRefParams $Info.CtorTypes 'c')) { return new $cls($(New-LcArgNames @($Info.CtorTypes).Count 'c')); }"
        $lines += "void lc_user_delete(void* p) { delete static_cast<$cls*>(p); }"
        foreach ($m in $Info.Methods) {
            $call = "static_cast<$cls*>(p)->$($m.Name)($(New-LcArgNames @($m.ParamTypes).Count 'a'))"
            if ($m.ReturnType -ne 'void') { $call = "return $call" }
            $lines += "$($m.ReturnType) lc_user_m_$($m.Name)($(Join-LcArgs 'void* p' (New-LcRefParams $m.ParamTypes 'a'))) { $call; }"
        }
    } else {
        $call = "lc_sol.$($Info.Method)($(New-LcArgNames @($Info.ParamTypes).Count 'a'))"
        if ($Info.ReturnType -ne 'void') { $call = "return $call" }
        $lines += "$($Info.ReturnType) lc_user_call($(New-LcRefParams $Info.ParamTypes 'a')) { Solution lc_sol; $call; }"
    }
    return ($lines -join "`n") + "`n"
}
