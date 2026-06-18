# MIGRATION.md

Living status tracker for the **yath 1.0 → 2.0** transition.

yath 2.0 is built by **evolving the 1.0 codebase in small, reviewable chunks**
(not a ground-up rewrite). This document is the single source of truth for
*where that transition stands*. Any agent doing transition work reads this
first to learn the current state, then updates it after landing a chunk.

This file tracks **status**; it is deliberately short and current. The *target
architecture* lives in `ARCHITECTURE.md`; the *how-to-work* rules live in
`AGENTS.md`. Do not duplicate those here — point at them.

## How to use this document

- **Before starting transition work:** read this file top to bottom, then read
  the section of `ARCHITECTURE.md` for the subsystem you are touching.
- **After landing a chunk:** flip its status below, record the commit
  reference(s), and update "Current state". Keep entries terse — status, not
  narrative. Move detail into commit messages or an `AI_DOCS/` entry when one
  is warranted (see `AGENTS.md` "AI task documentation").
- **Keep it honest:** if a chunk is partially done, say so and note what
  remains. A new agent must be able to trust this file.

## Key documents

- **`ARCHITECTURE.md`** — authoritative aspirational target-state spec.
  §1.1 holds the migration order; each subsystem section carries a status tag
  (`[1.0]` / `[migrating]` / `[target]`).
- **`IPC.md`** — living **current-state** map of IPC, the process tree, reaping,
  sockets, and on-disk artifacts + their consumers (the counterpart to
  `ARCHITECTURE.md`'s target view). Shows only what is true now — nothing removed,
  nothing aspirational. **Keep it current in the same change** whenever a chunk
  alters IPC, process topology, reaping, sockets, or files created/consumed.
- **`AGENTS.md`** — per-repo workflow, pre-review checks, dependency rules,
  commit/worktree policy, testing instructions.
- **`STYLE_GUIDE.md`** + **`STYLE_GUIDE_AGENT_CHECKLIST.md`** — code style and
  the self-audit checklist walked before handing work back.
- **`new_plan`** — the original transition brief (broad strokes).
- **`migration_revision`** — the brief that fleshes out chunks 4-6 into the
  runner-service + socket-IPC design. Its content is folded into the
  "Chunks 4-6 detailed plan" section below.
- **`AI_DOCS/2026-06-16-post6-redesign-source-notes.md`** — durable copy of the
  `thoughts` / `thoughts2` briefs that drive the post-6 chunks (9-16); their
  decisions are restated in `ARCHITECTURE.md` and mapped in the table above.
- **`reference/`** — read-only prior iterations (immutable; copy out to reuse).
  Beyond `legacy`/`old2`/`old3`/`old4`/`botched`, the abandoned 2.0 feature
  branches are snapshotted as the best reference for their subsystems:
  `2.0b` (collector swap + Monitor + harness-service MVP),
  `harness_service` (Role::Service, scheduler, system-load service),
  `dbix_quickorm` (DBIx::QuickORM layer), `painter` (renderer),
  `io_events` (in-tree formatter IO-events). `reference/notes/` holds
  working notes from that abandoned-branch era.

## Ground rules (current)

- **Branch:** `2.0d` (cut from `1.0`). Commit **directly** to it — the
  foundations override in `AGENTS.md`/project policy means no worktrees or
  feature branches until the user declares foundations done.
- **Testing:** `prove -Ilib -j16 -r t/`. The `-Ilib` is **mandatory** — it is
  what makes the suite exercise this repo's `lib/` instead of any installed
  1.0 (`Test2::Formatter::*` / `Test2::Tools::*` collide by name with the
  installed dist; `-Ilib` wins). Not self-hosting yet, so `yath test` is not
  used to run our own suite.
- **`Test2-Collector`** is a hard dependency and must be installed (declared
  in `dist.ini`).
- Each chunk stays small and keeps the suite green.
- **Do not rename** (decided): `Test2::Formatter::*` and `Test2::Tools::*`
  (much becomes obsolete with the collector swap), and the `App::Yath::Script`
  namespace itself (only its `V#` handler is ours).

## Migration chunks

Order mirrors `ARCHITECTURE.md` §1.1. Status: ✅ done · 🚧 in progress · ⬜ not started.

| # | Chunk | Status | Refs |
|---|-------|--------|------|
| 1 | Mechanical renames + version bump | ✅ | `2ea678e`, `aa6e5eb` |
| 2 | Argument processing → `Getopt::Yath` | ✅ | `3270b30`..`213b5bd` + this task's deletion/POD/docs commits |
| 3 | Collector swap → `Test2-Collector` (yath collector reads `.jsonl.zst`) | ✅ | `fa49f2b65` (merge) |
| 4 | Collectors everywhere (runner + preload stages) | ✅ | 4a ✅ `bf1081ab0` (merge) · 4b ✅ `46e75cd55` |
| 5 | Runner service + socket IPC (state sync, transition pipelining) | ✅ (transient + persistent; §6.1 serialized+routed) | 5a `ceec15894` · 5b `24cb1e798` · 5c `654a742b7` · 5d `c888157ad` · 5e `625079b01` · 5f `c6291a197` · 5g `3b0704488` · §6.1 `e881efa8f`,`f647c84c9`,`944757b05`,`59210f9e2`,`fb5e07174`,`5959fe720`,`6a0fdecc9`,`3a4586b31`,`a9ade9a7b` |
| 6 | Renderer: interim (commands own renderers) → base-renderer rewrite | ✅ | 6a `9c3ce01ae` (interim) · §4.5 base renderer `4410c8105` · watch/flat-logs retired `f9142217c` |
| 7 | System-load service (own process, reliable tick → reports load to runner) | ⬜ (9 done; rides §5.2) | — |
| 8a | Database + UI inline (**interim**, DBIx::Class, SQLite logs) | ✅ | `2d09d348a` (merge) |
| 8b | Convert inlined UI schema `DBIx::Class` → `DBIx::QuickORM` (the §2.4/§4.6 target) | ⬜ (deferred) | — |
| 9 | Unified service channel — full bidirectional RPC (identity + request_id-correlated request/response, no ordering), `Service::Connection` + `Role::Service` (§5.2); collapsed runner↔stage onto it; commands are peers | ✅ | `ba9bde35a` · `55c21a227` · `4baf34996` (Connection) · `9dc30a408` (RPC protocol) |
| 10 | Preload stage lifecycle states (`starting`/`restarting`/`down`) + stage-owned restart (§4.7) — registration + dispatch-over-registered-channel landed in 9 | ⬜ (residual) | — |
| 11 | Preload as a scheduler resource (§4.7a) — needs 10 | ⬜ | — |
| 12 | Discovery via runner-socket symlink + `PID`-file signal fallback (§5.3) | ⬜ | — |
| 13 | `spawn` bypasses runner: direct stage socket, dup2 IO, double-fork no collector (§4.8) — needs 9,10,12 | ⬜ | — |
| 14 | Split `Test2::Harness2::TestFile` → `App::Yath2` reader + state-only Harness2 object (§1) | ✅ | this task |
| 15 | Final renderer ordering (cross-job, post-§4.5 interim) | ⬜ | — |
| 16 | Concurrent run execution + run-scoped preload stages (§6.1) — needs 9,10 | ⬜ | — |
| 17 | Plugin `setup`/`teardown` move to the runner; aux output → collectors (`run_collected`); retire the `aux_logs` flat files | ✅ | this task |
| 18 | Collectors watch the runner pid → self-terminate if the runner dies (ARCH §4.1); + a code-review gate enforcing it | ✅ | this task |

Chunks 1-8a have landed. Chunks **9-16 are the post-6 revised-target work**
(the `thoughts` / `thoughts2` decisions); see "Next" below. Numeric order is
**not** execution order — dependencies are noted per row. Chunk 7 (system-load)
also depends on chunk 9 (the unified channel it rides).

Chunks 4-6 are broken into substeps in the **"Chunks 4-6 detailed plan"**
section below (the runner-service + socket-IPC design from `migration_revision`).
That section describes the **as-shipped** end state of 4-6; where chunks 9-16
revise it, the substeps are annotated below.

## Done so far

**Chunk 6 complete — base-renderer rewrite + finish the socket-IPC end state**
(`69ae0be63`, `b33162faf`, `4410c8105`, `f9142217c`, `1b5373e1a`, `ddaed0a0c`,
`3d9152cd1`; on branch `chunk5-runner-service`, **not yet merged**):
- **§4.5 base renderer** (`4410c8105`): new `Test2::Harness2::Renderer::Base`
  holds a transition-state mirror (`Runner::Monitor`), locates each collector's
  `.jsonl.zst` from that state, reads it by path (`JobReader`/`RunnerReader`),
  rolls up `harness_final`, and fans recorded events to `render_event` **sink**
  renderers (`Renderer::Formatter` → terminal; `App::Yath2::Renderer::{DB,Server}`)
  + the logger. The 6a `Renderer::Driver` is now a thin subclass holding ONLY the
  interim per-job 3-phase ordering (kept out of the base, so a future
  streaming/cross-job renderer reuses Base).
- **`watch` + flat-logs retired** (`f9142217c`): the runner collector-wrap moved
  into `Test2::Harness2::Runner->start_collected` (ARCH §4.2 — both transient and
  persistent runners wrapped uniformly); persistent preload stages are
  collector-wrapped too. `yath watch` is now a **global (no-run-id)
  `runner.socket` subscriber** rendering runner/stage output through `Renderer::Base`;
  the SIGHUP-reload message surfaces as a recorded runner event. `output.log` /
  `error.log` are gone — **the only IPC files anywhere are now `events.jsonl.zst`**
  (chunk 17 retired the last exception, the `aux_logs` plugin shell-call path).
  (pfile now records the runner's own pid, since the collector ignores HUP.)
- **`dispatch.jsonl`/observe machinery fully retired** (`1b5373e1a`): `resources`
  now queries the runner over the socket (`request_handler_resources`, like
  `status`/`ps`); the dead `dispatch_file`/`poll`-drain/`observe`/`.test_info`
  State plumbing is deleted.
- **Cleanups** (`69ae0be63`, `b33162faf`): dead `no_poll` State path removed;
  `Runner.pm` split (handlers + scheduler → `Runner::Role::*`), 1276 → 844 code
  lines (under the 1000-line guide).
- **Flake fixes:** `smoke.t` start-stamp tie (`ddaed0a0c`) and a real
  trailing-runner-output drop — the socket-close completion racing the runner
  collector's flush of late stdout into `runner-events` — fixed by draining
  runner-events to its terminal before finalize (`3d9152cd1`, `resource.t`).
- Suite reliably green: `Files=91, Tests=1662, Result: PASS` (confirmed across
  many clean full runs; resource.t 27/27 + smoke.t 10/10 isolated).

**Chunk 5 (5a-5g) + 6a — runner service, socket IPC, command-side renderer**
(`ceec15894`, `24cb1e798`, `654a742b7`, `c888157ad`, `625079b01`, `c6291a197`,
`9c3ce01ae` (6a), `3b0704488` (5g); on branch `chunk5-runner-service`, **not yet
merged**):

> **Historical snapshot — state as of 5g+6a.** The "Still flat-file" and "Also
> not built / deferred" bullets below were the gaps *at that point*; chunk 6
> (above) later closed most of them. Resolved items are annotated inline — read
> the chunk-6 block and "Current state" for what is true now.
- The **transient `yath test`** runner is now a collected **socket service**
  (`runner.socket`) with an **in-process scheduler** (no separate scheduler
  process, no `dispatch.lock`). New: `Test2::Harness2::Role::Service`, the
  `Runner::{Client,Stage,Stage::Client,Monitor,Subscriber,Watchdog}` family, the
  command-side `Test2::Harness2::Renderer::Driver`, and neutral by-path readers
  `Test2::Harness2::{JobReader,RunnerReader}` (moved out of `Collector::*`). All
  wire traffic reuses `Test2::Collector::Util::{Socket,Zstd,Zstd::FrameBuffer}` /
  `Recorder::Socket` — no harness-local copies.
- `test` submits runs **over the socket**; preload **stages are socket services**
  the runner dispatches to and which report back; every non-runner collector
  streams **transitions** to the runner, folded into canonical state
  (`Runner::Monitor`); clients **subscribe** for a snapshot + forwarded mutations
  (`Runner::Subscriber`). The `test` command **renders entirely from that
  subscription** + per-job events files (6a `Renderer::Driver`); the **gatherer
  is retired on the transient path** (5g), with stalled-job abort moved to the
  runner (`Runner::Watchdog`) and completion signalled by the runner closing the
  socket. Retired on the transient path: `run_queue.jsonl`, `dispatch.jsonl`,
  `dispatch.lock`, `queue.jsonl`, `jobs.jsonl`, the scheduler process, the
  gatherer spawn, and the `kill(0)` liveness — **the only transient IPC files left
  are `events.jsonl.zst`.**
- **§6.1 (persistent path migrated — serialized + per-run routing)** (`e881efa8f`,
  `f647c84c9`, `944757b05`, `59210f9e2`, `fb5e07174`, `5959fe720`, `6a0fdecc9`,
  `3a4586b31`, `a9ade9a7b`): the persistent `yath start` runner now runs the same
  socket service; `run` / `spawn` submit + subscribe over `runner.socket` (via the
  command-side `App::Yath2::Client`) and render via the subscription `Driver`;
  `stop` shuts down over the socket. The runner's canonical state is **keyed by
  run** and each client is routed only its run's transitions (`run_uuid`==`run_id`
  key; stage/runner-lifecycle transitions broadcast as a global bucket; no-run-id
  = global subscriber). Persistent preload **stages are socket-dispatch services**
  too and State always runs in-memory `direct` mode. `status` / `ps` / `abort` are
  served over the socket (`Runner::StatusReport`). The **gatherer
  (`Test2::Harness2::Collector`) is deleted outright**, and `dispatch.jsonl`,
  `jobs.jsonl`, `queue.jsonl`, `run_queue.jsonl` are all gone — **the only IPC
  files anywhere are now `events.jsonl.zst`**, except the flat-log shim below.
- **Refactor — shared command libs** (`2222e3bef`, `b1350c52d`, `84d88f06c`):
  extracted `App::Yath2::Pfile` (persistent discovery), `App::Yath2::RunPlan`
  (run/queue construction), and `App::Yath2::Client` (command-side socket
  submit/subscribe) out of `test`/`run`/`start`, each unit-tested.
- **Still flat-file (the one remaining non-events IPC):** `watch` tails the
  persistent runner's `output.log` / `error.log` / `aux_logs`. Retiring it needs
  the persistent runner + stages collector-wrapped and `watch` migrated to a
  global socket subscription — coupled to the SIGHUP-reload message `watch` reads
  from `output.log` (`persist.t` asserts it). Flagged follow-up.
  **→ RESOLVED in chunk 6 (`f9142217c`):** `output.log` / `error.log` are gone;
  `watch` is a global `runner.socket` subscriber and the reload message is a
  recorded runner event.
- **Also not built / deferred:** concurrent run *execution* (persistent stays
  serialized); run-scoped preload stages as a user feature (only the per-run
  subdir socket naming `runs/<run_id>/preload-<stage>.socket` foundation exists);
  moving the runner collector-wrap into `Runner->start`; the §4.5 base-renderer
  rewrite (6a is interim); dead `State` dispatch-file plumbing (file never created
  now) to remove; `Runner.pm` is 1426 lines (over the 1000 guide) — split
  candidate.
  **→ chunk 6 closed most:** collector-wrap moved into `Runner->start_collected`,
  the §4.5 base renderer landed (`4410c8105`), and `Runner.pm` was split to 844
  lines. **Still open:** concurrent run execution + run-scoped stages (now
  chunk 16); see "Next".
- A pre-existing `smoke.t` flake (start-stamp tie under `-j3`) was fixed
  (`ddaed0a0c`). Suite green throughout; final `Files=88` (`Result: PASS`,
  confirmed across 13 consecutive clean full runs).

**Foundations** (pre-chunk):
- Agent governance docs landed and reconciled to the evolve-from-1.0 plan
  (`ARCHITECTURE.md` rewritten aspirational — `1cd766f`; `AGENTS.md` +
  checklist — `8d002ca`).
- `reference/` rebuilt: curated base + abandoned-feature-branch snapshots
  (`e704dd7`, `f9d0f16`).

**Chunk 1 — mechanical renames + version bump** (`2ea678e`, `aa6e5eb`):
- `App::Yath` → `App::Yath2`, `Test2::Harness` → `Test2::Harness2`.
- `App::Yath::Script::V1` → `::V2` (`App::Yath::Script` namespace + external
  dispatcher dependency unchanged).
- All `$VERSION` `1.000173` → `2.000000`.
- Distribution `Test2-Harness` → `Test2-Harness2` (dist.ini, Makefile.PL) — so
  an installed 2.0 co-exists with an installed 1.0.
- Test-fixture modules and unit-test dir layout moved to the `*2` paths.
- Verified the suite runs against `lib/`, not installed 1.0.
- Suite green: `Files=67, Result: PASS`.

**Chunk 2 — argument processing → `Getopt::Yath`** (`3270b30`..`213b5bd` +
this task):
- All option, command, and plugin declarations converted to `Getopt::Yath`.
- `App::Yath2` parse flow swapped to `Getopt::Yath` two-stage processing;
  `Test2::Harness2` consumes `Getopt::Yath::Settings` throughout.
- The 1.0 option machinery (`App::Yath2::Options`, `App::Yath2::Option`,
  `Test2::Harness2::Settings`, `…::Settings::Prefix`) deleted.
- Release POD generators rewritten for the `Getopt::Yath::Instance` API;
  option/command/plugin POD regenerated.
- Suite green: `Files=63, Result: PASS`.

**Chunk 4b — wrap each transient preload stage in a collector** (`46e75cd55`):
- `Test2::Harness2::Runner::Preloader::launch_stage` now wraps each forked
  preload stage of the **transient** `yath test` runner in its own non-test
  `Test2::Collector` (`is_test => 0`), writing `stage-<name>-events.jsonl.zst`
  in the workdir. The stage process escapes the collector's `run_sub` via
  `Long::Jump` (no added stack frame — the same mechanism preloads/test jobs
  use) and carries on as the stage; the collector parent `POSIX::_exit`s with
  the stage's verdict (`collector_exit_code`), so reaping/respawn is unchanged.
- The gatherer (`Test2::Harness2::Collector`) discovers and tails those per-stage
  events files (reusing `RunnerReader` with a per-stage `label`), gated on
  `show_runner_output` exactly like the runner stream — so stage output that
  used to ride the runner's shared pipe stays visible.
- The **persistent** runner (`yath start`) is intentionally left on the flat
  `output.log`/`error.log` shim (chunk-4a parity): its stages are not collected,
  so `yath watch` still sees their output. `persist` is threaded
  Runner → Preloader to make that distinction.
- New `Test2::Harness2::Util::stage_events_file`; `RunnerReader` gained an
  optional `label`. Tests: `t/AI/integration/stage_collectors.t` (end-to-end
  stage stdout/stderr visible) + a `RunnerReader` label unit subtest.
- Monitor/reload restart: a stage that restarts reuses its events-file path, so
  the stage collector is marked **`resumable`** (new `Test2::Collector`
  attribute, `eabf87e` in Test2-Collector) when the preloader is monitoring — it
  closes without a terminal `harness_process_exit`, the next incarnation appends
  to the same file, and the gatherer's tail reader streams across the restart.
  Without monitor a stage runs once and finalizes normally.
- Suite green: `Files=78, Result: PASS`.

**Chunk 4a — wrap the `yath test` runner in a collector** (`bf1081ab0` merge):
- The non-test `yath test` runner now runs as the exec target of a
  `Test2::Collector` (`is_test => 0`); its stdout/stderr/exit become first-class
  timestamped events in `runner-events.jsonl.zst`.
- New `Test2::Harness2::Collector::RunnerReader` (the runner-stream sibling of
  `JobReader`) reads that file back; non-zero runner exit is surfaced as a
  visible diagnostic. `Test2::Collector` declared as a dependency.
- Paired Test2-Collector change: non-test collectors finish at reap instead of
  waiting for pipe EOF / the orphan window, so the gatherer's `kill(0)` runner
  liveness is prompt. Regression guard: `t/integration/runner_death_liveness.t`.
- Suite green: `Files=77, Result: PASS`.

## Current state

- **Namespaces/versions:** fully on the 2.0 names (`App::Yath2`,
  `Test2::Harness2`, dist `Test2-Harness2`, versions `2.000000`).
- **Option handling:** now `Getopt::Yath`. The settings object is
  `Getopt::Yath::Settings` (the 1.0 `App::Yath2::Options` / `App::Yath2::Option`
  / `Test2::Harness2::Settings` machinery is deleted).
- **Collector pipeline:** swapped to `Test2-Collector` (chunk 3, merged
  `fa49f2b65`). Each test job runs under its own collector and writes
  `events.jsonl.zst`. The **`yath test` runner** is wrapped too (chunk 4a, merged
  `bf1081ab0`, read via `RunnerReader`), as are the transient runner's **preload
  stages** (chunk 4b). The standing yath-side gatherer
  (`Test2::Harness2::Collector`) — which in the chunk-3 era walked the workdir,
  read those files via `JobReader`, and re-attached UUIDs — is **now deleted
  outright** (5g + §6.1): both `yath test` and persistent `yath run` render from
  the runner subscription via the command-side `Renderer::Driver`. `JobReader` /
  `RunnerReader` survive only as neutral `Test2::Harness2::*` **by-path** readers.
  See Runner IPC below.
- **Runner IPC (both `yath test` and persistent `yath start`/`run`):** fully on
  the **socket model** (chunk 5 + 6a + §6.1). The runner runs as a collected
  **service** bound to `runner.socket` with an **in-process scheduler** (no
  separate scheduler process, no `dispatch.lock`) and in-memory `direct` State.
  Commands are thin clients: `test`/`run`/`spawn` **submit over the socket**
  (`App::Yath2::Client` → `Runner::Client`) and **subscribe** scoped to their
  `run_id` (`Runner::Subscriber`); `stop` shuts down over the socket;
  `status`/`ps`/`abort` query the runner over the socket
  (`Runner::StatusReport`). Preload **stages are socket-dispatch services**
  (`preload-<stage>.socket`; run-scoped naming `runs/<run_id>/preload-<stage>.socket`
  reserved). Every non-runner collector streams **transitions** to `runner.socket`,
  folded into the runner's **per-run-keyed** canonical state
  (`Runner::Monitor`); each client is routed only its run's transitions (stage/
  runner lifecycle broadcasts globally). Both `test` and `run` **render from the
  subscription** via `Renderer::Driver`, fetching each job's `events.jsonl.zst` by
  path at completion via the **base renderer** `Renderer::Base` (chunk 6 §4.5;
  `Driver` is the thin interim-ordering subclass). The persistent runner + its
  stages are collector-wrapped (the runner wrap lives in `Runner->start_collected`,
  ARCH §4.2), and `yath watch` is a **global `runner.socket` subscriber** rendering
  runner/stage output through `Renderer::Base` (the SIGHUP-reload message is a
  recorded runner event). Stalled-job abort is the runner's (`Runner::Watchdog`);
  run completion is a `harness_run_end` transition (and, for `test`, the runner
  closing the socket — the command drains `runner-events` to its terminal before
  finalizing so late runner output isn't lost). All wire traffic reuses
  `Test2::Collector::Util::{Socket,Zstd,Zstd::FrameBuffer}` / `Recorder::Socket`.
  **The only IPC files anywhere are now `events.jsonl.zst`** — `run_queue.jsonl`,
  `dispatch.jsonl`, `dispatch.lock`, `queue.jsonl`, `jobs.jsonl`, and the
  `output.log`/`error.log` flat shim are all gone (the `aux_logs` plugin shell-call
  path is the lone remaining flat file, by design). **Execution stays serialized**
  on the persistent runner (one active run at a time) — §6.1 routed runs per-client
  but did not add concurrent execution. The system-load service is still chunk 7.
- **Web UI:** inlined (chunk 8a, merged `2d09d348a`) under `App::Yath2::Server*`
  / `App::Yath2::Schema*` (+ `Command::{server,db/*,client/*}`,
  `Options::{DB,WebServer,Server,WebClient,Publish,Yath}`, `Plugin::DB`,
  `Renderer::{DB,Server}`), following the pre_ai_2.0 layout, on **DBIx::Class**
  (5 drivers; SQLite default for ephemeral/tests). Assets in `share/`, samples in
  `demo/`. Tests: Perl unit + HTTP smoke (`t/AI/integration/ui_server.t`) +
  Playwright (`js-tests/`, run from `t/playwright.t`). The QuickORM conversion is
  **chunk 8b (deferred)**.
- **Logic:** otherwise still 1.0 only for chunk 7 (system-load service), the
  8b QuickORM conversion, and the post-6 revised-target chunks 9-16 (unified
  service channel, stage self-registration, preload-as-resource, symlink
  discovery, spawn-bypass, TestFile split, final renderer, multi-run). The
  *currently-shipped* service IPC diverges from chunks 9-13's target (see "Next").
- **Not renamed (intentional):** `Test2::Formatter::*`, `Test2::Tools::*`,
  `App::Yath::Script`.

## Next

**Chunks 1-8a and 9 are complete.** Both `yath test` and the persistent
`yath start`/`run`/`spawn`/`stop`/`watch` paths run on the socket model with the
§4.5 base renderer; the gatherer, all coordination files, and the flat-log shim
are gone — the only IPC files anywhere are `events.jsonl.zst` (chunk 17 retired the
last exception, the `aux_logs` plugin path); the DB/UI layer is inlined on interim
`DBIx::Class`; runner↔stage runs on the unified §5.2 service channel (chunk 9).
Remaining work is chunks **7, 8b, 10-16** (see the table for numbering +
dependencies). The notes below
flesh out each chunk; the `thoughts` / `thoughts2` decisions they capture are
restated in `ARCHITECTURE.md` (§1, §4.4/§4.7/§4.8/§5.2/§5.3) so they stand without
the untracked source notes.

**Service-IPC redesign (chunks 9-13 — see `ARCHITECTURE.md` §4.4/§4.7/§4.8/§5.2/§5.3).**

- **Chunk 9 — unified service channel, full RPC (§5.2). ✅ DONE**
  (`ba9bde35a`, `55c21a227`, `4baf34996`, `9dc30a408`; AI_DOC
  `AI_DOCS/2026-06-16-chunk9-unified-service-channel.md`).
  `Test2::Harness2::Role::Service::Connection` owns a full bidirectional RPC: a
  **mandatory identity exchange** on open, `{request=>{request_id,command,...}}` /
  `{response=>{request_id,...}}` frames **correlated by id** with **no ordering
  assumption**, and a bad-frame policy (non-identity-first / timeout / 3-strikes /
  fatal-read drops). `Role::Service` keeps **one** connection set and drives them
  (`service_connect_peer` / `service_peer_conn` / `service_send($id,$cmd,%args)`),
  reuse-never-duplicate. **runner↔stage is collapsed onto it** (the stage dials
  `runner.socket`, identifies as `preload-<stage>`, reports up and receives
  dispatch down the one channel; `preload-<stage>.socket` reserved for `spawn`;
  `Runner::Stage::Client` deleted). **Commands are full peers** (`Runner::Client` /
  `Runner::Subscriber` wrap a `Connection`). Collector reporters stay a one-way
  reporter lane (transition-first, no identity).
- **Chunk 10 — preload stage lifecycle states + stage-owned restart (§4.7).**
  Registration and dispatch-over-the-registered-channel **landed in chunk 9**
  (the stage initiates and the runner treats it unavailable until `stage_ready`).
  Residual: the explicit `starting`/`restarting`/`down` lifecycle states and
  giving the stage ownership of its restart decision (today the preloader monitor
  still drives reload-respawn through the runner's `set_proc_exit` longjump).
- **Chunk 11 — preload as a resource (§4.7a).** Model preload availability
  (expected + current state) as a scheduler resource so jobs gate on it like any
  other resource. Needs 10.
- **Chunk 12 — discovery via a runner-socket symlink (§5.3).** Replace
  `yath-persist.json` with a well-known symlink to `runner.socket` (follow it to
  the socket and to the workdir). **Keep a PID fallback:** clients query liveness/
  PID over the socket normally, but read the flat workdir `PID` file
  (`Runner.pm:408`) to signal a wedged runner whose socket is unresponsive.
- **Chunk 13 — `spawn` bypasses the runner (§4.8).** `spawn` connects **directly**
  to an available preload stage's socket (stage chosen by command options / run
  match; an unconnectable or non-`up` socket is not a target), and the stage
  **double-forks** the child with **no collector**, detached. **IO sharing uses
  `dup2`** of the accepted socket onto the child's STDIN/OUT/ERR (no `SCM_RIGHTS` /
  `Socket::MsgHdr` dependency), retiring the 1.0 `/proc` IO proxying. Needs 9,10,12.

**Chunk 14 — split `Test2::Harness2::TestFile` ✅ DONE (this task).** Reading test
files to decide how they run is a UI/input concern, so the file-reading half moved
to `App::Yath2`:
- **`App::Yath2::TestFile`** — the reader (file I/O, header/shbang scan, per-file
  decisions, `queue_item`). Moved out of `Test2::Harness2::TestFile`.
- **`App::Yath2::Finder`** — moved from `Test2::Harness2::Finder` (it constructs the
  reader, so the dependency rule — `Test2::Harness2` must not load `App::Yath2*` —
  forces it onto the `App::Yath2` side). The `--finder` default + auto-prefix is now
  `App::Yath2::Finder` (was `Test2::Harness2::Finder`); custom-finder subclasses
  under the old prefix must use the new prefix or a `+`-qualified name.
- **`Test2::Harness2::TestFile`** — rewritten as a **state-only** object: a typed,
  read-only, file-free view over the task payload (`from_task` / `TO_JSON` /
  `task_data` + accessors). It never reads a test file; it is the serializable
  per-test state the runner consumes (and chunk 19 will ship to the preload-root).
- The runner already consumed only the task payload hash (mutable scheduler state)
  and read no files, so its hot path is unchanged. Proven by
  `t/AI/unit/runner_no_file_read.t` (a job builds from a payload whose file does not
  exist; the runner side never loads the `App::Yath2` reader/finder).
- Consumers updated (`Finder`, `RunPlan`, `Plugin::Notify`, POD refs); reader unit
  test moved to `t/unit/App/Yath2/TestFile.t`; new state-only unit test at
  `t/unit/Test2/Harness2/TestFile.t`. Suite green: `Files=101, Tests=1718, PASS`.

- **Chunk 7 — system-load service (needs 9).** Its own (global) process with a
  reliable tick. Per the revised §4.4 it is a **full service on the unified
  connection model**: its own listen socket, connects to the runner on startup to
  push updates, and broadcasts load state-changes to all connected peers; the
  in-runner scheduler consumes them to gate concurrency. Port
  `reference/harness_service` `SystemLoad.pm` + its sampler service shape (drop the
  run-vs-global split; adopt the §5.2 channel rather than the old
  emit-only/no-socket shape).
- **Chunk 15 — final renderer ordering (post-§4.5 interim).** `Renderer::Driver`
  still pins the interim per-job 3-phase ordering on top of `Renderer::Base`; the
  final cross-job ordering guarantees are not yet defined (§4.5 stays authoritative).
- **Chunk 8b — QuickORM conversion.** Migrate the inlined DB/UI schema from interim
  `DBIx::Class` to `DBIx::QuickORM` (§2.4/§4.6), keeping the default SQLite path on
  `DBD::SQLite` directly. Until this lands, `DBIx::Class` is an interim import, not
  accepted long-term architecture.
- **Chunk 16 — concurrent run execution + run-scoped preload stages (needs 9,10).**
  §6.1 routes per run but execution stays serialized (single active run); making
  the persistent runner run multiple runs at once, and building run-scoped preload
  stages as a user feature (the `runs/<run_id>/preload-<stage>.socket` naming is
  reserved), are the next multi-run steps.
- **Chunk 17 — plugin `setup`/`teardown` move to the runner; aux output →
  collectors; retire `aux_logs`. ✅ DONE (this task).** `setup`/`teardown` now run
  **in the runner** (ARCH §4.9): the runner invokes `setup` after `runner.socket`
  binds and `teardown` after the run loop ends (`Runner::process`, root-only). They
  ran in the *command* before — before the runner existed — which is exactly what
  forced the flat-file workaround. The runner rebuilds plugin instances from the
  resolved specs the command stashes in `harness->plugin_specs`
  (`App::Yath2::_instantiate_plugins`), since `Plugin::TO_JSON` serializes to bare
  class names.
  - **Aux output is collector events.** `shellcall` (synchronous) now wraps the
    command in `Test2::Collector::collect` (returns `collector_exit_code`);
    `run_collected` (non-blocking, replaces `fork` + `redirect_io`) uses
    `spawn_collector` (`run` => the plugin sub, or `exec` => the command) and returns
    a pid. Both build a `Recorder::Socket` reporter (identity preamble + `no_reply`)
    to `runner.socket` **plus** a file recorder, and pass `watch_parent_pid => <runner
    pid>` (chunk 18 / ARCH §4.1; the audit gate stays green). Output is folded +
    rendered + archived like job/stage output, tagged with the plugin-chosen name.
    `redirect_io`, `aux_logs`, `_step_aux_logs`, `AUX_HANDLES`, and the `File::Stream`
    tail are deleted.
  - **No detach / no double-fork.** The aux collector stays a runner child and dies
    with the runner (no `setsid`); a `run_collected` daemon's pid is tracked in a
    **separate** list (NOT the runner's child-wait set, so it never blocks
    `wait(all=>1)`) and `TERM`→`KILL`+reaped at `teardown`; `watch_parent_pid` is the
    backstop.
  - **Rendering tag.** `RunnerReader` gained a `tag` (aux collectors are named
    `aux:<name>`; `step_runner_output` tags their output with `<name>` — the
    historical `(NAME)` shape — instead of `INTERNAL`).
  - **`yath stop` renders the runner's shutdown output.** Since `teardown` runs in
    the runner at stop, `stop` primes a TAIL-mode renderer (cursor at the current end
    of `runner-events`) **before** sending the stop request, then drains until the
    runner-events terminal — so it shows only the new teardown output without
    re-rendering the persistent runner's history, and the cleanup does not race the
    final write. `RunnerReader`/`Renderer::Base` gained a `tail` mode.
  - **Divergence from 1.0:** `reference/pre_ai_2.0/` split this into
    `client_*`/`instance_*` purely for 1.0-namespace back-compat; the `*2` namespaces
    keep a single `setup`/`teardown` on the runner. (Consequence: the runner loads
    plugin modules, so test children inherit them in `%INC` — see `test.tx`.)
  - **Out of scope (note it):** a command that self-daemonizes (its own `setsid`)
    escapes the runner's process group regardless — a general "kill the whole
    tree" concern, not specific to aux.
- **Chunk 18 — collectors watch the runner pid; enforce it (ARCHITECTURE.md §4.1). ✅ DONE (this task).**
  Every collector the runner spawns now passes `watch_parent_pid => <root runner
  pid>`: the test-job collector (`Job::run_under_collector`, via
  `$self->runner->rootpid`) and the stage collector (`Preloader`, via a new
  `runner_pid` threaded from `Runner::preloader`). `Test2::Collector` then kills
  the child and finalizes/exits if the runner vanishes (crash / `SIGKILL`), so no
  collector or test process outlives a dead runner. The runner-wrap collector is
  exempt (its child IS the runner — marked `WATCH-PARENT-EXEMPT`); `yath spawn`
  has no collector.
  - **Watch the runner ONLY (decided):** a job collector watches the runner pid,
    never its intermediate stage — a stage may intentionally restart (reload) with
    a new pid and must not take the in-flight test down. Single-pid is exactly
    right.
  - **Code-review gate:** `agent_scripts/audit-collector-watch-parent` flags any
    harness `collect()` / `spawn_collector()` lacking `watch_parent_pid` (honoring
    a `WATCH-PARENT-EXEMPT` marker); wired into the mandatory pre-review checks in
    `AGENTS.md`.
  - **Behavioral test:** `t/AI/integration/runner_death_kills_collectors.t` starts
    a persistent runner, backgrounds a `yath run` of a sleeping test, `SIGKILL`s the
    runner (which does not signal its children), and asserts the test process
    self-terminates — proving the contract end-to-end (stable 5/5).
- **Minor:** revisit the conservative `Runner::Watchdog` (abort-on-wind-down) if
  active mid-run stalled detection is wanted; `resources.pm`'s auto-generated
  `OPTIONS` POD lists its old narrower option set (it now inherits the full
  run/test set) — refreshed by the author POD-regen tool.

See the "Chunks 4-6 detailed plan" below. Reference: `reference/2.0b`,
`reference/harness_service`.

## Chunks 4-6 detailed plan

Source brief: `migration_revision`. Target topology:
`ARCHITECTURE.md` §4.2 (runner service), §4.3 (transition channel), §4.7
(preload stage services), §5.2-5.3 (socket wire form + naming). Reference
prototypes: `reference/2.0b` (Monitor-style state sync, proxy fan-out),
`reference/harness_service` (scheduler, tick, system-load sampler service).
**Borrow from `harness_service` selectively** — its scheduler/tick, its
system-load sampler **service**, and `Role::Service` are reusable. What
`service_revision` removed is the **run-vs-global service split** and
run-specific services: all services are now global, per-run scope is a preload
feature (§4.7). Do not reintroduce per-run services.

> **As-shipped design — partly superseded by chunks 9-16.** This section is the
> end state *of chunks 4-6 as they landed*. The post-6 redesign (chunks 9-16,
> §4.7/§5.2) reverses two things stated below: dispatch direction
> (**stage registers with the runner**, then the runner dispatches over that
> registered channel — not runner-connects-out) and the system-load service shape
> (**a full service with its own listen socket** on the unified channel — not
> emit-only/no-socket). Those points are annotated inline; the rest still holds.

**End state of chunks 4-6.** Every process the runner forks runs under its own
collector. The runner and each preload stage are **socket services**. The only
files on the IPC path are the per-collector `events.jsonl.zst` files, used to
feed display to renderers — all decision/dispatch data moves over unix sockets
in the collector wire format (zstd-compressed JSON object frames): runner →
preload (dispatch jobs — **reversed in chunk 10**: the stage registers with the
runner and the runner dispatches over that registered channel), and collector →
runner (transition messages). Commands queue work by messaging the runner. The
1.0 coordination files (`queue.jsonl`, `run_queue.jsonl`, `dispatch.jsonl`,
`dispatch.lock`) are gone.

**All services are global harness services; there are no per-run services.** The
service kinds: the runner, preload stages, and auxiliary harness services that
report to the runner (e.g. the system-load service, §4.4 — **reversed in
chunks 7/9**: it is now a full service with its **own** listen socket on the
unified channel (§5.2), connecting to the runner to push updates *and* accepting
peers, not the emit-only/no-socket shape described here). What is **dropped** is the
run-vs-global service split and run-specific *services* — an over-extrapolation
from two preload needs (`ARCHITECTURE.md` §4.4 / §4.7 / §6.1). Per-run needs are
met by **preload-stage scope** — global stages shared by all runs (use case 1,
already the 1.0 behavior) and run-scoped stages started/torn down per run (use
case 2), a feature, not a service class. The system-load service (chunk 7) stays
its **own process** with a reliable tick (the runner loop can exceed the sample
interval), reporting load to the runner. Implementation note: port
`reference/harness_service/lib/Test2/Harness2/SystemLoad.pm` and its sampler
**service** shape; drop only the run-vs-global-split bits, not the
process/socket.

This also **eliminates the yath-side gatherer process** — today's
`Test2::Harness2::Collector` loop (the one distinct from `Test2-Collector`,
which polls the queue/job files and walks the workdir for `events.jsonl.zst`,
reconstructs run state, rolls up verdicts, and decides completion). The runner
service becomes the state authority; completion arrives as transitions; clients
read a specific events file **by the path its transition carries**.
`JobReader` / `RunnerReader` survive only as by-path readers of a single events
file, not as a discovery/orchestration loop.

Within a chunk the substep order is a guide, not a contract.

### Chunk 4 — collectors everywhere

- **4a ✅** (`bf1081ab0`) — `yath test` runner wrapped in a non-test collector;
  read back via `RunnerReader`.
- **4b ✅** — each preload stage of the **transient** `yath test` runner is
  wrapped in its own non-test collector (`stage-<name>-events.jsonl.zst`),
  escaping the collector `run_sub` via `Long::Jump` so the stage keeps running
  in-process with everything preloaded. The gatherer tails those files (per-stage
  `RunnerReader`, gated on `show_runner_output`). The **persistent** runner's
  stages stay on the flat-file shim (chunk-4a parity) until the runner service
  lands. No-preload path still forks the test job's collector directly. After 4b
  no transient-runner-forked process is without a collector.

### Chunk 5 — runner service + socket IPC

Replaces the 1.0 file-polling IPC with sockets. (Subsumes the former
"transition pipelining" step.)

- **5a ✅** (`ceec15894`) **Runner as a collected service.** Ported
  `Test2::Harness2::Role::Service` (from `reference/harness_service`, wire utils
  repointed to `Test2::Collector::Util::{Socket,Zstd,Zstd::FrameBuffer}` — no
  harness-local copies). The runner `with`s the role, binds `runner.socket`, and
  services it inside its existing run loop (`service_io`/`service_tick`, root
  process only) — the role's own `run`/`reap_children` are not used so they don't
  race `Test2::Harness2::IPC`'s reaping. Workdir propagated to children via
  `T2_HARNESS_WORKDIR` (env, merged into collector `child_env` + curated job env).
  *Flag:* the runner's non-test collector wrap still lives **command-side**
  (`App::Yath2::Command::test::start_runner`); ARCH §4.2's "`Runner->start`
  launches the runner under a collector" — moving that into `Test2::Harness2` is
  left for a later phase.
- **5b ✅** (`24cb1e798`) **Scheduler becomes an in-runner object.** Removed
  `spawn_scheduler` (the scheduler fork) and the `dispatch.lock` flock; the runner
  advances the scheduler logic (`poll` + `advance` + `resource_timeout`) itself in
  `scheduler_tick`, driven from `service_tick`. `scheduler_death.t` re-expressed
  for an in-runner scheduler (errors caught + retried to a limit then clean
  abort). *Note:* `dispatch.jsonl` was **kept this phase** as the command→runner
  submission channel (it is not purely runner↔scheduler — `test`/`run`/`spawn`/
  `abort` enqueue actions a `no_poll` State writes); only the separate **process**
  and the flock were removed here. The transient `dispatch.jsonl` retires in 5c/5d.
- **5c ✅** (`654a742b7`) **Run submission over the socket.** `test` is a thin
  client (`Test2::Harness2::Runner::Client`) that submits the run + its tasks +
  the terminator as one-way JSON request frames to `runner.socket`; the runner
  folds them into its canonical State via `request_handler_{queue_run,queue_task,
  end_queue,...}`. `run_queue.jsonl` retired (no consumer). The submitter is
  **pluggable** so the gated persistent `run`/`spawn` path keeps using the
  `dispatch.jsonl` State. *Correction to the original plan:* `queue.jsonl` is
  **not** retired here — it is kept (still written by `test`) **only to feed the
  still-living gatherer**, and retires with the gatherer in 5g.
- **5d ✅** (`c888157ad`) **Preload stages as services.** Each transient stage is
  a service on `preload-<stage>.socket` (via `Role::Service` `service_name`); the
  runner connects out (`Test2::Harness2::Runner::Stage::Client`) to dispatch
  `run_task`, and the stage reports `stop_task`/`retry_task`/`stage_ready`/
  `stage_down` back over `runner.socket` (folded by the in-stage delegate
  `Test2::Harness2::Runner::Stage`). The runner's State runs in in-memory
  `direct` mode and **`dispatch.jsonl` is fully retired on the transient path**;
  readiness = the stage's socket accepting (bounded connect-retry). No-preload:
  the root forks the test collector directly. **Scope:** only **global** stages
  are implemented (the current codebase has no run-scoped stages). *Run-scoped
  stages + run-qualified socket naming are NOT built* — deferred to the gated
  §6.1 multi-run layer. The **persistent** path is gated: it keeps `dispatch.jsonl`
  and file-polled stages (`persist.t` green).
- **5e ✅** (`625079b01`) **Transition channel.** Each non-runner collector (test
  jobs + transient stages) gets a `Test2::Collector::Recorder::Socket` reporter
  pointed at `runner.socket` (in addition to its Zstd file recorder — full events
  still recorded), streaming its transition facets (`harness_collector`,
  `harness_state_transition`, `harness_final_state`, finalized). The runner folds
  them into canonical state (`Test2::Harness2::Runner::Monitor`, ported from the
  2.0b Monitor fold mechanics — **without** the `run_uuid`/proxy filter, the
  dropped split). `Role::Service` discriminates transition frames from
  `{request=>...}` frames. The runner's **own** collector does not report to
  itself (events file only). *Correction:* "after 5e the only IPC files are events
  files" is **not** reached this run — `queue.jsonl` + `jobs.jsonl` remain as
  gatherer feeds (5g deferred), and the transition-derived state is **not yet**
  the render source (that swaps in 6a).
- **5f ✅** (`c6291a197`) **Client state sync.** `request_handler_subscribe`
  registers a persistent connection and replies with a serialized snapshot of the
  runner's canonical state (`Runner::Monitor` `snapshot`/`apply_snapshot`, now
  including a jobs map folded from a `harness_runner_job` facet). The runner
  thereafter forwards every state mutation to subscribers — both folded collector
  transitions **and runner-originated** mutations (`announce_job` from
  dispatch/run/exit + the `stop_task`/`retry_task` handlers). Clients consume via
  `Test2::Harness2::Runner::Subscriber`, mirroring state with a feed-mode
  `Monitor`. Single `runner.socket`, no `run_uuid` filter; vanished subscribers
  dropped gracefully. **Infrastructure only** — `test.pm` rendering is **not** yet
  rewired onto this channel (that is 6a); the gatherer remains the render path.
- **5g ✅** (`3b0704488`) **Retire the yath-side gatherer — on the transient path.**
  Done after 6a. The transient `yath test` path no longer spawns or depends on the
  gatherer; the runner service is the transient completion / stalled-job / timeout
  authority, and the command renders entirely from the runner subscription.
  **Scope correction:** the gatherer is **not deleted** — `Test2::Harness2::Collector`
  (loop + `_abort_stalled_jobs` + `_note_verdict` + `_final_event` + `kill(0)`
  liveness) **survives intact for the gated persistent path** (`yath run`/`start`,
  `use_subscription_renderer => 0`), along with `queue.jsonl` / `jobs.jsonl`. Those
  retire from the persistent path only when it migrates (gated §6.1).
  - **Transient duty moves:** stalled-job abort → `Test2::Harness2::Runner::Watchdog`
    (runner-side, conservative abort-on-wind-down, faithful to the gatherer's actual
    "abort once the runner is gone" semantics; aggressive mid-run per-stage death
    detection was tried and dropped — it destabilized the nested-stage scheduler).
    Run-level timeout aborts already live in `scheduler_tick`. **Verdict rollup
    stays command-side** in the 6a `Renderer::Driver` (pass/failed/retried/halted/
    unseen from the subscription mirror + per-job events); the runner owns run
    completion + the **aborted-job** verdict (announced over the socket, rendered by
    the Driver). No double-owning.
  - **Completion (transient):** the runner closes `runner.socket` when the run is
    done + jobs reaped (after a final transition drain); `Runner::Subscriber` sets a
    `closed` flag on EOF, ending the command's render loop. No more gatherer sentinel.
  - **Retired (transient):** gatherer spawn / `start_collector`, `queue.jsonl`,
    `jobs.jsonl`, the sentinel-pipe reader, `defer_cleanup`, `kill(0)` reliance.
    After 5g the only IPC files on the transient path are `events.jsonl.zst`.
  - `JobReader` / `RunnerReader` **moved** to a neutral namespace
    (`Test2::Harness2::JobReader` / `Test2::Harness2::RunnerReader`) as by-path
    readers; all callers updated (the 6a Driver + the surviving persistent gatherer).
  - `runner_death_liveness.t` scoped to the persistent gatherer's `kill(0)`;
    `Collector.t` unchanged (drives the surviving persistent gatherer); new
    `Runner_Watchdog.t` covers the runner-side abort path.
  - The codex#1 `kill(0)`-on-the-collector-wrapper liveness concern disappears
    with it — clients connect to the runner service instead.
- **Throughout:** disentangle `test` / `start` / `run` into thin clients of the
  one runner service (the current deep entwinement is a maintenance hazard).
- **Runner lifespan:** *transient* (`yath test`) — exit once all runs finish and
  transition queues drain; *persistent* (`yath start`) — stay listening on
  `runner.socket` until an explicit shutdown request (e.g. `yath stop`).
- **Persistent path was gated on §6.1 — now RESOLVED + migrated.** The single
  `runner.socket` in *the workdir* (above) is the per-run / `yath test` baseline.
  The generalized global-vs-run *service* split was dropped, and the multi-run
  layer (`ARCHITECTURE.md` §6.1) resolved to **"serialized + per-run routing"**:
  each `yath run` client is routed only its own run's transitions, the persistent
  runner runs one active run at a time, and `start`/`run`/`stop` run on the socket
  model. Run-scoped preload-stage naming is decided
  (`runs/<run_id>/preload-<stage>.socket`). What's left is **future** chunks, not
  a gate: concurrent run execution + run-scoped stages as a feature (chunk 16).

### Chunk 6 — renderer (interim step toward the §4.5 rewrite)

- **6a ✅** (`9c3ce01ae`) **(interim) Renderers move into the `test` command.**
  `test` subscribes to `runner.socket` (`Runner::Subscriber`) and a new
  `Test2::Harness2::Renderer::Driver` consumes the snapshot + forwarded
  transitions, fetching each job's `events.jsonl.zst` **by the absolute path the
  transition carries** at completion and computing `harness_final` / summary /
  exit command-side. (At 6a, `run` was still gated on the gatherer; §6.1 then
  moved it onto this same subscription renderer.) Implemented exactly the per-job
  three-phase ordering below; the §4.5 base renderer (now landed, see next entry)
  supersedes this interim shape.
  They are driven by transitions received from the runner; when a job completes,
  the command fetches that job's `events.jsonl.zst` and feeds its events through
  the renderers / loggers. Render transitions in realtime, events at job
  completion. Only **per-job** ordering is guaranteed, in three phases per job:
  (1) render lifecycle transitions in realtime as they arrive over the socket;
  (2) on the completion trigger, **block final-status rendering**, fetch that
  job's `events.jsonl.zst` by the absolute path its transition carries, and feed
  all its events through the renderers / loggers; (3) render the job's final
  completion / status **last**, after its output is fully shown. Cross-job
  chronological ordering is **not** attempted here.
  (Persistent `run` adopted this same subscription renderer in §6.1; the gatherer
  is gone.)
- **§4.5 base renderer ✅** (`4410c8105`). The reusable `Test2::Harness2::Renderer::Base`
  now owns the transition-state mirror, events-file location, rollup, and the
  `render_event` fan-out to sink renderers + logger; `Renderer::Driver` is a thin
  subclass holding ONLY the interim per-job 3-phase ordering above. `yath watch`
  reuses Base as a global `runner.socket` subscriber (`f9142217c`), which let the
  persistent runner + stages be collector-wrapped and the flat `output.log` /
  `error.log` shim retired. The interim per-job ordering is **not** the final
  renderer contract; the final cross-job ordering guarantees are still not pinned
  — `ARCHITECTURE.md` §4.5 stays authoritative for the final target.
