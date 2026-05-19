# Codex Review Notes For Claude

Review target: documentation produced from `new_plan` for the ground-up
`Test2::Harness2` / `App::Yath2` rewrite.

## Summary

The overall direction is good: the new docs remove `IPC::Manager`, put the
database at the center, split `Test2::Harness2` from `App::Yath2`, and capture
the Part 1 / Part 2 boundary. Before continuing, fix the concrete issues below.

## Must Fix

1. **Do not leave the doc-only task mixed with broad unrelated deletions.**

   `git status --short` currently shows the requested docs plus a very large
   set of deleted code, tests, schema files, release files, and AI docs. The
   prompt was explicitly documentation-only and said no worktree was needed for
   this part. Before committing or asking for review, isolate the documentation
   changes from any unrelated deletes. If the deletions were intentional from a
   previous task, keep them out of this doc review commit; if they were accidental,
   restore them.

2. **Resolve the collector/auditor DB access contradiction.**

   `ARCHITECTURE.md` says collectors and auditors must never touch the DB
   directly and that all writes go through the recorder
   (`ARCHITECTURE.md:269`). `PART_1_PLAN.md` later says collectors and auditors
   may issue SQL on their own DBI handle directly (`PART_1_PLAN.md:217`).

   Pick one rule and make both files agree. The cleaner rule, and the one that
   preserves the `Files` recorder test path, is: parser / auditor / collector
   core do not own DB handles; DB writes go through recorder methods; the DB
   recorder itself may use raw SQL for hot paths.

3. **Fix misleading Part 2 database/log-backend wording in `AGENTS.md`.**

   `AGENTS.md:8` describes Part 2 as including "log archive / database
   backends", but `PART_2_PLAN.md:56` says there is intentionally no separate
   `App::Yath2::DB` layer and the harness database is the archive. Reword the
   Part 2 summary to "read-side tooling on the harness database" or similar.

4. **Do not make untracked `new_plan` a long-term canonical source.**

   `AGENTS.md:54` lists `new_plan` as a canonical source of truth. That file is
   untracked scratch input, and the assignment was to consume it into durable
   docs. Keeping it canonical invites future conflicts and stale references.
   Prefer: keep `ARCHITECTURE.md` authoritative, mention `new_plan` only as
   historical input if needed, or track/rename it deliberately if the user wants
   it preserved.

## Should Fix

5. **Clean up spelling / wording introduced from `new_plan`.**

   Do a pass for typos and terms that will become API vocabulary. Examples seen
   in source material include "stull", "abandining", "stdour", "mized",
   "asusme", "comming", "assoicated", "requets", "heret", "finalise/finalize"
   inconsistency. The generated docs are much cleaner than `new_plan`, but still
   do one final `rg` / read-through before review.

6. **Clarify whether Stage 1/2/3 splitting is intentional.**

   `new_plan` lists the collector namespace as the first top-level stage and
   includes utility, zstd/jsonl, Stream2, and Event porting as dependencies
   inside that stage. `PART_1_PLAN.md` splits these into Utility, Stream2, then
   Collector stages. That is probably a better execution order, but add one
   sentence saying the first `new_plan` stage was split into prerequisite stages
   so agents do not think the plan accidentally changed stage semantics.

7. **Tighten `AGENTS.md` references to old prompt-era docs.**

   `AGENTS.md:34` says to compare old3 against `ARCHITECTURE.md`,
   `STYLE_GUIDE.md`, or `new_plan`. Once `new_plan` is no longer canonical,
   remove it from this conflict rule. The stable rule should be old reference
   trees lose to current root docs, especially `ARCHITECTURE.md`.

## Verified Good

- The new architecture clearly removes `IPC::Manager` and avoids the old
  harness-service / run-service topology.
- `PART_1_PLAN.md` records that Part 1 must not touch `App::Yath2*` and must
  append deferred App-side notes to `PART_2_PLAN.md`.
- `PART_2_PLAN.md` captures the important future App-side notes from
  `new_plan`: `yath spawn`, persistent runner discovery, stale `.t2h2`
  cleanup, `--no-resource=TempDir`, and project auto-detection.
- `STYLE_GUIDE.md` correctly updates the sleep guidance to use
  `Time::HiRes::sleep` directly for sub-second poll sleeps.
