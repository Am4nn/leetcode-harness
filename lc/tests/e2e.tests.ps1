# End-to-end tests for .zed/lc.ps1 (LeetCode test task), run on a temp copy of lc/selftest.
# Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $lcPs1 = Join-Path $repo '.zed\lc.ps1'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path $env:TEMP 'lc self test'  # the space is deliberate
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
    Copy-Item -Recurse (Join-Path $repo 'lc\selftest') $tmp
    $journey = Join-Path $tmp 'journey'

    function Invoke-Lc([string]$File, [string[]]$Extra = @(), [string]$Stdin = '') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = $Stdin | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -JourneyRoot $journey @Extra $File 2>&1 | Out-String
        $code = $LASTEXITCODE
        $sw.Stop()
        return @{ Out = $out; Code = $code; Ms = $sw.ElapsedMilliseconds }
    }

    try {
        # Make the first two-sum run compile even when an earlier suite run left a matching stamp.
        $twoSum = Join-Path $tmp 'two-sum.cpp'
        [IO.File]::AppendAllText($twoSum, "// $([guid]::NewGuid())`n", $utf8)

        $titles = @{
            'two-sum' = 'Two Sum'; 'concatenation-of-array' = 'Concatenation of Array'; 'rotate-array' = 'Rotate Array'
            'maximum-depth-of-binary-tree' = 'Maximum Depth of Binary Tree'; 'reverse-linked-list' = 'Reverse Linked List'
            'lru-cache' = 'LRU Cache'; 'climbing-stairs' = 'Climbing Stairs'
        }
        $firstTwoSum = $null
        foreach ($slug in 'two-sum', 'concatenation-of-array', 'rotate-array', 'maximum-depth-of-binary-tree',
                          'reverse-linked-list', 'lru-cache', 'climbing-stairs') {
            $r = Invoke-Lc (Join-Path $tmp "$slug.cpp")
            Assert-Equal $r.Code 0 "e2e: $slug exit code`n$($r.Out)"
            Assert-Match $r.Out '\d+/\d+ passed'
            Assert-True ($r.Out -notmatch '(?m)^\s*FAIL\b') "e2e: $slug has FAIL lines`n$($r.Out)"
            $tf = Join-Path $tmp "tests\$slug.txt"
            Assert-True (Test-Path -LiteralPath $tf) "e2e: tests/$slug.txt not created"
            Assert-True ([IO.File]::ReadAllText($tf).StartsWith("# $($titles[$slug]) (#")) "e2e: tests/$slug.txt header"
            if ($slug -eq 'two-sum') { $firstTwoSum = $r }
            if ($slug -eq 'concatenation-of-array') {
                # e2e: debug prints don't break results
                Assert-Match $r.Out 'debug!'
                Assert-Match $r.Out '2/2 passed'
                Assert-Match $r.Out '(?m)^concatenation-of-array  \(#1929 Easy - Array, Simulation\)\s*$'
            }
        }

        # e2e: rerun skips compile
        $exe = Join-Path $repo 'build\lc\two-sum\test.exe'
        $mtime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $r = Invoke-Lc $twoSum
        Assert-Equal $r.Code 0 "e2e: two-sum rerun`n$($r.Out)"
        Assert-Equal (Get-Item -LiteralPath $exe).LastWriteTimeUtc $mtime 'e2e: rerun must not rebuild the exe'
        Assert-True ($r.Ms -lt $firstTwoSum.Ms) "e2e: rerun $($r.Ms) ms not faster than first run $($firstTwoSum.Ms) ms"

        # Build-LcExe reports Skipped on an unchanged rebuild.
        & {
            . (Join-Path $repo '.zed\common.ps1')
            . (Join-Path $repo '.zed\lc\build.ps1')
            $scratch = Join-Path $tmp 'my-scratch.cpp'
            $w = '#include "' + ($scratch -replace '\\', '/') + "`"`nint main(int argc, char** argv) { return lc::run_function(argc, argv, &Solution::add, {`"a`",`"b`"}, -1); }`n"
            $b1 = Build-LcExe -Slug 'my-scratch' -SrcPath $scratch -WrapperText $w -Flavor test -Name 'unit'
            Assert-True $b1.Ok "Build-LcExe failed: $($b1.Errors)"
            $b2 = Build-LcExe -Slug 'my-scratch' -SrcPath $scratch -WrapperText $w -Flavor test -Name 'unit'
            Assert-True ($b2.Ok -and $b2.Skipped) 'second Build-LcExe must be Skipped'
            Assert-True (Test-Path -LiteralPath $b2.Exe) 'skipped build keeps the exe'
            $pch = Initialize-LcPch -Flavor test
            Assert-Match ([IO.File]::ReadAllText($pch)) 'lc-prelude\.h'
        }

        # e2e: method mismatch
        $mm = Join-Path $tmp 'mismatch'
        New-Item -ItemType Directory -Force (Join-Path $mm 'tests\.meta') | Out-Null
        Copy-Item (Join-Path $repo 'leetcode-solves\concatenation-of-array.cpp') $mm
        Copy-Item (Join-Path $tmp 'tests\.meta\concatenation-of-array.json') (Join-Path $mm 'tests\.meta')
        $r = Invoke-Lc (Join-Path $mm 'concatenation-of-array.cpp')
        Assert-True $r.Out.Contains('LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)') "e2e: method mismatch`n$($r.Out)"

        # e2e: timeout names the running case
        $r = Invoke-Lc (Join-Path $tmp 'slow\climbing-stairs.cpp') @('-TimeoutMs', '2000')
        Assert-Match $r.Out 'TIMEOUT 1: still running after 2 s'
        Assert-Equal $r.Code 1 "e2e: timeout exit code`n$($r.Out)"
        Assert-True ($r.Ms -lt 15000) "e2e: timeout run took $($r.Ms) ms"

        # e2e: crash line
        $crashSrc = Join-Path $tmp 'crash\rotate-array.cpp'
        $line = (Select-String -LiteralPath $crashSrc -Pattern 'nums\[nums\.size\(\)\]').LineNumber
        $r = Invoke-Lc $crashSrc
        Assert-Match $r.Out 'CRASH 1'
        Assert-Match $r.Out "crashed at\s+line $line\b"
        Assert-Equal $r.Code 1 'e2e: crash exit code'

        # e2e: typed input
        $r = Invoke-Lc (Join-Path $tmp 'my-scratch.cpp') -Stdin "2`n3`n`n"
        Assert-True $r.Out.Contains('----  1  5') "e2e: typed input`n$($r.Out)"
        Assert-Match ([IO.File]::ReadAllText((Join-Path $tmp 'tests\my-scratch.txt'))) '(?m)^Input: a = 2, b = 3\s*$'

        # e2e: unsupported type
        $r = Invoke-Lc (Join-Path $tmp 'odd\my-map.cpp')
        Assert-Match $r.Out "parameter type the harness doesn't support"
        Assert-True ($r.Out -notmatch 'required from') "e2e: unsupported type shows the template dump`n$($r.Out)"
        Assert-Equal $r.Code 1 'e2e: unsupported type exit code'
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
