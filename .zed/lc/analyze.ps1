# Analyze library: LeetCode constraints -> spec text, complexity fit, TLE verdict.
# Pure functions: dot-source it. No side effects, no output (except Invoke-LcBruteCheck, which builds and runs;
# it needs common.ps1, info.ps1, testfile.ps1 and build.ps1).

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

    $pl = @(); $sizeLen = $null; $sizeVal = $null
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
        if ($n -eq $sizeName) { $sizeLen = $len; $sizeVal = $val }
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
        # bench's schedule maximum (the spec's lengths after defaults): a grid's size is its cells,
        # len_max^2 capped at 10^7 (R16, grid_max_cells in lc-run.h).
        $t = $PR[$sizeName].Type
        if ($sizeLen) {
            $maxN = [long]$sizeLen[1]
            if ($t -like 'vector<vector<*') { $maxN = [long][Math]::Min([double]$maxN * $maxN, 10000000) }
        }
        elseif ($sizeVal -and $t -in 'int', 'long long') { $maxN = [long]$sizeVal[1] }
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
    # Noise floor: 0.002 ms, 20 ticks of the 100 ns timer.
    $pts = @(@($Points) | Where-Object { $_.ms -ge 0.002 })
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

# Parses bench results lines. Returns @{ Points = @(@{ n; ms; capped; per_call_us? }) (completed sizes,
# plus a measured cap, which is a real one-run timing, with capped = $true); Capped = @{ n; ms; Predicted } or $null; Alloc = @{ count; bytes; peak; n }
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
        $pt = @{ n = [long]$o.n; ms = [double]$o.ms; capped = [bool]$o.capped }
        if ($null -ne $o.per_call_us) { $pt.per_call_us = [double]$o.per_call_us }
        $res.Points += $pt
    }
    return $res
}

function Format-LcDuration([double]$Ms) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Ms -ge 1e9) { return ($Ms / 1000).ToString('0.0e+0', $inv) + ' s' }
    if ($Ms -ge 1000) { return ($Ms / 1000).ToString('0.0', $inv) + ' s' }
    if ($Ms -ge 100) { return $Ms.ToString('0', $inv) + ' ms' }
    if ($Ms -ge 10) { return $Ms.ToString('0.0', $inv) + ' ms' }
    if ($Ms -ge 0.01) { return $Ms.ToString('0.00', $inv) + ' ms' }
    return ($Ms * 1000).ToString('0.0', $inv) + ' us'
}

function Format-LcPerCallUs([double]$Us) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Us -ge 100) { return $Us.ToString('0', $inv) + ' us/call' }
    if ($Us -ge 10) { return $Us.ToString('0.0', $inv) + ' us/call' }
    return $Us.ToString('0.00', $inv) + ' us/call'
}

function Format-LcBytes([long]$Bytes) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 104858) { return ($Bytes / 1048576.0).ToString('0.0', $inv) + ' MB' }
    if ($Bytes -ge 1024) { return ($Bytes / 1024.0).ToString('0.0', $inv) + ' KB' }
    return "$Bytes B"
}

# The function's own name from an nm -C name: no class, namespace or parameters
# ("Solution::climbStairs(int)" -> "climbStairs"); a lambda is "lambda in <enclosing function>".
function Get-LcShortName([string]$Name) {
    $s = ($Name -replace '\s*\[clone [^\]]*\]', '').Trim()
    while ($s -match '^(.*?)\s*(const|volatile|noexcept|&&|&)$') { $s = $Matches[1] }
    if ($s.EndsWith(')')) {
        $d = 0
        for ($i = $s.Length - 1; $i -ge 0; $i--) {
            if ($s[$i] -eq ')') { $d++ } elseif ($s[$i] -eq '(') { $d--; if ($d -eq 0) { $s = $s.Substring(0, $i); break } }
        }
    }
    # Split on top-level "::" (not inside (), <> or {}).
    $parts = @(); $d = 0; $start = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ('(<{'.IndexOf($ch) -ge 0) { $d++ }
        elseif (')>}'.IndexOf($ch) -ge 0) { $d-- }
        elseif ($d -eq 0 -and $ch -eq ':' -and $i + 1 -lt $s.Length -and $s[$i + 1] -eq ':') {
            $parts += $s.Substring($start, $i - $start); $start = $i + 2; $i++
        }
    }
    $parts += $s.Substring($start)
    $k = $parts.Count - 1
    # A generic lambda's call operator is a template: operator()<...>.
    if ($parts[$k].StartsWith('operator()') -and $k -ge 2 -and $parts[$k - 1].StartsWith('{lambda')) {
        return 'lambda in ' + (Get-LcShortName ($parts[0..($k - 2)] -join '::'))
    }
    # A template instance's name starts with its return type ("int go<int>"): keep what follows the last
    # top-level space.
    $last = $parts[$k]; $d = 0; $cut = -1
    for ($i = 0; $i -lt $last.Length; $i++) {
        $ch = $last[$i]
        if ('(<{'.IndexOf($ch) -ge 0) { $d++ } elseif (')>}'.IndexOf($ch) -ge 0) { $d-- } elseif ($d -eq 0 -and $ch -eq ' ') { $cut = $i }
    }
    return $last.Substring($cut + 1)
}

# The analyze line for the profiled functions (Resolve-LcProfile order): at most 3, and functions called
# once (the entry point, a constructor) left out. '' when every function ran once (R40: nothing to say).
function Format-LcCallsLine([long]$N, $Profile) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $list = @(@($Profile) | Where-Object { $_.Calls -gt 1 })
    if (-not $list.Count) { return '' }
    $items = @($list | Select-Object -First 3 | ForEach-Object {
        $word = if ($_.Calls -eq 1) { 'call' } else { 'calls' }
        "$(Get-LcShortName $_.Name): $(([long]$_.Calls).ToString('N0', $inv)) $word, max depth $($_.Depth)"
    })
    return "Calls (n=$N): " + ($items -join '; ')
}

# Profile results lines ({"fn":"0x<hex>","calls":C,"depth":D}) -> @(@{ Name; Calls; Depth }), names from
# nm's symbols for the exe (linked with --disable-dynamicbase, so they match the runtime addresses).
# Most calls first, top 5. An address nm doesn't know keeps its hex form. A run that threw (an error
# line) returns nothing: its counts stop mid-call (R41).
function Resolve-LcProfile([string]$Exe, [string[]]$Lines) {
    $want = @{}
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.status -eq 'error') { return @() }
        if ($null -eq $o.fn) { continue }
        $key = ([Convert]::ToUInt64(([string]$o.fn).Substring(2), 16)).ToString('x16')
        $want[$key] = @{ Name = [string]$o.fn; Calls = [long]$o.calls; Depth = [long]$o.depth }
    }
    if ($want.Count) {
        $named = @{}
        foreach ($l in @(& 'C:\msys64\ucrt64\bin\nm.exe' -C --defined-only $Exe 2>$null)) {
            if ($l.Length -lt 20) { continue }
            $key = $l.Substring(0, 16).ToLowerInvariant()
            # Skip section symbols (".text$_ZN8Solution...") at the same address.
            if ($want.ContainsKey($key) -and -not $named.ContainsKey($key) -and $l[19] -ne '.') {
                $named[$key] = $true
                $want[$key].Name = $l.Substring(19)
            }
        }
    }
    return @($want.Values | Sort-Object @{ Expression = { $_.Calls }; Descending = $true }, @{ Expression = { $_.Name } } | Select-Object -First 5)
}

# Reads a results file: @{ ByN = @{ <case n> = <result object> }; Pending = <n of a case that never finished> }.
function Read-LcCaseResults([string]$Path) {
    $res = @{ ByN = @{}; Pending = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if (-not $line.Trim()) { continue }
        $o = $line | ConvertFrom-Json
        if ($o.status -eq 'start') { $res.Pending = [int]$o.n } else { $res.ByN[[int]$o.n] = $o; $res.Pending = $null }
    }
    return $res
}

# Brute-force check (analyze, when tests/<slug>.brute.cpp exists). Builds the brute file as a bench exe of
# its own ('brute', same harness), generates 200 random cases with n in [1, 10] (seed 1), takes the brute's
# answers as the expected outputs and runs the solution's bench exe on them.
# Returns @{ Cases; Mismatch = $null | @{ Input = <'Input: ...' line>; Got; Expected };
# Crashed = $null | <case the brute crashed on>; TimedOut; Errors = <g++ output when a build failed> }.
function Invoke-LcBruteCheck {
    param(
        [Parameter(Mandatory)][string]$SrcPath,
        [Parameter(Mandatory)][string]$BrutePath,
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)][string]$SpecPath,
        [switch]$AnyOrder,
        [int]$TimeoutMs = 60000
    )
    $res = @{ Cases = 0; Mismatch = $null; Crashed = $null; TimedOut = $false; Errors = '' }
    $harness = New-LcHarnessText -Info $Info
    $bb = Build-LcExe -SrcPath $BrutePath -HarnessText $harness -UserText (New-LcUserText -SrcPath $BrutePath -Info $Info) -Flavor bench -Name brute
    if (-not $bb.Ok) { $res.Errors = $bb.Errors; return $res }
    # The analyze build: already up to date, so this only checks its stamps.
    $main = Build-LcExe -SrcPath $SrcPath -HarnessText $harness -UserText (New-LcUserText -SrcPath $SrcPath -Info $Info) -Flavor bench -Name bench
    if (-not $main.Ok) { $res.Errors = $main.Errors; return $res }

    $dir = Split-Path -Parent $bb.Exe
    $genPath = Join-Path $dir 'brute-gen.txt'
    $casesPath = Join-Path $dir 'brute-cases.txt'
    $bruteOut = Join-Path $dir 'brute-results.txt'
    $mainOut = Join-Path $dir 'brute-main-results.txt'
    foreach ($p in $genPath, $bruteOut, $mainOut) { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
    & $bb.Exe gen $SpecPath $genPath --count 200 --max-n 10 --seed 1 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $genPath)) { $res.Errors = "brute force: gen failed (exit code $LASTEXITCODE)"; return $res }

    # The generated cases: each one's lines between "case k" and "end".
    $cases = New-Object Collections.ArrayList
    $cur = $null
    foreach ($l in [IO.File]::ReadAllLines($genPath)) {
        if ($l -match '^case \d+$') { $cur = New-Object Collections.ArrayList }
        elseif ($l -eq 'end') { [void]$cases.Add([string[]]$cur.ToArray()); $cur = $null }
        elseif ($null -ne $cur) { [void]$cur.Add($l) }
    }
    $res.Cases = $cases.Count

    $m = Start-Measured -Exe $bb.Exe -ArgumentList @('test', $genPath, $bruteOut) -TimeoutMs $TimeoutMs -NoStdout
    $br = Read-LcCaseResults $bruteOut
    $bad = $br.Pending
    if ($null -eq $bad) {
        for ($k = 1; $k -le $cases.Count; $k++) {
            if (-not $br.ByN.ContainsKey($k) -or $br.ByN[$k].status -eq 'error') { $bad = $k; break }
        }
    }
    if ($null -ne $bad -or $m.TimedOut -or $m.Code -ne 0) {
        if ($null -eq $bad) { $bad = '?' }
        $res.Crashed = $bad; $res.TimedOut = [bool]$m.TimedOut
        return $res
    }

    $sb = New-Object Text.StringBuilder
    for ($k = 1; $k -le $cases.Count; $k++) {
        [void]$sb.Append("case $k`n")
        foreach ($l in $cases[$k - 1]) { [void]$sb.Append("$l`n") }
        [void]$sb.Append("expect $($br.ByN[$k].got)`nend`n")
    }
    [IO.File]::WriteAllText($casesPath, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

    $argv = @('test', $casesPath, $mainOut)
    if ($AnyOrder) { $argv += '--any-order' }
    $m = Start-Measured -Exe $main.Exe -ArgumentList $argv -TimeoutMs $TimeoutMs -NoStdout
    $mr = Read-LcCaseResults $mainOut
    for ($k = 1; $k -le $cases.Count; $k++) {
        $r = $null
        if ($mr.ByN.ContainsKey($k)) { $r = $mr.ByN[$k] }
        if ($r -and $r.status -eq 'pass') { continue }
        $got = if (-not $r) { if ($m.TimedOut) { '(timed out)' } else { '(crashed)' } }
               elseif ($r.status -eq 'error') { [string]$r.error } else { [string]$r.got }
        $lines = $cases[$k - 1]
        if ($Info.Kind -eq 'design') {
            $in = "Input`n" + (($lines | ForEach-Object { $_ -replace '^(ops|args) ', '' }) -join "`n")
        } else {
            $in = Format-LcInputLine -Info $Info -Values ([string[]]@($lines | Where-Object { $_.StartsWith('arg ') } | ForEach-Object { $_.Substring(4) }))
        }
        $res.Mismatch = @{ Input = $in; Got = $got; Expected = [string]$br.ByN[$k].got }
        break
    }
    return $res
}
