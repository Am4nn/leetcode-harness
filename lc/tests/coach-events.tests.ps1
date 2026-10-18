# Tests for .zed/lc-coach.ps1's hint / solution / review commands (dot-sourced by run-all.ps1; body wrapped
# to keep the caller's variables intact). A temp journey and solutions root; the real journey/ is never touched.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $coach = Join-Path $repo '.zed\lc-coach.ps1'
    . (Join-Path $repo '.zed\lc\journey.ps1')
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lcc-' + [guid]::NewGuid().ToString('N'))
    $journey = Join-Path $tmp 'journey'
    $sols = Join-Path $tmp 'leetcode-solves'
    New-Item -ItemType Directory -Force $journey, $sols | Out-Null
    $oldUf = $env:LC_USER_FILE
    $env:LC_USER_FILE = Join-Path $tmp 'no-user.txt'  # no username: a local pass never turns into failed
    function Invoke-Coach([string[]]$Cmd) {
        $out = powershell -NoProfile -ExecutionPolicy Bypass -File $coach @Cmd -JourneyRoot $journey -SolutionsRoot $sols 2>&1 | Out-String
        return @{ Out = $out.Trim(); Code = $LASTEXITCODE }
    }
    try {
        # A hint for a problem that was never run: the file exists, no events (journey.md has no row for it).
        [IO.File]::WriteAllText((Join-Path $sols 'two-sum.cpp'), 'int a;', $utf8)
        $h = Get-LcSrcHash (Join-Path $sols 'two-sum.cpp')
        $r = Invoke-Coach @('hint', '-Slug', 'two-sum', '-Now', '2026-10-18T10:00:00+05:30')
        Assert-Equal $r.Code 0 "hint exit code`n$($r.Out)"
        Assert-Equal $r.Out 'recorded hint: two-sum'
        $ev = @(Read-LcEvents $journey)
        Assert-Equal $ev.Count 1
        Assert-Equal "$($ev[0].event)|$($ev[0].slug)|$($ev[0].file)|$($ev[0].src_hash)|$($ev[0].ts)" "hint|two-sum|leetcode-solves/two-sum.cpp|$h|2026-10-18T10:00:00+05:30"

        # No solution file: still recorded, with an empty file and hash.
        $r = Invoke-Coach @('solution', '-Slug', 'ghost-problem', '-Now', '2026-10-18T10:01:00+05:30')
        Assert-Equal $r.Code 0 "solution without a file`n$($r.Out)"
        $g = @(Read-LcEvents $journey -Slug 'ghost-problem')[0]
        Assert-Equal "$($g.event)|$($g.file)|$($g.src_hash)" 'solution||'

        # review
        $r = Invoke-Coach @('review', '-Slug', 'two-sum', '-Score', '7', '-Label', 'Good', '-Pattern', 'Hash | Map \ y', '-Now', '2026-10-18T10:02:00+05:30')
        Assert-Equal $r.Code 0 "review exit code`n$($r.Out)"
        Assert-Equal $r.Out 'recorded review: two-sum'
        $rv = @(Read-LcEvents $journey -Slug 'two-sum' | Where-Object { $_.event -eq 'review' })[0]
        Assert-True ($rv.score -eq 7 -and $rv.label -eq 'Good') "review fields: $($rv | ConvertTo-Json -Compress)"
        Assert-True ($null -eq $rv.idea) 'review: idea is left out when not given'
        Assert-Equal $rv.pattern 'Hash | Map \ y'
        $r = Invoke-Coach @('review', '-Slug', 'two-sum', '-Score', '8', '-Label', 'Great', '-Pattern', 'Hash Map', '-Idea', 'Store each value''s index; look up target - x', '-Now', '2026-10-18T10:02:20+05:30')
        Assert-Equal $r.Code 0 "review -Idea exit code`n$($r.Out)"
        $rv = @(Read-LcEvents $journey -Slug 'two-sum' | Where-Object { $_.event -eq 'review' })[-1]
        Assert-Equal $rv.idea "Store each value's index; look up target - x"
        # Quotes and newlines (the command line can't carry them reliably): straight into the library.
        . (Join-Path $repo '.zed\lc\coach-events.ps1')
        $code = Invoke-LcCoachEvent @{ Command = 'review'; Slug = 'two-sum'; Score = 6; Label = 'fair'; Pattern = "say ""hi""`nthere"; JourneyRoot = $journey
            SolutionsRoot = $sols; Now = [datetime]'2026-10-18T10:02:30' } 6>&1 | Where-Object { $_ -is [int] }
        Assert-Equal $code 0 'library exit code'
        $rv = @(Read-LcEvents $journey -Slug 'two-sum' | Where-Object { $_.event -eq 'review' })[-1]
        Assert-Equal "$($rv.label)|$($rv.pattern)" 'Fair|say "hi" there'

        # Bad input: exit 1 and nothing written
        $before = (Read-LcEvents $journey).Count
        foreach ($bad in @(
                @('review', '-Slug', 'two-sum', '-Score', '11', '-Label', 'Good', '-Pattern', 'p'),
                @('review', '-Slug', 'two-sum', '-Score', '0', '-Label', 'Good', '-Pattern', 'p'),
                @('review', '-Slug', 'two-sum', '-Score', '5', '-Label', 'Okay', '-Pattern', 'p'),
                @('review', '-Slug', 'two-sum', '-Score', '5', '-Label', 'Good'),
                @('hint'),
                @('hint', '-Slug', '..\evil'))) {
            $r = Invoke-Coach $bad
            Assert-Equal $r.Code 1 "expected exit 1 for: $($bad -join ' ')`n$($r.Out)"
        }
        Assert-Equal (Read-LcEvents $journey).Count $before 'bad input wrote an event'

        # journey.md: a solution makes the row failed, and a | in the pattern never breaks a row
        Write-LcEvent -Root $journey -Event test_run -Slug 'two-sum' -File 'leetcode-solves/two-sum.cpp' -SrcHash $h -Ts '2026-10-18T09:00:00+05:30' -Data @{ compile_ok = $true }
        $r = Invoke-Coach @('solution', '-Slug', 'two-sum', '-Now', '2026-10-18T10:03:00+05:30')
        Assert-Equal $r.Code 0 "solution exit code`n$($r.Out)"
        $md = [IO.File]::ReadAllLines((Join-Path $journey 'journey.md'))
        Assert-Equal $md.Count 3 'header plus one row'
        Assert-Match $md[2] '\[two-sum\]\(https://leetcode\.com/problems/two-sum/\) \| failed \|'
        Assert-Equal (($md[2] -split '(?<!\\)\|').Count) 12 'the row keeps its 10 cells'

        # A time-based status follows the command's time: an old unsolved problem is failed on a rebuild
        Write-LcEvent -Root $journey -Event test_run -Slug 'old-one' -File 'leetcode-solves/old-one.cpp' -SrcHash $h -Ts '2026-10-01T09:00:00+05:30' -Data @{ compile_ok = $true }
        $r = Invoke-Coach @('hint', '-Slug', 'old-one', '-Now', '2026-10-18T10:04:00+05:30')
        Assert-Equal $r.Code 0 "hint old-one`n$($r.Out)"
        Assert-Match ([IO.File]::ReadAllText((Join-Path $journey 'journey.md'))) '\[old-one\]\(https://leetcode\.com/problems/old-one/\) \| failed \|'

        # -IdeaFile: double quotes and newlines reach the idea (a command-line -Idea drops the quotes)
        $if = Join-Path $tmp 'idea.txt'
        [IO.File]::WriteAllText($if, "Store `"target - x`" before`nchecking", $utf8)
        $r = Invoke-Coach @('review', '-Slug', 'two-sum', '-Score', '8', '-Label', 'Great', '-Pattern', 'Hash Map', '-IdeaFile', $if, '-Now', '2026-10-18T10:05:00+05:30')
        Assert-Equal $r.Code 0 "review -IdeaFile`n$($r.Out)"
        $rv = @(Read-LcEvents $journey -Slug 'two-sum' | Where-Object { $_.event -eq 'review' })[-1]
        Assert-Equal $rv.idea 'Store "target - x" before checking'

        # A harness append in progress (it holds the log open for writing): the event waits, then lands
        $ev = Join-Path $journey 'events.jsonl'
        $n = @(Read-LcEvents $journey).Count
        $hold = [IO.File]::Open($ev, 'Append', 'Write', 'Read')
        try {
            $si = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
            $si.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$coach`" hint -Slug two-sum -JourneyRoot `"$journey`" -SolutionsRoot `"$sols`""
            $si.UseShellExecute = $false; $si.CreateNoWindow = $true; $si.RedirectStandardOutput = $true
            $pr = [Diagnostics.Process]::Start($si)
            Start-Sleep -Milliseconds 2500
        } finally { $hold.Dispose() }
        $o = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
        Assert-Equal $pr.ExitCode 0 "hint while the log is busy`n$o"
        Assert-Equal @(Read-LcEvents $journey).Count ($n + 1) 'hint while the log is busy: event count'

        # A failed write prints an error and exits 1 (read-only log), and says nothing was recorded
        [IO.File]::SetAttributes($ev, 'ReadOnly')
        try {
            $r = Invoke-Coach @('hint', '-Slug', 'two-sum')
            Assert-Equal $r.Code 1 "hint on a read-only log`n$($r.Out)"
            Assert-Match $r.Out '^error: '; Assert-True ($r.Out -notmatch 'recorded') 'read-only log said recorded'
        } finally { [IO.File]::SetAttributes($ev, 'Normal') }
        Assert-Equal @(Read-LcEvents $journey).Count ($n + 1) 'read-only log: event count'
    }
    finally {
        $env:LC_USER_FILE = $oldUf
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
