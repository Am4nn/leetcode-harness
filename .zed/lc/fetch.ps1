# Fetch LeetCode problems from the public GraphQL endpoint (no login), cache them, convert HTML.
# Function library: dot-source it. No side effects.

$script:LcFetchError = ''
$script:LcFetchMissing = $false  # true only when LeetCode answered that the slug doesn't exist

function Get-LcQuestion([string]$Slug) {
    $script:LcFetchError = ''
    $script:LcFetchMissing = $false
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
            $script:LcFetchMissing = [bool]$r.data  # {"data":{"question":null}}; anything else may be transient
            return $null
        }
        return $r.data.question
    } catch {
        $script:LcFetchError = $_.Exception.Message
        return $null
    }
}

# Returns @{ Question; Fetched; Tried; NotProblem }. Tried: LeetCode was contacted on this call.
# A definite "no such problem" is remembered in .meta/<slug>.none so later runs skip the fetch;
# NotProblem is true when that marker exists (also offline) or this call just wrote it.
function Get-LcCachedQuestion([string]$TestsDir, [string]$Slug, [switch]$Offline) {
    $meta = Join-Path (Join-Path $TestsDir '.meta') "$Slug.json"
    $none = Join-Path (Join-Path $TestsDir '.meta') "$Slug.none"
    if (Test-Path -LiteralPath $meta) {
        $q = [IO.File]::ReadAllText($meta, [Text.Encoding]::UTF8) | ConvertFrom-Json
        return @{ Question = $q; Fetched = $false; Tried = $false; NotProblem = $false }
    }
    if (Test-Path -LiteralPath $none) { return @{ Question = $null; Fetched = $false; Tried = $false; NotProblem = $true } }
    if ($Offline) { return @{ Question = $null; Fetched = $false; Tried = $false; NotProblem = $false } }
    $q = Get-LcQuestion -Slug $Slug
    if ($null -eq $q) {
        if ($script:LcFetchMissing) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $none) | Out-Null
            [IO.File]::WriteAllText($none, '', (New-Object Text.UTF8Encoding $false))
        }
        return @{ Question = $null; Fetched = $false; Tried = $true; NotProblem = [bool]$script:LcFetchMissing }
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $meta) | Out-Null
    [IO.File]::WriteAllText($meta, ($q | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
    return @{ Question = $q; Fetched = $true; Tried = $true; NotProblem = $false }
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
