# The chat agent's writes (docs/2026-10-18-coach-design.md): coach events in the journey (hint, solution,
# review) and the local coach memory (journey/local/). One confirmation line per command; never commits
# or pushes. Exit code 1 on bad input, with nothing written.
#   hint|solution -Slug s
#   review -Slug s -Score 1-10 -Label Poor|Fair|Good|Great -Pattern p [-Idea one-line-key-idea]
#   remember -Kind k -Text t [-Evidence 'slug:ref',...] [-Source coach|user] [-Until yyyy-MM-dd] [-Replaces id]
#   forget|resolve -Id id     edit -Id id -Text t     memory     read -Slug s     weekly -Text markdown
# -TextFile <path> reads -Text from a UTF-8 file: PS 5.1 drops double quotes inside command-line arguments,
# so text with quotes or several lines (a weekly read) goes through a file.
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

. (Join-Path $PSScriptRoot 'lc\journey.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
if (-not $SolutionsRoot) { $SolutionsRoot = Join-Path $dsaRoot 'leetcode-solves' }
if ($TextFile) { $Text = [IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8).Trim() }
$nowDt = if ($Now) { [DateTimeOffset]::Parse($Now, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } else { Get-Date }

$A = @{
    Command = $Command; Slug = $Slug; Score = $Score; Label = $Label; Pattern = $Pattern; Idea = $Idea; Kind = $Kind; Text = $Text
    Evidence = [string[]]$Evidence; Source = $Source; Until = $Until; Replaces = $Replaces; Id = $Id
    JourneyRoot = [IO.Path]::GetFullPath($JourneyRoot); SolutionsRoot = [IO.Path]::GetFullPath($SolutionsRoot); Now = $nowDt
}

# Each command family lives in its own library: Invoke-LcCoachEvent / Invoke-LcCoachMemory return the exit code.
if ($Command -in @('hint', 'solution', 'review')) {
    . (Join-Path $PSScriptRoot 'lc\coach-events.ps1')
    exit (Invoke-LcCoachEvent $A)
}
. (Join-Path $PSScriptRoot 'lc\memory.ps1')
exit (Invoke-LcCoachMemory $A)
