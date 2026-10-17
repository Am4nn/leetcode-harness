# Tests for .zed/common.ps1 and the F7 script (.zed/run-cpp.ps1).
$lcDir = Split-Path -Parent $PSScriptRoot
$dsaRoot = Split-Path -Parent $lcDir
$zed = Join-Path $dsaRoot '.zed'
. (Join-Path $zed 'common.ps1')

$fix = Join-Path $PSScriptRoot 'fixtures'
$bt = Join-Path $dsaRoot 'build\tests'
New-Item -ItemType Directory -Force $bt | Out-Null
foreach ($n in 'fast', 'echo-first-byte', 'forever') {
    & $Gpp @CppFlags @TestFlags (Join-Path $fix "$n.cpp") -o (Join-Path $bt "fx-$n.exe") 2>&1 | Out-Null
    Assert-Equal $LASTEXITCODE 0 "compile fixture $n"
}

Assert-Match (Explain 0xC00000FD) 'Stack overflow'

$r = Start-Measured -Exe (Join-Path $bt 'fx-fast.exe')
Assert-True ($null -ne $r.Code) 'exit code must be readable for an instant exit'
Assert-Equal $r.Code 0

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lc-common-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
    $stdin = Join-Path $tmp 'in.txt'
    [IO.File]::WriteAllText($stdin, '3', (New-Object Text.UTF8Encoding $false))
    $echo = Join-Path $bt 'fx-echo-first-byte.exe'
    $outFile = Join-Path $tmp 'out.txt'
    $r = Start-Measured -Exe 'cmd.exe' -ArgumentList @('/c', "`"$echo`" > `"$outFile`"") -StdinFile $stdin
    Assert-Equal $r.Code 0
    Assert-Equal ([IO.File]::ReadAllText($outFile)) '51' 'first byte must be 51 (no BOM)'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Start-Measured -Exe (Join-Path $bt 'fx-forever.exe') -TimeoutMs 1000
    $sw.Stop()
    Assert-True $r.TimedOut 'forever.exe should time out'
    Assert-True ($null -eq $r.Code) 'Code is $null on timeout'
    Assert-True ($sw.ElapsedMilliseconds -lt 3000) "timeout took $($sw.ElapsedMilliseconds) ms"

    # F7 script regression: crash line in input mode.
    $d = Join-Path $tmp 'sp ace'
    New-Item -ItemType Directory $d | Out-Null
    Copy-Item (Join-Path $fix 'oob.cpp') $d
    [IO.File]::WriteAllText((Join-Path $d 'input.txt'), '7', (New-Object Text.UTF8Encoding $false))
    $runCpp = Join-Path $zed 'run-cpp.ps1'
    $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $runCpp -Mode input (Join-Path $d 'oob.cpp') 2>&1 | Out-String
    Assert-Match $out 'crashed at\s+line 5'

    $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $runCpp -Mode check (Join-Path $fix 'fast.cpp') 2>&1 | Out-String
    Assert-Match $out 'No errors\.'

    $tree = Join-Path $lcDir 'selftest\maximum-depth-of-binary-tree.cpp'
    foreach ($m in 'check', 'run') {
        $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $runCpp -Mode $m $tree 2>&1 | Out-String
        Assert-Match $out 'No errors\.'
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
