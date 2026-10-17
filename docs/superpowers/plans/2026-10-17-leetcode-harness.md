# LeetCode Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two Zed tasks: Alt+F7 runs a pure LeetCode solution file against auto-fetched examples, and Alt+F8 analyzes how it scales. Both record every action to a journey event log.

**Architecture:**
- **PowerShell** does all text and process work: fetch, test-file parsing, wrapper generation, building, display, events.
- **A header-only C++ runner (`lc/`)** gets `#include`d after the user's solution in a generated wrapper. It parses typed values, calls the method through a member pointer, and writes JSON-lines results to a file. The user's own `cout` output therefore never mixes with the results.
- **PowerShell and C++ talk only through three plain-text files:** a cases file, a spec file and a results file. Each format is defined once below.

**Tech Stack:**
- Windows PowerShell 5.1
- MSYS2 UCRT64 GCC 16.2 (`C:\msys64\ucrt64\bin`), C++23, precompiled headers
- LeetCode public GraphQL (no auth)
- Zed tasks and keymap

**Spec:** `docs/2026-10-17-leetcode-harness-design.md`. Read it before starting any task.

## Global Constraints

- **Branch:** work on branch `lc-harness`, created from `main` (ceb911e) in Task 1. Commit at the end of every task, and end each commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Compiler:** call `C:\msys64\ucrt64\bin\g++.exe` and `gdb.exe` by full path, and prepend `C:\msys64\ucrt64\bin` to `$env:Path` inside scripts. Zed holds a stale PATH.
- **PowerShell:**
  - Scripts must run on Windows PowerShell 5.1: no `&&`, `??` or ternary operators, and `ConvertFrom-Json` returns PSCustomObject.
  - Keep `.ps1` files **ASCII-only**, because PS 5.1 reads BOM-less files as ANSI. Complexity labels are therefore ASCII: `O(1)`, `O(log n)`, `O(n)`, `O(n log n)`, `O(n^2)`, `O(n^3)`, `O(2^n)`.
  - Write every text file with `[IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))` (or the `AppendAllText` equivalent): UTF-8, **no BOM**.
- **Test build flags:** exactly `run-cpp.ps1`'s set, i.e. `-std=c++23 -Wall -Wextra -Wshadow -O2 -g -static -D_GLIBCXX_ASSERTIONS -fsanitize=undefined -fsanitize-undefined-trap-on-error -Wl,--stack,268435456`. Never use `_GLIBCXX_DEBUG`.
- **Bench build flags:** `-std=c++23 -O2 -static -Wl,--stack,268435456`, with no checks.
- **F7, Shift+F7, Ctrl+F7 and Alt+A must behave exactly as before**, with one exception (user decision, Task 5): checking a file without `main()` adds `-include <dsa>/lc/lc-prelude.h`.
- **The spec's "Decisions after approval" section overrides anything earlier in the spec.**
- **No LeetCode login, cookie or token, ever.** Endpoint: `POST https://leetcode.com/graphql`, header `Referer: https://leetcode.com`.
- **Defaults and limits:**
  - Test-mode run timeout: 30 s, configurable via `-TimeoutMs`.
  - Analyze per-run cap: 2000 ms.
  - TLE budget: about 1 s. `<= 500 ms` is `ok`, `500-1000 ms` is `borderline`, `> 1000 ms` is `likely TLE`.
  - Double compare tolerance: 1e-5.
- **Missing constraints:** assume length/size max 10^5 and int values in ±10^9, and print `(assumed: no constraint found for <name>)`.
- **Event log:** `<JourneyRoot>/events.jsonl` (default `dsa/journey`) is append-only. Timestamps are `yyyy-MM-ddTHH:mm:sszzz`.

## Shared file formats (PowerShell ↔ C++)

**Cases file** (written by PS, read by C++). Line-based; each value fits on one line:
```
case 1
arg [1,2,3,4,5,6,7]
arg 3
expect [5,6,7,1,2,3,4]
end
case 2
ops ["LRUCache","put","get"]
args [[2],[1,1],[1]]
end
```
`expect` is optional. Function cases use `arg` lines in parameter order; design cases use `ops` + `args`.

**Results file** (written by C++, read by PS). One JSON object per line:
- Before each case: `{"n":1,"status":"start"}`.
- After it: `{"n":1,"status":"pass|fail|print|error","got":"[...]","expected":"[...]","ms":0.012,"diff":"...","error":"..."}`. Keys whose value would be empty are omitted.
- If a `start` line has no completion line, the case crashed or timed out.

**Spec file** (written by PS, read by C++). One directive per line:
```
size nums
param nums len 1 100000 val -2147483648 2147483647
param k val 0 100000
param s chars abcdefghijklmnopqrstuvwxyz
param n eqlen nums
param arr len 1 10000 val -10000 10000 sorted distinct
calls 200000
```
- `param` takes key/value groups in any order: `len a b`, `val a b`, `chars S`, `eqlen other`, and the bare flags `sorted` and `distinct`.
- `size` names the parameter that n drives.
- `calls` gives the maximum call count for design problems.

**Runner CLI:** every wrapper exe supports these modes:
- `test <cases> <results> [--any-order]`
- `bench <spec> <results> --seed S --max-ms M`
- `profile <spec> <results> --n N --seed S`
- `gen <spec> <out-cases> --count C --max-n N --seed S`

## Review Focus

1. **The solution prints its own debug output with `cout`.** Results must still parse, and the prints should appear above the result table. Test: Task 8 `e2e: debug prints don't break results`.
2. **Paths containing spaces.** The old folder was `c++ language`, and Zed may pass the path split into several arguments. Test: Task 8 e2e copies fixtures into a temp folder named `lc self test`.
3. **LeetCode starter code with no `#include`, no `using namespace std`, and the commented-out `TreeNode` block.** It should compile and show no false errors in clangd. Tests: Task 1 clangd check; Task 8 `maximum-depth-of-binary-tree` fixture.
4. **An infinite loop or a hopelessly slow solution in test mode.** The task should stop after the timeout and say which case was running, not hang forever. Test: Task 8 `e2e: timeout names the running case`.
5. **A test file saved with CRLF line endings and/or a UTF-8 BOM** (e.g. edited in Notepad). It should parse identically. Test: Task 7 `parser: CRLF and BOM`.

---

### Task 1: Prelude, editor support, and test runner

**Files:**
- Create: `lc/lc-prelude.h`, `lc/tests/check.h`, `lc/tests/run-all.ps1`, `lc/tests/assert.ps1`, `lc/tests/prelude.test.cpp`, `lc/selftest/maximum-depth-of-binary-tree.cpp`
- Modify: `.clangd` (append a fragment), `.gitignore`

**Interfaces:**
- Produces:
  - `lc/lc-prelude.h`: `#include <bits/stdc++.h>`, `using namespace std;`, and LeetCode's exact `struct TreeNode { int val; TreeNode *left; TreeNode *right; TreeNode(); TreeNode(int x); TreeNode(int x, TreeNode *left, TreeNode *right); };` and `struct ListNode { int val; ListNode *next; ListNode(); ListNode(int x); ListNode(int x, ListNode *next); };`. All constructors are inline. Include guard `LC_PRELUDE_H`.
  - `lc/tests/check.h`: macros `CHECK(cond)` and `CHECK_EQ(a, b)`. On failure they print `file:line` and both values, then increment a global `lc_test_failures`. `int lc_test_result()` prints `N failures` or `all passed` and returns the failure count.
  - `lc/tests/assert.ps1`: `Assert-Equal $actual $expected [$message]` and `Assert-True $cond [$message]`. Both throw on failure. `Assert-Match $text $regex`.
  - `lc/tests/run-all.ps1 [-Only <name>]`:
    - compiles each `lc/tests/*.test.cpp` with the test build flags, with `-I lc` and `-include lc/lc-prelude.h`, into `build/tests/`, and runs it;
    - dot-sources each `lc/tests/*.tests.ps1`;
    - prints `PASS <name>` or `FAIL <name>` per file and exits 1 if any failed.
    - `-Only io` runs just `io.test.cpp` or `io.tests.ps1`.

- [ ] **Step 0: Create the branch.** Run `git checkout -b lc-harness`.
- [ ] **Step 1: Write the failing test** `lc/tests/prelude.test.cpp`:
  ```cpp
  #include "tests/check.h"
  int main() {
      TreeNode t(1, new TreeNode(2), nullptr);
      CHECK_EQ(t.left->val, 2);
      ListNode l(3); CHECK(l.next == nullptr);
      vector<int> v{1}; CHECK_EQ(v.size(), 1u);   // using namespace std works
      return lc_test_result();
  }
  ```
- [ ] **Step 2: Run** `powershell -NoProfile -ExecutionPolicy Bypass -File lc/tests/run-all.ps1 -Only prelude`. **Expected:** FAIL, because `lc-prelude.h` doesn't exist yet.
- [ ] **Step 3: Implement `lc/lc-prelude.h`.** The test file includes `tests/check.h` relative to `-I lc`.
- [ ] **Step 4: Run** the same command. **Expected:** `PASS prelude`.
- [ ] **Step 5: Add the fixture** `lc/selftest/maximum-depth-of-binary-tree.cpp`. It is exact LeetCode starter style: the commented `/** Definition for a binary tree node. ... */` block, **no** `#include`, `class Solution { public: int maxDepth(TreeNode* root) {...} };`, solved recursively.
- [ ] **Step 6: Append a clangd fragment** to `.clangd`, separated by a `---` line:
  ```yaml
  ---
  If:
    PathMatch: [leetcode-solves/.*, lc/selftest/.*]
  CompileFlags:
    Add: [-include, C:/Aman/Coding-Bamzii/dsa/lc/lc-prelude.h]
  ```
- [ ] **Step 7: Verify clangd.** Run the newest `%LOCALAPPDATA%\Zed\languages\clangd\clangd_*\bin\clangd.exe --check=lc/selftest/maximum-depth-of-binary-tree.cpp`. **Expected:** output ends with `All checks completed, 0 errors`. Also re-run it on `leetcode-solves/concatenation-of-array.cpp`; **Expected:** 0 errors.
- [ ] **Step 8:** Add `build/` subfolders only if they aren't already ignored. `build/` is already in `.gitignore`, so there is nothing to add unless a test writes elsewhere.
- [ ] **Step 9: Commit:** `git add lc .clangd && git commit -m "lc: prelude, clangd support for LeetCode files, test runner"`

### Task 2: Value parsing, printing and comparison (`lc/lc-io.h`)

**Files:**
- Create: `lc/lc-io.h`
- Test: `lc/tests/io.test.cpp`

**Interfaces:**
- Produces (all in `namespace lc`):
  - `struct ParseError : std::runtime_error`
  - `template<class T> T parse(std::string_view text);` Supports `int`, `long long`, `double`, `bool`, `char`, `std::string`, `std::vector<U>` (nested), `TreeNode*` and `ListNode*`.
    - Whitespace and newlines anywhere are allowed.
    - Throws `ParseError` with a short message on bad input.
    - Any other `T` hits `static_assert(always_false<T>, "lc: unsupported parameter type")`.
  - `template<class T> std::string show(const T& v);` gives canonical LeetCode text:
    - no spaces;
    - strings and chars double-quoted, with `"` and `\` escaped;
    - doubles with 5 decimals;
    - trees in level order, with trailing `null`s trimmed and an empty tree as `[]`;
    - lists as `[1,2]`.
  - `template<class T> bool equal(const T& got, const T& want, bool any_order);` compares doubles within 1e-5 (also inside vectors). With `any_order`, order is ignored at every nesting level: recursively sort each inner vector (by `show` of its elements), then compare the outer vector as a multiset.
  - `template<class T> std::string describe_diff(const T& got, const T& want);` returns `""` for non-vectors.
  - `std::vector<std::string> split_top_level(std::string_view list_text);` turns `[[2],[1,1],[]]` into `{"[2]","[1,1]","[]"}`, respecting quotes and nesting.
  - `std::string json_escape(std::string_view);`

- [ ] **Step 1: Write the failing tests** `lc/tests/io.test.cpp`, including `lc-io.h`:
  ```cpp
  using namespace lc;
  CHECK((parse<vector<int>>(" [1, 2,\n 3] ") == vector<int>{1,2,3}));
  CHECK_EQ(show(vector<int>{1,2,3}), "[1,2,3]");
  CHECK_EQ(show(parse<vector<vector<int>>>("[[1,2],[]]")), "[[1,2],[]]");
  CHECK_EQ(parse<string>("\"a,b\\\"c\""), "a,b\"c");
  CHECK_EQ(show(string("a\"b")), "\"a\\\"b\"");
  CHECK_EQ(parse<char>("\"x\""), 'x');   CHECK_EQ(show('x'), "\"x\"");
  CHECK(parse<bool>("true"));             CHECK_EQ(show(false), "false");
  CHECK_EQ(parse<long long>("-9000000000"), -9000000000LL);
  CHECK_EQ(show(2.0), "2.00000");
  CHECK(equal(1.000001, 1.0, false));     CHECK(!equal(1.1, 1.0, false));
  CHECK_EQ(show(parse<TreeNode*>("[3,9,20,null,null,15,7]")), "[3,9,20,null,null,15,7]");
  CHECK_EQ(show(parse<TreeNode*>("[1,null,2]")), "[1,null,2]");
  CHECK(parse<TreeNode*>("[]") == nullptr);   CHECK_EQ(show((TreeNode*)nullptr), "[]");
  CHECK_EQ(show(parse<ListNode*>("[1,2,3]")), "[1,2,3]");
  CHECK(parse<ListNode*>("[]") == nullptr);
  CHECK(equal(vector<int>{1,0}, vector<int>{0,1}, true));
  CHECK(!equal(vector<int>{1,0}, vector<int>{0,1}, false));
  CHECK(equal(vector<vector<int>>{{1,2},{3}}, {{3},{1,2}}, true));
  CHECK(equal(vector<vector<int>>{{2,1},{3}}, {{1,2},{3}}, true));    // inner order ignored too
  CHECK(!equal(vector<vector<int>>{{2,1},{3}}, {{1,2},{3}}, false));
  CHECK(equal(vector<vector<string>>{{"tan","nat"},{"bat"}}, {{"bat"},{"nat","tan"}}, true));
  CHECK_EQ(describe_diff(vector<int>{1,3,2,1,1,3,2}, vector<int>{1,3,2,1,1,3,2,1}),
           "first difference at index 7 (got 7 items, expected 8)");
  CHECK_EQ(describe_diff(vector<int>{1,9}, vector<int>{1,2}), "first difference at index 1");
  CHECK((split_top_level("[[2],[1,1],[]]") == vector<string>{"[2]","[1,1]","[]"}));
  CHECK((split_top_level("[\"a,]\",\"b\"]") == vector<string>{"\"a,]\"","\"b\""}));
  // throws: parse<vector<int>>("[1,2"), parse<int>("abc"), parse<bool>("yes")
  ```
- [ ] **Step 2: Run** `lc/tests/run-all.ps1 -Only io`. **Expected:** FAIL (compile error: no `lc-io.h`).
- [ ] **Step 3: Implement `lc/lc-io.h`.** Use a small recursive-descent reader over `string_view`, with a position, a `skip_ws()` and `expect(char)`. Trees are built breadth-first from the token list.
- [ ] **Step 4: Run** the tests. **Expected:** `PASS io`.
- [ ] **Step 5: Commit:** `git commit -m "lc: parse/show/compare LeetCode values"`

### Task 3: Runner, test mode for function problems (`lc/lc-run.h`, `lc/lc.h`)

**Files:**
- Create: `lc/lc-run.h`, `lc/lc.h` (aggregator: includes `lc-io.h`, `lc-run.h`, and the later `lc-alloc.h`, `lc-gen.h`, `lc-prof.h`)
- Test: `lc/tests/run.test.cpp`

**Interfaces:**
- Consumes: `parse`, `show`, `equal`, `describe_diff` and `json_escape` from Task 2.
- Produces:
  - `struct lc::Case { int n; std::vector<std::string> args; std::optional<std::string> expect; std::string ops, design_args; };`
  - `std::vector<lc::Case> lc::read_cases(const std::string& path);` reads the shared cases format.
  - `template<class S, class R, class... A> int lc::run_function(int argc, char** argv, R (S::*method)(A...), std::vector<std::string> param_names, int out_param = -1);`
    - The overload for `const` member functions is the same.
    - Handles `test` mode now. `bench`, `profile` and `gen` are added in Task 10; until then they return 2 with `mode not supported yet`.
    - Arguments are stored as `std::remove_cvref_t<A>`, parsed fresh per case, and passed by reference.
    - For `R == void`, the result shown and compared is argument `out_param`. When `out_param` is -1, it's the first parameter whose type is a non-const lvalue reference.
    - Time only the call itself, with `steady_clock`, reported in ms.
    - A C++ exception in a call becomes `status:"error","error":"exception: <what()>"`.
  - Exit codes: 0 when all cases were processed (pass/fail is in the file), 2 on usage or file errors.

- [ ] **Step 1: Write the failing tests** `lc/tests/run.test.cpp`. They define
  ```cpp
  struct Solution {
      vector<int> getConcatenation(vector<int>& nums) { auto r = nums; r.insert(r.end(), nums.begin(), nums.end()); return r; }
      void rotate(vector<int>& nums, int k) { k %= nums.size(); std::rotate(nums.begin(), nums.end() - k, nums.end()); }
      int boom(int) { throw std::runtime_error("bad"); }
      int byValue(string s) const { return s.size(); }
  };
  ```
  Then a helper writes a cases file to `build/tests/tmp/`, calls `run_function` with a built `argv`, and reads the results lines back. Assertions:
  - `getConcatenation` case `arg [1,2,1]`, `expect [1,2,1,1,2,1]` gives a line with `"status":"pass"` and a `"ms":` field. The line before it is `{"n":1,"status":"start"}`.
  - The same method with `expect [1,2,1,1,2]` gives `"status":"fail"`, `"got":"[1,2,1,1,2,1]"`, and `"diff":"first difference at index 5 (got 6 items, expected 5)"`.
  - A case without `expect` gives `"status":"print"` and `"got":"[1,2,1,1,2,1]"`.
  - `rotate` with `arg [1,2,3,4,5,6,7]`, `arg 3` gives `"got":"[5,6,7,1,2,3,4]"`. This covers void and the in-place out parameter.
  - `rotate` with only one `arg` gives `"status":"error"` and `"error":"expected 2 arguments (nums, k), got 1"`.
  - `rotate` with `arg [1,2` gives `"status":"error"`, with `"error"` starting `can't read nums:`.
  - `boom` gives `"error":"exception: bad"`.
  - `byValue` (const, by-value param) with `arg "abc"`, `expect 3` gives pass.
  - `--any-order`: `getConcatenation` on `[1,2]` with `expect [2,1,1,2]` gives pass with the flag and fail without it.
- [ ] **Step 2: Run** `run-all.ps1 -Only run`. **Expected:** FAIL (no `lc.h`).
- [ ] **Step 3: Implement `read_cases` and `run_function`** in `lc/lc-run.h`, and create `lc/lc.h`. Flush the results file after every line, so a crash leaves the `start` line on disk.
- [ ] **Step 4: Run** the tests. **Expected:** `PASS run` (and `PASS io` still).
- [ ] **Step 5: Commit:** `git commit -m "lc: runner test mode for function problems"`

### Task 4: Runner, design problems

**Files:**
- Modify: `lc/lc-run.h`
- Test: `lc/tests/design.test.cpp`

**Interfaces:**
- Produces:
  - `template<class C> struct lc::Method { std::vector<std::string> names; std::function<std::string(C&, const std::vector<std::string>& args)> call; std::function<bool(const std::string& got, const std::string& want)> same; };` `call` returns `show(result)`, or `"null"` for void. `same` parses both strings into the return type and uses `equal`.
  - `template<class C, class R, class... A> lc::Method<C> lc::method(R (C::*m)(A...), std::vector<std::string> names);` (plus a const overload)
  - `template<class C, class... CtorA> int lc::run_design(int argc, char** argv, std::vector<std::string> ctor_names, std::map<std::string, lc::Method<C>> methods);`
    - `test` mode: `ops[0]` is the class name and `args[0]` are the constructor args. `got` is the list of per-call results, e.g. `[null,null,7]`.
    - Compare element by element. The first mismatch gives `diff` `call 3 (get): got 7, expected 8`.

- [ ] **Step 1: Write the failing tests** with `struct Counter { int v; Counter(int start) : v(start) {} void add(int x) { v += x; } int get() { return v; } };` and `run_design<Counter, int>(..., {"start"}, {{"add", method(&Counter::add, {"x"})}, {"get", method(&Counter::get, {})}})`. Assertions:
  - `ops ["Counter","add","get"]`, `args [[5],[2],[]]`, `expect [null,null,7]` gives pass with `"got":"[null,null,7]"`.
  - `expect [null,null,8]` gives fail with `"diff":"call 3 (get): got 7, expected 8"`.
  - `ops ["Counter","mul"]` gives error `"unknown method mul"`.
  - `ops` with 3 entries and `args` with 2 gives error `"ops has 3 entries but args has 2"`.
  - No `expect` gives `print`.
- [ ] **Step 2: Run** `run-all.ps1 -Only design`. **Expected:** FAIL.
- [ ] **Step 3: Implement** using `split_top_level` on `ops` and `args`, and on each call's argument list.
- [ ] **Step 4: Run** the tests. **Expected:** `PASS design`.
- [ ] **Step 5: Commit:** `git commit -m "lc: runner for design problems"`

### Task 5: Extract shared PowerShell helpers from `run-cpp.ps1`

**Files:**
- Create: `.zed/common.ps1`, `lc/tests/common.tests.ps1`, `lc/tests/fixtures/` (`fast.cpp` returning 0 with no output, `echo-first-byte.cpp` printing the first stdin byte as a number, `forever.cpp` with `while(true){}`, `oob.cpp` with an out-of-range `vector::operator[]` on line 5 that reads `input.txt`)
- Modify: `.zed/run-cpp.ps1` (dot-source `common.ps1` and delete the moved code. The one behavior change: the `-fsyntax-only` check of a file without `main()` gets `-include <dsa>/lc/lc-prelude.h`.)

**Interfaces:**
- Produces (dot-sourced; all paths absolute):
  - Variables `$Gpp`, `$Gdb`, `$CppFlags` (`-std=c++23 -Wall -Wextra -Wshadow`), `$TestFlags` (`run-cpp`'s `$runFlags`) and `$BenchFlags` (`-O2 -static -Wl,--stack,268435456`). The PATH prepend also happens here.
  - `Finish([int]$code)`, unchanged.
  - `Explain([int]$code) -> string`, unchanged text.
  - `Start-Measured -Exe <path> [-ArgumentList <string[]>] [-StdinFile <path>] [-TimeoutMs <int>] -> @{ Code; CpuMs; PeakBytes; TimedOut }`
    - Uses `Diagnostics.Process.Start` and the no-BOM stdin copy from `run-cpp.ps1`.
    - On timeout it kills the process tree and sets `TimedOut=$true` and `Code=$null`.
    - Arguments are quoted so paths with spaces survive.
  - `Show-CrashLine -CompileArgs <string[]> -DebugExe <path> -GdbRun <string> -WorkDir <path> -Src <path>`
    - `-CompileArgs` is the full g++ argument list minus `-o`, with `-O2` already replaced by `-O0`.
    - `-GdbRun` is the text after `run`, e.g. `'< input.txt > NUL 2> NUL'`.
    - Output format is unchanged: `crashed at   line N    in fn:  code`.

- [ ] **Step 1: Write the failing tests** `lc/tests/common.tests.ps1`, compiling the fixtures with `$TestFlags` into `build/tests/`:
  - `(Explain 0xC00000FD)` matches `Stack overflow`.
  - `Start-Measured` on `fast.exe` gives `Code -eq 0`. This is the old "exit code couldn't be read" bug.
  - Given a stdin file containing `3`, `echo-first-byte.exe` prints `51`, i.e. no BOM.
  - `Start-Measured forever.exe -TimeoutMs 1000` gives `TimedOut -eq $true` and returns in under 3 s.
  - **Regression on the F7 script:** create a temp dir with `oob.cpp` and an `input.txt`, and run `'' | powershell -File .zed/run-cpp.ps1 -Mode input <path>`. The output matches `crashed at\s+line 5`.
  - **Check mode:** `-Mode check` on `fast.cpp` matches `No errors.`
  - **Check mode, LeetCode tree file:** `-Mode check` on `lc/selftest/maximum-depth-of-binary-tree.cpp` (no `main()`, no `#include`) matches `No errors.` Plain `-Mode run` on it does the same, because a file without `main()` is only checked.
- [ ] **Step 2: Run** `run-all.ps1 -Only common`. **Expected:** FAIL (no `common.ps1`).
- [ ] **Step 3: Implement `.zed/common.ps1`** and switch `run-cpp.ps1` over to it.
- [ ] **Step 4: Run** the tests. **Expected:** `PASS common`. Then manually run `'' | powershell -NoProfile -ExecutionPolicy Bypass -File .zed/run-cpp.ps1 -Mode input leetcode-solves/test.cpp`. **Expected:** `Hello World x`, then `--- finished: exit code 0, time ... ---`.
- [ ] **Step 5: Commit:** `git commit -m "Extract shared helpers from run-cpp.ps1 into common.ps1"`

### Task 6: Problem info, C++ types, wrapper generation (`.zed/lc/info.ps1`)

**Files:**
- Create: `.zed/lc/info.ps1`
- Test: `lc/tests/info.tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertTo-LcCppType([string]$t) -> string` with this mapping:

    | LeetCode type | C++ type |
    |---|---|
    | `integer` | `int` |
    | `long` | `long long` |
    | `double` | `double` |
    | `boolean` | `bool` |
    | `character` | `char` |
    | `string` | `string` |
    | `TreeNode` | `TreeNode*` |
    | `ListNode` | `ListNode*` |
    | `X[]` and `list<X>` | `vector<X'>` (recursive) |

    Any other type throws `unsupported LeetCode type: <t>`.
  - `Get-LcInfoFromMeta([string]$metaDataJson) -> pscustomobject`. Two shapes:
    - **Function:** `{ Kind='function'; Method; ParamNames=[string[]]; ParamTypes=[string[]]; OutParam=[int] }`. `ParamTypes` are C++ types (via `ConvertTo-LcCppType`). `OutParam` is `output.paramindex`, else -1.
    - **Design:** `{ Kind='design'; Class; CtorNames; CtorTypes (C++); Methods=@(@{ Name; ParamNames; ParamTypes }) }`.
  - `Get-LcInfoFromSource([string]$srcText) -> { Kind='function'; Method; ParamNames; ParamTypes; OutParam=-1; AllMethods=@(@{ Name; ParamNames }) }`
    - `ParamTypes` is the C++ type text as written, with `const` and `&` stripped.
    - Finds the public, non-constructor methods inside `class Solution`.
    - Param names are the last identifier of each parameter, so `const vector<int> &nums` gives `nums`.
    - Returns `$null` when there is no `class Solution`.
  - `Test-LcMethodMatch($metaInfo, [string]$srcText) -> $null | string`:
    - function problems: `LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)`
    - design problems: `LeetCode expects class LRUCache but your file doesn't define it`
  - `New-LcWrapperText -SrcPath <abs> -Info <info> -> string`. The source path uses forward slashes.
    - **Function:**
      ```
      #include "<src>"
      int main(int argc, char** argv) { return lc::run_function(argc, argv, &Solution::rotate, {"nums","k"}, 0); }
      ```
    - **Design:** `return lc::run_design<LRUCache, int>(argc, argv, {"capacity"}, {{"get", lc::method(&LRUCache::get, {"key"})}, {"put", lc::method(&LRUCache::put, {"key","value"})}});`

- [ ] **Step 1: Write the failing tests.** Use these captured metaData strings verbatim:
  - **rotate-array:** `{"name":"rotate","params":[{"name":"nums","type":"integer[]"},{"name":"k","type":"integer"}],"return":{"type":"void"},"output":{"paramindex":0}}`
  - **two-sum:** `{"name":"twoSum","params":[{"name":"nums","type":"integer[]"},{"name":"target","type":"integer"}],"return":{"type":"integer[]","size":2},"manual":false}`
  - **lru-cache:** `classname LRUCache`, `constructor.params [capacity:integer]`, `methods get(key:integer)->integer, put(key:integer,value:integer)->void`, `systemdesign:true`

  Assertions:
  - The rotate info has `OutParam` 0, `ParamNames` `nums,k` and `ParamTypes` `vector<int>,int`.
  - The two-sum info has `OutParam` -1.
  - The lru info has `Kind 'design'`, `CtorTypes 'int'` and method `put` with params `key,value`.
  - `ConvertTo-LcCppType 'integer[][]'` gives `vector<vector<int>>`.
  - `ConvertTo-LcCppType 'list<list<string>>'` gives `vector<vector<string>>`.
  - `ConvertTo-LcCppType 'Node'` throws `unsupported LeetCode type: Node`.
  - `Get-LcInfoFromSource` on the text of `leetcode-solves/concatenation-of-array.cpp` gives Method `shuffle` and ParamNames `nums,n`.
  - `Test-LcMethodMatch` with a getConcatenation meta and that source gives exactly `LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)`.
  - The wrapper text for rotate contains `&Solution::rotate, {"nums","k"}, 0`.
  - The wrapper text for lru contains `lc::run_design<LRUCache, int>`.
- [ ] **Step 2: Run** `run-all.ps1 -Only info`. **Expected:** FAIL.
- [ ] **Step 3: Implement** `.zed/lc/info.ps1`.
- [ ] **Step 4: Run.** **Expected:** `PASS info`.
- [ ] **Step 5: Commit:** `git commit -m "lc: problem info from LeetCode metadata or source, wrapper generation"`

### Task 7: Fetch, test-file generation and parsing (`.zed/lc/fetch.ps1`, `.zed/lc/testfile.ps1`)

**Files:**
- Create: `.zed/lc/fetch.ps1`, `.zed/lc/testfile.ps1`, `lc/tests/testfile.tests.ps1`
- Create fixtures by capturing live responses: `lc/selftest/tests/.meta/<slug>.json` for `concatenation-of-array`, `two-sum`, `rotate-array`, `maximum-depth-of-binary-tree`, `reverse-linked-list`, `lru-cache`, `climbing-stairs`

**Interfaces:**
- Produces:
  - `Get-LcQuestion -Slug <s> -> pscustomobject | $null`
    - GraphQL query fields: `questionFrontendId title titleSlug difficulty isPaidOnly topicTags { name } metaData exampleTestcaseList content`.
    - 10 s timeout. Returns `$null` on network errors or a null question. The error text goes into `$script:LcFetchError`.
  - `Get-LcCachedQuestion -TestsDir <dir> -Slug <s> [-Offline] -> @{ Question; Fetched=[bool] }`
    - Reads `<TestsDir>/.meta/<slug>.json` if present.
    - Otherwise, unless `-Offline`, fetches and writes the cache. `Fetched` is true only when a network fetch happened now.
  - `ConvertFrom-LcHtml([string]$html) -> string`:
    - `<sup>x</sup>` becomes `^x`;
    - block tags (`p`, `li`, `pre`, `div`, `br`) become newlines;
    - all other tags are stripped, then entities are decoded and `&nbsp;` becomes a space;
    - each line is trimmed.
  - `Get-LcConstraints([string]$text) -> string[]`: the lines after `Constraints:` up to the first blank line, or a line starting `Follow` or `Note`.
  - `New-LcTestFileText -Question <q> -Info <info> -> string`:
    - inputs come from `exampleTestcaseList`, paired with param names;
    - outputs are the i-th `Output:` (or a bare `Output` line followed by the value) from the HTML text;
    - adds `compare: any-order` when the content text contains `any order`.
  - `Read-LcTestFile -Path <p> -Info <info> -> @{ AnyOrder=[bool]; Constraints=[string[]]; Cases=@(@{ Args=[string[]]; Expected=[string] or $null }) }`. Design cases use `Args = @(ops, args)`.
  - `Write-LcCasesFile -Cases <cases> -Kind function|design -Path <p>`: values are collapsed to one line.
  - `Format-LcInputLine -Info <info> -Args <string[]> -> 'Input: nums = [1,2], k = 3'`

- [ ] **Step 1: Capture fixtures.** For each of the 7 slugs, write `(Get-LcQuestion -Slug $s) | ConvertTo-Json -Depth 8` to `lc/selftest/tests/.meta/<slug>.json`, using a scratch call of the function once it exists. Order: write `Get-LcQuestion` first, capture, then do Steps 2–5 for the rest.
- [ ] **Step 2: Write the failing tests** `lc/tests/testfile.tests.ps1`. All are offline and read the captured fixtures. Assertions:
  - `New-LcTestFileText` for rotate-array equals exactly:
    ```
    # Rotate Array (#189, Medium) https://leetcode.com/problems/rotate-array/
    Constraints:
    1 <= nums.length <= 10^5
    -2^31 <= nums[i] <= 2^31 - 1
    0 <= k <= 10^5

    Example 1:
    Input: nums = [1,2,3,4,5,6,7], k = 3
    Output: [5,6,7,1,2,3,4]

    Example 2:
    Input: nums = [-1,-100,3,99], k = 2
    Output: [3,99,-1,-100]
    ```
  - The two-sum text contains the line `compare: any-order`.
  - The lru-cache text contains `Input` / `["LRUCache","put",...]` / `[[2],[1,1],...]` / `Output` / `[null, null, null, 1, null, -1, null, -1, 3, 4]`, as separate lines.
  - **Parser: raw paste.** Parse a file holding LeetCode's page text verbatim (Example 1 of rotate-array, including the `Explanation:` lines and `rotate 1 steps to the right: [...]`). It gives 1 case with Args `[1,2,3,4,5,6,7]`, `3` and Expected `[5,6,7,1,2,3,4]`.
  - **Parser: own cases.** `Input: nums = [5], k = 0` with no Output gives Expected `$null`. A `# comment` line is ignored.
  - **Parser: multi-line value.** `Input: nums = [1,\n2,3], k = 1` gives Args[0] `[1,2,3]`.
  - **Parser: design layout without colons** gives Args with 2 entries, ops then args, with the Expected list.
  - **Parser: CRLF and BOM.** The rotate-array generated text, re-saved with a BOM and CRLF, parses to the same object (compare via `ConvertTo-Json`).
  - **Parser: commas inside strings.** `Input: s = "a, b = c", k = 1` gives Args `"a, b = c"`, `1`.
  - **Paid-only:** a question with `isPaidOnly=$true`, `content=$null` and `exampleTestcaseList=@()` gives exactly the header line followed by `Constraints:`, without throwing. `Read-LcTestFile` on it gives 0 cases.
  - `Format-LcInputLine` with rotate info and `@('[1,2]','3')` gives `Input: nums = [1,2], k = 3`.
  - **Cases file round trip:** `Write-LcCasesFile` for rotate gives exactly `case 1`/`arg [1,2,3,4,5,6,7]`/`arg 3`/`expect [5,6,7,1,2,3,4]`/`end`, and so on.
- [ ] **Step 3: Run** `run-all.ps1 -Only testfile`. **Expected:** FAIL.
- [ ] **Step 4: Implement** `testfile.ps1`. Splitting an Input line: tokenize respecting `[]`/`""` nesting, then split at top-level commas that are followed by `ident =`. If no `name =` appears, each non-empty line is one value.
- [ ] **Step 5: Run.** **Expected:** `PASS testfile`.
- [ ] **Step 6: Commit:** `git commit -m "lc: fetch problems, generate and parse test files"`

### Task 8: `lc.ps1` test mode end to end

**Files:**
- Create: `.zed/lc.ps1`, `.zed/lc/build.ps1`, `lc/tests/e2e.tests.ps1`
- Create fixtures in `lc/selftest/`:
  - `concatenation-of-array.cpp`: correct, and also prints `debug!` to `cout`.
  - `two-sum.cpp`: hash map.
  - `rotate-array.cpp`
  - `reverse-linked-list.cpp`
  - `lru-cache.cpp`
  - `climbing-stairs.cpp`: naive recursion.
  - `my-scratch.cpp`: `class Solution { public: int add(int a, int b) {...} };`, with no meta.
  - `slow/climbing-stairs.cpp`: `while(true){}`, plus `slow/tests/.meta/climbing-stairs.json` (a copy).
  - `crash/rotate-array.cpp`: `nums[nums.size()]` on a known line, plus a `.meta` copy.

**Interfaces:**
- Consumes: Tasks 5–7, and the runner CLI.
- Produces:
  - `lc.ps1 -Mode test|analyze [-NoWait] [-NoOpen] [-Offline] [-JourneyRoot <dir>] [-TimeoutMs 30000] <path args...>`
    - Joins the rest args like `run-cpp.ps1`.
    - Exit code: 0 when every compared case passes and nothing crashed, otherwise 1.
  - `build.ps1`:
    - `Initialize-LcPch -Flavor test|bench|profile -> <path of build/pch/<flavor>/lc-all.h>`
      - `lc-all.h` holds `#include "<abs>/lc/lc-prelude.h"` and `#include "<abs>/lc/lc.h"`.
      - Rebuilds the `.gch` when any `lc/*.h` is newer or the flavor's flags changed (stamp file).
    - `Build-LcExe -Slug -SrcPath -WrapperText -Flavor -Name <exe base> -> @{ Ok; Exe; Ms; Skipped; Errors }`
      - Writes `build/lc/<slug>/<name>.cpp`.
      - Compiles with `-include <pch header> -Winvalid-pch`.
      - Skips when `build/lc/<slug>/<name>.stamp` equals the hash of wrapper + source + flags + gch mtime.
- Behavior, per spec "User workflow" and "Test task output":
  - Header line: `concatenation-of-array  (#1929 Easy · Array, Simulation)`. Use ASCII `-` instead of `·` (ASCII-only rule).
  - One line per case: `PASS`, `FAIL` + got/expected/diff, `----` (print), `ERR ` + error.
  - Values are truncated to 60 characters on PASS lines.
  - Summary line: `1/2 passed · 1 printed` (ASCII separator).
  - When the test file is created, it opens in Zed via `& "$env:LOCALAPPDATA\Programs\Zed\bin\zed.exe" <path>`, unless `-NoOpen`.
  - A method mismatch prints its one line, then runs anyway.
  - **Crash:** the case with a `start` line but no result shows `CRASH n`, then `Explain`, then `Show-CrashLine` (debug build of the wrapper with `-O0`, gdb `run test <cases> <results>`).
  - **Timeout:** `TIMEOUT n: still running after <TimeoutMs/1000> s - infinite loop or far too slow?`
  - **Compile failure:** print g++'s output. Exception: when it contains `lc: unsupported parameter type`, print only `This problem uses a parameter type the harness doesn't support yet: <type from the error line>`.
  - **Design problem with no `.meta` cache** (offline or `-Offline`): print `Design problems need LeetCode's info once: connect to the internet and run again.` and exit 1.
  - **No cases:** the typed-input loop prompts `<name> = ` per parameter, runs that single case, prints its line, and appends `Input: ...` to the test file. An empty first answer ends the loop.

- [ ] **Step 1: Write the failing e2e tests** `lc/tests/e2e.tests.ps1`:
  - Copy `lc/selftest` to `$env:TEMP\lc self test\` (the space is deliberate).
  - Call `powershell -NoProfile -ExecutionPolicy Bypass -File .zed/lc.ps1 -Mode test -NoWait -NoOpen -Offline -JourneyRoot <tmp>\journey <file>`.
  - Capture the output and exit code.

  Assertions:
  - For each of concatenation-of-array, two-sum, rotate-array, maximum-depth-of-binary-tree, reverse-linked-list, lru-cache and climbing-stairs: exit 0, output matches `\d+/\d+ passed`, and there are no `FAIL` lines. `tests/<slug>.txt` was created from the cached meta.
  - `e2e: debug prints don't break results`: the concatenation-of-array output contains `debug!` and `2/2 passed`.
  - `e2e: method mismatch`: for a copy of `leetcode-solves/concatenation-of-array.cpp` in the temp dir, the output contains `LeetCode expects getConcatenation(nums) but your Solution has shuffle(nums, n)`.
  - `e2e: timeout names the running case`: run `slow/climbing-stairs.cpp` with `-TimeoutMs 2000`. Output matches `TIMEOUT 1`, exit 1, and the whole run takes under 15 s.
  - `e2e: crash line`: `crash/rotate-array.cpp` output matches `CRASH 1` and `crashed at\s+line <N>`.
  - `e2e: typed input`: run `my-scratch.cpp` with stdin `"2`n3`n`n"` piped in. Output contains `----  1  5`, and `tests/my-scratch.txt` now contains `Input: a = 2, b = 3`.
  - `e2e: unsupported type`: uses fixture `lc/selftest/odd/my-map.cpp` (`class Solution { public: int f(map<int,int> m) { return m.size(); } };`, no meta) with `odd/tests/my-map.txt` containing `Input: m = [1]`. The output contains `parameter type the harness doesn't support` and no line containing `required from`.
  - `e2e: rerun skips compile`: a second run of two-sum reports the build skipped (`Build-LcExe` `Skipped`) and finishes faster than the first.
- [ ] **Step 2: Run** `run-all.ps1 -Only e2e`. **Expected:** FAIL (no `lc.ps1`).
- [ ] **Step 3: Implement** `build.ps1`, then `lc.ps1` test mode. `-Mode analyze` prints `analyze: not implemented yet` and exits 1 until Task 11.
- [ ] **Step 4: Run.** **Expected:** `PASS e2e`. Then run the full suite with `run-all.ps1`; **Expected:** all PASS.
- [ ] **Step 5: Measure.** Touch `lc/selftest/two-sum.cpp` (add a comment) in the temp copy and time one test run with `Measure-Command`. **Expected:** about 3 s or less, PowerShell startup included. Record the number in the commit message.
- [ ] **Step 6: Commit:** `git commit -m "lc: LeetCode test task end to end (edit->result <N> s)"`

### Task 9: Journey events, notes, snapshots, `journey.md`

**Files:**
- Create: `.zed/lc/journey.ps1`, `lc/tests/journey.tests.ps1`
- Modify: `.zed/lc.ps1` (emit events; note prompt)

**Interfaces:**
- Produces:
  - `Get-LcSrcHash -Path <p> -> string`: the first 12 hex characters of SHA-256 of the file bytes.
  - `Write-LcEvent -Root <dir> -Event <name> -Slug <s> -File <relpath> -SrcHash <h> [-Data <hashtable>] [-Ts <string>]`: appends one compressed JSON line (`ConvertTo-Json -Compress -Depth 8`). The common fields come first.
  - `Read-LcEvents -Root <dir> -> object[]`
  - `Get-LcAttempts -Events <e> -Slug <s> -> int`: `test_run` events for the slug after its latest `solved` event.
  - `Test-LcSolvedBefore -Events <e> -Slug <s> -SrcHash <h> -> bool`
  - `Save-LcSnapshot -Root <dir> -Slug <s> -SrcPath <p> -SrcHash <h> [-Ts <string>] -> string | $null`
    - Writes `snapshots/<slug>/<yyyyMMdd-HHmmss>.cpp` only when the hash differs from `snapshots/<slug>/.last-hash`.
  - `Update-LcJourneyFile -Root <dir>`: regenerates `journey.md` from the events, per spec. Specifics:
    - one row per slug with any `test_run`, ordered by first event;
    - `Date` is the date of the first `solved` event, or `-` if never solved;
    - `Max time` is formatted `0.02 ms`;
    - `Complexity` comes from the latest `analyze_run`, else blank;
    - `#`, Title, Difficulty and Tags come from the latest successful `fetch`, falling back to the `.meta` cache, else the slug with blanks;
    - `Note` is the latest note.
- `lc.ps1` wiring, using the field lists from the spec's Event log table:
  - `fetch` whenever `Fetched`
  - `typed_case` per typed case
  - `test_run` every run, including compile failures (`compile_ok:false`)
  - `solved` when all compared cases pass, with at least 1 compared, no error/crash/mismatch, and not `Test-LcSolvedBefore`
  - Snapshot on every run.
  - After a run where all compared cases pass, the closing prompt is `Note (Enter to skip): `. A non-empty answer writes a `note` event. Then `journey.md` is regenerated and the script exits. With `-NoWait` there is no prompt.
  - **Auto-commit:** when this run wrote a `solved` event, after the note and the `journey.md` update, call `Invoke-LcSolveCommit -RepoDir <dsa root> -Paths <solution, tests/<slug>.txt, tests/.meta/<slug>.json if present, JourneyRoot> -Message "solve: <slug> (<Difficulty>)"`. When the difficulty is unknown, use `solve: <slug>`.
- Also produces `Invoke-LcSolveCommit -RepoDir <dir> -Paths <string[]> -Message <string> -> [bool]`:
  - runs `git -C <dir> add -- <paths>`, then `git -C <dir> commit -m <msg> -- <paths>`, so other staged or unstaged work is never included;
  - never pushes;
  - when the folder isn't a git repo, or git fails, prints `(not committed: <reason>)` and returns `$false`. Nothing to commit also returns `$false` silently.

- [ ] **Step 1: Write the failing tests** `lc/tests/journey.tests.ps1`, in a temp root:
  - Writing 2 `test_run` events (`-Ts 2026-10-17T10:00:00+05:30`, `...10:05...`) then a `solved` event gives `Get-LcAttempts` = 0 afterwards. Before the `solved` event it is 2.
  - `Test-LcSolvedBefore` is true for the same hash and false for another hash.
  - `Save-LcSnapshot` called twice with the same hash creates 1 file; a new hash creates a 2nd file.
  - `journey.md` from a fixture event list (fetch for rotate-array #189 Medium with tags Array, Math, Two Pointers; 3 test_runs; solved with `attempts 3, max_ms 0.02`; analyze_run `O(n)`; note `reverse trick`) contains exactly this row:
    ```
    | 2026-10-17 | 189 | [Rotate Array](https://leetcode.com/problems/rotate-array/) | Medium | Array, Math, Two Pointers | O(n) | 0.02 ms | 3 | reverse trick |
    ```
  - The JSON of every event line parses and has `ts`, `event`, `slug`, `file` and `src_hash`.
  - `Invoke-LcSolveCommit` in a temp `git init` repo with one unrelated modified file: the new commit contains only the given paths, the message is exact, and the unrelated file is still modified and uncommitted. In a non-repo temp dir it returns `$false` and prints `(not committed:`.
  - **Add to `e2e.tests.ps1`:** in a temp copy made into a git repo (`git init` plus an initial commit), run two-sum without `-NoWait`. Afterwards `git log -1 --format=%s` is `solve: two-sum (Easy)`. Also run two-sum without `-NoWait` and with stdin `"two pointers next`n"`. Afterwards `events.jsonl` contains `test_run`, `solved` and `note` (`text` = `two pointers next`), and `journey.md` has a `two-sum` row.
- [ ] **Step 2: Run** `run-all.ps1 -Only journey`, then `-Only e2e`. **Expected:** FAIL.
- [ ] **Step 3: Implement** `journey.ps1` and wire it into `lc.ps1`.
- [ ] **Step 4: Run** the full `run-all.ps1`. **Expected:** all PASS.
- [ ] **Step 5: Commit:** `git commit -m "lc: journey event log, notes, snapshots, journey.md"`

### Task 10: Runner bench, gen and allocation counting (C++)

**Files:**
- Create: `lc/lc-alloc.h`, `lc/lc-gen.h`
- Modify: `lc/lc-run.h` (`bench` and `gen` modes for `run_function` and `run_design`), `lc/lc.h`
- Test: `lc/tests/gen.test.cpp`, `lc/tests/bench.test.cpp`

**Interfaces:**
- Produces:
  - `struct lc::AllocStats { uint64_t count, bytes, live, peak; }; lc::AllocStats& lc::alloc_stats(); void lc::reset_alloc_stats();`
    - Global replacement of all `operator new`/`delete` forms: plain, array, sized, nothrow, aligned.
    - Uses `malloc`/`_msize` and `_aligned_malloc`/`_aligned_msize`.
    - `peak` is the max of `live` since the reset.
  - `struct lc::ParamSpec { std::optional<long long> len_min, len_max, val_min, val_max; std::string chars, eqlen; bool sorted = false, distinct = false; };`
  - `struct lc::Spec { std::map<std::string, ParamSpec> params; std::string size; std::optional<long long> calls; };`
  - `lc::Spec lc::read_spec(const std::string& path);`
  - `template<class T> T lc::generate(const ParamSpec&, long long n, std::mt19937_64&);`
    - **Containers, strings, trees and lists:** length/node count is `clamp(n, len_min, len_max)`.
    - **2-D vectors:** `ceil(sqrt(n))` rows of that many columns.
    - **Scalars:** uniform in `[val_min, val_max]`. Defaults: int ±10^9, long long ±10^18, double ±10^4, chars `a-z`, tree/list values ±10^4.
    - **Trees:** random shape; each new node attaches to a random free child slot.
    - **Size parameter:** when it is a scalar (e.g. `climbStairs(n)`), its value is `n`.
    - **`eqlen` scalars** take the generated length of the named parameter.
    - **`sorted`:** the vector (or string) comes out in non-decreasing order.
    - **`distinct`:** no repeated values. If the value range is smaller than the requested length, the length is clamped to the range size. With both flags, the result is strictly increasing.
  - **`bench` mode:**
    - Sizes `maxN, maxN/2, ...` down to ≥ 8, at most 10 sizes, run ascending.
      - `maxN` is the size parameter's `len_max`, or its `val_max` for a scalar.
      - For design problems, `maxN` is `calls`, and n = the number of calls.
    - Per size, write `{"status":"start","n":N,"seed":S}`. Then repeat the call on fresh copies of the args (copy time is not counted) until the total is ≥ 30 ms or there are 50 reps. Write `{"n":N,"ms":<min per-call ms>,"reps":R}`.
    - For design problems, also write `"per_call_us"`, i.e. total time / number of calls.
    - Stop after a size whose single call takes more than `--max-ms`, and write `{"capped":true,"n":N,"ms":...}`.
    - Finally, at the largest completed size, reset the alloc stats, make one call, and write `{"alloc":{"count":..,"bytes":..,"peak":..},"n":N}`.
  - **`gen` mode:** writes `--count` cases in the cases format. Each uses n uniform in `[1, --max-n]` and seed `S + i`. No `expect` lines.
  - Generated inputs are deterministic for a given seed.

- [ ] **Step 1: Write the failing tests.**
  - **`gen.test.cpp`:**
    - With `ParamSpec{len 1..5, val -3..3}`, 100 generated `vector<int>` all have size in [1,5] and values in [-3,3].
    - `generate<string>` with `chars "ab"` contains only `a`/`b`.
    - A tree with n=50 has exactly 50 nodes.
    - The same seed gives the same `show()` text.
    - `read_spec` of the spec-format sample from this plan's header gives `size=="nums"`, `params["nums"].len_max==100000`, `params["n"].eqlen=="nums"` and `calls==200000`.
    - `alloc_stats().count` increases by at least 1 after `new int`, and `live` drops back after `delete`.
  - **`bench.test.cpp`:**
    - With a `Solution` that sums a vector (O(n)) and the spec `size nums` / `param nums len 1 4096`, `bench` writes ≥ 5 size lines with increasing `n`, the last being `4096`, and an `alloc` line.
    - With a quadratic solution and `--max-ms 5`, it writes a `capped` line.
    - `gen --count 20 --max-n 4` writes 20 cases, each with a `nums` of 1..4 items.
- [ ] **Step 2: Run** `run-all.ps1 -Only gen` and `-Only bench`. **Expected:** FAIL.
- [ ] **Step 3: Implement** `lc-alloc.h`, `lc-gen.h` and the modes.
- [ ] **Step 4: Run** the full suite. **Expected:** all PASS.
- [ ] **Step 5: Commit:** `git commit -m "lc: random input generation, bench mode, allocation counting"`

### Task 11: Analyze mode, constraints, complexity fit, TLE (PowerShell)

**Files:**
- Create: `.zed/lc/analyze.ps1`, `lc/tests/analyze.tests.ps1`
- Create fixture: `lc/selftest/variants/two-sum.cpp` (O(n^2) double loop) + `variants/tests/.meta/two-sum.json`
- Modify: `.zed/lc.ps1` (`-Mode analyze`), `lc/tests/e2e.tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertFrom-LcNumber([string]$expr) -> long`: handles `10^5`, `2 * 10^5`, `5 * 10^4`, `-2^31`, `2^31 - 1`, `-10^4`, and plain integers.
  - `ConvertTo-LcSpec -Constraints <string[]> -Info <info> -> @{ Text=<spec file text>; Assumed=[string[]]; MaxN=[long] }`. Recognized patterns:

    | Constraint text | Spec |
    |---|---|
    | `a <= x.length <= b` | `x len` |
    | `a <= x[i] <= b` | `x val` |
    | `a <= x <= b` (scalar) | `x val` |
    | `x == y.length` | `x eqlen y` |
    | `The number of nodes in the (tree\|list) is in the range [a, b]` | the single tree/list param's `len` |
    | `a <= Node.val <= b` | that param's `val` |
    | `x consists of lowercase English letters` | `chars a-z` |
    | `... only digits` | `0-9` |
    | `... English letters` | `a-zA-Z` |
    | `At most N calls` | `calls N` |
    | `x is sorted in (non-decreasing\|ascending\|increasing) order` | `x sorted` |
    | `x is sorted in strictly increasing order` | `x sorted distinct` |

    Range patterns also accept strict `<`, which tightens the bound by 1. A comma-separated name list (`-10^4 < nums[i], target < 10^4`) applies the range to each name. The test asserts `param target val -9999 9999` for that line.
    | `All the (integers\|values\|elements) of x are (unique\|distinct)`, `x contains distinct ...`, `x has unique ...` | `x distinct` |

    - **Size parameter:** the first param whose `Info.ParamTypes` entry is `vector<...>`, `string`, `TreeNode*` or `ListNode*`, else the first integer param.
    - **Design problems:** method and constructor param names are looked up the same way.
  - `Get-LcComplexity -Points <@(@{ n; ms })> -> @{ Label; Coef; TooFast=[bool] }`
    - Least squares of `ms ≈ c·f(n)` over the candidates.
    - Pick the minimum sum of squared log-ratios. `O(2^n)` is only a candidate when max n ≤ 64.
    - Points with ms < 0.002 (20 ticks of the 100 ns timer) are dropped. If fewer than 3 remain, `TooFast=$true` and `Label='too fast to measure'`.
  - `Get-LcEstimateMs -Fit <fit> -N <long> -> double`
  - `Get-LcTleVerdict -EstMs <double> -> 'ok' | 'borderline' | 'likely TLE'`
  - **Analyze output** (spec "Analyze task"):
    ```
    Complexity: looks O(n) (random inputs; worst case may differ)
      n=1024 0.01 ms | n=2048 0.02 ms | ... 
    At n = 100000: est. 0.9 ms -> ok
    Allocations at n=100000: 3 allocs, 0.8 MB total, peak 0.8 MB
    ```
    - Design problems print `Per call: looks O(1) ...`.
    - `Assumed` notes are printed after the output.
    - Writes an `analyze_run` event with `complexity, points, tle_risk, alloc` and updates `journey.md`.
    - **Crash during bench:** `Your solution crashed on a random input of size N (random inputs only follow ranges, sorted and distinct, so they may break other promises).` Then dump that input via `gen --count 1 --max-n N --seed S` and print it with `Format-LcInputLine`.

- [ ] **Step 1: Write the failing tests** `lc/tests/analyze.tests.ps1`:
  - `ConvertFrom-LcNumber '2 * 10^5'` gives 200000; `'-2^31'` gives -2147483648; `'2^31 - 1'` gives 2147483647.
  - The rotate-array constraints give spec text containing `param nums len 1 100000 val -2147483648 2147483647`, `param k val 0 100000` and `size nums`, with `MaxN` 100000.
  - Tree constraints `The number of nodes in the tree is in the range [0, 10^4].` + `-100 <= Node.val <= 100` give `param root len 0 10000 val -100 100`.
  - The lru constraints give `calls 200000`, `param capacity val 1 3000` and `param key val 0 10000`.
  - Binary-search constraints (`1 <= nums.length <= 10^4`, `-10^4 < nums[i], target < 10^4`, `All the integers in nums are unique.`, `nums is sorted in ascending order.`) give a `nums` line containing both `sorted` and `distinct`.
  - `nums is sorted in non-decreasing order.` alone gives `sorted` without `distinct`.
  - Constraints `@()` for two-sum give an `Assumed` entry for `nums` and `MaxN` 100000.
  - Points `n=1000,2000,4000,8000`, `ms=1e-6*n*n` give `O(n^2)`. `ms=1e-5*n` gives `O(n)`. `ms=1e-6*n*log2(n)` gives `O(n log n)`. `n=10..30 step 4`, `ms=1e-6*2^n` gives `O(2^n)`. All ms < 0.002 (`ms=1e-7*n`) gives `TooFast`; `n=10000..80000`, `ms=1e-6*n` (0.01-0.08 ms) still gives `O(n)`.
  - With the `O(n^2)` fit above, `Get-LcEstimateMs -N 100000` gives 10000 (±1%).
  - `Get-LcTleVerdict 400` gives `ok`; 800 gives `borderline`; 1500 gives `likely TLE`.
  - **e2e (append):**
    - `-Mode analyze` on `two-sum.cpp` (hash map) gives output matching `looks O\(n\)` or `looks O\(n log n\)`.
    - `variants/two-sum.cpp` gives `looks O\(n\^2\)` and `likely TLE`.
    - `climbing-stairs.cpp` (naive) gives `looks O\(2\^n\)`.
    - `lru-cache.cpp` gives `Per call: looks O\(1\)`.
    - `events.jsonl` gains `analyze_run` lines.
- [ ] **Step 2: Run** `run-all.ps1 -Only analyze`. **Expected:** FAIL.
- [ ] **Step 3: Implement** `analyze.ps1` and the analyze path in `lc.ps1`. Build the bench exe with `Build-LcExe -Flavor bench -Name bench`.
- [ ] **Step 4: Run** the full suite. **Expected:** all PASS.
- [ ] **Step 5: Commit:** `git commit -m "lc: analyze task - complexity estimate, TLE verdict, allocations"`

### Task 12: Call counts and recursion depth

**Files:**
- Create: `lc/lc-prof.h`
- Modify: `lc/lc-run.h` (`profile` mode), `.zed/lc/build.ps1` (`profile` flavor), `.zed/lc/analyze.ps1`, `.zed/lc.ps1`
- Test: `lc/tests/analyze.tests.ps1` (append), `lc/tests/e2e.tests.ps1` (append)

**Interfaces:**
- Produces:
  - **Profile flavor flags:** bench flags + `-finstrument-functions -finstrument-functions-exclude-file-list=include/c++,/lc/,/build/ -Wl,--disable-dynamicbase -DLC_PROFILE`. The last two keep `nm` addresses equal to runtime addresses.
  - **`lc-prof.h`** (active only under `LC_PROFILE`):
    - `__cyg_profile_func_enter`/`exit`, marked `no_instrument_function`, record per-function-address call count and max simultaneous depth of that same function.
    - `profile` mode runs one generated input of size `--n` and writes `{"fn":"0x<hex>","calls":C,"depth":D}` per function.
  - `Resolve-LcProfile -Exe <path> -Lines <results> -> @(@{ Name; Calls; Depth })`: runs `nm -C --defined-only <exe>`, maps the addresses, and sorts by calls descending, top 5.
  - **Analyze prints:** `Calls (n=N): climbStairs: 1,664,079 calls, max depth 30`. n is the largest bench size whose time was < 200 ms.
  - The `analyze_run` event gets `calls: { "<name>": { count, depth } }`.

- [ ] **Step 1: Write the failing tests:**
  - **analyze.tests:** build `climbing-stairs.cpp` with the profile flavor and run `profile` with `--n 20`. `Resolve-LcProfile` contains `Solution::climbStairs(int)` with `Calls` = 21891 (naive recursion for n=20: `2*fib(21)-1`) and `Depth` = 20.
  - **e2e:** the analyze output for `climbing-stairs.cpp` matches `climbStairs.*calls, max depth \d+`.
- [ ] **Step 2: Run** `-Only analyze`. **Expected:** FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full suite. **Expected:** all PASS.
- [ ] **Step 5: Commit:** `git commit -m "lc: call counts and recursion depth in analyze"`

### Task 13: Brute-force check

**Files:**
- Modify: `.zed/lc.ps1`, `.zed/lc/analyze.ps1`, `lc/tests/e2e.tests.ps1`
- Create fixtures:
  - `lc/selftest/bugged/climbing-stairs.cpp`: a memo version that returns `ways + 1` when `n % 7 == 0`.
  - `lc/selftest/bugged/tests/climbing-stairs.brute.cpp`: correct naive recursion.
  - `bugged/tests/.meta/climbing-stairs.json`

**Interfaces:**
- Produces:
  - `Invoke-LcBruteCheck -Slug -SrcPath -BrutePath -Info -SpecPath -> @{ Cases; Mismatch = $null | @{ Input=<'Input: ...' line>; Got; Expected } }`. Steps:
    1. Build `brute` with the bench flavor from the `.brute.cpp`, using the same wrapper text.
    2. `gen --count 200 --max-n 10 --seed 1`.
    3. Run the brute exe in `test` mode with no expects.
    4. Rewrite the cases with `expect` = brute's `got`.
    5. Run the main bench exe in `test` mode and take the first `fail`.
  - Skipped silently when there's no `.brute.cpp`. If the brute exe itself crashes, print `brute force crashed on case N` and continue.
  - **Analyze prints** either `Brute force: 200 random cases agree` or:
    ```
    Brute force: MISMATCH
    Input: n = 7
    yours: 22   brute: 21
    ```
  - The `analyze_run` event gets `brute: { cases, mismatch_input? }`.

- [ ] **Step 1: Write the failing e2e tests:**
  - `bugged/climbing-stairs.cpp` analyze output matches `Brute force: MISMATCH` and `Input: n = (7|14|21|28|35|42)`.
  - `climbing-stairs.cpp` with a copied correct `.brute.cpp` matches `200 random cases agree`.
- [ ] **Step 2: Run** `-Only e2e`. **Expected:** FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full suite. **Expected:** all PASS.
- [ ] **Step 5: Commit:** `git commit -m "lc: optional brute-force comparison in analyze"`

### Task 14: Zed tasks, shortcuts, final verification

**Files:**
- Modify: `.zed/tasks.json`, `%APPDATA%\Zed\keymap.json` (user's global keymap; it's outside the repo, so it isn't committed)

**Interfaces:**
- Produces:
  - **Task `LeetCode test (Alt+F7)`:** `powershell -NoProfile -ExecutionPolicy Bypass -File .zed/lc.ps1 -Mode test $ZED_FILE`.
  - **Task `LeetCode analyze (Alt+F8)`:** the same with `-Mode analyze`.
  - Both tasks use `cwd $ZED_WORKTREE_ROOT`, `use_new_terminal false`, `allow_concurrent_runs false`, `reveal always` and `hide always`, the same as the F7 tasks.
  - Keymap `Workspace` bindings: `"alt-f7": ["task::Spawn", { "task_name": "LeetCode test (Alt+F7)" }]` and `"alt-f8": [... "LeetCode analyze (Alt+F8)" ...]`.

- [ ] **Step 1: Re-check the keys.** Fetch `https://raw.githubusercontent.com/zed-industries/zed/main/assets/keymaps/default-windows.json` and grep for `alt-f7`, `f7-alt`, `alt-f8` and `f8-alt`. **Expected:** no matches. If there is a match, stop and ask the user for another key.
- [ ] **Step 2: Edit** `tasks.json` and the keymap. Validate both files: `Get-Content tasks.json -Raw | ConvertFrom-Json` should succeed. For the keymap, strip `//` comment lines first if there are any.
- [ ] **Step 3: Run** the full suite `run-all.ps1`. **Expected:** every file PASS.
- [ ] **Step 4: Regression-check the old tasks.** Run `'' | powershell ... run-cpp.ps1 -Mode input leetcode-solves/test.cpp`. **Expected:** `Hello World x` and `exit code 0`. Run `-Mode check leetcode-solves/concatenation-of-array.cpp`. **Expected:** `No errors.`
- [ ] **Step 5: Real run.** Copy `lc/selftest/rotate-array.cpp` to `leetcode-solves/rotate-array.cpp`. Run `.zed/lc.ps1 -Mode test -NoWait -NoOpen <that file>` **online** and check:
  - a live fetch created `leetcode-solves/tests/rotate-array.txt` and `.meta/rotate-array.json`;
  - the output shows `2/2 passed`;
  - `journey/events.jsonl` has `fetch`, `test_run` and `solved` events.

  Then delete those generated journey files and the copied solution, so the user's journey starts clean. Look before deleting: these are only the files this step created.
- [ ] **Step 6: Commit:** `git add .zed/tasks.json && git commit -m "lc: Zed tasks for LeetCode test (Alt+F7) and analyze (Alt+F8)"`
- [ ] **Step 7: Merge.** Once every test passes, run `git checkout main`, `git merge --no-ff lc-harness -m "Merge LeetCode harness"` and `git branch -d lc-harness`. **Expected:** `git log --oneline -1` shows the merge, and `git status` is clean.
- [ ] **Step 8: Hand over.** Tell the user that the keys can only be confirmed by pressing them in Zed. Ask them to press Alt+F7 on a LeetCode file and report back.
