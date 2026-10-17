# Builds LeetCode wrapper exes against a precompiled header (one per build flavor).
# Function library: dot-source it after common.ps1 ($Gpp, $CppFlags, $TestFlags, $BenchFlags). No side effects.

$script:LcDsaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-LcFlavorFlags([string]$Flavor) {
    switch ($Flavor) {
        'test'    { return @($CppFlags) + @($TestFlags) }
        'bench'   { return @($CppFlags) + @($BenchFlags) }
        'profile' {
            return @($CppFlags) + @($BenchFlags) + @('-finstrument-functions',
                '-finstrument-functions-exclude-file-list=include/c++,/lc/,/build/', '-Wl,--disable-dynamicbase', '-DLC_PROFILE')
        }
    }
    throw "unknown build flavor: $Flavor"
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

# Returns the path of build/pch/<flavor>/lc-all.h, (re)building lc-all.h.gch when lc/*.h is newer
# than it or the flavor's flags changed. Throws with g++'s output if the header doesn't compile.
function Initialize-LcPch {
    param([Parameter(Mandatory)][ValidateSet('test', 'bench', 'profile')][string]$Flavor)
    $dir = Join-Path $script:LcDsaRoot "build\pch\$Flavor"
    $hdr = Join-Path $dir 'lc-all.h'
    $gch = "$hdr.gch"
    $stampPath = Join-Path $dir 'lc-all.stamp'
    $lcDir = Join-Path $script:LcDsaRoot 'lc'
    $text = '#include "' + ((Join-Path $lcDir 'lc-prelude.h') -replace '\\', '/') + "`"`n" +
            '#include "' + ((Join-Path $lcDir 'lc.h') -replace '\\', '/') + "`"`n"
    $flags = Get-LcFlavorFlags $Flavor
    $stamp = Get-LcTextHash ($text + ($flags -join ' '))

    $fresh = (Test-Path -LiteralPath $gch) -and (Read-LcStamp $stampPath) -eq $stamp
    if ($fresh) {
        $built = (Get-Item -LiteralPath $gch).LastWriteTimeUtc
        foreach ($h in Get-ChildItem -LiteralPath $lcDir -Filter '*.h') {
            if ($h.LastWriteTimeUtc -gt $built) { $fresh = $false; break }
        }
    }
    if ($fresh) { return $hdr }

    New-Item -ItemType Directory -Force $dir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($hdr, $text, $utf8)
    Remove-Item -LiteralPath $stampPath -ErrorAction SilentlyContinue
    # Link-only flags (-Wl,... counts as linker input) would make g++ try to link the header.
    $compileFlags = @($flags | Where-Object { $_ -ne '-static' -and $_ -notlike '-Wl,*' })
    $out = & $Gpp @compileFlags -x c++-header $hdr -o $gch 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw ("Precompiled header failed:`n" + ($out -join "`n")) }
    [IO.File]::WriteAllText($stampPath, $stamp, $utf8)
    return $hdr
}

# Writes build/lc/<slug>/<name>.cpp and compiles it to <name>.exe with the flavor's PCH.
# Skips the compile when <name>.stamp matches wrapper + source + flags + PCH time.
# Returns @{ Ok; Exe; Ms; Skipped; Errors } (Errors: g++'s output, warnings included).
function Build-LcExe {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$SrcPath,
        [Parameter(Mandatory)][string]$WrapperText,
        [ValidateSet('test', 'bench', 'profile')][string]$Flavor = 'test',
        [string]$Name = 'test'
    )
    $dir = Join-Path $script:LcDsaRoot "build\lc\$Slug"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $cpp = Join-Path $dir "$Name.cpp"
    $exe = Join-Path $dir "$Name.exe"
    $stampPath = Join-Path $dir "$Name.stamp"
    try { $pch = Initialize-LcPch -Flavor $Flavor }
    catch { return @{ Ok = $false; Exe = $exe; Ms = 0; Skipped = $false; Errors = $_.Exception.Message } }

    $flags = Get-LcFlavorFlags $Flavor
    $gchTime = (Get-Item -LiteralPath "$pch.gch").LastWriteTimeUtc.Ticks
    $stamp = Get-LcTextHash ($WrapperText + "`n" + [IO.File]::ReadAllText($SrcPath) + "`n" + ($flags -join ' ') + "`n$gchTime")
    if ((Test-Path -LiteralPath $exe) -and (Read-LcStamp $stampPath) -eq $stamp) {
        return @{ Ok = $true; Exe = $exe; Ms = 0; Skipped = $true; Errors = '' }
    }

    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($cpp, $WrapperText, $utf8)
    Remove-Item -LiteralPath $stampPath -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $Gpp @flags -include $pch -Winvalid-pch $cpp -o $exe 2>&1 | ForEach-Object { "$_" }
    $ok = $LASTEXITCODE -eq 0
    $sw.Stop()
    if ($ok) { [IO.File]::WriteAllText($stampPath, $stamp, $utf8) }
    return @{ Ok = $ok; Exe = $exe; Ms = $sw.ElapsedMilliseconds; Skipped = $false; Errors = ($out -join "`n") }
}
