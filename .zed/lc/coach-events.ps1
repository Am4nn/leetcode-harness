# Coach events in the journey (docs/2026-10-18-coach-design.md): hint, solution and review, written for
# the chat agent by .zed/lc-coach.ps1. Function library: dot-source it after journey.ps1.

# $A: Command (hint|solution|review), Slug, Score, Label, Pattern, JourneyRoot and SolutionsRoot (full
# paths), Now ([datetime]). Writes one event, rebuilds journey.md and prints one line. Returns the exit
# code: 0, or 1 on bad input with nothing written.
function Invoke-LcCoachEvent([hashtable]$A) {
    $cmd = [string]$A.Command
    $slug = ([string]$A.Slug).Trim()
    if ($slug -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Write-Host "$cmd needs -Slug (a problem slug like two-sum)"; return 1 }
    $data = [ordered]@{}
    if ($cmd -eq 'review') {
        $score = [int]$A.Score
        $label = @('Poor', 'Fair', 'Good', 'Great') | Where-Object { $_ -eq [string]$A.Label } | Select-Object -First 1
        $pattern = ([string]$A.Pattern -replace '[\r\n]+', ' ').Trim()
        if ($score -lt 1 -or $score -gt 10) { Write-Host 'review needs -Score 1-10'; return 1 }
        if (-not $label) { Write-Host 'review needs -Label Poor, Fair, Good or Great'; return 1 }
        if (-not $pattern) { Write-Host 'review needs -Pattern'; return 1 }
        $data.score = $score; $data.label = $label; $data.pattern = Limit-LcText $pattern
    }

    # file and src_hash come from the solution file as it is now ('' for both when it doesn't exist),
    # the file relative to the folder holding the journey, like lc.ps1 does.
    $root = $A.JourneyRoot
    $src = Join-Path $A.SolutionsRoot "$slug.cpp"
    $file = ''; $hash = ''
    if ([IO.File]::Exists($src)) {
        $hash = Get-LcSrcHash $src
        $base = (Split-Path -Parent $root).TrimEnd('\') + '\'
        $file = $src.Replace('\', '/')
        if ($src.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $file = $src.Substring($base.Length).Replace('\', '/') }
    }

    $ts = ([datetime]$A.Now).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
    Write-LcEvent -Root $root -Event $cmd -Slug $slug -File $file -SrcHash $hash -Data $data -Ts $ts
    # A full rebuild, so time-based statuses (failed after 7 days) stay current. A problem that was never
    # run has no row; a journey.md problem must not undo the event that is already saved.
    try { Update-LcJourneyFile -Root $root -AcceptsTracked (Test-LcAcceptsTracked (Get-LcUserFile)) -Now ([datetime]$A.Now) }
    catch { Write-Host "(journey.md not updated: $($_.Exception.Message))" }
    Write-Host "recorded ${cmd}: $slug"
    return 0
}
