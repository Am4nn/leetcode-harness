# Runs lc/tests/*.test.cpp (compiled, then run) and lc/tests/*.tests.ps1 (dot-sourced).
# Prints one PASS/FAIL line per file; details only on failure. Exits 1 if any failed.
#   -Only io   runs just io.test.cpp / io.tests.ps1
param([string]$Only = '')

$env:Path = "C:\msys64\ucrt64\bin;$env:Path"
$gpp = 'C:\msys64\ucrt64\bin\g++.exe'
$lc = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $lc
$buildDir = Join-Path $root 'build\tests'
New-Item -ItemType Directory -Force $buildDir | Out-Null
. (Join-Path $PSScriptRoot 'assert.ps1')

$flags = '-std=c++23', '-Wall', '-Wextra', '-Wshadow', '-O2', '-g', '-static',
         '-D_GLIBCXX_ASSERTIONS', '-fsanitize=undefined', '-fsanitize-undefined-trap-on-error',
         '-Wl,--stack,268435456'

$failed = 0
function Report([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host "PASS $name" }
    else {
        Write-Host "FAIL $name"
        if ($detail.Trim()) { Write-Host $detail.TrimEnd() }
        $script:failed++
    }
}

# One whole run at a time: runs share the build caches and touch lc/lc.h.
$mutex = New-Object Threading.Mutex($false, 'Local\lc-harness-tests')
try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] {}
try {
    foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '*.test.cpp') | Sort-Object Name) {
        $name = $f.Name -replace '\.test\.cpp$', ''
        if ($Only -and $name -ne $Only) { continue }
        $exe = Join-Path $buildDir "$name.test.exe"
        $out = & $gpp @flags -I $lc -include (Join-Path $lc 'lc-prelude.h') $f.FullName -o $exe 2>&1 | ForEach-Object { "$_" } | Out-String
        if ($LASTEXITCODE -ne 0) { Report $name $false $out; continue }
        if ($out -match 'warning:') { Report $name $false "compiler warnings:`n$out"; continue }
        $out = & $exe 2>&1 | ForEach-Object { "$_" } | Out-String
        Report $name ($LASTEXITCODE -eq 0) "$out(exit code $LASTEXITCODE)"
    }

    foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '*.tests.ps1') | Sort-Object Name) {
        $name = $f.Name -replace '\.tests\.ps1$', ''
        if ($Only -and $name -ne $Only) { continue }
        try { . $f.FullName; Report $name $true '' }
        catch { Report $name $false $_.Exception.Message }
    }
} finally { $mutex.ReleaseMutex() }

exit $(if ($failed) { 1 } else { 0 })
