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
- **`AGENTS.md`** — per-repo workflow, pre-review checks, dependency rules,
  commit/worktree policy, testing instructions.
- **`STYLE_GUIDE.md`** + **`STYLE_GUIDE_AGENT_CHECKLIST.md`** — code style and
  the self-audit checklist walked before handing work back.
- **`new_plan`** — the original transition brief (broad strokes).
- **`migration_revision`** — the brief that fleshes out chunks 4-6 into the
  runner-service + socket-IPC design. Its content is folded into the
  "Chunks 4-6 detailed plan" section below.
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
| 5 | Runner service + socket IPC (state sync, transition pipelining) | 🚧 | 5a `ceec15894` · 5b `24cb1e798` · 5c `654a742b7` · 5d `c888157ad` · 5e `625079b01` · 5f `c6291a197` · 5g ⬜ deferred (needs 6a) |
| 6 | Renderer: interim (commands own renderers) → base-renderer rewrite | ⬜ | — |
| 7 | System-load service (own process, reliable tick → reports load to runner) | ⬜ | — |
| 8a | Database + UI inline (DBIx::Class, SQLite logs) | ✅ | `2d09d348a` (merge) |
| 8b | Convert inlined UI schema `DBIx::Class` → `DBIx::QuickORM` | ⬜ (deferred) | — |

Chunks 4-6 are broken into substeps in the **"Chunks 4-6 detailed plan"**
section below (the runner-service + socket-IPC design from `migration_revision`).

## Done so far

**Chunk 5 (5a-5f) — runner service + socket IPC** (`ceec15894`, `24cb1e798`,
`654a742b7`, `c888157ad`, `625079b01`, `c6291a197`; on branch
`chunk5-runner-service`, not yet merged):
- The **transient `yath test`** runner is now a collected **socket service**
  (`runner.socket`) with an **in-process scheduler** (no separate scheduler
  process, no `dispatch.lock`). New: `Test2::Harness2::Role::Service` and the
  `Runner::{Client,Stage,Stage::Client,Monitor,Subscriber}` family; all wire
  traffic reuses `Test2::Collector::Util::{Socket,Zstd,Zstd::FrameBuffer}` /
  `Recorder::Socket` (no harness-local copies).
- `test` submits runs **over the socket**; preload **stages are socket services**
  the runner dispatches to and which report back; every non-runner collector
  streams **transitions** to the runner, folded into canonical state
  (`Runner::Monitor`); clients **subscribe** for a snapshot + forwarded mutations
  (`Runner::Subscriber`). Retired on the transient path: `run_queue.jsonl`,
  `dispatch.jsonl`, `dispatch.lock`, the scheduler process.
- **Deferred / still-on-files:** `5g` (retire the gatherer) is deferred — it
  needs the chunk-6a command-side renderer. So the gatherer is still the render
  path and `queue.jsonl` + `jobs.jsonl` remain to feed it; the transition-derived
  runner state is built and tested but **not yet** the render source. The
  **persistent** path (`yath start`/`run`/`spawn`) is **not migrated** (gated
  §6.1) and keeps its file-polling IPC.
- Suite green at each phase; final `Files=83, Tests=1582, Result: PASS`.

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
  `events.jsonl.zst`; the yath-side gatherer (`Test2::Harness2::Collector` via
  `JobReader`) reads those files and re-attaches run/job/event UUIDs. The
  **`yath test` runner** is also wrapped now (chunk 4a, merged `bf1081ab0`),
  read via `RunnerReader`. The transient runner's **preload stages** are wrapped
  too (chunk 4b): each writes `stage-<name>-events.jsonl.zst`, read back by the
  gatherer via per-stage `RunnerReader`s. The **persistent** runner and its
  stages stay on the flat-file shim for now. This standing gatherer process is
  still present (its removal is **5g**, deferred — see below); chunk 5 (5a-5f)
  built the runner service *alongside* it without yet rewiring the render path.
- **Runner IPC (transient `yath test`):** now the **socket model** (chunk 5,
  5a-5f). The runner runs as a collected **service** bound to `runner.socket`
  with an **in-process scheduler** (no separate scheduler process, no
  `dispatch.lock`). `test` is a thin client that **submits runs over the
  socket** (`Test2::Harness2::Runner::Client`); `run_queue.jsonl` is retired and
  the runner's State runs in in-memory `direct` mode. Preload **stages are
  socket services** (`preload-<stage>.socket`): the runner connects out to
  dispatch jobs and stages report back over `runner.socket`, retiring
  `dispatch.jsonl` on the transient path. Every non-runner collector streams its
  **transitions** to `runner.socket`, folded into the runner's canonical state
  (`Test2::Harness2::Runner::Monitor`); clients **subscribe** for a snapshot +
  forwarded mutations (`Test2::Harness2::Runner::Subscriber`). All wire traffic
  reuses `Test2::Collector::Util::{Socket,Zstd,Zstd::FrameBuffer}` /
  `Recorder::Socket` — no harness-local copies. **Still on files (retire in
  5g/6a):** `queue.jsonl` + `jobs.jsonl`, kept only to feed the still-living
  gatherer; the transition-derived runner state is **not yet** the render
  source. The **persistent** path (`yath start` / `run` / `spawn`) is **not
  migrated** (gated §6.1): it keeps `dispatch.jsonl` submission and file-polled
  stages. The system-load service is still chunk 7.
- **Web UI:** inlined (chunk 8a, merged `2d09d348a`) under `App::Yath2::Server*`
  / `App::Yath2::Schema*` (+ `Command::{server,db/*,client/*}`,
  `Options::{DB,WebServer,Server,WebClient,Publish,Yath}`, `Plugin::DB`,
  `Renderer::{DB,Server}`), following the pre_ai_2.0 layout, on **DBIx::Class**
  (5 drivers; SQLite default for ephemeral/tests). Assets in `share/`, samples in
  `demo/`. Tests: Perl unit + HTTP smoke (`t/AI/integration/ui_server.t`) +
  Playwright (`js-tests/`, run from `t/playwright.t`). The QuickORM conversion is
  **chunk 8b (deferred)**.
- **Logic:** otherwise still 1.0 for the not-yet-migrated chunks (6-7) and the
  gated persistent path.
- **Not renamed (intentional):** `Test2::Formatter::*`, `Test2::Tools::*`,
  `App::Yath::Script`.

## Next

**Chunk 6a — command-side renderer (interim), then chunk 5g.** The transition
channel, canonical runner state, and client subscription now exist (chunk 5,
5a-5f), but the **render path is still the standing gatherer**. Chunk 6a moves
the renderer/logger + `harness_final` / `FINAL_DATA` path into the `test`
command, driven by the runner subscription (snapshot + forwarded transitions)
plus each job's `events.jsonl.zst` fetched at completion. Once 6a exists, **5g**
removes the gatherer loop, retires `queue.jsonl` / `jobs.jsonl`, moves its
non-walking duties (stalled-job detection, run-timeout aborts, verdict rollup)
into the runner tick over canonical state, and moves `JobReader` / `RunnerReader`
out of the deleted `Test2::Harness2::Collector::*` namespace into a neutral
`Test2::Harness2::*` namespace as by-path readers. See the "Chunks 4-6 detailed
plan" below. Reference: `reference/2.0b`, `reference/harness_service`.

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

**End state of chunks 4-6.** Every process the runner forks runs under its own
collector. The runner and each preload stage are **socket services**. The only
files on the IPC path are the per-collector `events.jsonl.zst` files, used to
feed display to renderers — all decision/dispatch data moves over unix sockets
in the collector wire format (zstd-compressed JSON object frames): runner →
preload (dispatch jobs), and collector → runner (transition messages). Commands
queue work by messaging the runner. The 1.0 coordination files
(`queue.jsonl`, `run_queue.jsonl`, `dispatch.jsonl`, `dispatch.lock`) are gone.

**All services are global harness services; there are no per-run services.** The
service kinds: the runner, preload stages, and auxiliary harness services that
report to the runner (e.g. the system-load service, §4.4 — emit-only, connects
to `runner.socket`, no socket of its own). What is **dropped** is the
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
- **5g ⬜ (deferred — blocked on 6a) Retire the yath-side gatherer.** Explicitly
  deferred when 5a-5f landed: the gatherer is still the render path, so it stays
  alive (fed by `queue.jsonl` / `jobs.jsonl`) until 6a replaces it.
  **Prerequisite: the command-side renderer/logger + final-data path (6a) must
  already exist.** The gatherer is
  not just a tree-walker — it is also what `test` reads to render, log, collect
  `harness_final` / `FINAL_DATA`, and emit summaries
  (`App::Yath2::Command::test` `start_collector` / `render`). So **sequence 6a
  before 5g** (or land them together); "retire" means *replace*, not merely
  delete. With state in the runner (5c), the channel live (5e), clients synced
  (5f), and the command-side renderer in place (6a), the standing
  `Test2::Harness2::Collector` gatherer loop (queue/job polling + workdir
  tree-walk + completion decision) is **removed**.
  - Its **non-walking duties move into the runner service/scheduler**:
    stalled-job detection, run-level timeout aborts, and verdict rollup become
    tick-loop work over the canonical state (per-test silence/lifetime timeouts
    already live in the `Test2-Collector` parent). `harness_final` / summary
    handling moves to the command-side renderer (6a).
  - `JobReader` / `RunnerReader` are kept only as by-path readers of one events
    file, and **move out of the deleted `Test2::Harness2::Collector::*`
    namespace** into a neutral `Test2::Harness2::*` namespace (reading recorded
    events is producing-results data access, consumed by `App::Yath2` display).
  - The codex#1 `kill(0)`-on-the-collector-wrapper liveness concern disappears
    with it — clients connect to the runner service instead.
- **Throughout:** disentangle `test` / `start` / `run` into thin clients of the
  one runner service (the current deep entwinement is a maintenance hazard).
- **Runner lifespan:** *transient* (`yath test`) — exit once all runs finish and
  transition queues drain; *persistent* (`yath start`) — stay listening on
  `runner.socket` until an explicit shutdown request (e.g. `yath stop`).
- **Persistent path is gated on §6.1 (now smaller).** The single `runner.socket`
  in *the workdir* (above) is the per-run / `yath test` baseline. The
  generalized global-vs-run *service* split is dropped; what remains open
  (`ARCHITECTURE.md` §6.1) is the multi-run layer on a persistent runner:
  routing each `yath run` client only its own run's transitions, run-scoped
  preload-stage lifecycle (5d), and what `start` owns (workdir, publish
  `runner.socket`, persist metadata) / how `run` discovers + submits to it.
  `start` / `run` must **not** migrate to the service model ahead of resolving
  it.

### Chunk 6 — renderer (interim step toward the §4.5 rewrite)

- **6a ⬜ (interim) Renderers move into the `test` / `run` command processes.**
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
- **Not the end state.** This interim shape is reworked by the §4.5
  base-renderer rewrite (a base renderer/role that locates `.jsonl.zst` files
  from transition state) in a later MIGRATION initiative. The interim per-job
  ordering is **not** the final renderer contract; the final ordering guarantees
  are not pinned here. Where this plan and `ARCHITECTURE.md` §4.5 disagree on
  renderers, §4.5 describes the final target.
