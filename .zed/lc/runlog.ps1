# Run log: a Zed run (F7, Shift+F7, Ctrl+F7, Alt+F7, Alt+F8) started with -LogRun saves what its terminal
# showed, so a coding agent can answer "why did that run fail" (.zed/lc-context.ps1 prints it).
#   <runs>/<id>.log  "name: value" header lines up to a "----" line, then the run's output
#   <runs>/<id>.cpp  the source as it was run
# <runs> is $env:LC_RUNS_ROOT when set (self-tests), else <dsa>/build/runs. The newest 50 runs are kept.
# Function library: dot-source it after common.ps1. Nothing is logged until Start-LcRunLog.

$script:LcRunsDsaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:LcRunLog = $null  # the open log (a FileStream) while this run is logged

function Get-LcRunsRoot {
    if ($env:LC_RUNS_ROOT) { return $env:LC_RUNS_ROOT }
    return Join-Path $script:LcRunsDsaRoot 'build\runs'
}

# The file as the log names it: relative to the dsa root when inside it, else the full path.
function Get-LcRunFileName([string]$Path) {
    $base = $script:LcRunsDsaRoot.TrimEnd('\') + '\'
    if ($Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($base.Length).Replace('\', '/') }
    return $Path
}

# Starts logging: writes the header and a copy of the source, then deletes all but the newest 50 runs.
# -Key: the Zed key that started the run ("Alt+F7"). Any failure leaves the run unlogged, never broken.
function Start-LcRunLog([string]$Key, [string]$Src) {
    try {
        $root = Get-LcRunsRoot
        New-Item -ItemType Directory -Force $root | Out-Null
        $slug = [IO.Path]::GetFileNameWithoutExtension($Src)
        $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$slug-" + ($Key.ToLower() -replace '\+', '-')
        $old = @(Get-ChildItem -LiteralPath $root -Filter '*.log' | Sort-Object Name -Descending | Select-Object -Skip 49)
        foreach ($f in $old) {
            Remove-Item -LiteralPath $f.FullName, ($f.FullName -replace '\.log$', '.cpp') -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath $Src -Destination (Join-Path $root "$id.cpp")
        $script:LcRunLog = New-Object IO.FileStream((Join-Path $root "$id.log"), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        Write-LcRunLogText ((@(
            "time: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')"
            "key: $Key"
            "file: $(Get-LcRunFileName $Src)"
            "source: $id.cpp"
            "command: $([Environment]::CommandLine)"
            '----'
        ) -join "`n") + "`n")
    } catch { $script:LcRunLog = $null }
}

function Write-LcRunLogText([string]$Text) {
    if (-not $script:LcRunLog) { return }
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Text)
        $script:LcRunLog.Write($b, 0, $b.Length)
        $script:LcRunLog.Flush()
    } catch {}
}

# Write-Host as usual, plus a copy in the run log. It replaces Write-Host in every script that dot-sources
# this file, functions from the other dot-sourced files included.
function Write-Host {
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)][object]$Object,
        [switch]$NoNewline,
        [object]$Separator = ' ',
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )
    process {
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
        if (-not $script:LcRunLog) { return }
        $text = if ($null -eq $Object) { '' }
                elseif ($Object -is [Collections.IEnumerable] -and $Object -isnot [string]) { (@($Object) | ForEach-Object { "$_" }) -join "$Separator" }
                else { "$Object" }
        if (-not $NoNewline) { $text += "`n" }
        Write-LcRunLogText $text
    }
}

# [Console]::ReadLine with the typed line copied into the run log.
function Read-LcLine {
    $a = [Console]::ReadLine()
    if ($null -ne $a) { Write-LcRunLogText "$a`n" }
    return $a
}
