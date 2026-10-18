# Tests for .zed/lc/journey.ps1 (dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact).
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repo '.zed\lc\journey.ps1')
    . (Join-Path $repo '.zed\lc\fetch.ps1')
    # The fixtures below are dated 2026-10-17/18: rows are built "on" 2026-10-19 so the 7-day failed rule stays out of the way.
    $PSDefaultParameterValues['Update-LcJourneyFile:Now'] = [datetime]'2026-10-19'

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lcj-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $root = Join-Path $tmp 'journey'
        $src = Join-Path $tmp 'a.cpp'
        [IO.File]::WriteAllText($src, 'int a;')
        $h = Get-LcSrcHash $src
        Assert-Match $h '^[0-9a-f]{12}$'

        # attempts / solved-before
        $s = 'rotate-array'; $f = 'rotate-array.cpp'
        Write-LcEvent -Root $root -Event test_run -Slug $s -File $f -SrcHash $h -Ts '2026-10-17T10:00:00+05:30' -Data @{ compile_ok = $true; passed = 1; failed = 0 }
        Write-LcEvent -Root $root -Event test_run -Slug $s -File $f -SrcHash $h -Ts '2026-10-17T10:05:00+05:30' -Data @{ compile_ok = $true; passed = 1; failed = 0 }
        Assert-Equal (Get-LcAttempts (Read-LcEvents $root) $s) 2
        Write-LcEvent -Root $root -Event solved -Slug $s -File $f -SrcHash $h -Ts '2026-10-17T10:06:00+05:30' -Data @{ attempts = 2; max_ms = 0.02 }
        Assert-Equal (Get-LcAttempts (Read-LcEvents $root) $s) 0
        Assert-True (Test-LcSolvedBefore (Read-LcEvents $root) $s $h)
        Assert-True (-not (Test-LcSolvedBefore (Read-LcEvents $root) $s 'abcdef012345'))

        # event line shape
        $lines = [IO.File]::ReadAllLines((Join-Path $root 'events.jsonl'))
        Assert-Equal $lines.Count 3
        foreach ($l in $lines) {
            $o = $l | ConvertFrom-Json
            foreach ($k in 'ts', 'event', 'slug', 'file', 'src_hash') { Assert-True ($null -ne $o.$k) "missing $k" }
        }
        Assert-True ($lines[0].StartsWith('{"ts":"2026-10-17T10:00:00+05:30","event":"test_run","slug":"rotate-array","file":"rotate-array.cpp","src_hash":"'))
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'events.jsonl'))
        Assert-True ($bytes[0] -eq 0x7B) 'no BOM'

        # -PassThru gives the event as Read-LcEvents would return it
        $pr = Join-Path $tmp 'passthru'
        $o = Write-LcEvent -Root $pr -Event note -Slug $s -File $f -SrcHash $h -Ts '2026-10-17T10:07:00+05:30' -Data @{ text = 'x' } -PassThru
        Assert-Equal "$($o.ts)|$($o.event)|$($o.slug)|$($o.file)|$($o.src_hash)|$($o.text)" "2026-10-17T10:07:00+05:30|note|$s|$f|$h|x"
        Assert-Equal @(Read-LcEvents $pr).Count 1

        # fetch event fields, in order, from a LeetCode question object
        $fq = '{"questionFrontendId":"1","title":"Two Sum","difficulty":"Easy","isPaidOnly":false,"topicTags":[{"name":"Array"},{"name":"Hash Table"}]}' | ConvertFrom-Json
        $fr = Join-Path $tmp 'fetchroot'
        Write-LcEvent -Root $fr -Event fetch -Slug 'two-sum' -File 'two-sum.cpp' -SrcHash $h -Ts 't' -Data (Get-LcFetchEventData $fq)
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $fr 'events.jsonl'))) ('{"ts":"t","event":"fetch","slug":"two-sum","file":"two-sum.cpp","src_hash":"' + $h +
            '","ok":true,"id":"1","title":"Two Sum","difficulty":"Easy","tags":["Array","Hash Table"],"paid_only":false}' + "`n")

        # R13: a malformed line (e.g. half-written by a crash) is skipped, not fatal
        $ev = Join-Path $root 'events.jsonl'
        $good = [IO.File]::ReadAllText($ev)
        [IO.File]::AppendAllText($ev, "not json`n" + '{"ts":"t","event":"note","slug":"x","file":"f","src_hash":"h","text":"ok"}' +
            "`n" + '{"ts":"2026-10-17T10:0', (New-LcUtf8))
        $read = @(Read-LcEvents $root)
        Assert-Equal $read.Count 4 'malformed lines skipped'
        Assert-Equal $read[2].event 'solved'
        Assert-Equal $read[3].text 'ok'
        Write-LcEvent -Root $root -Event note -Slug 'x' -File 'f' -SrcHash 'h' -Data @{ text = 'after' }
        $read = @(Read-LcEvents $root)
        Assert-Equal $read.Count 5 'an event after a cut-short line keeps its own line'
        Assert-Equal $read[4].text 'after'
        Assert-Equal (Get-LcAttempts $read $s) 0
        [IO.File]::WriteAllText($ev, $good, (New-LcUtf8))

        # snapshots
        $sr = Join-Path $tmp 'snaproot'
        $p1 = Save-LcSnapshot -Root $sr -Slug $s -SrcPath $src -SrcHash $h -Ts '2026-10-17T10:00:00+05:30'
        Assert-Equal (Split-Path -Leaf $p1) "20261017-100000-$h.cpp"
        Assert-Equal (Limit-LcText ('x' * 250)).Length 200
        Assert-True ((Limit-LcText ('x' * 250)).EndsWith('...')) 'a cut value ends in ...'
        Assert-Equal (Limit-LcText 'abc') 'abc'
        Assert-Equal (Limit-LcText ('y' * 200)) ('y' * 200) 'exactly 200 is kept'
        Assert-True ($null -eq (Save-LcSnapshot -Root $sr -Slug $s -SrcPath $src -SrcHash $h -Ts '2026-10-17T10:01:00+05:30'))
        Assert-Equal @(Get-ChildItem (Join-Path $sr "snapshots\$s") -Filter *.cpp).Count 1
        $p2 = Save-LcSnapshot -Root $sr -Slug $s -SrcPath $src -SrcHash 'ffffffffffff' -Ts '2026-10-17T10:02:00+05:30'
        Assert-True ($null -ne $p2)
        Assert-Equal @(Get-ChildItem (Join-Path $sr "snapshots\$s") -Filter *.cpp).Count 2

        # journey.md
        $jr = Join-Path $tmp 'jroot'
        $e = @{ Root = $jr; Slug = $s; File = $f; SrcHash = $h }
        Write-LcEvent @e -Event fetch -Ts '2026-10-17T09:59:00+05:30' -Data @{ ok = $true; id = 189; title = 'Rotate Array'; difficulty = 'Medium'; tags = @('Array', 'Math', 'Two Pointers'); paid_only = $false }
        foreach ($t in '10:00', '10:05', '10:06') { Write-LcEvent @e -Event test_run -Ts "2026-10-17T${t}:00+05:30" -Data @{ compile_ok = $true } }
        Write-LcEvent @e -Event solved -Ts '2026-10-17T10:06:30+05:30' -Data @{ attempts = 3; max_ms = 0.02 }
        Write-LcEvent @e -Event analyze_run -Ts '2026-10-17T10:10:00+05:30' -Data @{ complexity = 'O(n)' }
        # A failed analyze (no complexity) keeps the last one.
        Write-LcEvent @e -Event analyze_run -Ts '2026-10-17T10:10:30+05:30' -Data ([ordered]@{ status = 'crash'; complexity = $null })
        Write-LcEvent @e -Event note -Ts '2026-10-17T10:11:00+05:30' -Data @{ text = 'reverse trick' }
        Write-LcEvent -Root $jr -Event test_run -Slug 'two-sum' -File 'two-sum.cpp' -SrcHash $h -Ts '2026-10-18T10:00:00+05:30' -Data @{ compile_ok = $true }
        Update-LcJourneyFile -Root $jr -MetaDir (Join-Path $tmp 'nometa')
        $md = [IO.File]::ReadAllLines((Join-Path $jr 'journey.md'))
        Assert-Equal $md[0] '| Date | # | Problem | Status | Difficulty | Tags | Complexity | Max time | Attempts | Note |'
        Assert-Equal $md[2] '| 2026-10-17 | 189 | [Rotate Array](https://leetcode.com/problems/rotate-array/) | passed locally | Medium | Array, Math, Two Pointers | O(n) | 0.02 ms | 3 | reverse trick |'
        Assert-Equal $md[3] '| - |  | [two-sum](https://leetcode.com/problems/two-sum/) | attempted |  |  |  |  | 1 |  |'
        Assert-Equal $md.Count 4
        # Passing the events in gives the same file.
        $mdText = [IO.File]::ReadAllText((Join-Path $jr 'journey.md'))
        Remove-Item (Join-Path $jr 'journey.md')
        Update-LcJourneyFile -Root $jr -MetaDir (Join-Path $tmp 'nometa') -Events @(Read-LcEvents $jr)
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $jr 'journey.md'))) $mdText

        # -Slug reads only that slug's events
        Assert-Equal @(Read-LcEvents $jr -Slug $s).Count 8
        Assert-Equal @(Read-LcEvents $jr -Slug 'two-sum').Count 1
        Assert-Equal @(Read-LcEvents $jr -Slug 'two').Count 0

        # -Slug rebuilds one row in place (or appends a new slug) and matches a full regeneration
        $nm = Join-Path $tmp 'nometa'
        Write-LcEvent -Root $jr -Event note -Slug 'two-sum' -File 'two-sum.cpp' -SrcHash $h -Ts '2026-10-18T10:01:00+05:30' -Data @{ text = 'a | b' }
        Update-LcJourneyFile -Root $jr -MetaDir $nm -Slug 'two-sum' -Events @(Read-LcEvents $jr -Slug 'two-sum')
        Write-LcEvent -Root $jr -Event test_run -Slug 'climbing-stairs' -File 'climbing-stairs.cpp' -SrcHash $h -Ts '2026-10-18T10:02:00+05:30' -Data @{ compile_ok = $true }
        Update-LcJourneyFile -Root $jr -MetaDir $nm -Slug 'climbing-stairs'
        $inc = [IO.File]::ReadAllLines((Join-Path $jr 'journey.md'))
        Assert-Equal $inc.Count 5
        Assert-Equal $inc[2] $md[2]
        Assert-Equal $inc[3] '| - |  | [two-sum](https://leetcode.com/problems/two-sum/) | attempted |  |  |  |  | 1 | a \| b |'
        Assert-Equal $inc[4] '| - |  | [climbing-stairs](https://leetcode.com/problems/climbing-stairs/) | attempted |  |  |  |  | 1 |  |'
        Update-LcJourneyFile -Root $jr -MetaDir $nm
        Assert-Equal (([IO.File]::ReadAllLines((Join-Path $jr 'journey.md'))) -join "`n") ($inc -join "`n")
        # Without a journey.md, -Slug regenerates every row.
        Remove-Item (Join-Path $jr 'journey.md')
        Update-LcJourneyFile -Root $jr -MetaDir $nm -Slug 'two-sum' -Events @(Read-LcEvents $jr -Slug 'two-sum')
        Assert-Equal (([IO.File]::ReadAllLines((Join-Path $jr 'journey.md'))) -join "`n") ($inc -join "`n")

        # meta cache fallback
        $mdir = Join-Path $tmp 'meta'; New-Item -ItemType Directory $mdir | Out-Null
        [IO.File]::WriteAllText((Join-Path $mdir 'two-sum.json'), '{"questionFrontendId":"1","title":"Two Sum","difficulty":"Easy","topicTags":[{"name":"Array"},{"name":"Hash Table"}]}')
        Update-LcJourneyFile -Root $jr -MetaDir $mdir
        $cachedRow = '| - | 1 | [Two Sum](https://leetcode.com/problems/two-sum/) | attempted | Easy | Array, Hash Table |  |  | 1 | a \| b |'
        Assert-Equal ([IO.File]::ReadAllLines((Join-Path $jr 'journey.md')))[3] $cachedRow
        # Without -MetaDir the cache is <Root>/problems.
        Update-LcJourneyFile -Root $jr
        Assert-Equal ([IO.File]::ReadAllLines((Join-Path $jr 'journey.md')))[3] $inc[3] 'journey: no problems dir, no cached row'
        New-Item -ItemType Directory (Join-Path $jr 'problems') | Out-Null
        Copy-Item (Join-Path $mdir 'two-sum.json') (Join-Path $jr 'problems')
        Update-LcJourneyFile -Root $jr
        Assert-Equal ([IO.File]::ReadAllLines((Join-Path $jr 'journey.md')))[3] $cachedRow 'journey: default MetaDir is <Root>/problems'

        # LeetCode accepts: which ones become accepted events
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $ar = Join-Path $tmp 'acroot'
        $mz = 'move-zeroes'
        $t0 = [DateTimeOffset]::Parse('2026-10-17T10:00:00+05:30', $inv).ToUnixTimeSeconds()
        Write-LcEvent -Root $ar -Event test_run -Slug $mz -File 'old.cpp' -SrcHash 'aaaaaaaaaaaa' -Ts '2026-10-17T10:00:00+05:30' -Data @{ compile_ok = $true }
        Write-LcEvent -Root $ar -Event solved -Slug $mz -File "leetcode-solves/$mz.cpp" -SrcHash 'bbbbbbbbbbbb' -Ts '2026-10-17T10:01:00+05:30' -Data @{ attempts = 1; max_ms = 0.01 }
        $list = @(@{ Slug = $mz; Time = $t0 + 120 }, @{ Slug = $mz; Time = $t0 - 1 }, @{ Slug = 'unknown-slug'; Time = $t0 + 60 }, @{ Slug = $mz; Time = $t0 })
        $new = @(Add-LcAcceptedEvents -Root $ar -List $list)
        Assert-Equal $new.Count 2 'accepts: one before the first event and one of an unknown slug are skipped'
        $acc = @(Read-LcEvents $ar | Where-Object { $_.event -eq 'accepted' })
        Assert-Equal $acc.Count 2
        Assert-Equal (@($acc | ForEach-Object { [DateTimeOffset]::Parse($_.submitted_at, $inv).ToUnixTimeSeconds() }) -join ',') "$t0,$($t0 + 120)"
        foreach ($a in $acc) {
            Assert-Equal "$($a.slug)|$($a.file)|$($a.src_hash)" "$mz|leetcode-solves/$mz.cpp|bbbbbbbbbbbb" 'accepted: file and src_hash from the latest event'
            Assert-Match $a.submitted_at '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$'
            Assert-Match $a.ts '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$'
        }
        Assert-Equal @(Read-LcEvents $ar -Slug 'unknown-slug').Count 0
        Assert-Equal @(Add-LcAcceptedEvents -Root $ar -List $list).Count 0 'accepts: duplicates are skipped'
        Assert-Equal @(Read-LcEvents $ar).Count 4
        Assert-Equal @(Add-LcAcceptedEvents -Root $ar -List @()).Count 0

        # journey.md Status: accepted, else passed locally (solved), else attempted
        Write-LcEvent -Root $ar -Event test_run -Slug 'tried-only' -File 'tried-only.cpp' -SrcHash 'cccccccccccc' -Data @{ compile_ok = $true }
        Write-LcEvent -Root $ar -Event test_run -Slug 'local-only' -File 'local-only.cpp' -SrcHash 'dddddddddddd' -Data @{ compile_ok = $true }
        Write-LcEvent -Root $ar -Event solved -Slug 'local-only' -File 'local-only.cpp' -SrcHash 'dddddddddddd' -Data @{ attempts = 1; max_ms = 0.01 }
        Update-LcJourneyFile -Root $ar -MetaDir $nm
        $st = @([IO.File]::ReadAllLines((Join-Path $ar 'journey.md')) | Select-Object -Skip 2 | ForEach-Object { if ($_ -match '/\) \| ([a-z ]+) \| ') { $Matches[1] } })
        Assert-Equal ($st -join ',') 'accepted,attempted,passed locally'

        # Status order (spec): rows for one slug starting 2026-10-01, built on a given day
        $sr2 = Join-Path $tmp 'statusroot'
        $statusOf = {
            param([string[]]$Kinds, [string]$Now = '2026-10-03', [bool]$Tracked = $false)
            $slug = 'st-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $i = 0
            foreach ($k in $Kinds) {
                $i++
                $data = @{}
                if ($k -eq 'test_run') { $data = @{ compile_ok = $true } }
                if ($k -eq 'solved') { $data = @{ attempts = 1; max_ms = 0.01 } }
                if ($k -eq 'accepted') { $data = @{ submitted_at = '2026-10-01T10:30:00+05:30' } }
                Write-LcEvent -Root $sr2 -Event $k -Slug $slug -File "$slug.cpp" -SrcHash $h -Ts ('2026-10-01T10:{0:00}:00+05:30' -f ($i - 1)) -Data $data
            }
            $st = (Get-LcJourneyState @(Read-LcEvents $sr2 -Slug $slug))[$slug]
            $row = Format-LcJourneyRow $slug $st $nm $Tracked ([datetime]$Now)
            Assert-True ($row -match '/\) \| ([a-z ]+) \| ') "no status in: $row"
            Assert-Equal (Get-LcProblemStatus $st $Tracked ([datetime]$Now)) $Matches[1] 'Format-LcJourneyRow uses Get-LcProblemStatus'
            return $Matches[1]
        }
        Assert-Equal (& $statusOf @('test_run')) 'attempted'
        Assert-Equal (& $statusOf @('test_run') '2026-10-09') 'failed'
        Assert-Equal (& $statusOf @('test_run') '2026-10-08') 'attempted' '7 days not yet over'
        Assert-Equal (& $statusOf @('test_run', 'solved') '2026-10-09' $false) 'passed locally' 'no username: a local pass never fails'
        Assert-Equal (& $statusOf @('test_run', 'solved') '2026-10-09' $true) 'failed'
        Assert-Equal (& $statusOf @('test_run', 'solved') '2026-10-03' $true) 'passed locally'
        Assert-Equal (& $statusOf @('test_run', 'hint', 'accepted')) 'accepted with hints'
        Assert-Equal (& $statusOf @('test_run', 'accepted', 'hint')) 'accepted'
        Assert-Equal (& $statusOf @('test_run', 'solution', 'accepted')) 'failed'
        Assert-Equal (& $statusOf @('test_run', 'solved', 'accepted') '2026-10-20' $true) 'accepted' 'an accept beats the 7-day rule'

        # Get-LcUserFile / Test-LcAcceptsTracked
        $oldUf = $env:LC_USER_FILE
        try {
            $env:LC_USER_FILE = Join-Path $tmp 'u1.txt'
            Assert-Equal (Get-LcUserFile) (Join-Path $tmp 'u1.txt')
            Assert-True (-not (Test-LcAcceptsTracked (Get-LcUserFile))) 'missing file: not tracked'
            [IO.File]::WriteAllText($env:LC_USER_FILE, " `r`n")
            Assert-True (-not (Test-LcAcceptsTracked (Get-LcUserFile))) 'blank file: not tracked'
            [IO.File]::WriteAllText($env:LC_USER_FILE, "someone`n")
            Assert-True (Test-LcAcceptsTracked (Get-LcUserFile)) 'a name: tracked'
            $env:LC_USER_FILE = ''
            Assert-Match (Get-LcUserFile) '[\\/]\.zed[\\/]leetcode-user\.txt$'
        } finally { $env:LC_USER_FILE = $oldUf }

        # Start-LcAcceptedFetch: no username, no request; a response file stands in for the network
        $resp = Join-Path $tmp 'resp.json'
        [IO.File]::WriteAllText($resp, '{"data":{"recentAcSubmissionList":[{"titleSlug":"move-zeroes","timestamp":"1792324222"},{"titleSlug":"x","timestamp":"bad"}]}}')
        $uf = Join-Path $tmp 'user.txt'
        Assert-True ($null -eq (Start-LcAcceptedFetch -UserFile $uf -ResponsePath $resp)) 'accepts: missing username file, no request'
        [IO.File]::WriteAllText($uf, "  `r`n")
        Assert-True ($null -eq (Start-LcAcceptedFetch -UserFile $uf -ResponsePath $resp)) 'accepts: empty username file, no request'
        Assert-True ($null -eq (Start-LcAcceptedFetch -UserFile '' -ResponsePath $resp)) 'accepts: no username file, no request'
        [IO.File]::WriteAllText($uf, " someone`r`n")
        $task = Start-LcAcceptedFetch -UserFile $uf -ResponsePath $resp
        Assert-True ($null -ne $task) 'accepts: username and response file give a request'
        $got = @(Receive-LcAcceptedList $task)
        Assert-Equal (@($got | ForEach-Object { "$($_.Slug)@$($_.Time)" }) -join ',') 'move-zeroes@1792324222'
        Assert-True ($null -eq (Start-LcAcceptedFetch -UserFile $uf -ResponsePath (Join-Path $tmp 'none.json'))) 'accepts: missing response file'
        [IO.File]::WriteAllText($resp, 'not json')
        Assert-Equal @(Receive-LcAcceptedList (Start-LcAcceptedFetch -UserFile $uf -ResponsePath $resp)).Count 0 'accepts: bad JSON is ignored'
        Assert-Equal @(Receive-LcAcceptedList $null).Count 0

        # solve commit (temp repo only)
        $git = (Get-Command git -ErrorAction Stop).Source
        $rp = Join-Path $tmp 'repo'; New-Item -ItemType Directory $rp | Out-Null
        & $git -C $rp init -q 2>$null
        & $git -C $rp config user.email t@example.com
        & $git -C $rp config user.name t
        [IO.File]::WriteAllText((Join-Path $rp 'sol.cpp'), 'v1')
        [IO.File]::WriteAllText((Join-Path $rp 'other.txt'), 'o1')
        & $git -C $rp add -A; & $git -C $rp commit -q -m init
        [IO.File]::WriteAllText((Join-Path $rp 'sol.cpp'), 'v2')
        [IO.File]::WriteAllText((Join-Path $rp 'other.txt'), 'o2')
        [IO.File]::WriteAllText((Join-Path $rp 'new.txt'), 'n')
        $outside = Join-Path $tmp 'outside.txt'; [IO.File]::WriteAllText($outside, 'x')
        $r = Invoke-LcSolveCommit -RepoDir $rp -Paths @((Join-Path $rp 'sol.cpp'), (Join-Path $rp 'new.txt'), (Join-Path $rp 'missing.txt'), $outside) -Message 'solve: two-sum (Easy)'
        Assert-True ($r -is [bool] -and $r) 'commit returned true'
        Assert-Equal ((& $git -C $rp log -1 --format=%s) -join '') 'solve: two-sum (Easy)'
        $files = (& $git -C $rp show --name-only --format= HEAD) | Sort-Object
        Assert-Equal ($files -join ',') 'new.txt,sol.cpp'
        Assert-Match ((& $git -C $rp status --porcelain) -join "`n") '^ M other\.txt'
        $res = @(Invoke-LcSolveCommit -RepoDir $rp -Paths @((Join-Path $rp 'sol.cpp')) -Message 'again' 6>&1)
        Assert-True ($res.Count -eq 1 -and $res[0] -is [bool] -and -not $res[0]) 'nothing to commit: $false, silent'
        Assert-Equal ((& $git -C $rp log -1 --format=%s) -join '') 'solve: two-sum (Easy)'

        # A failing commit returns git's first meaningful line as a string (R13: without PS 5.1's
        # "git.exe : " or warning lines) and prints nothing; the caller prints it and waits.
        [IO.File]::WriteAllText((Join-Path $rp '.git\hooks\pre-commit'), "#!/bin/sh`necho 'warning: first' >&2`necho 'hook says no' >&2`nexit 1`n")
        [IO.File]::WriteAllText((Join-Path $rp 'sol.cpp'), 'v3')
        $res = @(Invoke-LcSolveCommit -RepoDir $rp -Paths @((Join-Path $rp 'sol.cpp')) -Message 'blocked' 6>&1)
        Assert-True ($res.Count -eq 1 -and $res[0] -is [string]) "failed commit: one string, no output ($($res -join '|'))"
        Assert-Equal $res[0] 'hook says no'

        # non-repo
        $nr = Join-Path $tmp 'norepo'; New-Item -ItemType Directory $nr | Out-Null
        [IO.File]::WriteAllText((Join-Path $nr 'a.cpp'), 'x')
        $res = @(Invoke-LcSolveCommit -RepoDir $nr -Paths @((Join-Path $nr 'a.cpp')) -Message 'm' 6>&1)
        Assert-True ($res.Count -eq 1 -and $res[0] -is [string]) "non-repo: one string, no output ($($res -join '|'))"
        Assert-Equal $res[0] 'not a git repo'
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
