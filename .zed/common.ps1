# Shared helpers, dot-sourced by run-cpp.ps1 (F7) and lc.ps1 (LeetCode).

# Zed can hold a stale PATH, and g++ needs the DLLs in its own bin folder.
$env:Path = "C:\msys64\ucrt64\bin;$env:Path"
$Gpp = 'C:\msys64\ucrt64\bin\g++.exe'
$Gdb = 'C:\msys64\ucrt64\bin\gdb.exe'
$CppFlags = '-std=c++23', '-Wall', '-Wextra', '-Wshadow'
$TestFlags = @(
    '-O2', '-g', '-static'                                    # -static: the .exe doesn't need MSYS2's DLLs on PATH
    '-D_GLIBCXX_ASSERTIONS'                                   # vector/string index checks (_GLIBCXX_DEBUG is ~20x slower)
    '-fsanitize=undefined', '-fsanitize-undefined-trap-on-error'  # int overflow, divide by zero, null pointer
    '-Wl,--stack,268435456'                                   # 256 MB stack like Codeforces; Windows defaults to 1 MB
)
$BenchFlags = '-O2', '-static', '-Wl,--stack,268435456'

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

# Runs a program and returns @{ Code; CpuMs; PeakBytes; TimedOut }.
# Process.Start keeps the process handle from launch, so ExitCode and CPU time stay
# readable even when the program exits instantly (Start-Process loses them).
# -StdinFile is copied to the program's stdin; without it stdin is inherited.
# -TimeoutMs 0 means no timeout; on timeout the process tree is killed and Code is $null.
# -NoStdout discards the program's stdout (LeetCode analyze: debug prints would flood the terminal).
# -TeeTo: the program's stdout and stderr still reach the terminal and are also copied to this stream (the
# run log). Piped stdout is fully buffered, so the program should make it unbuffered (lc/lc-unbuffered.h)
# or prints before a crash are lost. Two pipes read one after the other lose the order of cout and cerr
# lines, so the program also gets LC_STDERR_TO_STDOUT=1 and points its stderr at stdout's pipe (the
# headers above and lc-run.h do); the stderr pipe stays pumped for anything written before that.
function Start-Measured {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$ArgumentList = @(),
        [string]$StdinFile,
        [int]$TimeoutMs = 0,
        [switch]$NoStdout,
        [IO.Stream]$TeeTo
    )
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe
    $psi.UseShellExecute = $false
    $quoted = foreach ($a in $ArgumentList) {
        if ($a -eq '' -or $a -match '[\s"]') { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $a }
    }
    $psi.Arguments = $quoted -join ' '
    $tee = $null -ne $TeeTo -and -not $NoStdout
    $psi.RedirectStandardInput = [bool]$StdinFile
    $psi.RedirectStandardOutput = $NoStdout -or $tee
    $psi.RedirectStandardError = $tee
    if ($tee) { $psi.EnvironmentVariables['LC_STDERR_TO_STDOUT'] = '1' }
    # Otherwise .NET writes a UTF-8 BOM (ef bb bf) before the file and the first cin >> fails.
    if ($StdinFile) { [Console]::InputEncoding = New-Object Text.UTF8Encoding $false }
    $p = [Diagnostics.Process]::Start($psi)
    if ($NoStdout) { [void]$p.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null) }
    $pumps = @()
    if ($tee) {
        $pumps = @(
            @{ From = $p.StandardOutput.BaseStream; To = [Console]::OpenStandardOutput() }
            @{ From = $p.StandardError.BaseStream; To = [Console]::OpenStandardError() }
        )
        foreach ($q in $pumps) { $q.Buf = New-Object byte[] 65536; $q.Task = $q.From.ReadAsync($q.Buf, 0, $q.Buf.Length) }
    }
    # Copied in the background: a program that prints while it reads blocks on a full stdout pipe until the
    # loop below drains it, so a copy that waits for the program to read everything first never finishes.
    $stdin = $null
    if ($StdinFile) {
        $fs = [IO.File]::OpenRead($StdinFile)
        $stdin = @{ File = $fs; Task = $fs.CopyToAsync($p.StandardInput.BaseStream) }
    }
    $peak = 0
    $timedOut = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        if ($stdin -and $stdin.Task.IsCompleted) { Close-LcStdin $p $stdin; $stdin = $null }  # end of input
        try { $p.Refresh(); $peak = [Math]::Max($peak, $p.PeakWorkingSet64) } catch {}
        if ($TimeoutMs -gt 0 -and $sw.ElapsedMilliseconds -ge $TimeoutMs) {
            $timedOut = $true
            & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
            try { $p.Kill() } catch {}
            break
        }
        Copy-LcPumped $pumps $TeeTo
        Start-Sleep -Milliseconds 10
    }
    if ($stdin) { Close-LcStdin $p $stdin }  # the program exited (or was killed) before reading it all
    $p.WaitForExit()
    Copy-LcPumped $pumps $TeeTo -Drain
    $code = $null
    if (-not $timedOut) { $code = $p.ExitCode }
    $cpuMs = 0
    try { $cpuMs = [int]$p.TotalProcessorTime.TotalMilliseconds } catch {}
    $p.Dispose()
    @{ Code = $code; CpuMs = $cpuMs; PeakBytes = $peak; TimedOut = $timedOut }
}

# Start-Measured -StdinFile: closes the program's stdin (it sees end of input) and the file. Closing the pipe
# first also ends a copy still writing to a program that has exited.
function Close-LcStdin($P, $Stdin) {
    try { $P.StandardInput.Close() } catch {}  # broken pipe: the program exited before reading it all
    try { [void]$Stdin.Task.Wait(1000) } catch {}
    $Stdin.File.Dispose()
}

# Start-Measured -TeeTo: copies what each pipe has read so far to the terminal and the log, then reads on.
# -Drain: reads each pipe to its end (the program has exited).
function Copy-LcPumped($Pumps, [IO.Stream]$Log, [switch]$Drain) {
    foreach ($q in $Pumps) {
        while ($q.Task -and ($Drain -or $q.Task.IsCompleted)) {
            $n = 0
            try { $n = $q.Task.GetAwaiter().GetResult() } catch {}
            if ($n -le 0) { $q.Task = $null; break }
            $q.To.Write($q.Buf, 0, $n); $q.To.Flush()
            try { $Log.Write($q.Buf, 0, $n); $Log.Flush() } catch {}
            $q.Task = $q.From.ReadAsync($q.Buf, 0, $q.Buf.Length)
        }
    }
}

# Reruns a crashed program under gdb and prints the crash lines in -Src.
# -CompileArgs: the full g++ arguments minus -o, with -O2 already replaced by -O0
# (at -O2 the compiler moves code and gdb reports the wrong line).
# -GdbRun: the text after gdb's "run", e.g. '< input.txt > NUL 2> NUL'.
# -Build: instead of -CompileArgs, a script block that builds -DebugExe.
function Show-CrashLine {
    param(
        [string[]]$CompileArgs,
        [scriptblock]$Build,
        [Parameter(Mandatory)][string]$DebugExe,
        [Parameter(Mandatory)][string]$GdbRun,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$Src
    )
    $script:LcCrashLine = $null
    Write-Host 'Finding the crash line...' -ForegroundColor DarkGray
    if ($Build) { & $Build | Out-Null }
    else { & $Gpp @CompileArgs -o $DebugExe 2>&1 | Out-Null }
    Push-Location $WorkDir
    # bt 20: a stack overflow has millions of frames.
    $out = & $Gdb -q -batch -nx -ex "run $GdbRun" -ex 'bt 20' $DebugExe 2>&1 | ForEach-Object { "$_" }
    Pop-Location

    $file = Split-Path -Leaf $Src
    $lines = Get-Content -LiteralPath $Src
    $found = $false
    $prev = ''
    foreach ($frame in $out) {
        if ($frame -match '^#\d+\s+(?:0x[0-9a-f]+ in\s+)?(.+?)\s\(.*\)\s+at\s+(.+):(\d+)$' -and (Split-Path -Leaf $Matches[2]) -eq $file) {
            $fn = $Matches[1]; $n = [int]$Matches[3]
            if ("$fn`:$n" -eq $prev) { continue }  # recursion repeats the same frame
            $prev = "$fn`:$n"
            if (-not $found) { $script:LcCrashLine = $n }  # for callers that log the crash
            $label = if ($found) { '  called from' } else { '  crashed at ' }
            Write-Host ("{0} line {1,-4} in {2}:  {3}" -f $label, $n, $fn, $lines[$n - 1].Trim()) -ForegroundColor Yellow
            $found = $true
        }
    }
    if (-not $found) { Write-Host "  Couldn't find a line in $file (the unoptimized rerun may not crash the same way)." -ForegroundColor DarkGray }
}
