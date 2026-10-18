# Coach memory (.zed/lc/memory.ps1) and the memory commands of .zed/lc-coach.ps1, with temp roots only.
# Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $coach = Join-Path $repo '.zed\lc-coach.ps1'
    . (Join-Path $repo '.zed\lc\journey.ps1')
    . (Join-Path $repo '.zed\lc\memory.ps1')
    $tmp = Join-Path $env:TEMP 'lc memory test'  # the space is deliberate
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $j = Join-Path $tmp 'journey'
    $local = Join-Path $j 'local'

    function Invoke-Coach([string[]]$Args2, [string]$At = '2026-10-18') {
        $o = powershell -NoProfile -ExecutionPolicy Bypass -File $coach @Args2 -JourneyRoot $j -Now $At 2>&1 | Out-String
        return @{ Out = $o; Code = $LASTEXITCODE }
    }
    function Get-Fact([string]$Id, [string]$At) { return @(Read-LcMemory $local ([datetime]::Parse($At)) | Where-Object { $_.id -eq $Id })[0] }

    try {
        # Remember, then the same text in other words: seen, with more evidence
        $r = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Loop bound off by one', '-Evidence', 'two-sum:20261018-100000-abc.cpp')
        Assert-Equal $r.Code 0 'memory: remember exit'
        Assert-Match $r.Out '(?m)^saved m[0-9a-f]{6}\s*$'
        $id = [regex]::Match($r.Out, 'saved (m[0-9a-f]{6})').Groups[1].Value
        $r = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'loop bound, off-by-one', '-Evidence', 'rotate-array:chat')
        Assert-Match $r.Out "(?m)^seen $id\s*$"
        $f = Get-Fact $id '2026-10-18'
        Assert-Equal @($f.evidence).Count 2 'memory: evidence after seen'
        Assert-Equal $f.evidence[1].slug 'rotate-array'
        Assert-Equal @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count 1 'memory: seen adds no fact'
        # Evidence given as one comma-separated value
        $r = Invoke-Coach @('remember', '-Kind', 'style', '-Text', 'Short helper lambdas', '-Evidence', 'a:1,b:2')
        $sid = [regex]::Match($r.Out, 'saved (m[0-9a-f]{6})').Groups[1].Value
        Assert-Equal @((Get-Fact $sid '2026-10-18').evidence).Count 2 'memory: comma evidence'

        # memory prints live facts
        $r = Invoke-Coach @('memory')
        Assert-Match $r.Out "habit:\r?\n- \[$id\] Loop bound off by one"
        Assert-Match $r.Out 'style:'

        # Edit: user source, active, until cleared
        $r = Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Finish graphs by Friday', '-Until', '2026-10-25')
        $gid = [regex]::Match($r.Out, 'saved (m[0-9a-f]{6})').Groups[1].Value
        Assert-Equal (Get-Fact $gid '2026-10-18')['until'] '2026-10-25'
        $r = Invoke-Coach @('edit', '-Id', $gid, '-Text', 'Finish graphs soon')
        Assert-Equal $r.Code 0
        $f = Get-Fact $gid '2026-10-18'
        Assert-Equal $f.source 'user'; Assert-Equal $f.text 'Finish graphs soon'
        Assert-True (-not $f.Contains('until')) 'memory: edit clears until'

        # Replaces resolves the old fact
        $r = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Forgets to reset the counter', '-Replaces', $id)
        Assert-Match $r.Out '^saved m'
        Assert-Equal (Get-Fact $id '2026-10-18').status 'resolved'
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'x', '-Replaces', 'mffffff')).Code 1 'memory: unknown replaces'

        # Forget: dismissed for good
        $r = Invoke-Coach @('forget', '-Id', $sid)
        Assert-Match $r.Out "forgot $sid"
        $f = Get-Fact $sid '2026-10-18'
        Assert-Equal $f.status 'dismissed'; Assert-Equal @($f.evidence).Count 0
        $before = @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count
        $r = Invoke-Coach @('remember', '-Kind', 'style', '-Text', 'short helper lambdas')
        Assert-Equal $r.Code 0; Assert-Match $r.Out 'dismissed before'
        Assert-Equal @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count $before 'memory: dismissed text re-added'
        Assert-Equal (Invoke-Coach @('forget', '-Id', 'mffffff')).Code 1 'memory: unknown id'

        # resolve
        $r = Invoke-Coach @('remember', '-Kind', 'preference', '-Text', 'Hints before code')
        $pid2 = [regex]::Match($r.Out, 'saved (m[0-9a-f]{6})').Groups[1].Value
        Assert-Equal (Invoke-Coach @('resolve', '-Id', $pid2)).Code 0
        Assert-Equal (Get-Fact $pid2 '2026-10-18').status 'resolved'

        # Bad input writes nothing and exits 1
        $n = @(Get-Content -LiteralPath (Join-Path $local 'memory.jsonl')).Count
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'mood', '-Text', 'sad')).Code 1 'memory: bad kind'
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', ('x' * 301))).Code 1 'memory: long text'
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'ok', '-Until', 'soon')).Code 1 'memory: bad until'
        Assert-Equal @(Get-Content -LiteralPath (Join-Path $local 'memory.jsonl')).Count $n 'memory: bad input wrote'

        # Ageing: a habit seen 2026-10-18 and a goal until 2026-10-20 (fresh store)
        Remove-Item -Recurse -Force -LiteralPath $local
        $h = (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Ages out')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        $g = (Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Short goal', '-Until', '2026-10-20')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        Assert-Equal (Get-Fact $g '2026-10-20').status 'active' 'until day itself'
        Assert-Equal (Get-Fact $g '2026-10-21').status 'resolved' 'goal past until'
        Assert-Equal (Get-Fact $h '2026-11-01').status 'active' '14 days is not over 14'
        Assert-Equal (Get-Fact $h '2026-11-03').status 'improving' 'habit 16 days'
        Assert-Match ((Format-LcMemory (Read-LcMemory $local ([datetime]::Parse('2026-11-03')))) -join "`n") 'Ages out \(improving\)'
        Assert-Equal (Get-Fact $h '2026-11-16').status 'resolved' 'habit 29 days'
        Assert-True (-not (Format-LcMemory (Read-LcMemory $local ([datetime]::Parse('2026-11-16'))))) 'memory: resolved facts listed'
        # Seen again brings an improving habit back to active
        Remove-Item -Recurse -Force -LiteralPath $local
        $h = (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Comes back')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        Assert-Equal (Get-Fact $h '2026-11-03').status 'improving'
        $null = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Comes back') '2026-11-03'
        Assert-Equal (Get-Fact $h '2026-11-03').status 'active' 'seen resets improving'

        # A malformed line is skipped by every command
        Remove-Item -Recurse -Force -LiteralPath $local
        $null = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'First fact')
        $p = Join-Path $local 'memory.jsonl'
        $lines = @(Get-Content -LiteralPath $p)
        [IO.File]::WriteAllText($p, ($lines[0] + "`n{bad`n" + ($lines[0].Replace('First fact', 'Second fact') -replace '"id":"m[0-9a-f]{6}"', '"id":"mabcdef"') + "`n"), (New-LcUtf8))
        Assert-Equal @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count 2 'memory: malformed line'
        Assert-Equal (Invoke-Coach @('memory')).Code 0
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'style', '-Text', 'Third fact')).Code 0
        Assert-Equal @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count 3 'memory: remember after malformed line'

        # Quotes, backslashes, | and newlines survive the round trip (the newline becomes a space)
        $odd = "say `"hi`" and C:\path | pipe`nnext line"
        $res = Add-LcMemoryFact @() 'context' $odd @('s:a "q"') 'user' '' '' ([datetime]::Parse('2026-10-18'))
        Save-LcMemory $local $res.Facts
        $back = @(Read-LcMemory $local ([datetime]::Parse('2026-10-18')))
        Assert-Equal $back[0].text 'say "hi" and C:\path | pipe next line'
        Assert-Equal $back[0].evidence[0].ref 'a "q"'
        Assert-Equal @(Get-Content -LiteralPath $p).Count 1 'memory: one line per fact'

        # read: the latest solved hash goes to coach-state.json; no solved event exits 1
        Assert-Equal (Invoke-Coach @('read', '-Slug', 'two-sum')).Code 1 'memory: read without solved'
        Write-LcEvent -Root $j -Event solved -Slug 'two-sum' -File 'x.cpp' -SrcHash 'aaaaaaaaaaaa'
        Write-LcEvent -Root $j -Event solved -Slug 'two-sum' -File 'x.cpp' -SrcHash 'bbbbbbbbbbbb'
        Assert-Equal @(Get-LcUnreadSolves $j).Count 1
        $r = Invoke-Coach @('read', '-Slug', 'two-sum')
        Assert-Equal $r.Code 0; Assert-Match $r.Out 'recorded read: two-sum'
        Assert-Match ([IO.File]::ReadAllText((Join-Path $local 'coach-state.json'))) '"two-sum":"bbbbbbbbbbbb"'
        Assert-Equal @(Get-LcUnreadSolves $j).Count 0

        # weekly: a Wednesday goes to that week's Monday; saving again overwrites
        $r = Invoke-Coach @('weekly', '-Text', '# w') '2026-10-21'
        Assert-Equal $r.Code 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $local 'weekly\2026-10-19.md'))) '# w'
        $null = Invoke-Coach @('weekly', '-Text', '# w2') '2026-10-25'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $local 'weekly\2026-10-19.md'))) '# w2'
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
