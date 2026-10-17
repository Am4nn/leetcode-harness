# Fetch LeetCode problems from the public GraphQL endpoint (no login), cache them, convert HTML.
# Function library: dot-source it. No side effects.

$script:LcFetchError = ''

function Get-LcQuestion([string]$Slug) {
    $script:LcFetchError = ''
    $fields = 'questionFrontendId title titleSlug difficulty isPaidOnly topicTags { name } metaData exampleTestcaseList content'
    $body = @{
        query     = 'query q($s:String!){question(titleSlug:$s){' + $fields + '}}'
        variables = @{ s = $Slug }
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $r = Invoke-RestMethod -Uri 'https://leetcode.com/graphql' -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' -Headers @{ Referer = 'https://leetcode.com' } -TimeoutSec 10
        if (-not $r.data -or -not $r.data.question) {
            $script:LcFetchError = "no such problem: $Slug"
            return $null
        }
        return $r.data.question
    } catch {
        $script:LcFetchError = $_.Exception.Message
        return $null
    }
}

function Get-LcCachedQuestion([string]$TestsDir, [string]$Slug, [switch]$Offline) {
    $meta = Join-Path (Join-Path $TestsDir '.meta') "$Slug.json"
    if (Test-Path -LiteralPath $meta) {
        $q = [IO.File]::ReadAllText($meta, [Text.Encoding]::UTF8) | ConvertFrom-Json
        return @{ Question = $q; Fetched = $false }
    }
    if ($Offline) { return @{ Question = $null; Fetched = $false } }
    $q = Get-LcQuestion -Slug $Slug
    if ($null -eq $q) { return @{ Question = $null; Fetched = $false } }
    New-Item -ItemType Directory -Force (Split-Path -Parent $meta) | Out-Null
    [IO.File]::WriteAllText($meta, ($q | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
    return @{ Question = $q; Fetched = $true }
}

function ConvertFrom-LcHtml([string]$html) {
    if (-not $html) { return '' }
    $t = $html -replace '(?is)<sup>(.*?)</sup>', '^$1'
    $t = $t -replace '(?i)</?(p|li|pre|div|br|ul|ol)\b[^>]*>', "`n"
    $t = $t -replace '<[^>]+>', ''
    $t = $t.Replace('&nbsp;', ' ')
    $t = [Net.WebUtility]::HtmlDecode($t)
    $t = $t.Replace([string][char]0xA0, ' ')
    $lines = $t -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    return (@($lines) -join "`n")
}
