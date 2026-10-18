# The journey view (Alt+F9): a read-only web page over journey/ and leetcode-solves/, served on
# http://localhost:8790/. Every page load reads the files again, so it always shows the latest runs.
#   (no args)   serve and open the page; when the port is taken (the view is already running), just open it
#   -Json       print the page's data and exit (self-tests)
#   -NoOpen     don't open the browser
# The page is .zed/view/index.html; it fetches /data.json. Stop the server by closing its terminal.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8790,
    [switch]$Json,
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

# events.jsonl as a JSON array, passed through as written. A malformed line (a write cut short) is dropped.
function Get-LcViewEventsJson {
    $p = Join-Path $JourneyRoot 'events.jsonl'
    if (-not [IO.File]::Exists($p)) { return '[]' }
    $lines = @(foreach ($l in [IO.File]::ReadAllLines($p, $utf8)) { $t = $l.Trim(); if ($t) { $t } })
    $all = '[' + ($lines -join ',') + ']'
    try { $null = $all | ConvertFrom-Json; return $all } catch {}
    $ok = @(foreach ($l in $lines) { try { $null = $l | ConvertFrom-Json; $l } catch {} })
    return '[' + ($ok -join ',') + ']'
}

# Everything the page shows besides the events: problem data, snapshots, statuses, sources, memory and
# weekly reads. Returns the page's data as one JSON string.
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
    # Snapshots: <yyyyMMdd-HHmmss>[-<src_hash>].cpp, with t in unix milliseconds for the page.
    $snaps = [ordered]@{}
    $snapDir = Join-Path $JourneyRoot 'snapshots'
    if (Test-Path -LiteralPath $snapDir) {
        foreach ($d in Get-ChildItem -LiteralPath $snapDir -Directory) {
            $list = @(foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Filter '*.cpp' | Sort-Object Name) {
                if ($f.Name -notmatch '^(\d{8}-\d{6})(?:-([0-9a-f]+))?\.cpp$') { continue }
                $t = [DateTimeOffset]([datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $inv))
                [ordered]@{ t = $t.ToUnixTimeMilliseconds(); hash = [string]$Matches[2]; code = [IO.File]::ReadAllText($f.FullName, $utf8) }
            })
            $snaps[$d.Name] = $list
        }
    }
    # Statuses come from journey.ps1, so the page and journey.md always agree.
    $events = @(Read-LcEvents $JourneyRoot)
    $tracked = Test-LcAcceptsTracked (Get-LcUserFile)
    $states = Get-LcJourneyState $events
    $status = [ordered]@{}
    $source = [ordered]@{}
    foreach ($slug in @($states.Keys)) {
        $status[$slug] = Get-LcProblemStatus $states[$slug] $tracked $now
        $src = Join-Path $SolutionsRoot "$slug.cpp"
        if ([IO.File]::Exists($src)) { $source[$slug] = [IO.File]::ReadAllText($src, $utf8) }
    }
    $local = Join-Path $JourneyRoot 'local'
    $memory = @(Read-LcMemory $local $now | Where-Object { $_.status -ne 'dismissed' })
    $weekly = @()
    $weekDir = Join-Path $local 'weekly'
    if (Test-Path -LiteralPath $weekDir) {
        $weekly = @(Get-ChildItem -LiteralPath $weekDir -Filter '*.md' | Sort-Object Name -Descending | ForEach-Object {
            [ordered]@{ week = $_.BaseName; text = [IO.File]::ReadAllText($_.FullName, $utf8).Trim() }
        })
    }
    $rest = [ordered]@{ meta = $meta; snaps = $snaps; status = $status; source = $source; memory = $memory; weekly = $weekly }
    $restJson = $rest | ConvertTo-Json -Compress -Depth 8
    return '{"events":' + (Get-LcViewEventsJson) + ',' + $restJson.Substring(1)
}

if ($Json) { [Console]::Out.Write((Get-LcViewData)); exit 0 }

$url = "http://localhost:$Port/"
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() }
catch {
    # The port is taken: the view is already running (a second Alt+F9), so just show it.
    if (-not $NoOpen) { Start-Process $url }
    exit 0
}
Write-Host "Journey view on $url (close this terminal to stop it)"
if (-not $NoOpen) { Start-Process $url }

$types = @{ '.html' = 'text/html; charset=utf-8'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon' }
try {
    while ($listener.IsListening) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(500)) {}  # wakes up twice a second, so Ctrl+C works
        $ctx = $listener.EndGetContext($ar)
        $res = $ctx.Response
        try {
            $path = $ctx.Request.Url.AbsolutePath
            $res.Headers['Cache-Control'] = 'no-store'
            if ($path -eq '/data.json') {
                $bytes = $utf8.GetBytes((Get-LcViewData))
                $res.ContentType = 'application/json; charset=utf-8'
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
