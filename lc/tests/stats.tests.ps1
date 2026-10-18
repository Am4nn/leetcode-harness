# Tests for .zed/lc-stats.ps1 (dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact).
# A temp journey; the real journey/ is never touched.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $stats = Join-Path $repo '.zed\lc-stats.ps1'
    . (Join-Path $repo '.zed\lc\journey.ps1')
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lcs-' + [guid]::NewGuid().ToString('N'))
    $journey = Join-Path $tmp 'journey'
    New-Item -ItemType Directory -Force (Join-Path $journey 'problems') | Out-Null
    $oldUf = $env:LC_USER_FILE
    $env:LC_USER_FILE = Join-Path $tmp 'no-user.txt'  # no username: only the 7-day rule for never-passed problems applies
    function Invoke-Stats([string[]]$Extra) {
        $out = powershell -NoProfile -ExecutionPolicy Bypass -File $stats @Extra -JourneyRoot $journey 2>&1 | Out-String
        return @{ Out = $out.Trim(); Code = $LASTEXITCODE }
    }
    function Add-Ev([string]$Event, [string]$Slug, [string]$Ts, $Data = @{}) {
        Write-LcEvent -Root $journey -Event $Event -Slug $Slug -File "leetcode-solves/$Slug.cpp" -SrcHash 'abc123' -Data $Data -Ts $Ts
    }
    try {
        foreach ($s in 'a-ok', 'b-crash', 'c-compile') {
            $meta = '{"questionFrontendId":"1","title":"' + $s + '","difficulty":"Easy","topicTags":[{"name":"Array"},{"name":"Hash Table"}]}'
            [IO.File]::WriteAllText((Join-Path $journey "problems\$s.json"), $meta, $utf8)
        }
        $pass = @(@{ n = 1; status = 'pass'; ms = 0.1 })
        # a-ok: a wrong answer, then a pass (2 runs), accepted; analyze O(n^2) then O(n); 6 reviews.
        Add-Ev 'test_run' 'a-ok' '2026-10-01T10:00:00+05:30' @{ compile_ok = $true; cases = @(@{ n = 1; status = 'fail'; input = '[1, 2], 3'; expected = '[0, 1]'; got = '[]' }); passed = 0; failed = 1 }
        Add-Ev 'test_run' 'a-ok' '2026-10-01T10:05:00+05:30' @{ compile_ok = $true; cases = $pass; passed = 1; failed = 0 }
        Add-Ev 'solved' 'a-ok' '2026-10-01T10:05:00+05:30' @{ attempts = 2; max_ms = 0.1 }
        Add-Ev 'accepted' 'a-ok' '2026-10-01T10:30:00+05:30' @{ submitted_at = '2026-10-01T10:30:00+05:30' }
        Add-Ev 'analyze_run' 'a-ok' '2026-10-01T11:00:00+05:30' @{ complexity = 'O(n^2)' }
        Add-Ev 'analyze_run' 'a-ok' '2026-10-01T11:10:00+05:30' @{ complexity = 'O(n)' }
        $i = 0
        foreach ($sc in 4, 5, 6, 7, 8, 9) {
            Add-Ev 'review' 'a-ok' ('2026-10-01T12:0{0}:00+05:30' -f $i++) @{ score = $sc; label = 'Good'; pattern = 'Hash Map' }
        }
        # b-crash: a crashing run with failed cases.
        Add-Ev 'test_run' 'b-crash' '2026-10-01T13:00:00+05:30' @{ compile_ok = $true; cases = @(@{ n = 1; status = 'crash' }); passed = 0; failed = 1
            crash = @{ cause = 'Program aborted: vector/string index out of range...' } }
        # c-compile: a build failure.
        Add-Ev 'test_run' 'c-compile' '2026-10-01T14:00:00+05:30' @{ compile_ok = $false; cases = @(); passed = 0; failed = 0; compile_error = "line 3: expected ';' before '}' token" }

        $now = '2026-10-03T12:00:00+05:30'
        $r = Invoke-Stats @('-Json', '-Now', $now)
        Assert-Equal $r.Code 0 "json exit code`n$($r.Out)"
        $j = $r.Out | ConvertFrom-Json
        $arr = @($j.tags | Where-Object { $_.tag -eq 'Array' })[0]
        Assert-True ($arr.problems -eq 3 -and $arr.accepted -eq 1 -and $arr.avg_runs_to_pass -eq 2) "Array tag: $($arr | ConvertTo-Json -Compress)"
        Assert-Equal @($j.tags).Count 2
        Assert-Equal $j.problems.total 3
        Assert-Equal $j.problems.attempted 2
        Assert-Equal @($j.mistakes.crash).Count 1
        Assert-Equal $j.mistakes.crash[0].count 1
        Assert-Match $j.mistakes.crash[0].examples[0] '^b-crash: Program aborted'
        Assert-Equal @($j.mistakes.compile).Count 1
        Assert-Match $j.mistakes.compile[0].examples[0] '^c-compile: line 3:'
        Assert-Equal $j.mistakes.compile[0].message "expected ';' before '}' token"
        Assert-Equal $j.mistakes.wrong.count 1
        Assert-Match $j.mistakes.wrong.examples[0] '^a-ok: \[1, 2\], 3'
        Assert-Equal @($j.complexity).Count 1
        Assert-Equal "$($j.complexity[0].slug)|$($j.complexity[0].first)|$($j.complexity[0].latest)" 'a-ok|O(n^2)|O(n)'
        Assert-True ($j.reviews.count -eq 6 -and $j.reviews.mean -eq 6.5 -and $j.reviews.last5 -eq 7 -and $j.reviews.prev5 -eq 4) "reviews: $($j.reviews | ConvertTo-Json -Compress)"

        # Text output: a first summary line, one line per row, sections with data only.
        $r = Invoke-Stats @('-Now', $now)
        Assert-Equal $r.Code 0 "text exit code`n$($r.Out)"
        $lines = @($r.Out -split "\r?\n")
        Assert-Equal $lines[0] 'problems: 3 (accepted 1, with hints 0, passed locally 0, attempted 2, failed 0)'
        foreach ($h in '== By tag', '== Mistakes', '== Complexity', '== Reviews') { Assert-True ($lines -contains $h) "missing section $h`n$($r.Out)" }
        Assert-True ($lines -contains 'a-ok: O(n^2) -> O(n)') "complexity line`n$($r.Out)"

        # -Since after every event: nothing counts, and no empty sections are printed.
        $r = Invoke-Stats @('-Since', '2026-12-01', '-Now', $now)
        Assert-Equal $r.Out 'problems: 0 (accepted 0, with hints 0, passed locally 0, attempted 0, failed 0)'
        $j = (Invoke-Stats @('-Since', '2026-12-01', '-Json', '-Now', $now)).Out | ConvertFrom-Json
        Assert-True ($j.problems.total -eq 0 -and @($j.tags).Count -eq 0 -and $j.reviews.count -eq 0) 'empty window'
        Assert-Equal (Invoke-Stats @('-Since', 'yesterday')).Code 1

        # A stale journey.md: 8 days after its first event a never-passed problem reads failed (Review Focus 5).
        $md = Join-Path $journey 'journey.md'
        $row = @([IO.File]::ReadAllLines($md) | Where-Object { $_.Contains('/problems/c-compile/') })[0]
        Assert-Match $row '\| attempted \|'
        $null = Invoke-Stats @('-Now', '2026-10-09T12:00:00+05:30')
        $rows = [IO.File]::ReadAllLines($md)
        $row = @($rows | Where-Object { $_.Contains('/problems/c-compile/') })[0]
        Assert-Match $row '\| failed \|'
        Assert-Match (@($rows | Where-Object { $_.Contains('/problems/a-ok/') })[0]) '\| accepted \|'
    } finally {
        $env:LC_USER_FILE = $oldUf
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
