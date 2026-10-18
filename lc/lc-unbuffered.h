// Force-included into logged F7 / Shift+F7 runs (.zed/run-cpp.ps1 -LogRun). The run log pipes the
// program's stdout, and a piped stdout is fully buffered: prints before a crash would be lost.
// LC_STDERR_TO_STDOUT=1 (set by Start-Measured -TeeTo) also sends stderr down stdout's pipe, so cout and
// cerr lines reach the terminal and the log in the order they were printed.
#pragma once
#include <cstdio>
#include <cstdlib>

// io.h's declaration, repeated so the program doesn't get io.h's other names (read, write, dup, ...).
extern "C" _CRTIMP int __cdecl _dup2(int, int);

[[maybe_unused]] static const int lc_unbuffered_stdout = [] {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    if (const char* v = std::getenv("LC_STDERR_TO_STDOUT"); v && v[0] == '1') _dup2(_fileno(stdout), _fileno(stderr));
    return 0;
}();
