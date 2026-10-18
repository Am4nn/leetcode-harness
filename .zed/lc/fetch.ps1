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
# The cache lives in $ProblemsDir (<JourneyRoot>/problems), never next to the solution: <slug>.json.
# A definite "no such problem" is remembered in <slug>.none so later runs skip the fetch;
# NotProblem is true when that marker exists (also offline) or this call just wrote it.
function Get-LcCachedQuestion([string]$ProblemsDir, [string]$Slug, [switch]$Offline) {
    $meta = Join-Path $ProblemsDir "$Slug.json"
    $none = Join-Path $ProblemsDir "$Slug.none"
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

# The user's recent accepted submissions (public profile, no login), started in the background.
# Returns the request's Task[string], or $null when there is no username (missing or empty $UserFile).
# -ResponsePath: a JSON file used as the response instead of the network (self-tests); a missing file
# gives $null. Never throws.
function Start-LcAcceptedFetch([string]$UserFile, [string]$ResponsePath = '') {
    try {
        if (-not $UserFile -or -not [IO.File]::Exists($UserFile)) { return $null }
        $user = [IO.File]::ReadAllText($UserFile).Trim()
        if (-not $user) { return $null }
        if ($ResponsePath) {
            if (-not [IO.File]::Exists($ResponsePath)) { return $null }
            return [Threading.Tasks.Task]::FromResult([IO.File]::ReadAllText($ResponsePath, [Text.Encoding]::UTF8))
        }
        $body = @{
            query     = 'query r($u:String!,$l:Int!){recentAcSubmissionList(username:$u,limit:$l){titleSlug timestamp}}'
            variables = @{ u = $user; l = 20 }
        } | ConvertTo-Json -Depth 5 -Compress
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['Content-Type'] = 'application/json'
        $wc.Headers['Referer'] = 'https://leetcode.com'
        return $wc.UploadStringTaskAsync([Uri]'https://leetcode.com/graphql', $body)
    } catch { return $null }
}

# Waits up to $WaitMs more for the request, then returns its list as @{ Slug; Time } objects
# (Time: unix seconds), or an empty list on any failure. Never throws.
function Receive-LcAcceptedList($Task, [int]$WaitMs = 1500) {
    if ($null -eq $Task) { return @() }
    try {
        if (-not $Task.Wait($WaitMs) -or $Task.Status -ne 'RanToCompletion') { return @() }
        $r = $Task.Result | ConvertFrom-Json
        $out = foreach ($a in @($r.data.recentAcSubmissionList)) {
            $t = 0L
            if ($a.titleSlug -and [long]::TryParse([string]$a.timestamp, [ref]$t)) { @{ Slug = [string]$a.titleSlug; Time = $t } }
        }
        return @($out)
    } catch { return @() }
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
