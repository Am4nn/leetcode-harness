// Force-included into logged F7 / Shift+F7 runs (.zed/run-cpp.ps1 -LogRun). The run log pipes the
// program's stdout, and a piped stdout is fully buffered: prints before a crash would be lost.
#pragma once
#include <cstdio>

[[maybe_unused]] static const int lc_unbuffered_stdout = (std::setvbuf(stdout, nullptr, _IONBF, 0), 0);
