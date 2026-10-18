# Tests for .zed/lc-view.ps1, the journey view: its data (-Json) and its server (dot-sourced by run-all.ps1;
# body wrapped to keep the caller's variables intact).
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $view = Join-Path $repo '.zed\lc-view.ps1'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lcv-' + [guid]::NewGuid().ToString('N'))
    $journey = Join-Path $tmp 'journey'
    $sols = Join-Path $tmp 'solves'
    $oldUser = $env:LC_USER_FILE
    $env:LC_USER_FILE = Join-Path $tmp 'no-user.txt'  # accepts not tracked: the real username never decides
    $server = $null

    function Get-ViewData([string]$Root) {
        $out = powershell -NoProfile -ExecutionPolicy Bypass -File $view -Json -JourneyRoot $Root -SolutionsRoot $sols 2>&1 | Out-String
        return @{ Text = $out; Data = ($out | ConvertFrom-Json) }
    }

    try {
        # An empty journey still gives valid data
        $r = Get-ViewData (Join-Path $tmp 'empty')
        Assert-Equal @($r.Data.events).Count 0 "view: empty events`n$($r.Text)"
        Assert-Equal @($r.Data.weekly).Count 0 'view: empty weekly'

        # A journey with two problems, a snapshot named by hash, a source, memory and a weekly read
        foreach ($d in @($journey, $sols, "$journey\problems", "$journey\snapshots\two-sum", "$journey\local\weekly")) { New-Item -ItemType Directory -Force $d | Out-Null }
        [IO.File]::WriteAllText("$journey\problems\two-sum.json", '{"questionFrontendId":"1","title":"Two Sum","difficulty":"Easy","topicTags":[{"name":"Array"},{"name":"Hash Table"}]}', $utf8)
        $events = @(
            '{"ts":"2026-10-18T10:00:00+05:30","event":"test_run","slug":"two-sum","file":"solves/two-sum.cpp","src_hash":"aaaaaaaaaaaa","compile_ok":true,"cases":[{"n":1,"status":"fail","ms":0.01,"input":"nums = [2,7], target = 9","expected":"[0,1]","got":"[]"}],"passed":0,"failed":1}'
            '{"ts":"2026-10-18T10:05:00+05:30","event":"test_run","slug":"two-sum","file":"solves/two-sum.cpp","src_hash":"bbbbbbbbbbbb","compile_ok":true,"cases":[{"n":1,"status":"pass","ms":0.01}],"passed":1,"failed":0}'
            '{"ts":"2026-10-18T10:05:00+05:30","event":"solved","slug":"two-sum","file":"solves/two-sum.cpp","src_hash":"bbbbbbbbbbbb","attempts":2,"max_ms":0.01}'
            '{"ts":"2026-10-18T10:06:00+05:30","event":"review","slug":"two-sum","file":"solves/two-sum.cpp","src_hash":"bbbbbbbbbbbb","score":8,"label":"Great","pattern":"Hash Map","idea":"Store each index"}'
            '{"ts":"2026-10-18T10:07:00+05:30","event":"test_run","slug":"rotate-array","file":"solves/rotate-array.cpp","src_hash":"cccccccccccc","compile_ok":false,"compile_error":"line 3: x"}'
            '{"ts":"2026-10-18T10:08:00+05:30","event":"test_ru'  # cut short by a crash
        )
        [IO.File]::WriteAllText("$journey\events.jsonl", (($events -join "`n") + "`n"), $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\20261018-100500-bbbbbbbbbbbb.cpp", "class Solution {};`n", $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\20261018-100000.cpp", "// old name, no hash`n", $utf8)
        [IO.File]::WriteAllText("$sols\two-sum.cpp", "class Solution { /* now */ };`n", $utf8)
        $mem = @(
            '{"id":"m000001","kind":"habit","text":"Reads past the end","evidence":[{"slug":"two-sum","ref":"chat"}],"status":"active","source":"coach","created":"2026-10-18T10:00:00+05:30","updated":"2026-10-18T10:00:00+05:30","last_seen":"2099-01-01T00:00:00+05:30"}'
            '{"id":"m000002","kind":"style","text":"Forgotten","evidence":[],"status":"dismissed","source":"user","created":"2026-10-18T10:00:00+05:30","updated":"2026-10-18T10:00:00+05:30","last_seen":"2026-10-18T10:00:00+05:30"}'
        )
        [IO.File]::WriteAllText("$journey\local\memory.jsonl", (($mem -join "`n") + "`n"), $utf8)
        [IO.File]::WriteAllText("$journey\local\weekly\2026-10-12.md", "# Older`n", $utf8)
        [IO.File]::WriteAllText("$journey\local\weekly\2026-10-19.md", "Said ""hi"".`n", $utf8)

        $r = Get-ViewData $journey
        $d = $r.Data
        Assert-Equal @($d.events).Count 5 'view: the cut-short event line is dropped'
        Assert-Equal $d.meta.'two-sum'.title 'Two Sum'
        Assert-Equal (@($d.meta.'two-sum'.tags) -join ',') 'Array,Hash Table'
        Assert-Equal "$($d.status.'two-sum')|$($d.status.'rotate-array')" 'passed locally|attempted'
        $snaps = @($d.snaps.'two-sum')
        Assert-Equal $snaps.Count 2 'view: both snapshots'
        Assert-Equal (@($snaps | ForEach-Object { $_.hash }) -join ',') ',bbbbbbbbbbbb'
        Assert-Equal ($snaps[1].t) ([DateTimeOffset]([datetime]'2026-10-18T10:05:00')).ToUnixTimeMilliseconds()
        Assert-Match $d.source.'two-sum' 'now'
        Assert-Equal (@($d.memory) | ForEach-Object { $_.id }) 'm000001'
        Assert-Equal (@($d.weekly | ForEach-Object { $_.week }) -join ',') '2026-10-19,2026-10-12'
        Assert-Equal @($d.weekly)[0].text 'Said "hi".'

        # The server: page, data, icons, 404, nothing outside .zed/view; a second start just exits
        $port = 8790 + (Get-Random -Minimum 50 -Maximum 400)
        $server = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$view`"", '-NoOpen', '-Port', $port, '-JourneyRoot', "`"$journey`"", '-SolutionsRoot', "`"$sols`"" -WindowStyle Hidden -PassThru
        $base = "http://localhost:$port"
        $ok = $false
        for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
            try { $null = Invoke-WebRequest "$base/" -UseBasicParsing -TimeoutSec 2; $ok = $true } catch { Start-Sleep -Milliseconds 250 }
        }
        Assert-True $ok 'view: the server answers'
        $page = Invoke-WebRequest "$base/" -UseBasicParsing
        Assert-Match $page.Content '<title>DSA Journey</title>'
        $data = Invoke-WebRequest "$base/data.json" -UseBasicParsing
        Assert-Match $data.Headers['Content-Type'] 'application/json'
        Assert-Equal @(($data.Content | ConvertFrom-Json).events).Count 5 'view: /data.json'
        Assert-Equal (Invoke-WebRequest "$base/favicon.svg" -UseBasicParsing).Headers['Content-Type'] 'image/svg+xml'
        $codes = foreach ($p in '/nope.html', '/..%2f..%2flc-view.ps1', '/view.tests.ps1') {
            try { (Invoke-WebRequest "$base$p" -UseBasicParsing).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
        }
        # http.sys itself refuses the encoded ../ (403); either way nothing outside .zed/view is served
        Assert-True (@($codes | Where-Object { $_ -ne 404 -and $_ -ne 403 }).Count -eq 0) "view: served a file it shouldn't: $($codes -join ',')"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = powershell -NoProfile -ExecutionPolicy Bypass -File $view -NoOpen -Port $port 2>&1
        Assert-Equal $LASTEXITCODE 0 'view: a second start exits cleanly'
        Assert-True ($sw.ElapsedMilliseconds -lt 10000) "view: a second start took $($sw.ElapsedMilliseconds) ms"
        Assert-True (-not $server.HasExited) 'view: the first server keeps running'
    } finally {
        if ($server -and -not $server.HasExited) { & taskkill.exe /T /F /PID $server.Id 2>&1 | Out-Null }
        $env:LC_USER_FILE = $oldUser
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
