# leetcode-harness

A harness for solving LeetCode in C++ inside the Zed editor on Windows, plus my own solutions and the journey it records.

You write a plain LeetCode solution with no `main()` and no test code, then press one key:
- **Alt+F7** fetches the problem's examples from LeetCode, runs your code on them and compares the output.
- **Alt+F8** estimates the time complexity, warns about TLE, counts allocations and recursive calls, and can check your answer against a brute force.

Every run is logged, so the repo builds up a record of what you solved, when, in how many attempts and how fast.

## Set it up

Give your coding agent this link:

```
https://raw.githubusercontent.com/Am4nn/leetcode-harness/main/SETUP.md
```

It installs what's missing (MSYS2 GCC, Zed, Git), clears out my solutions and journey so you start fresh, adds the shortcuts and checks that a test runs. It asks before installing anything or touching your Zed keymap. You can also follow [SETUP.md](SETUP.md) by hand.

Windows only for now.

## How a problem goes

1. Create `leetcode-solves/<slug>.cpp`, where the slug is the end of the problem URL, e.g. `two-sum`. Paste the starter code and solve it.
2. Press **Alt+F7**. On the first run the harness:
   - fetches the problem from LeetCode's public API, with no login;
   - writes the constraints and examples to `cases/<slug>/cases.txt` and opens that file;
   - runs every case.

   ```
   two-sum  (#1 Easy - Array, Hash Table)

     PASS  1  [0,1]           0.01 ms
     PASS  2  [1,2]           0.00 ms
     PASS  3  [0,1]           0.00 ms
     FAIL  4  got      [1,2]  0.00 ms
              expected [0,2]
              first difference at index 0
     ----  5  [0,2]           0.00 ms
   3/4 passed - 1 printed
   ```

   Cases 4 and 5 are ones I added. Case 4 has a wrong expected output on purpose, to show what a failure looks like. Case 5 has no `Output:`, so it's only printed.

3. Add your own cases to the test file. A case with `Output:` is compared, and one without it is just printed:

   ```
   Input: nums = [1,5,9], target = 14
   Output: [0,2]

   Input: nums = [-3,4,3,90], target = 0
   ```

   If the file has no cases (offline, or a paid-only problem), the terminal asks for each parameter and saves what you type as a new case.
4. When everything passes, the closing prompt asks for an optional one-line note, such as "two pointers after sorting". Press Enter to skip it.
5. Press **Alt+F8** for the analysis:

   ```
   two-sum  (#1 Easy - Array, Hash Table)

   growth   looks O(n)   (random inputs; worst case may differ)
            n     19     78     625     2500    10000
            time  2.0us  8.1us  0.07ms  0.29ms  1.11ms
   TLE      est. 1.11 ms at n = 10000 -> ok
   memory   10010 allocs, 0.3 MB total, peak 0.2 MB at n = 10000
   ```

   It times your code at doubling input sizes up to the constraint maximum and fits the growth. Each run is capped at about 2 s; past that it extrapolates. Recursive solutions also get a `calls` line with call counts and recursion depth, and compiler warnings show up as `warning  line N: ...` with the code line under it.

   The inputs are random, within the problem's constraints. They can miss the worst case, and the report says so.

## Keys

One-glance version: [CHEATSHEET.png](CHEATSHEET.png).

| Key | What it does |
|---|---|
| Alt+F7 | LeetCode test: examples plus your cases, compared |
| Alt+F8 | LeetCode analyze: complexity, TLE risk, allocations, call counts, brute-force check |
| F7 | Run any C++ file that has a `main()` |
| Shift+F7 | Run it with `input.txt` (next to the file) as stdin |
| Ctrl+F7 | Compile only, to check for errors |
| Alt+A | Turn the autocomplete popup on or off |

Crashes are explained in plain words, e.g. "index out of range" or "stack overflow: check the base case", along with the line and the case that crashed. Builds use `_GLIBCXX_ASSERTIONS`, a UB trap and a 256 MB stack.

## What's supported

- **Types:** `int`, `long long`, `double`, `bool`, `char`, `string`, nested `vector`s, `TreeNode*` and `ListNode*`. Trees and lists use LeetCode's `[1,null,2]` format.
- **Problem shapes:**
  - `void` methods that modify the input, such as rotate-array.
  - Design problems such as LRU Cache: the `["LRUCache","put","get"]` / `[[2],[1,1],[1]]` layout. Analyze reports the cost per call for these.
- **Comparison:**
  - Answers in any order: when the problem says "in any order", order is ignored at every level of nesting.
  - Doubles are compared within 1e-5.

## Brute-force check

Write a slow, obviously correct version as `cases/<slug>/brute.cpp`, as a normal `class Solution`. Alt+F8 then runs both on 200 random inputs. On the first input where they disagree, it prints that input in test-file format, ready to paste in as a case.

## The journey

Everything lands in `journey/`:

- `events.jsonl`: one JSON line per action (fetch, test run, solve, analyze, note). Nothing is ever deleted from it. It's meant to feed a web view of progress and patterns later.
- `journey.md`: a table with one row per problem. Columns: date solved, status, difficulty, tags, complexity, slowest case time, attempts and your note.
- `snapshots/<slug>/`: a copy of the solution each time it changes, so you can see it go from brute force to optimal.
- `problems/<slug>.json`: the problem's title, difficulty, tags and examples as fetched from LeetCode, so runs work offline.

Status is `accepted` once LeetCode has accepted a submission (`accepted with hints` if the coach gave hints first), `passed locally` when every local case passed, and `attempted` otherwise. It becomes `failed` when the coach showed you the solution, or when 7 days pass without a pass or, with a username set, an accept. To get `accepted`, put your LeetCode username (from `leetcode.com/u/<username>`) in `.zed/leetcode-user.txt`. The file is git-ignored, and each run then reads your public list of recent accepts, with no login. A run prints `LeetCode accepted: <slug>` when it finds a new one.

Every Alt+F7 run where all cases pass commits the solution, `cases/<slug>/` and `journey/`: `solve: <slug>` for a new version, `pass: <slug>` for a rerun. It then pushes in the background; if you're offline, the next push catches up.

## Asking a coding agent

`CLAUDE.md` tells a coding agent how to coach you here: hints before answers, reviews in a fixed format, and claims checked by running your code. Every run from a Zed key also saves its terminal output and a copy of the source to `build/runs/`, which keeps the last 50 and is git-ignored. The agent reads these with `.zed/lc-context.ps1`, so you can ask "why did that Alt+F7 fail" or "what's wrong at line 15" without pasting anything.

The agent also records the hints, solutions and review scores it gives you, and keeps a memory about you: mistakes you repeat, strengths, coding style and goals, each with the problems behind it. The memory and weekly reads are in `journey/local/`, which is git-ignored. `.zed/lc-stats.ps1` counts results per tag, mistakes by kind, complexity changes and the review score trend. The agent uses it to answer "what's my weakness" or "how did my week go".

## Speed

Measured on my laptop: about 3 s from saving an edit to seeing results, and 1.4 s to rerun without changes. The first run of a new problem takes longer because it compiles the harness part once. After that, each edit recompiles only your solution file.

## Layout

```
leetcode-solves/          your solutions, nothing else: <slug>.cpp
cases/<slug>/cases.txt    examples + your cases (generated, then yours to edit)
cases/<slug>/brute.cpp    optional brute force
journey/                  event log, journey.md, snapshots, cached problem data
lc/                       C++ harness headers + self-tests
.zed/                     the scripts behind every key, and tasks.json
.clangd                   makes clangd know TreeNode/ListNode
build/                    compiled output and runs/ (the run logs); git-ignored
```

## Changing things

| To change | Edit |
|---|---|
| Compiler path, warnings, debug checks, stack size | `.zed/common.ps1` |
| TLE thresholds (500 ms ok, 1 s borderline) | `.zed/lc/analyze.ps1` |
| Where the journey is written | the `-JourneyRoot` parameter in `.zed/lc.ps1` |
| Key bindings | `%APPDATA%\Zed\keymap.json` (task names come from `.zed/tasks.json`) |
| Supported types, parsing, comparison | `lc/lc-io.h` |

After changing the harness, run `powershell -NoProfile -ExecutionPolicy Bypass -File lc\tests\run-all.ps1` and check that every line says PASS.

## License

[MIT](LICENSE)
