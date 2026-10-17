# LeetCode harness — design

Date: 2026-10-17. Status: reviewed, awaiting the user's approval.

## Why

The user practices LeetCode in C++ in Zed (workspace `C:\Aman\Coding-Bamzii\dsa`, solutions in `leetcode-solves/`). Two things cost them the most time today:

1. **Writing a `main()` and typing test input by hand** just to try the examples locally.
2. **TLE surprises**: code passes the examples locally, then times out on LeetCode.

They want one generic harness that runs any LeetCode solution file unchanged, compares it against the examples, tells them how their solution scales, and records everything they do so a future web view can show their journey and patterns.

## Goals

- Run any LeetCode solution file with **no extra code in it**. The file stays copy-pasteable into LeetCode.
- Fetch the problem's examples, constraints and metadata from LeetCode **without login or token**, on the first run.
- Print every case's output; when an expected output is given, also compare it and show PASS or FAIL.
- A separate analysis task: complexity estimate, TLE warning against the constraints, allocation count, call counts and recursion depth, and an optional brute-force comparison.
- Record every action (runs, results, analysis, notes) as structured events, plus a readable journey log.
- Support all problem shapes: plain functions, `TreeNode*`/`ListNode*`, design problems (LRU Cache style), `void` in-place methods, any-order answers.

## Non-goals

- The web view itself. This project only records the data it will need.
- Submitting to LeetCode, logging in, or using a LeetCode token or cookie.
- Changing the existing F7 / Shift+F7 / Ctrl+F7 / Alt+A behavior.
- Smart random inputs that respect hidden promises ("array is sorted", "exactly one answer"). The user chose **plain random only**.
- Hardware stats (cache misses etc.).

## Anti-goals (the user will stop using it if…)

- **Slow feedback.** Edit → press → results should take about 2–3 s, recompile included. An unchanged rerun should be faster. The user chose to keep the debug checks (index checks, UB trap) and gdb crash lines in the test build rather than strip them for speed.
- **Noisy output.** Passing cases take one line each; only failures get detail.
- **Fiddly test format.** Text copied from the LeetCode page must work as pasted, including `Example 1:`, `Explanation:` lines, and the design-problem `Input` / `Output` layout.
- **Confusing failures on unusual problems.** An unsupported type, a missing method, or a network failure gives one clear line. Never a wall of template errors.

## Existing setup to build on

- MSYS2 UCRT64 GCC 16.2 at `C:\msys64\ucrt64\bin`, C++23. Zed may hold a stale PATH, so scripts call `C:\msys64\ucrt64\bin\g++.exe` directly and prepend that folder to PATH (see `.zed/run-cpp.ps1`).
- `.zed/run-cpp.ps1` already has: `-D_GLIBCXX_ASSERTIONS`, UB trap, 256 MB stack, `-static`, crash-code explanations, gdb crash-line replay, `Process.Start` for reliable exit codes, the BOM fix for stdin, "Press Enter to close". Reuse these by moving shared helpers into a common script that both scripts dot-source. **F7 behavior must not change.**
- Tasks live in `.zed/tasks.json`. Shortcuts live in the user's global Zed keymap (`%APPDATA%\Zed\keymap.json`) and bind tasks by label. Each label includes its shortcut, e.g. `Run C++ file (F7)`.
- `.clangd` sets `--target=x86_64-w64-windows-gnu`, `--sysroot=C:/msys64/ucrt64`, `-std=c++23`.
- Do not use `_GLIBCXX_DEBUG`. It measured about 20× slower and ruins timing.

## User workflow

1. Create `leetcode-solves/<slug>.cpp`, where `<slug>` is the last part of the problem URL (e.g. `concatenation-of-array`). Paste LeetCode's starter code and solve.
2. Press the **LeetCode test** key. On the first run for a slug the harness:
   - fetches the problem from LeetCode's public GraphQL endpoint,
   - writes `leetcode-solves/tests/<slug>.txt` with the constraints and examples,
   - opens that file in Zed (`zed <path>`), and
   - runs the cases.
3. The user can add their own cases to the test file. A case **with** `Output:` is compared; a case **without** it just prints the result.
4. If the test file has no cases (offline, paid-only problem, or the user deleted them), the terminal asks for each parameter in LeetCode format (`nums = `, `n = `), prints the result, appends that case to the test file, and asks for the next one. Empty Enter stops.
5. Press the **LeetCode analyze** key for the complexity / TLE / allocation / call-count / brute-force report. It always uses random inputs; the test task never does.
6. When every case passes, the closing prompt becomes `Note (Enter to skip):`. That is the same single Enter as today's "Press Enter to close", so it adds no friction.

## Problem metadata (no login)

Verified 2026-10-17: `POST https://leetcode.com/graphql` with a `Referer: https://leetcode.com` header and no cookies returns these fields for free problems:

- `questionFrontendId`, `title`, `difficulty`, `topicTags { name }`, `isPaidOnly`
- `metaData`: a JSON string. For a function it gives `name`, `params[{name,type}]` and `return.type`; e.g. `concatenation-of-array` → `getConcatenation(nums: integer[]) → integer[]`. For a design problem it gives `classname`, `constructor.params`, `methods[]` and `systemdesign: true`; e.g. `lru-cache`.
- `exampleTestcaseList`: the raw example **inputs** only, one parameter per line.
- `content`: the problem HTML. The expected **outputs** (`Output:` in the example blocks) and the **Constraints** list must be parsed from here.

Cache the response at `leetcode-solves/tests/.meta/<slug>.json` so later runs and the journey log work offline.

Failure handling:
- **Offline, unknown slug or 404** (e.g. a file not named after a problem): continue without metadata. Find the method by reading the source; it should be the single public method of `class Solution`. Say once, in one line, that the problem couldn't be fetched.
- **Paid-only:** `content` is null. Write the test file with only a header, then fall back to typed input.

## Test file format

`leetcode-solves/tests/<slug>.txt`, generated on first run and edited freely afterwards:

```
# Concatenation of Array (#1929, Easy) https://leetcode.com/problems/concatenation-of-array/
Constraints:
n == nums.length
1 <= n <= 1000
1 <= nums[i] <= 1000

Example 1:
Input: nums = [1,2,1]
Output: [1,2,1,1,2,1]

Example 2:
Input: nums = [1,3,2,1]
Output: [1,3,2,1,1,3,2,1]

Input: nums = [5]
```

Parsing rules (keep it forgiving):
- **Case boundaries:** an `Input:` line starts a case. The next `Output:` belongs to it. `Example N:`, `Explanation:` and blank lines are ignored. Lines starting with `#` are comments.
- **Parameters:** the `name = value` pairs on the Input line. Match them to the method's parameters by name when metadata exists, otherwise by position. Values may also be split across lines.
- **Design problems:** accept LeetCode's page layout, i.e. `Input` / `["LRUCache","put",…]` / `[[2],[1,1],…]` / `Output` / `[null,null,…]`, with or without colons.
- **Constraints:** the `Constraints:` block runs to the first blank line. Read it for analyze, e.g. `1 <= n <= 10^5`, `-10^4 <= nums[i] <= 10^4`, `s consists of lowercase English letters`, `1 <= nums.length <= …`. Lines it can't read are ignored.
- **Optional directive (builder's call):** `compare: any-order` on its own line. It is set automatically when the problem text says "in any order".

## How a solution gets called

The harness never edits the solution file. For each run it writes a wrapper into `build/` that:

1. includes `lc.h`, which holds parsing, printing, comparison, `TreeNode`/`ListNode`, and the allocation counter;
2. `#include`s the user's `.cpp`;
3. invokes the method through a member-function pointer (`&Solution::getConcatenation`). Template deduction on that pointer gives the parameter and return types, so the type list never needs to be written out by hand;
4. for design problems, constructs the class from the first call's arguments, then dispatches each method name through a generated table of member pointers.

Requirements:
- **Types:** `int`, `long long`, `double`, `bool`, `char`, `string`, nested `vector<…>`, `TreeNode*`, `ListNode*`, by value or by reference.
  - Trees and lists use LeetCode's level-order `[1,null,2]` format.
  - An unsupported type gives a clear `static_assert` naming the type, plus a script-side one-line message. No template error dump.
- **`void` in-place methods:** print and compare the modified argument. `metaData` usually names it via `output.paramindex`; otherwise use the first non-const reference parameter.
- **Comparison:**
  - Exact, after normalizing whitespace.
  - `double` within 1e-5.
  - With `any-order`, compare the outer list as a multiset.
- **Method name mismatch:** if metadata says `getConcatenation` and the class doesn't have it, print one line, e.g. `LeetCode expects getConcatenation(...) but your Solution has shuffle(...)`. Then run the single public method anyway, but don't log a PASS.
- **Crashes:** reuse `run-cpp.ps1`'s crash explanation and gdb crash-line replay, and also say which case crashed.
- **Speed:** precompile `bits/stdc++.h` + `lc.h` (PCH). Skip recompiling when neither the solution nor the wrapper changed (hash check).

**Editor support.** LeetCode starter code uses `TreeNode`/`ListNode` without defining them, and often has no `#include`. Add a `.clangd` rule for `leetcode-solves/` that force-includes a small `lc-prelude.h` (`bits/stdc++.h`, `using namespace std;`, `TreeNode`, `ListNode`). That way clangd shows no false errors. The wrapper includes the same prelude.

## Test task output

```
concatenation-of-array  (#1929 Easy · Array, Simulation)
  PASS  1  [1,2,1,1,2,1]                        0.01 ms
  FAIL  2  got      [1,3,2,1,1,3,2]              0.01 ms
           expected [1,3,2,1,1,3,2,1]
           first difference at index 7
  ----  3  [5,5]                                0.00 ms
1/2 passed · 1 printed
```

Long values are truncated in the one-line view and shown in full on failure.

## Analyze task

Runs in its own build without the debug checks (plain `-O2`), so timing is close to LeetCode's.

- **Random inputs:**
  - Plain random within the parsed constraints. If a constraint is missing, assume n ≤ 10^5 and values in ±10^9, and say so.
  - Trees: random shape. Strings: lowercase letters unless the constraints say otherwise.
  - Inputs are seeded and deterministic, so a reported failing input can be reproduced.
- **Complexity estimate:**
  - Time the solution at doubling sizes up to the constraint maximum. Fit the growth and report the closest of O(1), O(log n), O(n), O(n log n), O(n²), O(n³), O(2ⁿ), with the measured times.
  - Cap each run at ~2 s and extrapolate past the cap.
  - State plainly that random inputs can miss the worst case.
- **TLE warning:** the measured or extrapolated time at the maximum constraint, compared against a ~1 s budget, e.g. `n = 10^5 → est. 4.2 s: likely TLE`.
- **Allocations:** a global `operator new`/`delete` override in `lc.h` reports allocation count, total bytes, and peak live bytes at the largest size.
- **Calls and recursion depth:** a separate instrumented build (`-finstrument-functions`, filtered to functions defined in the solution file) on a mid-size input, e.g. `dfs: 1,048,576 calls, max depth 20`. It is slow, so it is never mixed into the timing.
- **Design problems (e.g. LRU Cache):**
  - Generate random call sequences: construct once with random constructor arguments within the constraints, then random method names with random arguments.
  - Use growing sequence lengths. Here n = number of calls.
  - Report **cost per call** ("get/put look O(1) each"), not total time. Allocation and call stats are reported as usual.
  - The brute-force check works the same way: both executables replay the same seeded call sequence, and the results are compared call by call.
- **Brute-force check (optional):**
  - If `leetcode-solves/tests/<slug>.brute.cpp` exists, written as a normal LeetCode-style `class Solution`, build it as a second executable.
  - Run both executables on the same seeded small random inputs and stop at the first input where the outputs differ. Print that input in test-file format so it can be pasted in as a case.

## Event log (for the future web view)

Every action appends one JSON object per line to `dsa/journey/events.jsonl`. This is the source of truth and is append-only.

Common fields: `ts` (ISO local time with offset), `event`, `slug`, `file`, `src_hash`.

| event | extra fields |
|---|---|
| `fetch` | `ok`, `id`, `title`, `difficulty`, `tags`, `paid_only`, `error?` |
| `test_run` | `compile_ok`, `compile_ms`, `cases: [{n, status: pass/fail/print/crash, ms, mem_kb?}]`, `passed`, `failed`, `printed`, `crash?: {code, cause, line?}` |
| `solved` | written on the first all-pass for a given `src_hash`: `attempts` (test runs for this slug since the previous `solved`, or since the first run), `max_ms` |
| `analyze_run` | `complexity`, `points: [{n, ms}]`, `tle_risk`, `alloc: {count, bytes, peak}`, `calls: {fn: {count, depth}}`, `brute?: {cases, mismatch_input?}` |
| `note` | `text` |
| `typed_case` | `input` (when a case is added via the terminal prompt) |

**Snapshots (my call):** when `src_hash` changes on a run, copy the solution to `dsa/journey/snapshots/<slug>/<ts>.cpp`. This lets the web view later show how a solution evolved, e.g. brute force to optimal. It's cheap: files are a few KB.

**Journey log:** `dsa/journey/journey.md` is a markdown table regenerated from `events.jsonl` after each run. It has one row per problem, updated in place rather than duplicated:

| Date | # | Problem | Difficulty | Tags | Complexity | Max time | Attempts | Note |
|---|---|---|---|---|---|---|---|---|

- `Date` is the first solved date.
- `Problem` links to `https://leetcode.com/problems/<slug>/`.
- `Complexity` comes from the latest `analyze_run` (blank until analyze has run).
- `Note` is the latest note.

## Tasks and shortcuts

Two new tasks in `.zed/tasks.json`, bound in the global keymap by label:

- `LeetCode test (Alt+F7)`
- `LeetCode analyze (Alt+F8)`

Both run the open file (`$ZED_FILE`) and behave like the existing run tasks: `reveal: always`, `hide: always`, and wait for Enter (or a note) before closing.

**Shortcut check:** Zed's published `default-windows.json` (fetched 2026-10-17) binds F8, Shift+F8, Ctrl+F8, F9, Shift+F9 and Ctrl+Shift+F8. `alt-f7` and `alt-f8` are unbound. Re-check both key orderings before binding.

## Files (proposed layout)

```
dsa/
├── lc/
│   ├── lc.h             parsing, printing, compare, alloc counter, call dispatch
│   └── lc-prelude.h     bits/stdc++.h, using namespace std, TreeNode, ListNode
├── .zed/
│   ├── run-cpp.ps1      unchanged behavior (shared helpers moved out)
│   ├── common.ps1       compiler paths, flags, crash explain, gdb replay, Finish
│   └── lc.ps1           -Mode test | analyze
├── leetcode-solves/
│   ├── <slug>.cpp
│   └── tests/
│       ├── <slug>.txt
│       ├── <slug>.brute.cpp   (optional)
│       └── .meta/<slug>.json
├── journey/
│   ├── events.jsonl
│   ├── journey.md
│   └── snapshots/<slug>/<ts>.cpp
└── build/               wrappers, PCH, exes (disposable)
```

## Done when

**Sandbox (my call).** Self-tests must not pollute the user's real journey:
- Fixtures live in `lc/selftest/` (their own `.cpp` files and `tests/`).
- `lc.ps1` takes a `-JourneyRoot` override, which the self-test points at a throwaway folder.
- The user's existing `leetcode-solves/` files are never modified by the build. `leetcode-solves/concatenation-of-array.cpp` actually holds #1470 Shuffle the Array, so the self-test uses its own correct fixture.

**Parameter mismatch (my call).** When the solution's method takes parameters the test case doesn't supply (e.g. a mismatched file), stop with one line naming the missing parameters. Don't prompt.

A small self-test set runs green through both tasks:
- `concatenation-of-array` (vector)
- `two-sum` (vector + int → vector, any-order)
- `maximum-depth-of-binary-tree` (TreeNode)
- `reverse-linked-list` (ListNode)
- `rotate-array` (void in-place)
- `lru-cache` (design)
- `climbing-stairs` (int, recursion stats)
- one offline / non-slug file

Also:
- Analyze labels a deliberately O(n²) two-sum as O(n²) and a hash-map version as O(n).
- A planted bug is found by the brute-force check.
- `events.jsonl` and `journey.md` reflect the runs.
- F7, Shift+F7, Ctrl+F7 and Alt+A behave exactly as before.

## Left to the builder

- PowerShell vs C++ for parsing the test file and HTML. Recommendation: parse the HTML in PowerShell at fetch time and write the clean test file; parse the test file in C++ inside `lc.h`, so the C++ side never sees HTML.
- The exact complexity-fitting method and the size steps.
- How the call-count instrumentation filters out STL frames.
- The PCH details and the change-detection scheme.
