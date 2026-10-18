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

    function Get-ViewData([string]$Root, [string]$Snap = '') {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $view, '-Json', '-JourneyRoot', $Root, '-SolutionsRoot', $sols)
        if ($Snap) { $a += @('-Snap', $Snap) }
        $out = powershell @a 2>&1 | Out-String
        return @{ Text = $out; Data = ($out | ConvertFrom-Json) }
    }
    # A raw request: any Host header, any extra headers, and the status code instead of an exception.
    function Get-ViewRaw([string]$Url, [hashtable]$Headers = @{}, [string]$HostHeader = '') {
        $req = [Net.HttpWebRequest]::Create($Url); $req.Proxy = $null; $req.Timeout = 20000
        if ($HostHeader) { $req.Host = $HostHeader }
        foreach ($k in $Headers.Keys) { $req.Headers[$k] = $Headers[$k] }
        try { $res = $req.GetResponse() } catch [Net.WebException] { $res = $_.Exception.Response; if (-not $res) { return @{ Code = 0; Body = ''; ETag = '' } } }
        $sr = New-Object IO.StreamReader($res.GetResponseStream(), $utf8)
        try { return @{ Code = [int]$res.StatusCode; Body = $sr.ReadToEnd(); ETag = [string]$res.Headers['ETag'] } } finally { $sr.Close(); $res.Close() }
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
            '{"ts":"2026-10-18T10:09:00+05:30","event":"analyze_run","slug":"two-sum","src_hash":"bbbbbbbbbbbb","status":"ok","points":[{"n":8,"ms":NaN}]}'  # PS reads NaN, JSON.parse doesn't
            '{"event":"note","slug":"two-sum","text":"hand-added, no ts"}'
            'null'
            '{"ts":"2026-10-18T10:08:00+05:30","event":"test_ru'  # cut short by a crash
        )
        [IO.File]::WriteAllText("$journey\events.jsonl", (($events -join "`n") + "`n"), $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\20261018-100500-bbbbbbbbbbbb.cpp", "class Solution {};`n", $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\20261018-100000.cpp", "// old name, no hash`n", $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\20261318-100500-dddddddddddd.cpp", "// month 13`n", $utf8)
        [IO.File]::WriteAllText("$journey\snapshots\two-sum\notes.cpp", "// not a snapshot`n", $utf8)
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
        # dropped: the cut-short line, the NaN line, the line without ts and the null line
        Assert-Equal @($d.events).Count 5 "view: only the 5 good event lines`n$($r.Text)"
        Assert-True ($r.Text -notmatch 'NaN') 'view: a NaN line reaches the page'
        Assert-Equal $d.meta.'two-sum'.title 'Two Sum'
        Assert-Equal (@($d.meta.'two-sum'.tags) -join ',') 'Array,Hash Table'
        Assert-Equal "$($d.status.'two-sum')|$($d.status.'rotate-array')" 'passed locally|attempted'
        Assert-Equal (@($d.code) -join ',') 'two-sum' 'view: problems with code'
        Assert-True ($r.Text -notmatch 'class Solution') 'view: /data.json carries no code'
        Assert-Equal (@($d.memory) | ForEach-Object { $_.id }) 'm000001'
        Assert-Equal (@($d.weekly | ForEach-Object { $_.week }) -join ',') '2026-10-19,2026-10-12'
        Assert-Equal @($d.weekly)[0].text 'Said "hi".'

        # One problem's code: the two good snapshots (month 13 and notes.cpp skipped) and the solution now
        $s = (Get-ViewData $journey 'two-sum').Data
        $snaps = @($s.snaps)
        Assert-Equal $snaps.Count 2 'view: both snapshots, bad names skipped'
        Assert-Equal (@($snaps | ForEach-Object { $_.hash }) -join ',') ',bbbbbbbbbbbb'
        Assert-Equal ($snaps[1].t) ([DateTimeOffset]([datetime]'2026-10-18T10:05:00')).ToUnixTimeMilliseconds()
        Assert-Match $s.source 'now'
        $s = (Get-ViewData $journey 'rotate-array').Data
        Assert-True (@($s.snaps).Count -eq 0 -and $null -eq $s.source) 'view: no code for rotate-array'
        $null = powershell -NoProfile -ExecutionPolicy Bypass -File $view -Json -Snap '..\two-sum' -JourneyRoot $journey -SolutionsRoot $sols 2>&1
        Assert-Equal $LASTEXITCODE 1 'view: -Snap refuses a path'

        # When every line parses for PS (no cut-short line), the NaN, no-ts and null lines are still dropped
        $j2 = Join-Path $tmp 'j2'
        New-Item -ItemType Directory -Force $j2 | Out-Null
        [IO.File]::WriteAllText("$j2\events.jsonl", (($events[0..($events.Count - 2)] + '{"ts":"2026-10-18T10:10:00+05:30","event":"note","slug":"two-sum","n":01}') -join "`n"), $utf8)
        $r = Get-ViewData $j2
        Assert-Equal @($r.Data.events).Count 5 "view: whole-file parse drops the same lines`n$($r.Text)"

        # Many versions of much code: /data.json stays small, one problem's code comes on its own
        $big = Join-Path $tmp 'big'
        $code = ("class Solution {`n    // BIGCODE " + ('x' * 1500) + "`n};`n")
        $sb = New-Object Text.StringBuilder
        for ($p = 0; $p -lt 30; $p++) {
            $sd = "$big\snapshots\p-$p"; New-Item -ItemType Directory -Force $sd | Out-Null
            for ($v = 0; $v -lt 10; $v++) {
                $h = '{0:x12}' -f ($p * 100 + $v)
                $mm = '{0:d2}' -f $v
                [IO.File]::WriteAllText("$sd\20261001-10$($mm)00-$h.cpp", $code, $utf8)
                [void]$sb.Append("{`"ts`":`"2026-10-01T10:$($mm):00+05:30`",`"event`":`"test_run`",`"slug`":`"p-$p`",`"src_hash`":`"$h`",`"compile_ok`":true,`"passed`":1,`"failed`":0}`n")
            }
        }
        [IO.File]::WriteAllText("$big\events.jsonl", $sb.ToString(), $utf8)
        $r = Get-ViewData $big
        Assert-Equal @($r.Data.events).Count 300 'view: big journey events'
        Assert-True ($r.Text.Length -lt 100000 -and $r.Text -notmatch 'BIGCODE') "view: /data.json is $($r.Text.Length) chars for 450 KB of snapshots"
        Assert-Equal @((Get-ViewData $big 'p-7').Data.snaps).Count 10 'view: one problem''s 10 versions'

        # The server: page, data, icons, 404, nothing outside .zed/view; a second start just exits
        $port = Get-Random -Minimum 9000 -Maximum 9500
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

        # Unchanged data: the same ETag, and a 304 with no body when the page sends it back
        $a = Get-ViewRaw "$base/data.json"
        Assert-True ($a.Code -eq 200 -and $a.ETag) "view: /data.json has an ETag ($($a.Code))"
        Assert-True ($a.Body -notmatch 'class Solution') 'view: served /data.json carries no code'
        $b = Get-ViewRaw "$base/data.json" @{ 'If-None-Match' = $a.ETag }
        Assert-True ($b.Code -eq 304 -and -not $b.Body) "view: unchanged /data.json gives $($b.Code)"
        [IO.File]::AppendAllText("$journey\events.jsonl", '{"ts":"2026-10-18T10:11:00+05:30","event":"note","slug":"two-sum","text":"later"}' + "`n", $utf8)
        $c = Get-ViewRaw "$base/data.json" @{ 'If-None-Match' = $a.ETag }
        Assert-True ($c.Code -eq 200 -and $c.ETag -ne $a.ETag -and $c.Body -match 'later') "view: a new event changes /data.json ($($c.Code))"

        # The code route: one problem's versions; anything but a plain slug is refused
        $s = Get-ViewRaw "$base/snap/two-sum"
        Assert-True ($s.Code -eq 200 -and @(($s.Body | ConvertFrom-Json).snaps).Count -eq 2) "view: /snap/two-sum ($($s.Code))"
        foreach ($p in '/snap/Two-Sum', '/snap/two_sum', '/snap/', '/snap/two-sum/x', '/snap/..%5c..%5cevents.jsonl', '/snap/a.b') {
            $code = (Get-ViewRaw "$base$p").Code
            Assert-True ($code -eq 404 -or $code -eq 400 -or $code -eq 403) "view: $p gave $code"
        }

        # Only this machine: a request to a LAN or WSL address of this machine is refused, even with Host: localhost
        $ips = @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [Net.IPAddress]::IsLoopback($_) })
        foreach ($ip in $ips) {
            $code = (Get-ViewRaw "http://$($ip):$port/data.json" @{} "localhost:$port").Code
            Assert-True ($code -eq 403 -or $code -eq 0) "view: answered $code to $ip"
        }
        Assert-Equal (Get-ViewRaw "http://127.0.0.1:$port/data.json" @{} "localhost:$port").Code 200 'view: 127.0.0.1 is served'
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
