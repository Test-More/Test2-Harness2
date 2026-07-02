# HANDOFF — TODO_TASKS cleanup execution (2026-06-20)

State at handoff for the next session continuing the `TODO_TASKS.md` cleanup work.

## Current state

- **Branch `2.0d`**, HEAD `4224bc567`. Working tree clean (only untracked scratch
  files: `19_*`, `bloat_*`, `review_*`, `doc_refactor_*`, `do`, `t2clib`, etc.).
- **Both suites GREEN** at HEAD: `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` (Files=109,
  Tests=1751) AND `AUTHOR_TESTING=1 yath test -D -j16` (PASSED). Run **both**, always
  `AUTHOR_TESTING=1`, always `-j16`. No `scripts/yath`. (See AGENTS.md Testing.)
- **Test2-Collector** (external, via `t2clib` symlink) has one commit from this work:
  `680e751` (multi-pid `watch_parent_pid`). It must stay installed/current.

## The three planning docs (read these first)

- **`ARCHITECTURE.md`** — target state (§4.2 runner, §4.7/§4.7a preload + resource,
  §4.10 interactive, §5.4 spawn/reap, §6.1 multi-run).
- **`TODO_STEPS.md`** — broad migration chunks (1-23) + status.
- **`TODO_TASKS.md`** — the 26 cleanup tickets (#1-#26) with per-ticket Status.
- **`TODO_DONE.md`** — full per-ticket completion record + review notes + every
  deferral. **This is the authoritative log of what landed and why.**

> NOTE: ticket numbers (#1-#26) are NOT the same as TODO_STEPS chunk numbers. A
> ticket's `Step:` line names its parent chunk.

## What's done (24 of 26 tickets fully)

✅ #1-#7, #9-#19, #22-#26 fully landed; all integrated on 2.0d, suite green at each.
Highlights: connection-identity foundation (#1), single 4-state stage lifecycle (#2),
the chunk-19 keystone — connection-currency + `requeue_task` + preload-root-crash-fatal
(#3), runner self-restart deleted + no-preload fork+exec (#4), **the big untanglement —
runner & preload-root are now two independent classes (`Preload::Host`), ZERO rootpid
guards (#22)**, Stage classes renamed (#23), Resource→Role (#24), and **#10 (chunk 23 +
chunk 11): resolver/file_stage/eager eliminated, client-side stage assignment via 3
directives, full §4.7a preload Resource**.

## Remaining work

### 3 cleanup tickets still open (DOABLE — not parked)

These are real, decided, applicable cleanup tickets — verified still present in code:

- **#8 — Collapse IPC controller: Part 4 only.** Parts 1-3 done (`280720efb`). Part 4
  = migrate **no-preload** job completion onto the collector socket report + delete
  `Runner::set_proc_exit`'s job branch. DEFERRED because it's a **rewrite, not a
  cleanup**: the runner makes the retry-vs-stop-vs-bail decision from runner-side proc
  state (`is_try`/`retry`/`bailed_out`) the collector doesn't
  have. Needs the retry/bail decision relocated + a fire-exactly-once transition-vs-reap
  ordering fix. Target is ARCHITECTURE §5.4. (Don't touch `Preload::Host::set_proc_exit`
  — legitimate multi-child reaping.)

- **#20 — Preload `require` happens outside the guard.** STILL APPLICABLE:
  `Preload::_handshake` (Preload.pm:329) calls `_load_preloads` (349) at handshake,
  before `test2_start_preload` → require-time Test2 side effects escape the guard +
  double-load. **Decided fix (lightweight handshake):** handshake = dial + identify +
  `get_preload_list` only (NO `_load_preloads`, NO `set_stage_data`); load preloads
  **once under the `test2_start_preload` guard** in the stage-host flow; report
  `set_stage_data` + warnings AFTER the guarded load. The runner already blocks on
  `_ready_to_schedule`, so no runner change. Deletes `_load_preloads` + the duplicate
  load. See ARCHITECTURE §4.7 + TODO_DONE #20-discussion. NOTE: post-#22 the stage-host
  is `Preload::Host`; confirm where the guarded load lives now.

- **#21 — Preload failure: diagnostics simplify + configurable timeouts.** Depends on
  #20. STILL APPLICABLE: `Runner::_emit_preload_failure_output` (Runner.pm:715) still
  does the inline `Zstd::FrameBuffer` event-file scrape — **delete it**; the runner only
  needs to know a stage failed (the renderer already surfaces the recorded error). Also:
  the hardcoded **60s** (Runner.pm:1016) + **30s** (Preload.pm:398) deadlines → make
  **configurable settings**; add an optional/generous/off-by-default **per-stage startup
  timeout** (covers `starting` AND `restarting`) enforced by the preload Resource (#10
  built it) → too-long → `available` = -1 (skip/fail). See ARCHITECTURE §4.7a.

### Parked — needs a design conversation with the user (NOT autonomous)

- **TODO_STEPS chunk 13 — `yath spawn`** (direct stage socket, `dup2` IO sharing per
  §4.8, double-fork no collector). Real migration feature.
- **TODO_STEPS chunk 20 — interactive mode rewrite** (socket FD-share, §4.10).
  **Interactive is currently BROKEN** (deliberately — #4 removed the goto-file FIFO
  launcher; the owner accepted this). The rewrite reuses the chunk-13 spawn mechanism.
  The user said this needs a larger conversation and has ideas. Do NOT attempt blind.

### Deferred sub-parts of completed tickets (follow-ups, in TODO_DONE)

- **#3:** harness preload-root-watch wiring (the multi-pid collector capability landed,
  but adding the preload-root to the *stage* collectors' watch list hit a teardown race
  — deferred; crash is covered transitively since preload-root crash is fatal). Also the
  Part-5 explicit stage-ack protocol (the no-send requeue landed; ack-before-dispatched
  did not).
- **#22 residuals:** flatten the now-vestigial `setjump "Stage-Runner"` loop in the
  no-preload `run_tests`; make `run_scheduler_only` the runner's ONLY run path (collapse
  the no-preload fork path into it, delete `_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS`).
- **One stale comment:** `Runner/Role/Scheduler.pm:~120` still says tasks dispatch to
  "preload-<stage>.socket" but the code uses `service_send` over the registered channel
  (wording only; the #15 comment-sweep left it as a code-accuracy item).

## How this work was run (orchestration playbook)

- One ticket (or producer/consumer half) per **fresh general-purpose agent** in an
  **isolated git worktree** (`isolation: "worktree"`). Each agent: reads AGENTS.md +
  its ticket + STYLE_GUIDE, implements, runs BOTH suites, commits in its worktree.
- **I (orchestrator) integrate**: cherry-pick the agent's commits onto 2.0d, resolve
  conflicts, run the combined suite, then record in TODO_DONE.md + flip the TODO_TASKS
  status. Agents do NOT edit the TODO_*.md files.
- Ran in batches of up to ~4 parallel agents on **file-disjoint** tickets; serialized
  anything touching the same hot files (Runner.pm/State.pm/Handlers.pm).
- **Worktree quirk:** agent worktrees spawn on a stale 1.0-era base; each agent must
  `git merge --ff-only 2.0d` first (they all did). Agent commits end up based on 2.0d so
  cherry-picks are clean.
- **Commit trailers** (every commit, both repos):
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and the
  `Claude-Session:` line.

## Housekeeping

- **~9 leftover `worktree-agent-*` worktrees + branches** accumulated — `git worktree
  remove`/`branch -D` started getting permission-denied mid-run, so cleanup is
  incomplete. Harmless but should be pruned (needs permission). Command:
  `git worktree remove --force <path>` per leftover, then `git worktree prune`, then
  `git branch -D worktree-agent-*`.
- Stale background-task re-notifications from finished agents are a runtime artifact —
  ignore them.

## Recommended next steps (in order)

1. **#20 then #21** (preload guard + diagnostics/timeouts) — both decided, applicable,
   green-achievable cleanups. #21 depends on #20.
2. **#8 Part 4** — only if you want the full IPC collapse; it's a rewrite (§5.4), treat
   as its own focused effort.
3. **#22 residuals** — small, makes the runner truly scheduler-only.
4. **Chunk 13 (`yath spawn`) + chunk-20 interactive rewrite** — design conversation
   with the user first (they have ideas; interactive is intentionally broken meanwhile).
