# Compiles and runs the C++ file open in Zed. Used by the tasks in .zed/tasks.json.
#   -Mode run    compile + run, type input in the terminal
#   -Mode input  compile + run with input.txt (next to the .cpp) as stdin
#   -Mode check  compile only and report errors
# Files without main() (LeetCode style) are always just checked.
param(
    [ValidateSet('run', 'input', 'check')][string]$Mode = 'run',
    # The path may arrive split on spaces ("c++ language"), so take all remaining args.
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)

. (Join-Path $PSScriptRoot 'common.ps1')

$src = ($Rest -join ' ').Trim('"')
if (-not $src -or -not (Test-Path -LiteralPath $src)) { Write-Host "No such file: '$src'" -ForegroundColor Red; Finish 1 }
if ([IO.Path]::GetExtension($src) -ne '.cpp') { Write-Host "Not a .cpp file: $src" -ForegroundColor Red; Finish 1 }

$name = [IO.Path]::GetFileNameWithoutExtension($src)
$hasMain = Select-String -LiteralPath $src -Pattern '\bmain\s*\(' -Quiet

if ($Mode -eq 'check' -or -not $hasMain) {
    if ($Mode -ne 'check') { Write-Host "No main() in $name.cpp - checking for errors only." -ForegroundColor Yellow }
    # LeetCode starters have no #includes: the prelude supplies them.
    $pre = @()
    if (-not $hasMain) { $pre = '-include', (Join-Path (Split-Path -Parent $PSScriptRoot) 'lc\lc-prelude.h') }
    & $Gpp @CppFlags @pre -fsyntax-only $src
    if ($LASTEXITCODE -eq 0) { Write-Host 'No errors.' -ForegroundColor Green }
    Finish $LASTEXITCODE
}

$buildDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
New-Item -ItemType Directory -Force $buildDir | Out-Null
$exe = Join-Path $buildDir "$name.exe"

Write-Host "Compiling $name.cpp..." -ForegroundColor Cyan
& $Gpp @CppFlags @TestFlags $src -o $exe
if ($LASTEXITCODE -ne 0) { Finish $LASTEXITCODE }

$in = Join-Path (Split-Path -Parent $src) 'input.txt'
if ($Mode -eq 'input') {
    if (-not (Test-Path -LiteralPath $in)) {
        New-Item -ItemType File $in | Out-Null
        Write-Host "Created empty $in - paste the sample input there and run again." -ForegroundColor Yellow
        Finish 1
    }
    Write-Host '--- running with input.txt ---' -ForegroundColor Cyan
} else {
    Write-Host '--- running (type input; Ctrl+Z then Enter ends input) ---' -ForegroundColor Cyan
}

$m = if ($Mode -eq 'input') { Start-Measured -Exe $exe -StdinFile $in } else { Start-Measured -Exe $exe }
$code = $m.Code
$cpuMs = $m.CpuMs
$peak = $m.PeakBytes

Write-Host ''
if ($null -eq $code) {
    Write-Host "--- finished, but the exit code couldn't be read ---" -ForegroundColor Yellow
    Finish 0
}
if ($code -eq 0) {
    $mem = if ($peak) { ", memory ~$([Math]::Round($peak / 1MB)) MB" } else { '' }
    Write-Host "--- finished: exit code 0, time $cpuMs ms$mem ---" -ForegroundColor Green
    if ($cpuMs -gt 1000) { Write-Host 'Over 1 s: may be too slow for a 1-2 s limit (the checks here add up to ~40%).' -ForegroundColor Yellow }
    if ($peak -gt 256MB) { Write-Host 'Over 256 MB: many judges limit memory to 256 MB.' -ForegroundColor Yellow }
} else {
    Write-Host ("--- crashed: exit code {0} (0x{0:X8}) ---" -f $code) -ForegroundColor Red
    Write-Host (Explain $code) -ForegroundColor Red
    if ($code -ne -1073741510) {  # not Ctrl+C
        if ($Mode -eq 'input') {
            $debugExe = $exe -replace '\.exe$', '-debug.exe'
            $debugArgs = @($CppFlags) + @($TestFlags | ForEach-Object { if ($_ -eq '-O2') { '-O0' } else { $_ } }) + $src
            Show-CrashLine -CompileArgs $debugArgs -DebugExe $debugExe -GdbRun '< input.txt > NUL 2> NUL' -WorkDir (Split-Path -Parent $in) -Src $src
        }
        else { Write-Host 'To see the crash line, put this input in input.txt and press Shift+F7.' -ForegroundColor DarkGray }
    }
}
Finish $code
