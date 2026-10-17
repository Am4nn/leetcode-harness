# Test file generation/parsing (tests/<slug>.txt) and cases-file writing.
# Function library: dot-source it (needs fetch.ps1 for ConvertFrom-LcHtml). No side effects.

function Get-LcConstraints([string]$text) {
    $out = New-Object System.Collections.Generic.List[string]
    $lines = $text -split "\r?\n"
    $i = 0
    while ($i -lt $lines.Count -and $lines[$i].Trim() -notmatch '^Constraints\s*:?$') { $i++ }
    $i++
    while ($i -lt $lines.Count -and $lines[$i].Trim() -eq '') { $i++ }
    for (; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].Trim()
        if ($l -eq '' -or $l -match '^(Follow|Note|Example)') { break }
        $out.Add($l)
    }
    return , [string[]]$out.ToArray()
}

# -Args is accepted as an alias ($Args itself is a reserved automatic variable).
function Format-LcInputLine($Info, [Alias('Args')][string[]]$Values) {
    $parts = @()
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $parts += ('{0} = {1}' -f $Info.ParamNames[$i], $Values[$i])
    }
    return 'Input: ' + ($parts -join ', ')
}

function Get-LcOutputsFromText([string]$text) {
    $outs = New-Object System.Collections.Generic.List[string]
    $lines = $text -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].Trim()
        if ($l -match '^Output\s*:\s*(\S.*)$') { $outs.Add($Matches[1]) }
        elseif ($l -match '^Output\s*:?$') {
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim() -eq '') { $j++ }
            if ($j -lt $lines.Count) { $outs.Add($lines[$j].Trim()) } else { $outs.Add('') }
        }
    }
    return , $outs.ToArray()
}

# Lines joined with LF, no trailing newline.
function New-LcTestFileText($Question, $Info) {
    $q = $Question
    $text = ConvertFrom-LcHtml ([string]$q.content)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('# {0} (#{1}, {2}) https://leetcode.com/problems/{3}/' -f $q.title, $q.questionFrontendId, $q.difficulty, $q.titleSlug))
    if ($text -match 'any order') { $out.Add('compare: any-order') }
    $out.Add('Constraints:')
    foreach ($c in (Get-LcConstraints $text)) { $out.Add($c) }
    $outs = Get-LcOutputsFromText $text
    $n = 0
    foreach ($tc in @($q.exampleTestcaseList)) {
        $n++
        $vals = @(([string]$tc) -split "\r?\n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
        $out.Add('')
        $out.Add("Example ${n}:")
        $o = $null
        if ($n -le $outs.Count -and $outs[$n - 1] -ne '') { $o = $outs[$n - 1] }
        if ($Info.Kind -eq 'design') {
            $out.Add('Input')
            foreach ($v in $vals) { $out.Add($v) }
            if ($null -ne $o) { $out.Add('Output'); $out.Add($o) }
        } else {
            $out.Add((Format-LcInputLine -Info $Info -Args ([string[]]$vals)))
            if ($null -ne $o) { $out.Add("Output: $o") }
        }
    }
    return ($out.ToArray() -join "`n")
}

# Splits 'a = [1,2], b = "x, y = z"' at top-level commas followed by 'ident ='.
# Returns @(@{Name; Value}), or $null when the text does not start with 'name ='.
function Split-LcNamedValues([string]$s) {
    if ($s -notmatch '^\s*[A-Za-z_]\w*\s*=(?!=)') { return $null }
    $pieces = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $depth = 0; $inStr = $false
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($inStr) {
            [void]$cur.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $s.Length) { $i++; [void]$cur.Append($s[$i]) }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true }
        elseif ($c -eq '[' -or $c -eq '{' -or $c -eq '(') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}' -or $c -eq ')') { $depth-- }
        elseif ($c -eq ',' -and $depth -le 0 -and $s.Substring($i + 1) -match '^\s*[A-Za-z_]\w*\s*=(?!=)') {
            $pieces.Add($cur.ToString()); [void]$cur.Clear(); continue
        }
        [void]$cur.Append($c)
    }
    $pieces.Add($cur.ToString())
    $res = @()
    foreach ($p in $pieces) {
        if ($p -match '(?s)^\s*([A-Za-z_]\w*)\s*=\s*(.*?)\s*$') { $res += @{ Name = $Matches[1]; Value = $Matches[2] } }
    }
    return , $res
}

function Read-LcTestFile([string]$Path, $Info) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $lines = @($text -split "\r?\n" | ForEach-Object { $_.Trim() })
    $anyOrder = ($text -match '(?m)^\s*compare\s*:\s*any-order') -or ($text -match 'any order')
    $stop = '^(Output|Explanation|Example|Input|Constraints|Follow|Note)\b'
    $cases = New-Object System.Collections.ArrayList
    $cur = $null
    $n = $lines.Count
    $i = 0
    while ($i -lt $n) {
        $l = $lines[$i]
        if ($l -match '^Input(\s*:\s*(?<r>.*)|\s*)$') {
            $vl = New-Object System.Collections.Generic.List[string]
            if ($Matches['r']) { $vl.Add($Matches['r']) }
            $j = $i + 1
            while ($j -lt $n -and $lines[$j] -ne '' -and $lines[$j] -notmatch $stop) {
                if ($lines[$j][0] -ne '#') { $vl.Add($lines[$j]) }
                $j++
            }
            $named = Split-LcNamedValues ($vl.ToArray() -join '')
            if ($null -ne $named) {
                $vals = @($named | ForEach-Object { $_.Value })
                if ($Info.Kind -eq 'function' -and $named.Count -eq $Info.ParamNames.Count) {
                    $ordered = @()
                    foreach ($pn in $Info.ParamNames) {
                        $m = @($named | Where-Object { $_.Name -eq $pn })
                        if ($m.Count -eq 1) { $ordered += $m[0].Value }
                    }
                    if ($ordered.Count -eq $named.Count) { $vals = $ordered }
                }
            } else {
                $vals = @($vl.ToArray() | Where-Object { $_ -ne '' })
            }
            $cur = @{ Args = [string[]]$vals; Expected = $null }
            [void]$cases.Add($cur)
            $i = $j
            continue
        }
        if ($null -ne $cur -and $null -eq $cur.Expected -and $l -match '^Output(\s*:\s*(?<r>.*)|\s*)$') {
            $ol = New-Object System.Collections.Generic.List[string]
            if ($Matches['r']) { $ol.Add($Matches['r']) }
            $j = $i + 1
            while ($j -lt $n -and $lines[$j] -ne '' -and $lines[$j] -notmatch $stop) { $ol.Add($lines[$j]); $j++ }
            if ($ol.Count -gt 0) { $cur.Expected = ($ol.ToArray() -join '') }
            $i = $j
            continue
        }
        $i++
    }
    return @{
        AnyOrder    = [bool]$anyOrder
        Constraints = [string[]](Get-LcConstraints $text)
        Cases       = [object[]]$cases.ToArray()
    }
}

function Write-LcCasesFile($Cases, [string]$Kind, [string]$Path) {
    $one = { param($s) ([string]$s) -replace '\s*[\r\n]+\s*', ' ' }
    $sb = New-Object System.Text.StringBuilder
    $k = 0
    foreach ($c in @($Cases)) {
        $k++
        [void]$sb.Append("case $k`n")
        if ($Kind -eq 'design') {
            [void]$sb.Append('ops ' + (& $one $c.Args[0]) + "`n")
            [void]$sb.Append('args ' + (& $one $c.Args[1]) + "`n")
        } else {
            foreach ($a in $c.Args) { [void]$sb.Append('arg ' + (& $one $a) + "`n") }
        }
        if ($null -ne $c.Expected) { [void]$sb.Append('expect ' + (& $one $c.Expected) + "`n") }
        [void]$sb.Append("end`n")
    }
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}
