# Coach: memory, stats and a fuller journey

A personal tracker and helper, modelled on the coach in 90x (`Web Development/90X/web/src/lib/coach/`). I decide what I practice. The coach describes how I have been doing from my own history. It suggests what to focus on only when I ask, and then bases it on my goals and history.

## Goals
- Every failure is kept: the failing input, expected value, what I returned, and the first compiler error. Each failure links to the exact code version that produced it.
- Hints, shown solutions and review scores are recorded, so a problem's status says how it was solved.
- The coach remembers lasting facts about me: mistake habits, strengths, coding style and goals. Each fact cites its evidence, and I can correct or delete it.
- "What's my weakness", "how did my week go" and "how do I write code" get answers built from my data.

## Non-goals
- No readiness score, target lists (NeetCode 150, AlgoMaster 150) or review ladder.
- No reminders and no schedule. The coach acts only when I talk to it.
- No web view yet. The files are shaped so one can read them later.
- No model calls from the harness. All judgement happens in the chat agent, through CLAUDE.md.

## Anti-goals
- Facts that aren't backed by my data, like "you struggle with DP" without counts or problems behind it.
- Memory or weekly reads pushed to the public GitHub repo.
- Counting debug help ("why did it fail", "line 15") as a hint.

## Decisions

### Journey (public, `journey/`, committed by solve commits)
- **Failures in `test_run`.** Each failed case adds `input`, `expected` and `got`. An errored case adds `error`. A build failure adds `compile_error`, the first error in the compact form `line N: message`. Each value is cut to 200 characters, ending in `...`.
- **Snapshot names carry the hash:** `<yyyyMMdd-HHmmss>-<src_hash>.cpp`. Older snapshots keep their names.
- **New events,** written only through `.zed/lc-coach.ps1`, which takes `file` and `src_hash` from the solution file:
  - `hint`: the agent gave a hint from the hint ladder;
  - `solution`: the agent showed the full solution;
  - `review`, with `score` (1-10), `label` (Poor, Fair, Good or Great) and `pattern`.
- **journey.md Status**, checked in this order:
  1. `failed` if a `solution` event came before the first accept, or it isn't accepted;
  2. `accepted with hints` if accepted and a `hint` came before the first accept. An accept's time is its `submitted_at`, not when a run found it;
  3. `accepted` if accepted;
  4. `failed` if 7 days have passed since the problem's first event, and accepts are tracked (a LeetCode username is set) or it never passed locally;
  5. `passed locally` if it passed locally;
  6. `attempted` otherwise.

  Status is computed when the table is built, never stored, so a later accept shows. `lc-stats.ps1` and `lc-coach.ps1` rebuild the whole table, so time-based statuses stay current.

### Coach memory (local, `journey/local/`, git-ignored)
- **`memory.jsonl`,** one fact per line, rewritten whole on each change. Fields:
  - `id` (`m` + 6 hex);
  - `kind`: `habit` (a mistake pattern), `strength`, `style`, `goal`, `preference` or `context`;
  - `text`: 1-300 characters, on one line;
  - `evidence`: up to 20 entries of `{slug, ref}`, where ref is a snapshot file name, an event ts or `chat`;
  - `status`: `active`, `improving`, `resolved` or `dismissed`;
  - `source`: `user` or `coach`;
  - `created`, `updated` and `last_seen`, as ISO dates with offset;
  - `until` (optional), a `yyyy-MM-dd` date.
- **Dedup.** Texts are compared lowercased, keeping only letters, digits and single spaces.
  - Saving a text that matches a live fact (`active` or `improving`) counts as "seen": the evidence is appended, `last_seen` moves to now and the status goes back to `active`.
  - Saving a text that matches a `dismissed` fact is refused.
- **`-Replaces <id>`** resolves the old fact when the new one is saved.
- **Ageing,** applied on every read and written back when anything changed:
  - a `habit` whose `last_seen` is over 14 days old becomes `improving`; over 28 days, `resolved`;
  - any fact whose `until` date has passed becomes `resolved`.
- **Forget** sets `dismissed` and clears the evidence. The row stays, so the fact is never learned again.
- **Edit** sets `source=user`, `status=active` and clears `until`.
- **`coach-state.json`:** `{ "read": { "<slug>": "<src_hash>" } }`. This records the latest solved version the coach has already read for habits, so `lc-context.ps1` can list solves it hasn't read yet.
- **`weekly/<yyyy-MM-dd>.md`:** one file per week, named for the week's Monday. Saving again in the same week overwrites it.

### Commands
- **`.zed/lc-coach.ps1 <command>`** handles: `hint`, `solution`, `review`, `remember`, `forget`, `edit`, `resolve`, `memory`, `read`, `weekly`. It writes and prints one confirmation line. It never commits or pushes.
- **`.zed/lc-stats.ps1 [-Since yyyy-MM-dd] [-Json]`**, computed from `events.jsonl`:
  - per tag: problems, accepted, with hints, passed locally, attempted, failed, and average Alt+F7 runs to the first pass;
  - mistakes: wrong-answer runs, crash causes and compile errors, grouped, each with its count and its 3 most recent `slug: detail` examples;
  - per problem with 2 or more analyze results: first vs latest complexity, when they differ;
  - review scores: count, mean, and the mean of the last 5 against the 5 before.
- **`.zed/lc-context.ps1`** also prints the active and improving memory facts and the solves the coach hasn't read.

### Agent rules (CLAUDE.md)
- **After a hint from the ladder:** `lc-coach hint`. **After the full solution:** `lc-coach solution`. **After a review:** `lc-coach review`.
- **Extract memory at milestones:**
  - after a review;
  - after showing a solution;
  - when `lc-context` lists a solve the coach hasn't read. It diffs that problem's snapshots: what each failed version got wrong and what fixed it. Then it runs `lc-coach read`.
- **What to save.** Only lasting facts: a mistake in 2 or more problems, a clear style trait, a goal or preference I state. Each fact has evidence. The agent tells me in one line what it saved. "Remember …" saves my fact with `source=user`, and "forget that" dismisses it.
- **Weekly read, on request:**
  - inputs: `lc-stats -Since <Monday>` plus memory;
  - at most 180 words: what went well, what slipped, one thing to focus on;
  - saved with `lc-coach weekly`.
- **"What should I focus on"** is answered from my `goal` facts and stats, and only when I ask.

## Left to the builder
- The exact wording of command output, beyond the fields above.
- The internal function layout inside the new files.
