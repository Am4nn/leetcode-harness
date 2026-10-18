# Tests for the label-column output helpers: g++ diagnostics (.zed/lc/build.ps1) and the analyze growth
# table (.zed/lc/analyze.ps1). Dot-sourced by run-all.ps1; body wrapped to keep the caller's variables intact.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repo '.zed\common.ps1')
    . (Join-Path $repo '.zed\lc\build.ps1')
    . (Join-Path $repo '.zed\lc\analyze.ps1')

    $show = { param($entries) (@($entries) | ForEach-Object { if ($null -eq $_.Label) { "<$($_.Text)>" } else { "$($_.Label)|$($_.Text)" } }) -join "`n" }

    # Real g++ 16 output (paths swapped): context lines, aka, -W flags, carets, a note in the same file,
    # an error in the generated user TU, a fix-it line, a duplicate and a linker line.
    $sol = 'C:/x/lc self test/sol.cpp'
    $gpp = @(
        'In file included from C:/b/lc/sol-1234abcd/bench-user.cpp:1:'
        "${sol}: In member function 'int Solution::f(std::vector<int>&, int)':"
        "${sol}:9:30: warning: comparison of integer expressions of different signedness: 'size_t' {aka 'long long unsigned int'} and 'int' [-Wsign-compare]"
        '    9 |         for (size_t i = 0; i < n; ++i) n += v[i];'
        '      |                            ~~^~~'
        "${sol}:10:17: error: too few arguments to function 'int g(int, int)'"
        '   10 |         return g(n);'
        '      |                ~^~~'
        "${sol}:4:5: note: declared here"
        '    4 | int g(int a, int b) { return a + b; }'
        '      |     ^'
        "${sol}:4:5: note: declared here"
        "C:/msys64/ucrt64/include/c++/16/bits/stl_vector.h:1263:7: note: candidate: 'void push_back()'"
        "C:/b/lc/sol-1234abcd/bench-user.cpp: In function 'int lc_user_call()':"
        "C:/b/lc/sol-1234abcd/bench-user.cpp:2:30: error: expected ';' before '}' token"
        '    2 | int lc_user_call() { return 0 }'
        '      |                              ^~'
        '      |                              ;'
        "${sol}: At global scope:"
        "${sol}:1:1: fatal error: oops"
        'C:/msys64/ucrt64/bin/ld.exe: bench-user.o: undefined reference to `foo'''
    ) -join "`r`n"
    $want = @(
        "warning|line 9: comparison of integer expressions of different signedness: 'size_t' and 'int'"
        '|    for (size_t i = 0; i < n; ++i) n += v[i];'
        "error|line 10: too few arguments to function 'int g(int, int)'"
        '|    return g(n);'
        'note|line 4: declared here'
        '|    int g(int a, int b) { return a + b; }'
        'note|line 4: declared here'
        "note|stl_vector.h line 1263: candidate: 'void push_back()'"
        "error|harness line 2: expected ';' before '}' token"
        '|    int lc_user_call() { return 0 }'
        'error|line 1: oops'
        '<C:/msys64/ucrt64/bin/ld.exe: bench-user.o: undefined reference to `foo''>'
    ) -join "`n"
    $got = & $show (Format-LcGppDiagnostics $gpp 'C:\x\lc self test\sol.cpp')
    Assert-Equal $got $want "g++ diagnostics`n$got"
    Assert-True ($got -notmatch '-user\.cpp') 'diagnostics name the generated user TU'
    # Consecutive duplicates collapse; the same line apart from its neighbour stays.
    Assert-Equal (& $show (Format-LcGppDiagnostics "${sol}:4:5: note: x`n${sol}:4:5: note: x`n${sol}:5:5: note: x" $sol)) "note|line 4: x`nnote|line 5: x"
    # Without -SrcPath every location names its file.
    Assert-Equal (& $show (Format-LcGppDiagnostics "${sol}:3:1: error: bad")) 'error|sol.cpp line 3: bad'
    Assert-Equal @(Format-LcGppDiagnostics '').Count 0

    # Growth table: at most 5 points (smallest, largest, 3 evenly by index), two aligned rows.
    $pts = @(195, 390, 781, 1562, 3125, 6250, 12500, 25000, 50000, 100000 | ForEach-Object { @{ n = $_; ms = $_ * 6e-7 } })
    Assert-Equal (@(Select-LcShownPoints $pts | ForEach-Object { $_.n }) -join ',') '195,781,6250,25000,100000'
    Assert-Equal (@(Select-LcShownPoints $pts[0..3] | ForEach-Object { $_.n }) -join ',') '195,390,781,1562'
    Assert-Equal (@(Select-LcShownPoints $pts[0..5] | ForEach-Object { $_.n }) -join ',') '195,390,1562,3125,6250'
    Assert-Equal @(Select-LcShownPoints @($pts[0])).Count 1
    $t = @(Format-LcPointsTable @(@{ n = 195; ms = 0.0002 }, @{ n = 1562; ms = 0.0009 }, @{ n = 12500; ms = 0.02 }, @{ n = 100000; ms = 0.06 }))
    Assert-Equal $t[0] 'n     195    1562   12500   100000'
    Assert-Equal $t[1] 'time  0.2us  0.9us  0.02ms  0.06ms'
    $t = @(Format-LcPointsTable @(@{ n = 8; ms = 0.5; per_call_us = 62.5 }, @{ n = 2000; ms = 0.5; per_call_us = 0.25 }) -PerCall)
    Assert-Equal ($t -join '|') 'n         8       2000|per call  62.5us  0.25us'
}
