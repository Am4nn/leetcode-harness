# The journey view (Alt+F6): a read-only web page over journey/ and leetcode-solves/, served on
# http://localhost:8790/. Every page load reads the files again, so it always shows the latest runs.
#   (no args)   serve and open the page; when the port is taken (the view is already running), just open it
#   -Json       print the page's data and exit (self-tests); with -Snap <slug>, that problem's code instead
#   -NoOpen     don't open the browser
# The page is .zed/view/index.html. It fetches /data.json (small: no code), and /snap/<slug> (every saved
# version of one problem plus its solution) when it shows code. Only this machine may connect.
# Stop the server by closing its terminal.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8790,
    [switch]$Json,
    [string]$Snap = '',
    [switch]$NoOpen,
    [string]$JourneyRoot = '',    # default <dsa>/journey
    [string]$SolutionsRoot = ''   # default <dsa>/leetcode-solves
)

. (Join-Path $PSScriptRoot 'lc\journey.ps1')
. (Join-Path $PSScriptRoot 'lc\memory.ps1')

$dsaRoot = Split-Path -Parent $PSScriptRoot
if (-not $JourneyRoot) { $JourneyRoot = Join-Path $dsaRoot 'journey' }
if (-not $SolutionsRoot) { $SolutionsRoot = Join-Path $dsaRoot 'leetcode-solves' }
$viewDir = Join-Path $PSScriptRoot 'view'
$utf8 = New-Object Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture
$snapDir = Join-Path $JourneyRoot 'snapshots'
$localDir = Join-Path $JourneyRoot 'local'

# A line of strict JSON (RFC 8259 tokens). PS 5.1's ConvertFrom-Json also reads NaN, Infinity, single quotes,
# unquoted keys and leading zeros, which the browser's JSON.parse rejects.
$jsonLine = New-Object Text.RegularExpressions.Regex ('^(?>[ \t]+|"(?:[^"\\\x00-\x1f]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?(?![0-9A-Za-z.+-])|(?:true|false|null)(?![0-9A-Za-z])|[{}\[\]:,])*$'), 'Compiled'

# events.jsonl, parsed once. Objects: the events for the statuses, read like Read-LcEvents does. Json: the
# page's array of the lines as written, without the ones it can't use: a line cut short, one that isn't an
# object or has no ts, or one only PS 5.1 can read (NaN, Infinity, ...).
function Read-LcViewEvents {
    $r = @{ Objects = @(); Json = '[]' }
    $p = Join-Path $JourneyRoot 'events.jsonl'
    if (-not [IO.File]::Exists($p)) { return $r }
    $lines = @(foreach ($l in [IO.File]::ReadAllText($p, $utf8).Split("`n")) { $t = $l.Trim(); if ($t) { $t } })
    if (-not $lines.Count) { return $r }
    $all = $null
    try { $all = ('[' + ($lines -join ',') + ']') | ConvertFrom-Json } catch {}
    $all = @($all)
    $whole = $all.Count -eq $lines.Count
    $objs = New-Object Collections.Generic.List[object]
    $keep = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($whole) { $o = $all[$i] }
        else { try { $o = $lines[$i] | ConvertFrom-Json } catch { continue } }
        if ($o -isnot [pscustomobject]) { continue }
        $objs.Add($o)
        if ([string]$o.ts -and $jsonLine.IsMatch($lines[$i])) { $keep.Add($lines[$i]) }
    }
    $r.Objects = $objs.ToArray()
    $r.Json = '[' + ($keep.ToArray() -join ',') + ']'
    return $r
}

# A short tag of everything /data.json is built from (file sizes and times, and the hour, since statuses and
# memory age with time). The same tag means the same data, so the page's refetch on focus costs ~nothing.
function Get-LcViewTag {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append((Get-Date).ToString('yyyyMMddHH', $inv))
    foreach ($p in @((Join-Path $JourneyRoot 'events.jsonl'), (Join-Path $localDir 'memory.jsonl'), (Get-LcUserFile))) {
        $f = New-Object IO.FileInfo $p
        if ($f.Exists) { [void]$sb.Append("|$($f.Length):$($f.LastWriteTimeUtc.Ticks)") } else { [void]$sb.Append('|-') }
    }
    # a file added or removed changes its folder's time (snapshots and solutions only decide which have code)
    foreach ($d in @($snapDir, $SolutionsRoot)) { [void]$sb.Append("|$([IO.Directory]::GetLastWriteTimeUtc($d).Ticks)") }
    foreach ($d in @((Join-Path $JourneyRoot 'problems'), (Join-Path $localDir 'weekly'))) {
        $di = New-Object IO.DirectoryInfo $d
        if ($di.Exists) { foreach ($f in $di.GetFiles()) { [void]$sb.Append("|$($f.Name):$($f.Length):$($f.LastWriteTimeUtc.Ticks)") } }
    }
    $md5 = [Security.Cryptography.MD5]::Create()
    try { return (($md5.ComputeHash($utf8.GetBytes($sb.ToString())) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $md5.Dispose() }
}

# One problem's code, for the drawer and Revise: every snapshot <yyyyMMdd-HHmmss>[-<src_hash>].cpp, with t in
# unix milliseconds, and the solution as it is now. A file with another name or an impossible date is skipped.
# $Slug is checked by the caller (^[a-z0-9-]+$), so this never reads outside snapshots/ and the solutions.
function Get-LcViewSnapJson([string]$Slug) {
    $list = @()
    $dir = Join-Path $snapDir $Slug
    if ([IO.Directory]::Exists($dir)) {
        $list = @(foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.cpp' | Sort-Object Name) {
            if ($f.Name -notmatch '^(\d{8}-\d{6})(?:-([0-9a-f]+))?\.cpp$') { continue }
            $hash = [string]$Matches[2]
            $d = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($Matches[1], 'yyyyMMdd-HHmmss', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
            try { $code = [IO.File]::ReadAllText($f.FullName, $utf8) } catch { continue }
            [ordered]@{ t = ([DateTimeOffset]$d).ToUnixTimeMilliseconds(); hash = $hash; code = $code }
        })
    }
    $source = $null
    $src = Join-Path $SolutionsRoot "$Slug.cpp"
    if ([IO.File]::Exists($src)) { try { $source = [IO.File]::ReadAllText($src, $utf8) } catch {} }
    return ([ordered]@{ snaps = $list; source = $source } | ConvertTo-Json -Compress -Depth 4)
}

# Only this machine may read the journey: http.sys listens on every interface and only checks the Host
# header, so a request with Host: localhost to a LAN or WSL address would otherwise be answered.
function Test-LcViewLocal($EndPoint) {
    if ($null -eq $EndPoint -or $null -eq $EndPoint.Address) { return $false }
    $a = $EndPoint.Address
    if ($a.IsIPv4MappedToIPv6) { $a = $a.MapToIPv4() }
    return [Net.IPAddress]::IsLoopback($a)
}

# Everything the page shows besides code: events, problem data, statuses, which problems have code, memory
# and weekly reads. Returns the page's data as one JSON string.
function Get-LcViewData {
    $now = Get-Date
    $meta = [ordered]@{}
    $metaDir = Join-Path $JourneyRoot 'problems'
    if (Test-Path -LiteralPath $metaDir) {
        foreach ($f in Get-ChildItem -LiteralPath $metaDir -Filter '*.json') {
            try {
                $j = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json
                if ($j.data -and $j.data.question) { $j = $j.data.question }
                $meta[$f.BaseName] = [ordered]@{
                    id = [string]$j.questionFrontendId; title = [string]$j.title; difficulty = [string]$j.difficulty
                    tags = @($j.topicTags | ForEach-Object { if ($_.name) { [string]$_.name } else { [string]$_ } })
                }
            } catch {}
        }
    }
    # Statuses come from journey.ps1, so the page and journey.md always agree.
    $ev = Read-LcViewEvents
    $tracked = Test-LcAcceptsTracked (Get-LcUserFile)
    $states = Get-LcJourneyState $ev.Objects
    $status = [ordered]@{}
    $code = @(foreach ($slug in @($states.Keys)) {
        $status[$slug] = Get-LcProblemStatus $states[$slug] $tracked $now
        if ($slug -cmatch '^[a-z0-9-]+$' -and ([IO.File]::Exists((Join-Path $SolutionsRoot "$slug.cpp")) -or [IO.Directory]::Exists((Join-Path $snapDir $slug)))) { $slug }
    })
    $local = Join-Path $JourneyRoot 'local'
    $memory = @(Read-LcMemory $local $now -NoSave | Where-Object { $_.status -ne 'dismissed' })  # read-only: ages, never writes
    $weekly = @()
    $weekDir = Join-Path $local 'weekly'
    if (Test-Path -LiteralPath $weekDir) {
        $weekly = @(Get-ChildItem -LiteralPath $weekDir -Filter '*.md' | Sort-Object Name -Descending | ForEach-Object {
            [ordered]@{ week = $_.BaseName; text = [IO.File]::ReadAllText($_.FullName, $utf8).Trim() }
        })
    }
    $rest = [ordered]@{ meta = $meta; status = $status; code = $code; memory = $memory; weekly = $weekly }
    $restJson = $rest | ConvertTo-Json -Compress -Depth 8
    return '{"events":' + $ev.Json + ',' + $restJson.Substring(1)
}

if ($Json) {
    if ($Snap) {
        if ($Snap -cnotmatch '^[a-z0-9-]+$') { [Console]::Error.WriteLine("Not a slug: $Snap"); exit 1 }
        [Console]::Out.Write((Get-LcViewSnapJson $Snap))
    } else { [Console]::Out.Write((Get-LcViewData)) }
    exit 0
}

$url = "http://localhost:$Port/"
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() }
catch {
    # The port is taken: the view is already running (a second Alt+F6), so just show it.
    if (-not $NoOpen) { Start-Process $url }
    exit 0
}
Write-Host "Journey view on $url (close this terminal to stop it)"
if (-not $NoOpen) { Start-Process $url }

$types = @{ '.html' = 'text/html; charset=utf-8'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon' }
$noBytes = New-Object byte[] 0
$cache = @{ Tag = ''; Bytes = $noBytes }  # the last /data.json, rebuilt only when its tag changes
try {
    while ($listener.IsListening) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(500)) {}  # wakes up twice a second, so Ctrl+C works
        $ctx = $listener.EndGetContext($ar)
        $res = $ctx.Response
        try {
            $path = $ctx.Request.Url.AbsolutePath
            $res.Headers['Cache-Control'] = 'no-store'
            if (-not (Test-LcViewLocal $ctx.Request.RemoteEndPoint)) {
                $res.StatusCode = 403; $bytes = $utf8.GetBytes('forbidden')
            } elseif ($path -eq '/data.json') {
                $tag = '"' + (Get-LcViewTag) + '"'
                $res.Headers['Cache-Control'] = 'no-cache'
                $res.Headers['ETag'] = $tag
                if ($ctx.Request.Headers['If-None-Match'] -eq $tag) { $res.StatusCode = 304; $bytes = $noBytes }
                else {
                    if ($cache.Tag -ne $tag) { $cache.Bytes = $utf8.GetBytes((Get-LcViewData)); $cache.Tag = $tag }
                    $bytes = $cache.Bytes
                    $res.ContentType = 'application/json; charset=utf-8'
                }
            } elseif ($path -match '^/snap/(.*)$') {
                $slug = $Matches[1]
                if ($slug -cnotmatch '^[a-z0-9-]+$') { $res.StatusCode = 404; $bytes = $utf8.GetBytes('not found') }
                else { $bytes = $utf8.GetBytes((Get-LcViewSnapJson $slug)); $res.ContentType = 'application/json; charset=utf-8' }
            } else {
                $name = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
                $file = Join-Path $viewDir $name
                if ($name -notmatch '^[\w.-]+$' -or -not [IO.File]::Exists($file)) { $res.StatusCode = 404; $bytes = $utf8.GetBytes('not found') }
                else { $bytes = [IO.File]::ReadAllBytes($file); $res.ContentType = $types[[IO.Path]::GetExtension($file)] }
            }
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            try { $res.StatusCode = 500; $b = $utf8.GetBytes([string]$_.Exception.Message); $res.OutputStream.Write($b, 0, $b.Length) } catch {}
        } finally { $res.Close() }
    }
} finally { $listener.Stop() }
