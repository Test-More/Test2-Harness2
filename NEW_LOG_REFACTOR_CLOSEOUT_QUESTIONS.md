# `new_log_refactor` Closeout — Questions

Questions raised by the close-out audit (see prior chat). Answer inline
under each `ANSWER:` block. Plan will be written against these answers.

---

## Q1. Splitting the uncommitted diff into commits

The 32-file uncommitted set mixes several logical changes. Proposed commit
split (per CLAUDE.md "distinct commit per change"):

1. **`ord 0→1 shift`** — `run_id`, `job_id`, `job_try` all switch from 0-based
   to 1-based across `Test2::Harness2*`, `App::Yath2::Command::{run,start}`,
   plus matching test updates and the regenerated `t/Yath/integration/replay/*.yath`
   fixtures.
2. **`renderer Driver — skinny transition events`** — `RunService.pm` retires
   the `run_mutation` full-snapshot event in favor of skinny
   `run_queued`/`run_started`/`job_started`/`job_completed`/`run_completed`
   events; `Renderer/Driver.pm` rewrites synthesis to use those + per-job
   `spec.jsonl`/`report.jsonl` artifact lookups; `Collector.pm` stashes
   `_pending_exit_timing` so `report.jsonl.zst` carries `times`/`child_times`/
   `child_wall`. Tests updated. Replay fixtures regenerated.
3. **`--log-compress + plaintext archive mode`** — `Options/Log.pm` adds
   `format` + `compress` options; `Log/Directory.pm`, `Log/TarZIdx.pm`,
   `Log/DB.pm` add `compress=>0` plaintext storage path with `inner='plain'`
   tar entries; `Command/test.pm` plumbs the options.
4. **`DB summary-row population`** — `Log/DB.pm` `_populate_summary_rows` +
   helpers + `sealed_at` stamping at end of `insert()`.
5. **`Stream2 / Event — drop stream_id + assert_count mirroring`** —
   `Test2::Formatter::Stream2` stops stamping `stream_id`/`assert_count`;
   `Test2::Harness2::Event` drops the accessors; `Renderer/JUnit.pm` reads
   `assert.number` directly.
6. **`Renderer/Default — preserve job_id 0`** (now job_id 1, but the patch
   was about treating `defined $jid` correctly so the first job isn't
   rendered as the bare RUNNER label).
7. **`Collector — graceful TERM-then-KILL termination`** —
   `Collector.pm:_run_collection_loop` sends TERM, schedules KILL after
   `kill_timeout`, and continues draining pipes between the two so
   multipart writes finish and Atomic::Pipe doesn't surface "Incomplete
   message received before EOF".
8. **`Collector — strip trace.full_caller before write`** — adds
   `_strip_trace_full_caller` recursion and the new
   `t/AI/unit/Collector/strip_full_caller.t` (currently untracked).

Approve, amend (e.g. fold #5/#6 into earlier commits), or change order.

ANSWER: Approve

---

## Q2. Archive command option naming

Today:

- `yath archive --format sqlite` (option group `archive`)
- `yath test --log-format sqlite` (option group `log`)

Test command sets archive policy via `--log-format`/`--no-log-compress`
because it owns the log; archive command sets archive policy via
`--format` because that command's whole job is archiving.

Pick one:

- **(A)** Unify on `log` group: rename `archive` command's `--format` →
  `--log-format`; move both options into `App::Yath2::Options::Log`.
- **(B)** Keep current; add `--log-compress` alias to `archive` so the
  flag exists.
- **(C)** Move to `archive` group on both: rename `test`'s
  `--log-format`/`--log-compress` → `--archive-format`/`--archive-compress`.

I lean (A) — the options describe the log/archive shape regardless of
which command writes it; one option group avoids drift.

ANSWER: A

---

## Q3. 0→1 ord shift: keep, revert, or document

The uncommitted shift moves `run_id`/`job_id`/`job_try` from 0-based to
1-based. Reasons it might have been done:

- Renderer reads `if ($id) { ... }` in many places — 0 trips the falsy
  branch, treating job 0 as "no job" / RUNNER. The diff in
  `Renderer/Default.pm` switches to `defined $jid` to fix this for the
  ord=0 case.
- 1-based ords match human expectation in command output (`job 1`,
  `job 2`, ...).

Either fix works. Confirm:

- **(A)** Keep 1-based shift; commit it.
- **(B)** Revert the shift; fix all renderer-side falsy checks to
  `defined($id)` instead.

I lean (A) — the shift is already done and renderer output reads cleanly
("job 1" not "job 0"). Cost is the test-fixture update.

ANSWER: A

---

## Q4. `RunService::emit_service_event` `job_try => 0`

`lib/Test2/Harness2/RunService.pm:993` emits run-service events with
`job_id => $self->{+JOB_ID}`, `job_try => 0`. Run service has no job; the
`0` is a placeholder.

After the 0→1 shift `0` is no longer a valid `job_try`. Pick:

- **(A)** Leave `0`; document as "no try" sentinel.
- **(B)** Switch to `undef` (truthy-falsy callers must already cope).
- **(C)** Drop `job_try` from the emission entirely.

I lean (C) — the run service isn't a job; the field is meaningless. Code
that needs it for something can `// undef` at the read site.

ANSWER: C

---

## Q5. `App::Yath2::Util::Log::open_log` cleanup

Function returns `($log, $cleanup)` where `$cleanup` is a no-op preserved
for back-compat with the deleted auto-extract path. All four callers
(`failed`, `replay`, `speedtag`, `times`) use scalar context.

Pick:

- **(A)** Delete the helper entirely; inline `App::Yath2::Log->new(dir => $p)`
  / `->new(file => $p)` at each caller.
- **(B)** Simplify to `sub open_log { return App::Yath2::Log->new(...); }`;
  drop `$cleanup`, drop `wantarray` branch, keep one-liner.
- **(C)** Leave as-is; might want to re-introduce cleanup later for
  decorator output.

I lean (B) — keeps the path-dispatch convenience (file vs dir) but removes
the dead bits. (A) duplicates the `-d`/`-f` dispatch four times.

ANSWER: Move the auto-detect functionality into App::Yath2::Log->new() and remove the helper.

App::Yath2::Log->new(auto => $PATH); # Detect dir vs file, etc.

---

## Q6. Skipped-test files: rewrite or delete

`t/AI/unit/Yath2/Command/{failed,speedtag,times}.t` are `plan skip_all`.
The integration tests `t/AI/integration/{failed_command,replay_command}.t`
exist but `speedtag` / `times` have no integration coverage; the only
coverage of those two commands is `t/Yath/integration/{speedtag,times}.t`
(human-authored, runs via yath).

Pick:

- **(A)** Rewrite all three unit tests against `App::Yath2::Log`. Cost:
  ~3 short test files exercising each command's `open_log` + report
  iteration.
- **(B)** Delete the three skipped files; rely on
  `t/Yath/integration/{speedtag,times}.t` and `t/Yath/integration/failed.t`
  for coverage.
- **(C)** Delete `failed.t` (covered by integration); rewrite
  `speedtag.t` + `times.t` (no unit coverage exists).

I lean (B) — the integration tests already cover end-to-end; unit-level
tests of these commands mostly duplicate that. Deleting reduces dead
weight.

ANSWER: A

---

## Q7. Untracked `t/AI/unit/Collector/strip_full_caller.t`

File exists, passes, uses 0-based ords (`runs/0/jobs/0/0/...`).

Pick:

- **(A)** Commit as-is in commit #8 ("strip trace.full_caller"), then
  the 0→1 shift commit #1 updates it.
- **(B)** Re-author with 1-based ords first, commit once, no follow-up.
- **(C)** Squash strip_full_caller change into commit #1 so the test
  arrives 1-based.

I lean (B) — the file is untracked, so we can edit before commit; one
clean commit beats commit-then-rename.

ANSWER: B

---

## Q8. Untracked detritus at repo root

Currently untracked (per `git status`):

- `LOGGER_ARTIFACT_REFACTOR/` (directory)
- `LOGGER_ARTIFACT_REFACTOR2/` (directory)
- `LOGGER_ARTIFACT_REFACTOR_FOLLOWUPS.md`
- `LOGGER_ARTIFACT_REFACTOR_QUESTIONS.md`
- `fail.t`
- `pass.t`
- `fix_log_paths` (likely a directory or script)
- `logs/` (run-output detritus)

These look like artifacts from the prior worktree iteration plus a
local test scratch. Confirm safe to remove. Specifically:

- Are `LOGGER_ARTIFACT_REFACTOR*` / `LOGGER_ARTIFACT_REFACTOR_*.md`
  superseded by `NEW_LOG_REFACTOR_QUESTIONS.md` / `_FOLLOWUPS.md`?
- `fix_log_paths` — local scratch or something to keep?

ANSWER: Safe to remove

---

## Q9. Final-commit shape

Plan completes with branch in mergeable state. Pick merge strategy
preference (drives whether close-out commits should be squash-friendly):

- **(A)** Merge commit (preserves the 23+ branch commits).
- **(B)** Squash merge to `2.0` with a single canonical message.
- **(C)** Rebase + fast-forward (linear history; commits stay distinct).

CLAUDE.md says "distinct commit per change". The branch already follows
that; closing it out the same way means (A) or (C).

ANSWER: Do not merge yet. I want to do a final review before we merge.

---

## Q10. F18 / F22 test coverage

The audit flagged that some F-followups have no direct test:

- **F18**: per-job state forwarded via `test_job_completed` IPC payload
  (so run service builds the run-level `collector_report` without disk
  reads).
- **F22**: renderer EOE-timeout (10s grace after harness pid gone).

Pick:

- **(A)** Add direct tests in this branch before merge.
- **(B)** Note as followup in a tracking file; merge without.
- **(C)** Add F18 test (cheap unit), defer F22 (timing test, fragile).

I lean (C).

ANSWER: A

---

## Q11. Tempdir name strings

`lib/Test2/Harness2/Collector.pm:1077` uses `'yath-tarzidx-rearch-XXXXXX'`
and `lib/App/Yath2/Log/DB.pm:1522` uses `'yath-db-arch-XXXXXX'`. The
"rearch"/"arch" suffix is leftover from earlier rename work.

Pick:

- **(A)** Rename to `'yath-tarzidx-XXXXXX'` / `'yath-db-XXXXXX'`.
- **(B)** Leave; the name doesn't affect behavior.

I lean (A).

ANSWER: A

---

## Q12. ARCHITECTURE.md addendum updates

Two edits needed in the rev-2 addendum:

- Add `App::Yath2::LogDB` to the Module map (post-rev-2) table.
- Mention the `compress=0` plaintext archive mode in §23 (on-disk wire
  formats) so future readers know `inner='plain'` is a valid tar.zidx
  entry kind.

Confirm these belong in the addendum vs. inline edits to §23/§17 proper.

I lean: addendum for both — the rev-2 addendum already supersedes the
upstream sections.

ANSWER: No Preference

---

## Q13. Stale POD / comment sweep — single commit or per-file

POD/comment fixes (items 9–14, 16, 19 from the audit):

- `archive.pm:21` — drop "M2 step 14, not yet implemented".
- `Log.pm:387` POD examples 0→1.
- `IOParser.pm:146` POD examples 0→1.
- `IOParser/Stream.pm:91` POD examples 0→1.
- `RunService.pm:343` "state.json" → "report.jsonl.zst".
- ARCHITECTURE.md addendum updates.
- `Filter/Quiet.pm`, `Filter/Verbose.pm`, `Renderer/JUnit.pm`,
  `replay.pm` — drop "Streamer" wording.
- `Collector.pm:1077`, `Log/DB.pm:1522` — tempdir name cleanup.

Pick:

- **(A)** One commit "docs: post-refactor comment + POD sweep" covering
  all of the above.
- **(B)** Group by subsystem: one commit for Log/Collector POD, one for
  Renderer/Filter, one for ARCHITECTURE.md.

I lean (A) — purely cosmetic, easier to review as one diff.

ANSWER: A

---

## Q14. Unused — anything else for me to cover

ANSWER: Do not merge yet, I want another review phase first
