# Builds LeetCode exes from two translation units per build flavor, each against its own precompiled header:
#   <name>-harness.cpp  hook declarations, the LcProxy class and main() running lc.h; compiled once per
#                       problem signature (and again when lc/*.h or the flags change)
#   <name>-user.cpp     the solution plus the hook definitions; recompiled when the solution changes
# Function library: dot-source it after common.ps1 ($Gpp, $CppFlags, $TestFlags, $BenchFlags). No side effects.

$script:LcDsaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Where PCHs, objects and exes go: $env:LC_BUILD_ROOT when set (self-tests), else <dsa>/build.
function Get-LcBuildRoot {
    if ($env:LC_BUILD_ROOT) { return $env:LC_BUILD_ROOT }
    return Join-Path $script:LcDsaRoot 'build'
}

# The flavor's flags for both translation units, link flags included.
function Get-LcFlavorFlags([string]$Flavor) {
    switch ($Flavor) {
        'test'    { return @($CppFlags) + @($TestFlags) }
        # Crash-line replay: test flags at -O0 (at -O2 gdb reports the wrong line).
        'debug'   { return @($CppFlags) + @($TestFlags | ForEach-Object { if ($_ -eq '-O2') { '-O0' } else { $_ } }) }
        'bench'   { return @($CppFlags) + @($BenchFlags) }
        'profile' { return @($CppFlags) + @($BenchFlags) + @('-Wl,--disable-dynamicbase', '-DLC_PROFILE') }
    }
    throw "unknown build flavor: $Flavor"
}

# Extra compile flags for the user translation unit (and its PCH) only. Profile: only the user's own
# functions call lc-prof.h's hooks; the STL and the prelude (TreeNode/ListNode) are excluded by file, the
# generated lc_user_* hooks by name. (The solution may itself sit under a /lc/ or /build/ folder.)
function Get-LcUserFlags([string]$Flavor) {
    if ($Flavor -eq 'profile') {
        return @('-finstrument-functions', '-finstrument-functions-exclude-file-list=include/,lc-prelude.h',
                 '-finstrument-functions-exclude-function-list=lc_user_')
    }
    return @()
}

# Link-only flags (-Wl,... counts as linker input) would make g++ try to link a header or object.
function Get-LcCompileFlags([string[]]$Flags) {
    return @($Flags | Where-Object { $_ -ne '-static' -and $_ -notlike '-Wl,*' })
}

function Get-LcLinkFlags([string[]]$Flags) {
    return @($Flags | Where-Object { $_ -eq '-static' -or $_ -like '-Wl,*' -or $_ -like '-fsanitize*' })
}

function Get-LcTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Read-LcStamp([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return ''
}

# <build root>/lc/<slug>-<8 hex of the full path>: files with the same name in different folders don't share one.
function Get-LcBuildDir([string]$SrcPath) {
    $full = [IO.Path]::GetFullPath($SrcPath)
    $slug = [IO.Path]::GetFileNameWithoutExtension($full)
    $hash = (Get-LcTextHash $full.ToLowerInvariant()).Substring(0, 8).ToLowerInvariant()
    return Join-Path (Get-LcBuildRoot) "lc\$slug-$hash"
}

# Writes <Dir>\<Name> (#include lines) and (re)builds <Name>.gch when it's missing, the flags changed or one
# of $Deps is newer. Returns the header path; throws with g++'s output if the header doesn't compile.
function Initialize-LcGch([string]$Dir, [string]$Name, [string]$Text, [string[]]$Flags, [IO.FileInfo[]]$Deps) {
    $hdr = Join-Path $Dir $Name
    $gch = "$hdr.gch"
    $stampPath = [IO.Path]::ChangeExtension($hdr, '.stamp')
    $stamp = Get-LcTextHash ($Text + ($Flags -join ' '))
    $fresh = (Test-Path -LiteralPath $gch) -and (Read-LcStamp $stampPath) -eq $stamp
    if ($fresh) {
        $built = (Get-Item -LiteralPath $gch).LastWriteTimeUtc
        foreach ($d in $Deps) { if ($d.LastWriteTimeUtc -gt $built) { $fresh = $false; break } }
    }
    if ($fresh) { return $hdr }

    New-Item -ItemType Directory -Force $Dir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($hdr, $Text, $utf8)
    Remove-Item -LiteralPath $stampPath -ErrorAction SilentlyContinue
    $out = & $Gpp @Flags -x c++-header $hdr -o $gch 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw ("Precompiled header failed:`n" + ($out -join "`n")) }
    [IO.File]::WriteAllText($stampPath, $stamp, $utf8)
    return $hdr
}

function Get-LcInclude([string]$Header) {
    return '#include "' + ((Join-Path (Join-Path $script:LcDsaRoot 'lc') $Header) -replace '\\', '/') + "`"`n"
}

# The harness PCH: <build root>/pch/<flavor>/lc-all.h (prelude + lc.h), rebuilt when any lc/*.h changes.
function Initialize-LcPch {
    param([Parameter(Mandatory)][ValidateSet('test', 'debug', 'bench', 'profile')][string]$Flavor)
    $deps = Get-ChildItem -LiteralPath (Join-Path $script:LcDsaRoot 'lc') -Filter '*.h'
    return Initialize-LcGch -Dir (Join-Path (Get-LcBuildRoot) "pch\$Flavor") -Name 'lc-all.h' `
        -Text ((Get-LcInclude 'lc-prelude.h') + (Get-LcInclude 'lc.h')) `
        -Flags (Get-LcCompileFlags (Get-LcFlavorFlags $Flavor)) -Deps $deps
}

# The user PCH: <build root>/pch/<flavor>-user/lc-prelude.h (prelude only), rebuilt when lc/lc-prelude.h changes.
function Initialize-LcUserPch {
    param([Parameter(Mandatory)][ValidateSet('test', 'debug', 'bench', 'profile')][string]$Flavor)
    $deps = Get-Item -LiteralPath (Join-Path $script:LcDsaRoot 'lc\lc-prelude.h')
    return Initialize-LcGch -Dir (Join-Path (Get-LcBuildRoot) "pch\$Flavor-user") -Name 'lc-prelude.h' `
        -Text (Get-LcInclude 'lc-prelude.h') `
        -Flags (@(Get-LcCompileFlags (Get-LcFlavorFlags $Flavor)) + @(Get-LcUserFlags $Flavor)) -Deps $deps
}

# Starts g++ without waiting; Wait-LcGpp returns @{ Ok; Text }. Lets the two objects compile in parallel.
function Start-LcGpp([string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Gpp
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $quoted = foreach ($a in $Arguments) {
        if ($a -eq '' -or $a -match '[\s"]') { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $a }
    }
    $psi.Arguments = $quoted -join ' '
    $p = [Diagnostics.Process]::Start($psi)
    return @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Wait-LcGpp($job) {
    $job.P.WaitForExit()
    $text = ($job.Out.Result + $job.Err.Result) -replace "`r`n", "`n"
    $ok = $job.P.ExitCode -eq 0
    $job.P.Dispose()
    return @{ Ok = $ok; Text = $text.TrimEnd() }
}

# Builds <build root>/lc/<slug>-<hash>/<Name>.exe (Name defaults to the flavor) from the harness and user texts.
# Each object is compiled only when its stamp changed (harness: text + flags + lc-all.h.gch time;
# user: text + solution + flags + lc-prelude.h.gch time); the exe is relinked when either object changed.
# Returns @{ Ok; Exe; Ms; Skipped; Errors; Stage }. On failure Errors is g++'s output (warnings included)
# and Stage says which step failed: 'harness' (also for the unsupported-type static_assert), 'user' or 'link'.
function Build-LcExe {
    param(
        [Parameter(Mandatory)][string]$SrcPath,
        [Parameter(Mandatory)][string]$HarnessText,
        [Parameter(Mandatory)][string]$UserText,
        [ValidateSet('test', 'debug', 'bench', 'profile')][string]$Flavor = 'test',
        [string]$Name = ''
    )
    if (-not $Name) { $Name = $Flavor }
    $dir = Get-LcBuildDir $SrcPath
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir "$Name.exe"
    $fail = @{ Ok = $false; Exe = $exe; Ms = 0; Skipped = $false; Errors = ''; Stage = '' }
    try {
        $pch = Initialize-LcPch -Flavor $Flavor
        $userPch = Initialize-LcUserPch -Flavor $Flavor
    } catch {
        $fail.Errors = $_.Exception.Message
        return $fail
    }

    $flags = Get-LcFlavorFlags $Flavor
    $compile = Get-LcCompileFlags $flags
    $utf8 = New-Object Text.UTF8Encoding $false
    $gchTime = { param($h) (Get-Item -LiteralPath "$h.gch").LastWriteTimeUtc.Ticks }
    $parts = @(
        @{ Stage = 'harness'; Text = $HarnessText; Flags = @($compile) + @('-include', $pch, '-Winvalid-pch')
           Stamp = $HarnessText + "`n" + ($compile -join ' ') + "`n" + (& $gchTime $pch) }
        @{ Stage = 'user'; Text = $UserText; Flags = @($compile) + @(Get-LcUserFlags $Flavor) + @('-include', $userPch, '-Winvalid-pch')
           Stamp = $UserText + "`n" + [IO.File]::ReadAllText($SrcPath) + "`n" + ($compile -join ' ') + ' ' +
                   (@(Get-LcUserFlags $Flavor) -join ' ') + "`n" + (& $gchTime $userPch) }
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($t in $parts) {
        $base = Join-Path $dir "$Name-$($t.Stage)"
        $t.Obj = "$base.o"
        $t.StampPath = "$base.stamp"
        $t.Hash = Get-LcTextHash $t.Stamp
        if ((Test-Path -LiteralPath $t.Obj) -and (Read-LcStamp $t.StampPath) -eq $t.Hash) { continue }
        [IO.File]::WriteAllText("$base.cpp", $t.Text, $utf8)
        Remove-Item -LiteralPath $t.StampPath -ErrorAction SilentlyContinue
        $t.Job = Start-LcGpp (@($t.Flags) + @('-c', "$base.cpp", '-o', $t.Obj))
    }
    foreach ($t in $parts) {
        if (-not $t.Job) { continue }
        $t.Result = Wait-LcGpp $t.Job
        if ($t.Result.Ok) { [IO.File]::WriteAllText($t.StampPath, $t.Hash, $utf8) }
    }
    # The unsupported-type message comes first, then the user's own errors, then anything else.
    $h = $parts[0]; $u = $parts[1]
    $failed = $null
    if ($h.Result -and -not $h.Result.Ok -and $h.Result.Text -match 'lc: unsupported parameter type') { $failed = $h }
    elseif ($u.Result -and -not $u.Result.Ok) { $failed = $u }
    elseif ($h.Result -and -not $h.Result.Ok) { $failed = $h }
    if ($failed) {
        $fail.Ms = $sw.ElapsedMilliseconds
        $fail.Errors = $failed.Result.Text
        $fail.Stage = $failed.Stage
        return $fail
    }

    $linkStampPath = Join-Path $dir "$Name.stamp"
    $linkFlags = Get-LcLinkFlags $flags
    $linkStamp = Get-LcTextHash ($h.Hash + "`n" + $u.Hash + "`n" + ($linkFlags -join ' '))
    if ((Test-Path -LiteralPath $exe) -and (Read-LcStamp $linkStampPath) -eq $linkStamp) {
        return @{ Ok = $true; Exe = $exe; Ms = 0; Skipped = $true; Errors = ''; Stage = '' }
    }
    Remove-Item -LiteralPath $linkStampPath -ErrorAction SilentlyContinue
    $link = Wait-LcGpp (Start-LcGpp (@($linkFlags) + @($h.Obj, $u.Obj, '-o', $exe)))
    $sw.Stop()
    if (-not $link.Ok) {
        $fail.Ms = $sw.ElapsedMilliseconds
        $fail.Errors = $link.Text
        $fail.Stage = 'link'
        return $fail
    }
    [IO.File]::WriteAllText($linkStampPath, $linkStamp, $utf8)
    return @{ Ok = $true; Exe = $exe; Ms = $sw.ElapsedMilliseconds; Skipped = $false; Errors = ''; Stage = '' }
}
