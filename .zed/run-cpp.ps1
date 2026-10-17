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

# Waits for Enter so the output stays readable; the task closes its tab once we exit.
function Finish([int]$code) {
    Write-Host "`nPress Enter to close" -NoNewline
    [void][Console]::ReadLine()
    exit $code
}

# Windows crash codes, translated into the usual DSA causes.
function Explain([int]$code) {
    switch ('0x{0:X8}' -f $code) {
        '0xC0000005' { 'Memory access violation: reading or writing outside an array, or through a null or dangling pointer.' }
        '0xC00000FD' { 'Stack overflow: recursion that never stops (check the base case).' }
        '0xC000001D' { 'Undefined behavior caught: signed integer overflow (use long long?), division by zero, null pointer, or a bad shift.' }
        '0xC0000094' { 'Division or modulo by zero.' }
        '0xC0000409' { 'Program aborted: vector/string index out of range, a failed assert, or an uncaught exception (see the message above).' }
        '0x00000003' { 'Program aborted: vector/string index out of range, a failed assert, or an uncaught exception (see the message above).' }
        '0xC000013A' { 'Stopped with Ctrl+C.' }
        default      { "main() returned $code." }
    }
}

# Reruns the crashed program under gdb with the same input and prints the crash lines in $src.
function Show-CrashLine([string]$exe, [string]$src, [string]$inputFile) {
    Write-Host 'Finding the crash line...' -ForegroundColor DarkGray
    # Rebuild with -O0: at -O2 the compiler moves code and gdb reports the wrong line.
    $exe = $exe -replace '\.exe$', '-debug.exe'
    $debugFlags = $runFlags | ForEach-Object { if ($_ -eq '-O2') { '-O0' } else { $_ } }
    & $gpp @flags @debugFlags $src -o $exe 2>&1 | Out-Null
    Push-Location (Split-Path -Parent $inputFile)
    # bt 20: a stack overflow has millions of frames.
    $out = & $gdb -q -batch -nx -ex "run < input.txt > NUL 2> NUL" -ex 'bt 20' $exe 2>&1 | ForEach-Object { "$_" }
    Pop-Location

    $file = Split-Path -Leaf $src
    $lines = Get-Content -LiteralPath $src
    $found = $false
    $prev = ''
    foreach ($frame in $out) {
        if ($frame -match '^#\d+\s+(?:0x[0-9a-f]+ in\s+)?(.+?)\s\(.*\)\s+at\s+(.+):(\d+)$' -and (Split-Path -Leaf $Matches[2]) -eq $file) {
            $fn = $Matches[1]; $n = [int]$Matches[3]
            if ("$fn`:$n" -eq $prev) { continue }  # recursion repeats the same frame
            $prev = "$fn`:$n"
            $label = if ($found) { '  called from' } else { '  crashed at ' }
            Write-Host ("{0} line {1,-4} in {2}:  {3}" -f $label, $n, $fn, $lines[$n - 1].Trim()) -ForegroundColor Yellow
            $found = $true
        }
    }
    if (-not $found) { Write-Host "  Couldn't find a line in $file (the unoptimized rerun may not crash the same way)." -ForegroundColor DarkGray }
}

# Zed can hold a stale PATH, and g++ needs the DLLs in its own bin folder.
$env:Path = "C:\msys64\ucrt64\bin;$env:Path"
$gpp = 'C:\msys64\ucrt64\bin\g++.exe'
$gdb = 'C:\msys64\ucrt64\bin\gdb.exe'
$flags = '-std=c++23', '-Wall', '-Wextra', '-Wshadow'
$runFlags = @(
    '-O2', '-g', '-static'                                    # -static: the .exe doesn't need MSYS2's DLLs on PATH
    '-D_GLIBCXX_ASSERTIONS'                                   # vector/string index checks (_GLIBCXX_DEBUG is ~20x slower)
    '-fsanitize=undefined', '-fsanitize-undefined-trap-on-error'  # int overflow, divide by zero, null pointer
    '-Wl,--stack,268435456'                                   # 256 MB stack like Codeforces; Windows defaults to 1 MB
)

$src = ($Rest -join ' ').Trim('"')
if (-not $src -or -not (Test-Path -LiteralPath $src)) { Write-Host "No such file: '$src'" -ForegroundColor Red; Finish 1 }
if ([IO.Path]::GetExtension($src) -ne '.cpp') { Write-Host "Not a .cpp file: $src" -ForegroundColor Red; Finish 1 }

$name = [IO.Path]::GetFileNameWithoutExtension($src)
$hasMain = Select-String -LiteralPath $src -Pattern '\bmain\s*\(' -Quiet

if ($Mode -eq 'check' -or -not $hasMain) {
    if ($Mode -ne 'check') { Write-Host "No main() in $name.cpp - checking for errors only." -ForegroundColor Yellow }
    & $gpp @flags -fsyntax-only $src
    if ($LASTEXITCODE -eq 0) { Write-Host 'No errors.' -ForegroundColor Green }
    Finish $LASTEXITCODE
}

$buildDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
New-Item -ItemType Directory -Force $buildDir | Out-Null
$exe = Join-Path $buildDir "$name.exe"

Write-Host "Compiling $name.cpp..." -ForegroundColor Cyan
& $gpp @flags @runFlags $src -o $exe
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

# Process.Start keeps the process handle from launch, so ExitCode and CPU time stay
# readable even when the program exits instantly (Start-Process loses them).
$psi = New-Object Diagnostics.ProcessStartInfo $exe
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = ($Mode -eq 'input')
# Otherwise .NET writes a UTF-8 BOM (ef bb bf) before input.txt and the first cin >> fails.
if ($Mode -eq 'input') { [Console]::InputEncoding = New-Object Text.UTF8Encoding $false }
$p = [Diagnostics.Process]::Start($psi)
if ($Mode -eq 'input') {
    $fs = [IO.File]::OpenRead($in)
    try { $fs.CopyTo($p.StandardInput.BaseStream) } catch {}  # the program may exit before reading it all
    finally { $fs.Dispose(); try { $p.StandardInput.Close() } catch {} }
}
$peak = 0
while (-not $p.HasExited) {
    try { $p.Refresh(); $peak = [Math]::Max($peak, $p.PeakWorkingSet64) } catch {}
    Start-Sleep -Milliseconds 10
}
$p.WaitForExit()
$code = $p.ExitCode
$cpuMs = [int]$p.TotalProcessorTime.TotalMilliseconds

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
        if ($Mode -eq 'input') { Show-CrashLine $exe $src $in }
        else { Write-Host 'To see the crash line, put this input in input.txt and press Shift+F7.' -ForegroundColor DarkGray }
    }
}
Finish $code
