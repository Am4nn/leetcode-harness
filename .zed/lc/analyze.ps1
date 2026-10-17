# Analyze library: LeetCode constraints -> spec text, complexity fit, TLE verdict.
# Pure functions: dot-source it. No side effects, no output.

function ConvertFrom-LcNumber([string]$expr) {
    $s = ($expr -replace '[\s,]', '')
    if (-not $s) { throw "empty number expression" }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $total = [decimal]0
    foreach ($m in [regex]::Matches($s, '[+-]?[^+-]+')) {
        $t = $m.Value
        $neg = $t.StartsWith('-')
        $body = $t.TrimStart('+', '-')
        $prod = [decimal]1
        foreach ($f in $body.Split('*')) {
            if ($f -match '^(\d+)\^(\d+)$') {
                $v = [decimal]1
                for ($i = 0; $i -lt [int]$Matches[2]; $i++) { $v *= [decimal]::Parse($Matches[1], $inv) }
            } elseif ($f -match '^\d+$') {
                $v = [decimal]::Parse($f, $inv)
            } else { throw "cannot parse number: $expr" }
            $prod *= $v
        }
        if ($neg) { $total -= $prod } else { $total += $prod }
    }
    return [long]$total
}

function ConvertTo-LcSpec {
    param([string[]]$Constraints, $Info)
    $names = @(); $types = @()
    if ($Info.Kind -eq 'design') {
        $names = @($Info.CtorNames); $types = @($Info.CtorTypes)
        foreach ($m in $Info.Methods) {
            for ($i = 0; $i -lt @($m.ParamNames).Count; $i++) {
                if ($names -notcontains $m.ParamNames[$i]) { $names += $m.ParamNames[$i]; $types += $m.ParamTypes[$i] }
            }
        }
    } else { $names = @($Info.ParamNames); $types = @($Info.ParamTypes) }

    $PR = [ordered]@{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $PR[$names[$i]] = @{ Type = $types[$i]; Len = $null; Val = $null; Chars = $null; Eqlen = $null; Sorted = $false; Distinct = $false }
    }
    $treeName = $null
    foreach ($n in $names) { if ($PR[$n].Type -match '^(TreeNode|ListNode)\*$') { $treeName = $n; break } }
    $calls = $null

    $leq = [string][char]0x2264
    $num = '[\d\s\^\*\+\-]+'
    foreach ($raw in @($Constraints)) {
        $c = ($raw -replace '<sup>(\d+)</sup>', '^$1' -replace $leq, '<=' -replace '`', '').Trim().TrimEnd('.')
        if (-not $c) { continue }
        if ($c -match "^($num)\s*(<=|<)\s*(.+?)\s*(<=|<)\s*($num)`$") {
            $lo = ConvertFrom-LcNumber $Matches[1]; if ($Matches[2] -eq '<') { $lo++ }
            $hi = ConvertFrom-LcNumber $Matches[5]; if ($Matches[4] -eq '<') { $hi-- }
            foreach ($item in $Matches[3].Split(',')) {
                $it = $item.Trim()
                if ($it -match '^(\w+)\.length$') { $nm = $Matches[1]; $kind = 'Len' }
                elseif ($it -match '^Node\.val$') { $nm = $treeName; $kind = 'Val' }
                elseif ($it -match '^(\w+)(\[\w+\])+$') { $nm = $Matches[1]; $kind = 'Val' }
                elseif ($it -match '^\w+$') { $nm = $it; $kind = 'Val' }
                else { continue }
                if ($nm -and $PR.Contains($nm)) { $PR[$nm][$kind] = @($lo, $hi) }
            }
        }
        elseif ($c -match '^(\w+)\s*==\s*(\w+)\.length$') {
            if ($PR.Contains($Matches[1]) -and $PR.Contains($Matches[2])) { $PR[$Matches[1]].Eqlen = $Matches[2] }
        }
        elseif ($c -match 'number of nodes in .*?is in the range \[\s*(.+?)\s*,\s*(.+?)\s*\]') {
            if ($treeName) { $PR[$treeName].Len = @((ConvertFrom-LcNumber $Matches[1]), (ConvertFrom-LcNumber $Matches[2])) }
        }
        elseif ($c -match '^(\w+) consists of') {
            $nm = $Matches[1]
            if ($PR.Contains($nm)) {
                $s = ''
                if ($c -match 'digits') { $s = '0123456789' }
                elseif ($c -match 'lowercase and uppercase|uppercase and lowercase') { $s = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' }
                elseif ($c -match 'lowercase') { $s = 'abcdefghijklmnopqrstuvwxyz' }
                elseif ($c -match 'uppercase') { $s = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' }
                elseif ($c -match 'English letters') { $s = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' }
                if ($s) { $PR[$nm].Chars = $s }
            }
        }
        elseif ($c -match '^At most (.+?) calls') { $calls = ConvertFrom-LcNumber $Matches[1] }
        elseif ($c -match '^(\w+) is sorted in strictly increasing') {
            if ($PR.Contains($Matches[1])) { $PR[$Matches[1]].Sorted = $true; $PR[$Matches[1]].Distinct = $true }
        }
        elseif ($c -match '^(\w+) is sorted in (non-decreasing|ascending|increasing)') {
            if ($PR.Contains($Matches[1])) { $PR[$Matches[1]].Sorted = $true }
        }
        elseif ($c -match '^All\s+(?:the\s+)?(?:\w+\s+)?(?:of|in)\s+(\w+)\s+are\s+(?:unique|distinct)' -or
                $c -match '^(\w+)\s+(?:contains|has)\s+(?:distinct|unique)') {
            if ($PR.Contains($Matches[1])) { $PR[$Matches[1]].Distinct = $true }
        }
    }

    $assumed = @(); $lines = @()
    $dLen = @(1, 100000); $dVal = @(-1000000000, 1000000000); $dChars = 'abcdefghijklmnopqrstuvwxyz'
    $sizeName = $null
    foreach ($n in $names) {
        if ($PR[$n].Type -match '^(vector<|string$|TreeNode\*|ListNode\*)') { $sizeName = $n; break }
    }
    if (-not $sizeName) { foreach ($n in $names) { if ($PR[$n].Type -in 'int', 'long long') { $sizeName = $n; break } } }

    $pl = @()
    foreach ($n in $names) {
        $p = $PR[$n]; $t = $p.Type
        if ($t -eq 'bool') { continue }
        $found = $p.Len -or $p.Val -or $p.Chars -or $p.Eqlen
        if (-not $found) { $assumed += "(assumed: no constraint found for $n)" }
        $isVec = $t -like 'vector<*'
        $elem = $t; while ($elem -like 'vector<*') { $elem = $elem.Substring(7, $elem.Length - 8) }
        $isStr = ($t -eq 'string') -or ($isVec -and $elem -eq 'string')
        $isNode = $t -match '^(TreeNode|ListNode)\*$'
        $len = $p.Len; $val = $p.Val; $chars = $p.Chars
        if (($isVec -or $t -eq 'string' -or $isNode) -and -not $len -and -not $p.Eqlen) { $len = if ($isNode) { @(0, 10000) } else { $dLen } }
        if ($isStr -and -not $chars) { $chars = $dChars }
        if (-not $isStr -and -not $val) {
            if ($isVec -or $isNode) { $val = $dVal }
            elseif ($t -in 'int', 'long long', 'double') {
                if ($n -eq $sizeName) { $val = @(1, 100000) }
                elseif ($t -eq 'long long') { $val = @(-1000000000000000000, 1000000000000000000) }
                else { $val = $dVal }
            }
            elseif ($t -eq 'char' -and -not $chars) { $chars = $dChars }
        }
        $parts = @("param $n")
        if ($len) { $parts += "len $($len[0]) $($len[1])" }
        if ($val -and -not $isStr) { $parts += "val $($val[0]) $($val[1])" }
        if ($chars) { $parts += "chars $chars" }
        if ($p.Eqlen) { $parts += "eqlen $($p.Eqlen)" }
        if ($p.Sorted) { $parts += 'sorted' }
        if ($p.Distinct) { $parts += 'distinct' }
        $pl += ($parts -join ' ')
    }

    $maxN = [long]100000
    if ($Info.Kind -eq 'design') {
        if ($calls) { $maxN = $calls }
    } elseif ($sizeName) {
        $p = $PR[$sizeName]
        if ($p.Len) { $maxN = $p.Len[1] }
        elseif ($p.Val -and $p.Type -in 'int', 'long long') { $maxN = $p.Val[1] }
    }

    if ($Info.Kind -ne 'design' -and $sizeName) { $lines += "size $sizeName" }
    $lines += $pl
    if ($calls) { $lines += "calls $calls" }
    return @{ Text = (($lines -join "`n") + "`n"); Assumed = [string[]]$assumed; MaxN = [long]$maxN }
}

function Get-LcComplexityShape([string]$label, [double]$n) {
    switch ($label) {
        'O(1)'        { return 1.0 }
        'O(log n)'    { return [math]::Log([math]::Max($n, 2), 2) }
        'O(n)'        { return $n }
        'O(n log n)'  { return $n * [math]::Log([math]::Max($n, 2), 2) }
        'O(n^2)'      { return $n * $n }
        'O(n^3)'      { return $n * $n * $n }
        'O(2^n)'      { return [math]::Pow(2, $n) }
    }
    throw "unknown complexity label: $label"
}

function Get-LcComplexity {
    param($Points)
    $pts = @(@($Points) | Where-Object { $_.ms -ge 0.05 })
    if ($pts.Count -lt 3) { return [pscustomobject]@{ Label = 'too fast to measure'; Coef = 0.0; TooFast = $true } }
    $maxN = ($pts | ForEach-Object { [double]$_.n } | Measure-Object -Maximum).Maximum
    $labels = @('O(1)', 'O(log n)', 'O(n)', 'O(n log n)', 'O(n^2)', 'O(n^3)')
    if ($maxN -le 64) { $labels += 'O(2^n)' }
    $best = $null
    foreach ($l in $labels) {
        $sff = 0.0; $sfy = 0.0
        foreach ($p in $pts) { $f = Get-LcComplexityShape $l ([double]$p.n); $sff += $f * $f; $sfy += $f * [double]$p.ms }
        if ($sff -le 0 -or $sfy -le 0) { continue }
        $c = $sfy / $sff
        $score = 0.0
        foreach ($p in $pts) { $r = [math]::Log([double]$p.ms / ($c * (Get-LcComplexityShape $l ([double]$p.n)))); $score += $r * $r }
        if ($null -eq $best -or $score -lt $best.Score - 1e-9) { $best = @{ Label = $l; Coef = $c; Score = $score } }
    }
    return [pscustomobject]@{ Label = $best.Label; Coef = [double]$best.Coef; TooFast = $false }
}

function Get-LcEstimateMs {
    param($Fit, [long]$N)
    if ($Fit.TooFast) { return 0.0 }
    return [double]($Fit.Coef * (Get-LcComplexityShape $Fit.Label ([double]$N)))
}

function Get-LcTleVerdict([double]$EstMs) {
    if ($EstMs -le 500) { return 'ok' }
    if ($EstMs -le 1000) { return 'borderline' }
    return 'likely TLE'
}

# The design per-call label from the fit of a whole n-call sequence: total O(n) is O(1) per call.
function Get-LcPerCallLabel([string]$Label) {
    switch ($Label) {
        'O(1)'       { return 'O(1)' }
        'O(log n)'   { return 'O(1)' }
        'O(n)'       { return 'O(1)' }
        'O(n log n)' { return 'O(log n)' }
        'O(n^2)'     { return 'O(n)' }
        'O(n^3)'     { return 'O(n^2)' }
    }
    return $Label
}

# Parses bench results lines. Returns @{ Points = @(@{ n; ms }) (completed sizes, plus a measured cap,
# which is a real one-run timing); Capped = @{ n; ms; Predicted } or $null; Alloc = @{ count; bytes; peak; n }
# or $null; Pending = @{ n; seed } for a size that started and never finished (crash or kill), else $null;
# Error = @{ n; seed; error } when the solution threw, else $null }.
function Read-LcBenchResults([string[]]$Lines) {
    $res = @{ Points = @(); Capped = $null; Alloc = $null; Pending = $null; Error = $null }
    $seed = 0
    foreach ($line in @($Lines)) {
        if (-not $line -or -not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.status -eq 'start') { $seed = $o.seed; $res.Pending = @{ n = [long]$o.n; seed = $o.seed }; continue }
        if ($o.status -eq 'error') { $res.Error = @{ n = [long]$o.n; seed = $seed; error = [string]$o.error }; $res.Pending = $null; continue }
        if ($null -ne $o.alloc) {
            $res.Alloc = @{ count = [long]$o.alloc.count; bytes = [long]$o.alloc.bytes; peak = [long]$o.alloc.peak; n = [long]$o.n }
            continue
        }
        $res.Pending = $null
        if ($o.capped) {
            $res.Capped = @{ n = [long]$o.n; ms = [double]$o.ms; Predicted = [bool]$o.predicted }
            if ($o.predicted) { continue }
        }
        $res.Points += @{ n = [long]$o.n; ms = [double]$o.ms }
    }
    return $res
}

function Format-LcDuration([double]$Ms) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Ms -ge 1e9) { return ($Ms / 1000).ToString('0.0e+0', $inv) + ' s' }
    if ($Ms -ge 1000) { return ($Ms / 1000).ToString('0.0', $inv) + ' s' }
    if ($Ms -ge 100) { return $Ms.ToString('0', $inv) + ' ms' }
    if ($Ms -ge 10) { return $Ms.ToString('0.0', $inv) + ' ms' }
    return $Ms.ToString('0.00', $inv) + ' ms'
}

function Format-LcBytes([long]$Bytes) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 104858) { return ($Bytes / 1048576.0).ToString('0.0', $inv) + ' MB' }
    if ($Bytes -ge 1024) { return ($Bytes / 1024.0).ToString('0.0', $inv) + ' KB' }
    return "$Bytes B"
}
