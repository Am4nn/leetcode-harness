# SETUP

These are instructions for a coding agent such as Claude Code, Codex or Cursor. To use them, paste this into your agent:

> Set up this for me: https://raw.githubusercontent.com/Am4nn/leetcode-harness/main/SETUP.md

You can also follow the steps by hand.

**Agent:** work through the steps in order. Each step has a check, so run it before you move on. Ask the user when a step says **Ask**, or when something on their machine doesn't match what's described here. Don't guess paths, and don't overwrite the user's existing files without showing them first. Never ask for a LeetCode login, cookie or token: the harness only uses LeetCode's public API.

## 0. Check the machine

This only works on **Windows 10/11**, because the scripts are Windows PowerShell 5.1 and the compiler is MSYS2 GCC. On macOS or Linux, stop and tell the user it isn't supported yet.

Check: `$PSVersionTable.PSVersion` shows 5.1, and `powershell.exe` exists.

## 1. Ask where it goes

**Ask** the user:
- Which folder should the workspace live in? Suggest `C:\dsa`. A path with spaces works, but a short path is easier to read in error messages.
- Do they want their own GitHub repo for it later? Only note the answer: nothing gets pushed during setup.

## 2. Install the tools

Install whatever is missing with `winget`. **Ask** before installing anything.

| Tool | Check | Install |
|---|---|---|
| Git | `git --version` | `winget install --id Git.Git -e` |
| Zed | `Test-Path "$env:LOCALAPPDATA\Programs\Zed\bin\zed.exe"` | `winget install --id ZedIndustries.Zed -e` |
| MSYS2 | `Test-Path C:\msys64\usr\bin\bash.exe` | `winget install --id MSYS2.MSYS2 -e` |

Then install GCC and GDB inside MSYS2:

```powershell
C:\msys64\usr\bin\bash.exe -lc "pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb"
```

Check: `C:\msys64\ucrt64\bin\g++.exe --version` prints GCC 13 or newer (the code uses C++23).

If MSYS2 lives somewhere other than `C:\msys64`, **ask** the user for the path. After step 3, replace `C:\msys64` / `C:/msys64` in every file that `git grep -l msys64` lists: `.clangd`, `.zed/common.ps1`, `.zed/lc/analyze.ps1` and `lc/tests/run-all.ps1`.

clangd needs no install, because Zed downloads it the first time it opens a C++ file.

## 3. Get the code without the author's progress

The repo holds the author's own solutions and journey log. The user gets the tooling and a clean slate.

```powershell
git clone --depth 1 https://github.com/Am4nn/leetcode-harness.git "<folder>"
cd "<folder>"
Remove-Item -Recurse -Force .git
```

Then delete the author's progress:
- `leetcode-solves\*`: the solutions. The folder itself must exist, so create it empty if it's missing (git doesn't keep empty folders).
- `cases\`: the test files and brute forces. The harness recreates it on the first run.
- `journey\`: the event log, snapshots, `journey.md` and the cached problem data in `journey\problems\`. The harness recreates it on the first run.
- `docs\`: the author's design notes and build plan.

Keep `lc\`, `.zed\`, `.clangd`, `.gitignore`, `README.md`, `SETUP.md`, `CHEATSHEET.png`, `CLAUDE.md` (how Claude Code coaches in this folder; the user can edit it) and `LICENSE`.

Start a fresh history, because the harness commits each solved problem automatically:

```powershell
git init -b main
git add -A
git commit -m "Start my LeetCode journey"
```

If `git commit` complains about a missing name or email, **ask** the user for theirs and set them with `git config user.name` / `git config user.email` (repo-local unless they say global).

Check: `git log --oneline` shows one commit, and `leetcode-solves\` is empty.

## 4. Point clangd at the prelude

`.clangd` has one absolute path, the author's. Replace `C:/Aman/Coding-Bamzii/dsa` with the user's folder. Keep forward slashes:

```yaml
  Add: [-include, C:/dsa/lc/lc-prelude.h]
```

This makes `TreeNode`, `ListNode` and `using namespace std` known to clangd, so LeetCode starter code shows no false errors.

Commit the change: `git commit -am "Point clangd at this folder"`.

## 5. Create the project's Zed settings

`.zed/settings.json` is git-ignored because Alt+A rewrites it on every press. Create it:

```json
{
  // Flipped by the "Toggle autocomplete" task (alt-a).
  // When false, press ctrl-space to open completions manually.
  "show_completions_on_input": false
}
```

## 6. Add the shortcuts

Zed only reads key bindings from the user's global keymap, `%APPDATA%\Zed\keymap.json`. Merge these bindings into it:

```json
{
  "context": "Workspace",
  "bindings": {
    "alt-a": ["task::Spawn", { "task_name": "Toggle autocomplete (Alt+A)" }],
    "f7": ["task::Spawn", { "task_name": "Run C++ file (F7)" }],
    "shift-f7": ["task::Spawn", { "task_name": "Run C++ file with input.txt (Shift+F7)" }],
    "ctrl-f7": ["task::Spawn", { "task_name": "Check C++ file (Ctrl+F7)" }],
    "alt-f7": ["task::Spawn", { "task_name": "LeetCode test (Alt+F7)" }],
    "alt-f8": ["task::Spawn", { "task_name": "LeetCode analyze (Alt+F8)" }]
  }
}
```

- If the file doesn't exist, create it as a JSON array holding this one object.
- If it exists, add the object to the array and keep everything else.
- If any of these keys is already bound to something else, **ask** the user: keep theirs, use ours, or pick another key. If a key changes, the `task_name` stays the same. Only the key changes.

These bindings do nothing in other projects, because the tasks only exist in this folder's `.zed/tasks.json`.

## 7. Verify

Run one offline test on a copy of a bundled sample, so nothing lands in the user's journey or in the repo:

```powershell
$t = "$env:TEMP\lc-setup-check"
New-Item -ItemType Directory -Force "$t\journey\problems" | Out-Null
Copy-Item lc\selftest\two-sum.cpp $t
Copy-Item lc\selftest\problems\two-sum.json "$t\journey\problems"
powershell -NoProfile -ExecutionPolicy Bypass -File .zed\lc.ps1 -Mode test -NoWait -NoOpen -Offline -NoCommit -JourneyRoot "$t\journey" -CasesRoot "$t\cases" "$t\two-sum.cpp"
```

Check: the output ends with `3/3 passed` and has no FAIL line. The first run takes 30 to 60 s while it builds the precompiled headers. Later runs take a few seconds.

Optional full self-test, which takes a few minutes: `powershell -NoProfile -ExecutionPolicy Bypass -File lc\tests\run-all.ps1`. Every line should say PASS.

Delete `$env:TEMP\lc-setup-check` afterwards.

## 8. Optional: LeetCode username

With a username, the harness can tell which problems LeetCode accepted. It reads the public profile, so no login is needed.

**Ask** the user for their LeetCode username, the last part of `leetcode.com/u/<username>`. If they'd rather not, skip this step.

Write it to `.zed\leetcode-user.txt` in the workspace:

```powershell
Set-Content -Encoding ascii .zed\leetcode-user.txt '<username>'
```

The file is git-ignored, so the username stays on this machine. Without it, everything else works the same.

Check: `git check-ignore .zed/leetcode-user.txt` prints the path.

## 9. Hand over

Tell the user:
1. Open the folder in Zed (`zed "<folder>"`).
2. Create `leetcode-solves\two-sum.cpp`. The file name is the last part of the problem URL. Paste LeetCode's starter code and solve it.
3. Press **Alt+F7** to test. The first run fetches the examples into `cases\two-sum\cases.txt` and opens it.
4. Press **Alt+F8** to analyze: complexity, TLE risk, allocations.

Point them to `README.md` for everything else.
