# The chat agent's writes (docs/2026-10-18-coach-design.md): coach events in the journey (hint, solution,
# review) and the local coach memory (journey/local/). One confirmation line per command; never commits
# or pushes. Exit code 1 on bad input, with nothing written, and on a failed write ("error: ..."), so a
# confirmation line always means it was saved.
#   hint|solution -Slug s
#   review -Slug s -Score 1-10 -Label Poor|Fair|Good|Great -Pattern p [-Idea one-line-key-idea | -IdeaFile path]
#   remember -Kind k -Text t [-Evidence 'slug:ref',...] [-Source coach|user] [-Until yyyy-MM-dd] [-Replaces id]
#   forget|resolve -Id id     edit -Id id -Text t     memory     read -Slug s     weekly -Text markdown
# -TextFile <path> reads -Text from a file, and -IdeaFile <path> reads -Idea: PS 5.1 drops double quotes
# inside command-line arguments, so text with quotes or several lines (a weekly read) goes through a file.
# A file with a BOM is read in that encoding; without one, as UTF-8 when it is valid UTF-8, else in the
# ANSI code page (what PS 5.1's Set-Content writes).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('hint', 'solution', 'review', 'remember', 'forget', 'edit', 'resolve', 'memory', 'read', 'weekly')]
    [string]$Command,
    [string]$Slug = '',
    [int]$Score = 0,
    [string]$Label = '',
    [string]$Pattern = '',
    [string]$Idea = '',
    [string]$IdeaFile = '',
    [string]$Kind = '',
    [string]$Text = '',
    [string]$TextFile = '',
    [string[]]$Evidence = @(),
    [ValidateSet('coach', 'user')][string]$Source = 'coach',
    [string]$Until = '',
    [string]$Replaces = '',
    [string]$Id = '',
    [string]$JourneyRoot = '',    # default <dsa>/journey
    [string]$SolutionsRoot = '',  # default <dsa>/leetcode-solves
    [string]$Now = ''             # self-tests: the time to act at (ISO 8601); default now
)

# A .NET exception (a locked or read-only file) must stop the command, not let it print its confirmation.
$ErrorActionPreference = 'Stop'

function Read-LcTextFile([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -or
           ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF)))
    if ($bom) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }  # follows the BOM
    try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($b) }
    catch { return [Text.Encoding]::Default.GetString($b) }
}

try {
    . (Join-Path $PSScriptRoot 'lc\journey.ps1')

    $dsaRoot = Split-Path -Parent $PSScriptRoot
    if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
    if (-not $SolutionsRoot) { $SolutionsRoot = Join-Path $dsaRoot 'leetcode-solves' }
    if ($TextFile) { $Text = (Read-LcTextFile $TextFile).Trim() }
    if ($IdeaFile) { $Idea = (Read-LcTextFile $IdeaFile).Trim() }
    $nowDt = if ($Now) { [DateTimeOffset]::Parse($Now, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } else { Get-Date }

    $A = @{
        Command = $Command; Slug = $Slug; Score = $Score; Label = $Label; Pattern = $Pattern; Idea = $Idea; Kind = $Kind; Text = $Text
        Evidence = [string[]]$Evidence; Source = $Source; Until = $Until; Replaces = $Replaces; Id = $Id
        JourneyRoot = [IO.Path]::GetFullPath($JourneyRoot); SolutionsRoot = [IO.Path]::GetFullPath($SolutionsRoot); Now = $nowDt
    }

    # Each command family lives in its own library: Invoke-LcCoachEvent / Invoke-LcCoachMemory return the exit code.
    if ($Command -in @('hint', 'solution', 'review')) {
        . (Join-Path $PSScriptRoot 'lc\coach-events.ps1')
        $code = Invoke-LcCoachEvent $A
    } else {
        . (Join-Path $PSScriptRoot 'lc\memory.ps1')
        $code = Invoke-LcCoachMemory $A
    }
} catch {
    $e = $_.Exception
    if ($e -is [Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    Write-Host "error: $($e.Message)"
    exit 1
}
exit $code
