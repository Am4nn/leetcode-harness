# Tests for .zed/lc/fetch.ps1 and .zed/lc/testfile.ps1 (offline, read captured fixtures).
# Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repo '.zed\lc\info.ps1')
    . (Join-Path $repo '.zed\lc\fetch.ps1')
    . (Join-Path $repo '.zed\lc\testfile.ps1')
    $metaDir = Join-Path $repo 'lc\selftest\tests'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lc-testfile-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        function Get-Fixture([string]$slug) {
            $r = Get-LcCachedQuestion -TestsDir $metaDir -Slug $slug -Offline
            Assert-True ($null -ne $r.Question) "fixture $slug missing"
            Assert-True (-not $r.Fetched) 'cache hit must not count as fetched'
            return $r.Question
        }
        function Write-Tmp([string]$name, [string]$text, [bool]$bom = $false) {
            $p = Join-Path $tmp $name
            $enc = New-Object Text.UTF8Encoding $bom
            [IO.File]::WriteAllText($p, $text, $enc)
            return $p
        }

        # offline + no cache -> null, not fetched
        $miss = Get-LcCachedQuestion -TestsDir $tmp -Slug 'no-such' -Offline
        Assert-True ($null -eq $miss.Question -and -not $miss.Fetched) 'offline miss'

        # "no such problem" is cached as tests/.meta/<slug>.none; network errors are not (stubbed fetch)
        & {
            $calls = @{ n = 0; missing = $true }
            function Get-LcQuestion([string]$Slug) {
                $calls.n++
                $script:LcFetchMissing = $calls.missing
                $script:LcFetchError = if ($calls.missing) { "no such problem: $Slug" } else { 'timed out' }
                return $null
            }
            $r1 = Get-LcCachedQuestion -TestsDir $tmp -Slug 'my-scratch'
            Assert-True ($null -eq $r1.Question -and $r1.Tried -and -not $r1.Fetched) 'missing: first call tries'
            Assert-True (Test-Path -LiteralPath (Join-Path $tmp '.meta\my-scratch.none')) 'missing: marker written'
            $r2 = Get-LcCachedQuestion -TestsDir $tmp -Slug 'my-scratch'
            Assert-True ($null -eq $r2.Question -and -not $r2.Tried) 'missing: marker skips the fetch'
            Assert-Equal $calls.n 1 'missing: fetched once'

            $calls.missing = $false
            $r3 = Get-LcCachedQuestion -TestsDir $tmp -Slug 'flaky'
            Assert-True ($null -eq $r3.Question -and $r3.Tried) 'network error: tried'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp '.meta\flaky.none'))) 'network error: no marker'
            $null = Get-LcCachedQuestion -TestsDir $tmp -Slug 'flaky'
            Assert-Equal $calls.n 3 'network error: retried'
        }

        # html conversion
        Assert-Equal (ConvertFrom-LcHtml '<p>10<sup>5</sup> &lt;= <code>k</code>&nbsp;x</p><ul><li>a</li><li>b</li></ul>') "10^5 <= k x`na`nb"

        $rotQ = Get-Fixture 'rotate-array'
        $rot = Get-LcInfoFromMeta $rotQ.metaData
        $expected = @(
            '# Rotate Array (#189, Medium) https://leetcode.com/problems/rotate-array/',
            'Constraints:',
            '1 <= nums.length <= 10^5',
            '-2^31 <= nums[i] <= 2^31 - 1',
            '0 <= k <= 10^5',
            '',
            'Example 1:',
            'Input: nums = [1,2,3,4,5,6,7], k = 3',
            'Output: [5,6,7,1,2,3,4]',
            '',
            'Example 2:',
            'Input: nums = [-1,-100,3,99], k = 2',
            'Output: [3,99,-1,-100]') -join "`n"
        $rotText = New-LcTestFileText -Question $rotQ -Info $rot
        Assert-Equal $rotText $expected 'rotate-array test file'

        # any-order
        $twoQ = Get-Fixture 'two-sum'
        $twoText = New-LcTestFileText -Question $twoQ -Info (Get-LcInfoFromMeta $twoQ.metaData)
        Assert-True (($twoText -split "`n") -contains 'compare: any-order') 'two-sum any-order'
        Assert-True (-not (($rotText -split "`n") -contains 'compare: any-order')) 'rotate has no any-order'

        # design layout
        $lruQ = Get-Fixture 'lru-cache'
        $lruText = New-LcTestFileText -Question $lruQ -Info (Get-LcInfoFromMeta $lruQ.metaData)
        $lruLines = $lruText -split "`n"
        $k = [array]::IndexOf($lruLines, 'Input')
        Assert-True ($k -ge 0) 'lru Input line'
        Assert-Equal $lruLines[$k + 1] '["LRUCache","put","put","get","put","get","put","get","get","get"]'
        Assert-Equal $lruLines[$k + 2] '[[2],[1,1],[2,2],[1],[3,3],[2],[4,4],[1],[3],[4]]'
        Assert-Equal $lruLines[$k + 3] 'Output'
        Assert-Equal $lruLines[$k + 4] '[null, null, null, 1, null, -1, null, -1, 3, 4]'

        # parser: raw paste of LeetCode page text
        $paste = @'
Example 1:

Input: nums = [1,2,3,4,5,6,7], k = 3
Output: [5,6,7,1,2,3,4]
Explanation:
rotate 1 steps to the right: [7,1,2,3,4,5,6]
rotate 2 steps to the right: [6,7,1,2,3,4,5]
rotate 3 steps to the right: [5,6,7,1,2,3,4]
'@
        $r = Read-LcTestFile -Path (Write-Tmp 'paste.txt' $paste) -Info $rot
        Assert-Equal $r.Cases.Count 1
        Assert-Equal ($r.Cases[0].Args -join '|') '[1,2,3,4,5,6,7]|3'
        Assert-Equal $r.Cases[0].Expected '[5,6,7,1,2,3,4]'

        # parser: own cases, no Output, comment ignored
        $r = Read-LcTestFile -Path (Write-Tmp 'own.txt' "# a comment`nInput: nums = [5], k = 0`n") -Info $rot
        Assert-Equal $r.Cases.Count 1
        Assert-True ($null -eq $r.Cases[0].Expected) 'no Output -> null'
        Assert-Equal ($r.Cases[0].Args -join '|') '[5]|0'

        # parser: multi-line value
        $r = Read-LcTestFile -Path (Write-Tmp 'ml.txt' "Input: nums = [1,`n2,3], k = 1`n") -Info $rot
        Assert-Equal $r.Cases[0].Args[0] '[1,2,3]'
        Assert-Equal $r.Cases[0].Args[1] '1'

        # parser: design layout without colons
        $design = "Input`n[`"LRUCache`", `"get`"]`n[[2], [1]]`nOutput`n[null, -1]`n"
        $lruInfo = Get-LcInfoFromMeta $lruQ.metaData
        $r = Read-LcTestFile -Path (Write-Tmp 'design.txt' $design) -Info $lruInfo
        Assert-Equal $r.Cases.Count 1
        Assert-Equal $r.Cases[0].Args.Count 2
        Assert-Equal $r.Cases[0].Args[0] '["LRUCache", "get"]'
        Assert-Equal $r.Cases[0].Args[1] '[[2], [1]]'
        Assert-Equal $r.Cases[0].Expected '[null, -1]'

        # parser: CRLF and BOM give the same object
        $plain = Read-LcTestFile -Path (Write-Tmp 'plain.txt' $rotText) -Info $rot
        $crlf = Read-LcTestFile -Path (Write-Tmp 'crlf.txt' ($rotText -replace "`n", "`r`n") $true) -Info $rot
        Assert-Equal ($crlf | ConvertTo-Json -Depth 5) ($plain | ConvertTo-Json -Depth 5)
        Assert-Equal $plain.Cases.Count 2
        Assert-Equal ($plain.Constraints -join '|') '1 <= nums.length <= 10^5|-2^31 <= nums[i] <= 2^31 - 1|0 <= k <= 10^5'
        Assert-True (-not $plain.AnyOrder) 'rotate not any-order'
        $tw = Read-LcTestFile -Path (Write-Tmp 'two.txt' $twoText) -Info (Get-LcInfoFromMeta $twoQ.metaData)
        Assert-True $tw.AnyOrder 'two-sum any-order parsed'

        # parser: any-order only from an explicit compare line
        $r = Read-LcTestFile -Path (Write-Tmp 'ao1.txt' "Input: nums = [5], k = 0`nOutput: [5]`nExplanation: the answer may be in any order`n") -Info $rot
        Assert-True (-not $r.AnyOrder) 'Explanation prose must not set any-order'
        $r = Read-LcTestFile -Path (Write-Tmp 'ao2.txt' "# not any order`nInput: nums = [5], k = 0`n") -Info $rot
        Assert-True (-not $r.AnyOrder) 'comment must not set any-order'

        # parser: commas inside strings
        $sInfo = [pscustomobject]@{ Kind = 'function'; Method = 'f'; ParamNames = [string[]]@('s', 'k'); ParamTypes = [string[]]@('string', 'int'); OutParam = -1 }
        $r = Read-LcTestFile -Path (Write-Tmp 'str.txt' 'Input: s = "a, b = c", k = 1') -Info $sInfo
        Assert-Equal $r.Cases[0].Args[0] '"a, b = c"'
        Assert-Equal $r.Cases[0].Args[1] '1'

        # paid-only
        $paid = [pscustomobject]@{ questionFrontendId = '1'; title = 'Paid'; titleSlug = 'paid'; difficulty = 'Hard'
            isPaidOnly = $true; content = $null; exampleTestcaseList = @() }
        $paidText = New-LcTestFileText -Question $paid -Info $rot
        Assert-Equal $paidText "# Paid (#1, Hard) https://leetcode.com/problems/paid/`nConstraints:"
        $r = Read-LcTestFile -Path (Write-Tmp 'paid.txt' $paidText) -Info $rot
        Assert-Equal $r.Cases.Count 0

        # input line
        Assert-Equal (Format-LcInputLine -Info $rot -Args @('[1,2]', '3')) 'Input: nums = [1,2], k = 3'

        # cases file
        $cf = Join-Path $tmp 'cases.txt'
        Write-LcCasesFile -Cases $plain.Cases -Kind function -Path $cf
        $want = "case 1`narg [1,2,3,4,5,6,7]`narg 3`nexpect [5,6,7,1,2,3,4]`nend`ncase 2`narg [-1,-100,3,99]`narg 2`nexpect [3,99,-1,-100]`nend`n"
        Assert-Equal ([IO.File]::ReadAllText($cf)) $want
        $dcf = Join-Path $tmp 'dcases.txt'
        $dr = Read-LcTestFile -Path (Write-Tmp 'lru.txt' $lruText) -Info $lruInfo
        Write-LcCasesFile -Cases $dr.Cases -Kind design -Path $dcf
        $dl = [IO.File]::ReadAllText($dcf) -split "`n"
        Assert-Equal $dl[0] 'case 1'
        Assert-Equal $dl[1] 'ops ["LRUCache","put","put","get","put","get","put","get","get","get"]'
        Assert-Equal $dl[2] 'args [[2],[1,1],[2,2],[1],[3,3],[2],[4,4],[1],[3],[4]]'
        Assert-Equal $dl[3] 'expect [null, null, null, 1, null, -1, null, -1, 3, 4]'
        Assert-Equal $dl[4] 'end'
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
