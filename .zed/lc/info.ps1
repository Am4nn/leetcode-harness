# Problem info (from LeetCode metaData or solution source), C++ type mapping, wrapper generation.
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

function Get-LcInfoFromMeta([string]$metaDataJson) {
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
    $out = -1
    if ($m.output -and $null -ne $m.output.paramindex) { $out = [int]$m.output.paramindex }
    return [pscustomobject]@{
        Kind       = 'function'
        Method     = [string]$m.name
        ParamNames = [string[]]@($ps | ForEach-Object { [string]$_.name })
        ParamTypes = [string[]]@($ps | ForEach-Object { ConvertTo-LcCppType $_.type })
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
    $type = $type -replace '\bconst\b', '' -replace '&', ''
    $type = ($type -replace '\s+', ' ').Trim()
    $type = $type -replace '\s*([<>,*])\s*', '$1'
    return [pscustomobject]@{ Name = $name; Type = $type }
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
        $methods += [pscustomobject]@{
            Name       = $nm
            ParamNames = [string[]]@($params | ForEach-Object { $_.Name })
            ParamTypes = [string[]]@($params | ForEach-Object { $_.Type })
        }
    }
    if ($methods.Count -eq 0) { return $null }
    $first = $methods[0]
    return [pscustomobject]@{
        Kind       = 'function'
        Method     = $first.Name
        ParamNames = $first.ParamNames
        ParamTypes = $first.ParamTypes
        OutParam   = -1
        AllMethods = @($methods | ForEach-Object { @{ Name = $_.Name; ParamNames = $_.ParamNames } })
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

function New-LcWrapperText {
    param([Parameter(Mandatory)][string]$SrcPath, [Parameter(Mandatory)]$Info)
    $inc = '#include "' + ($SrcPath -replace '\\', '/') + '"'
    if ($Info.Kind -eq 'design') {
        $cls = $Info.Class
        $targs = (@($cls) + @($Info.CtorTypes)) -join ', '
        $ms = @($Info.Methods | ForEach-Object {
            '{"' + $_.Name + '", lc::method(&' + $cls + '::' + $_.Name + ', ' + (New-LcNameList $_.ParamNames) + ')}'
        }) -join ', '
        $call = "lc::run_design<$targs>(argc, argv, $(New-LcNameList $Info.CtorNames), {$ms})"
    } else {
        $call = "lc::run_function(argc, argv, &Solution::$($Info.Method), $(New-LcNameList $Info.ParamNames), $($Info.OutParam))"
    }
    return $inc + "`n" + "int main(int argc, char** argv) { return $call; }`n"
}
