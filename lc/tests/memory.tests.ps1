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

        # -TextFile: double quotes and several lines survive (a command-line -Text would lose the quotes)
        $tf = Join-Path $tmp 'read.md'
        [IO.File]::WriteAllText($tf, "# Week`n`nSaid `"off by one`" twice.`n", (New-Object Text.UTF8Encoding $false))
        $r = Invoke-Coach @('weekly', '-TextFile', $tf) '2026-10-28'
        Assert-Equal $r.Code 0 "memory: weekly -TextFile`n$($r.Out)"
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $local 'weekly\2026-10-26.md'))).Replace("`r", '') "# Week`n`nSaid `"off by one`" twice."

        # Parallel writers (an agent's parallel tool calls): every fact is kept
        Remove-Item -Recurse -Force -LiteralPath $local
        $procs = @(foreach ($i in 1..8) {
                $si = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
                $si.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$coach`" remember -Kind context -Text `"Parallel fact $i`" -JourneyRoot `"$j`" -Now 2026-10-18"
                $si.UseShellExecute = $false; $si.CreateNoWindow = $true; $si.RedirectStandardOutput = $true
                [Diagnostics.Process]::Start($si)
            })
        foreach ($pr in $procs) {
            $o = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
            Assert-Equal $pr.ExitCode 0 "memory: parallel remember`n$o"; Assert-Match $o '^saved m'
        }
        $texts = @(Read-LcMemory $local ([datetime]::Parse('2026-10-18')) | ForEach-Object { $_.text } | Sort-Object)
        Assert-Equal ($texts -join ',') ((1..8 | ForEach-Object { "Parallel fact $_" } | Sort-Object) -join ',') 'memory: parallel remember lost facts'

        # Same fact: case, spacing, hyphens between words and end punctuation merge; operators and kinds don't
        Remove-Item -Recurse -Force -LiteralPath $local
        $null = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Uses i <= n where i < n is needed')
        Assert-Match (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Uses i < n where i <= n is needed')).Out '^saved m'
        Assert-Match (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'uses i<=n where  i<n is needed.')).Out '^seen m'
        $null = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Overflow in a*b')
        Assert-Match (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Overflow in a+b')).Out '^saved m'
        $null = Invoke-Coach @('remember', '-Kind', 'strength', '-Text', 'Two pointers')
        $r = Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Two pointers', '-Until', '2026-12-31')
        Assert-Match $r.Out '^saved m'
        $tp = [regex]::Match($r.Out, 'saved (m[0-9a-f]{6})').Groups[1].Value
        Assert-Equal (Get-Fact $tp '2026-10-18')['until'] '2026-12-31' 'memory: goal kept apart from the strength'
        Assert-Equal @(Read-LcMemory $local ([datetime]::Parse('2026-10-18'))).Count 6 'memory: same-fact matching'

        # Seen again with -Until and -Replaces: the new date is kept, and -Replaces still resolves
        Remove-Item -Recurse -Force -LiteralPath $local
        $g = (Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Solve 10 mediums', '-Until', '2026-10-05') '2026-10-01').Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        $r = Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Solve 10 mediums', '-Until', '2026-11-30', '-Replaces', $g) '2026-10-02'
        Assert-Match $r.Out "^seen $g"
        $f = Get-Fact $g '2026-10-06'
        Assert-Equal "$($f.status)|$($f['until'])" 'active|2026-11-30' 'memory: seen with -Until'
        $old = (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Old wording of a habit')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        $new = (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Skips the empty input')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        Assert-Match (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'skips the empty input', '-Replaces', $old)).Out "^seen $new"
        Assert-Equal (Get-Fact $old '2026-10-18').status 'resolved' 'memory: seen with -Replaces'

        # Edit counts as seen: an old habit doesn't age straight back
        Remove-Item -Recurse -Force -LiteralPath $local
        $h = (Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Forgets empty arrays') '2026-09-01').Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        Assert-Equal (Get-Fact $h '2026-09-20').status 'improving'
        Assert-Equal (Invoke-Coach @('edit', '-Id', $h, '-Text', 'Forgets to handle empty arrays') '2026-09-20').Code 0
        Assert-Equal (Get-Fact $h '2026-09-21').status 'active' 'memory: edit then ageing'

        # The user's own remember brings a dismissed fact back; the coach's doesn't
        $d = (Invoke-Coach @('remember', '-Kind', 'preference', '-Text', 'Wants hints in Hindi')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        $null = Invoke-Coach @('forget', '-Id', $d)
        Assert-Match (Invoke-Coach @('remember', '-Kind', 'preference', '-Text', 'Wants hints in Hindi')).Out "dismissed before: $d"
        $r = Invoke-Coach @('remember', '-Kind', 'preference', '-Text', 'wants hints in Hindi.', '-Source', 'user', '-Evidence', 'two-sum:chat')
        Assert-Equal $r.Code 0; Assert-Match $r.Out "^saved $d"
        $f = Get-Fact $d '2026-10-18'
        Assert-Equal "$($f.status)|$($f.source)|$($f.text)|$(@($f.evidence).Count)" 'active|user|wants hints in Hindi.|1' 'memory: user remember of a dismissed fact'

        # -Until must be a real date
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Do 3 hards', '-Until', '2026-13-45')).Code 1 'memory: month 13'
        Assert-Equal (Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'Do 3 hards', '-Until', '2026-02-30')).Code 1 'memory: Feb 30'

        # Lines that aren't facts (cut short, unknown kind) survive every save unchanged
        $p = Join-Path $local 'memory.jsonl'
        $bad1 = '{"id":"mcut'; $bad2 = '{"id":"m000001","kind":"mood","text":"Hand-edited","status":"active"}'
        [IO.File]::AppendAllText($p, "$bad1`n$bad2`n", (New-LcUtf8))
        $null = Invoke-Coach @('remember', '-Kind', 'style', '-Text', 'Kept lines test')
        $null = Invoke-Coach @('resolve', '-Id', $h)
        $null = Read-LcMemory $local ([datetime]::Parse('2027-01-01'))  # ages, so it saves
        $all = @([IO.File]::ReadAllLines($p))
        Assert-True (($all -contains $bad1) -and ($all -contains $bad2)) "memory: kept lines lost`n$($all -join "`n")"

        # -NoSave ages in memory but never writes
        $ng = (Invoke-Coach @('remember', '-Kind', 'goal', '-Text', 'NoSave goal', '-Until', '2027-06-01')).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
        $before = [IO.File]::ReadAllText($p)
        $f = @(Read-LcMemory $local ([datetime]::Parse('2028-01-01')) -NoSave | Where-Object { $_.id -eq $ng })[0]
        Assert-Equal $f.status 'resolved' 'memory: -NoSave ages'
        Assert-Equal ([IO.File]::ReadAllText($p)) $before 'memory: -NoSave wrote'

        # A failed write prints an error and exits 1 (read-only store, read-only weekly file)
        [IO.File]::SetAttributes($p, 'ReadOnly')
        try {
            $r = Invoke-Coach @('remember', '-Kind', 'habit', '-Text', 'Never saved')
            Assert-Equal $r.Code 1 "memory: remember on a read-only store`n$($r.Out)"
            Assert-Match $r.Out '^error: '; Assert-True ($r.Out -notmatch 'saved') 'memory: read-only store said saved'
            Assert-Equal (Invoke-Coach @('forget', '-Id', $h)).Code 1 'memory: forget on a read-only store'
        } finally { [IO.File]::SetAttributes($p, 'Normal') }
        $null = Invoke-Coach @('weekly', '-Text', '# w') '2026-10-21'
        $wf = Join-Path $local 'weekly\2026-10-19.md'
        [IO.File]::SetAttributes($wf, 'ReadOnly')
        try { Assert-Equal (Invoke-Coach @('weekly', '-Text', '# w3') '2026-10-21').Code 1 'memory: weekly on a read-only file' }
        finally { [IO.File]::SetAttributes($wf, 'Normal') }
        Assert-Equal (Invoke-Coach @('memory', '-TextFile', (Join-Path $tmp 'missing.txt'))).Code 1 'memory: missing -TextFile'

        # -TextFile: a BOM picks the encoding; no BOM is UTF-8 when valid, else the ANSI code page
        $odd2 = 'Off by one ' + [char]0x2014 + ' na' + [char]0xEF + 've loop'
        $ansi = [Text.Encoding]::Default
        foreach ($enc in @((New-Object Text.UTF8Encoding $false), (New-Object Text.UTF8Encoding $true), [Text.Encoding]::Unicode, $ansi)) {
            Remove-Item -Recurse -Force -LiteralPath $local
            $tf = Join-Path $tmp 'fact.txt'
            [IO.File]::WriteAllText($tf, $odd2, $enc)
            $id2 = (Invoke-Coach @('remember', '-Kind', 'habit', '-TextFile', $tf)).Out -replace '(?s).*saved (m[0-9a-f]{6}).*', '$1'
            $want = if ($enc -eq $ansi) { $ansi.GetString($ansi.GetBytes($odd2)) } else { $odd2 }
            Assert-Equal (Get-Fact $id2 '2026-10-18').text $want "memory: -TextFile in $($enc.EncodingName)"
        }

        # Stamps and the weekly name don't follow the culture (fi-FI writes dots for colons, th-TH a Buddhist year)
        $at = New-Object DateTime 2026, 10, 21, 10, 0, 0
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        foreach ($c in @('fi-FI', 'th-TH')) {
            Remove-Item -Recurse -Force -LiteralPath $local
            [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo $c
            try {
                $null = Invoke-LcCoachMemory @{ Command = 'remember'; Kind = 'habit'; Text = 'Culture fact'; Source = 'coach'; JourneyRoot = $j; Now = $at } 6>&1
                $null = Invoke-LcCoachMemory @{ Command = 'weekly'; Text = '# c'; JourneyRoot = $j; Now = $at } 6>&1
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
            Assert-Match ([IO.File]::ReadAllText($p)) '"created":"2026-10-21T10:00:00[+-]\d\d:\d\d"'
            Assert-True ([IO.File]::Exists((Join-Path $local 'weekly\2026-10-19.md'))) "memory: weekly name under $c"
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
