# TODO_STEPS.md — Broad migration steps

The **broad steps** to get from where the code is now to the target in
`ARCHITECTURE.md`. Each step (a "chunk") is a coherent unit of migration work.

**The three planning docs:**
- **`ARCHITECTURE.md`** — *where we want to be* (the target-state spec; each
  subsystem tagged `[1.0]` / `[migrating]` / `[target]`).
- **`TODO_STEPS.md`** (this file) — *the broad steps* to get there (the chunk list +
  status + dependencies).
- **`TODO_TASKS.md`** — *specific, well-defined tickets* (decided, ready-to-implement
  tasks). Many tasks belong to a step here and are cross-linked.

Also: **`AGENTS.md`** (how-to-work rules, pre-review checks), **`IPC.md`**
(current-state IPC/process/socket map), `STYLE_GUIDE*.md`.

## Ground rules

- **Branch:** `2.0d` (cut from `1.0`). Commit **directly** to it (foundations
  override — no worktrees/feature branches until foundations are declared done).
- **Testing:** run **both**, must pass under both, **always** `AUTHOR_TESTING=1`:
  `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`.
  `-Ilib`/`-D` are mandatory (make the suite use this repo's `lib/`, not an installed
  1.0). `AUTHOR_TESTING=1` always — author-gated tests must run, not skip. Skip the
  `yath test` run **only** for interim steps expected to be broken (note it). No
  repo-local `scripts/yath` (`yath` is the installed `App::Yath::Script`). See AGENTS
  Testing.
- **`Test2-Collector`** is a hard dependency (declared in `dist.ini`); reinstall
  from its checkout when a step requires a collector change (e.g. the multi-pid
  `watch_parent_pid`, the `SOMAXCONN` backlog fix).
- Each chunk stays small and keeps the suite green.
- **Do not rename** (decided): `Test2::Formatter::*`, `Test2::Tools::*`, and the
  `App::Yath::Script` namespace.

## Chunk status

Order mirrors `ARCHITECTURE.md` §1.1. Numeric order is **not** execution order —
dependencies are per row. Status: ✅ done · 🚧 in progress · ⬜ not started.

| # | Step | Status | Tasks (TODO_TASKS) |
|---|------|--------|--------------------|
| 1 | Mechanical renames + version bump | ✅ | — |
| 2 | Argument processing → `Getopt::Yath` | ✅ | — |
| 3 | Collector swap → `Test2-Collector` | ✅ | — |
| 4 | Collectors everywhere (runner + preload stages) | ✅ | — |
| 5 | Runner service + socket IPC (state sync, transition pipelining) | ✅ | — |
| 6 | Renderer: interim → §4.5 base-renderer rewrite | ✅ | — |
| 7 | System-load service (own process, reliable tick → reports load) + opt-in CPU/memory throttling resources — needs 9 | ✅ DONE | TODO-43 |
| 8a | Database + UI inline (interim DBIx::Class, SQLite logs) | ✅ | — |
| DB-1 | Move old DBIC DB/web layer → `reference/old_db` (`git mv`); db/server/recent commands → error stubs + tests `SKIP_ALL`; dist.ini `exclude_match = ^reference` + drop DBIx::Class prereqs | ✅ (647b55466) | TODO-45 |
| DB-2 | New schema PostgreSQL-first (hand-written DDL + QuickORM autofill + Flavor; `App::Yath2` namespace); add optional DBIx::QuickORM/QuickDB deps; needs ARCHITECTURE §2.4 reword | ✅ (966eb6516) | TODO-46 |
| DB-3 | Port schema to SQLite/MySQL/MariaDB/Percona (per-engine UUID storage; MariaDB 10.7+) — needs DB-2 | ✅ (e6ec83c61) | TODO-47 |
| DB-Jsonl | Convert current jsonl logger → a renderer + renderer-owned options (`mod_adds_options`); lands before DB-4 (frees the "logger" concept) | ✅ (597a86e9b/03ac4243c) | TODO-55, TODO-56 |
| DB-4 | DB logger process (own Client+Subscriber; folds transitions into run/job/job_try rows; whole-blob artifact import; SQLite-first; optional DB deps) — needs DB-3 | ✅ (bf75f888c..a8b5dab7c) | TODO-48, TODO-49, TODO-50, TODO-51, TODO-52 |
| DB-5 | DB→DB sync (`yath db sync`) + `import` command — needs DB-4 | ✅ (df7b8863a/c05e9b8d9) | TODO-53, TODO-54 |
| REF-PORT | Reference-port features (directives, UnixLimits+Disk resources, Units helpers, ResetTerm, list/ping) | ✅ (b756025da,0e93506b0,fdec15e72,d5baf0e0b,409f4fc8c) | TODO-58, TODO-59, TODO-60, TODO-61, TODO-62 |
| 9 | Unified service channel — full bidirectional RPC (§5.2) | ✅ | — |
| 10 | Preload stage lifecycle states + stage-owned restart (§4.7) — needs 9 | ✅ | TODO-2, TODO-3 |
| 11 | Preload as a scheduler resource (§4.7a) — needs 10, 23 | ⬜ | TODO-24 (resource iface), TODO-2, TODO-3 |
| 12 | Discovery via runner-socket symlink + PID-file fallback (§5.3) | ✅ (`App::Yath2::Discovery`) | — |
| 13 | `spawn` bypasses runner: direct `Preload::Host` socket, **SCM_RIGHTS fd-pass** of real STDIN/OUT/ERR, supervisor (no exec → longjump preload path) + dedicated control protocol, kill-on-command-EOF, no collector (§4.8) — needs 12, 29, 30 | ✅ | TODO-39 |
| 14 | Split `Test2::Harness2::TestFile` → `App::Yath2` reader + state-only object (§1) | ✅ | — |
| 15 | Final renderer ordering (per-job-only guarantee) + `--live` tail-all-events feeder (default-on in interactive) | ✅ | TODO-44 |
| 16 | Concurrent run execution + run-scoped preload stages (§6.1) — needs 9,10 | ⬜ | TODO-13 (%SORTED concurrency); TODO-12 (run lifecycle, primary home ch22) |
| 17 | Plugin setup/teardown move to the runner; aux output → collectors; retire aux_logs flat files | ✅ | — |
| 18 | Collectors watch the runner pid → self-terminate if runner dies (§4.1) + audit gate | ✅ | — |
| 19 | Extract the preload root out of the runner; runner goes scheduler-only (§4.2/§4.7) — needs 14 | ✅ (residuals → 20-23 + tasks) | TODO-1–TODO-4, TODO-8, TODO-10, TODO-11, TODO-26 |
| 20 | Interactive mode IO: replace FIFO proxy with **STDIN-only SCM_RIGHTS fd-pass** (output stays with collector), command-listens/per-test-accept (§4.10, reuses §4.8 primitive) — needs 29, 13. May be temporarily disabled / xfail until this lands (do not block TODO-4-task) | ✅ | TODO-7 (7b), TODO-40 |
| 21 | Collapse the `Test2::Harness2::IPC` controller → spawn + zombie-reap on `Util::IPC` (§5.4) — needs 6 | ✅ (base class slimmed, not dismantled — `Preload::Host` is a 3rd consumer, out of scope per 26/TODO-29) | TODO-6, TODO-8, TODO-11 |
| 22 | Run state lifecycle (§4.2): fold raw item onto `Run`, connection-gated retention, abort-on-disconnect | ✅ (via TODO-12 `5ac411700`; status cell was stale) | TODO-12 |
| 23 | Client-side stage assignment; eliminate the resolver / `resolve_file_stages` / `file_stage` / `eager` (§4.7/§4.7a). Folds into 11 | ⬜ | TODO-10, TODO-20, TODO-21, TODO-2, TODO-23 |
| 24 | Transition-driven test completion (§5.4): pass/fail/retry/bail from transitions + connection EOF; collector exit health-only; bidirectional conns + runner→collector terminate; fd hygiene. Spans Test2-Collector. | ✅ | TODO-32, TODO-27 |
| 25 | Runner as child subreaper + preload collectors double-fork/detach (§4.1/§5.4); new `Test2::Harness2::Util::SubReaper` (pure-Perl `syscall`). Lets the preload tree reap nothing. — needs 24 | ✅ | TODO-28 |
| 26 | Collapse to one run path (§5.4): `run_scheduler_only` becomes the runner's only run loop; delete the in-runner `run_tests`/`run_stage`/`run_job` stage machinery. Completes TODO-22 residual + TODO-4 P4 + TODO-8 P4. — needs 24, 25 | ✅ | TODO-29 |
| 27 | Generic `collector_transition` event facet (Test2-Collector forwards verbatim) + runner→plugin hook for non-builtin transitions. — needs 24 | ⬜ (deferred) | TODO-30 |
| 28 | Runtime retry-request: a test-facing helper emits an event → collector `retry` transition → runner retries via normal re-queue. — needs 24, 27 | ⬜ (deferred) | TODO-31 |
| 29 | Socket FD-pass primitive `Test2::Harness2::Util::FdPass` (SCM_RIGHTS; optional `IO::FDPass`; command-listens) — shared by spawn (13) + interactive (20) | ✅ (primitive only; consumers 13/20 separate) | TODO-38 |
| 30 | Harness-client library: grow `App::Yath2::Client` to own runner-lifecycle modes + finders/specs + state queries; thin `test`/`run`/`start` (§4.11) | ✅ | TODO-41 |
| 31 | Render-loop library: `RenderLoop` (owns dispatch+rollup) + pure-source `Producer`; `LiveProducer` + `JSONLFileProducer` now, `ArchiveProducer` deferred to DB rewrite (§4.12) | ✅ (ArchiveProducer deferred) | TODO-42 |
| CLEAN-1 | Cleanup audit (2026-07-01): renderer/formatter stack — dead Composer/Formatter/RenderLoop plumbing, Driver & status-bar duplication, fan-out consolidation | ✅ (2.0d-bugfix) | TODO-64, TODO-65, TODO-66 |
| CLEAN-2 | Cleanup audit: Runner core (State/Scheduler/process-mgmt) — dead code, duplication, key & HashBase consistency | ✅ (2.0d-bugfix) | TODO-67, TODO-68, TODO-69 |
| CLEAN-3 | Cleanup audit: Runner service — split oversized Handlers.pm, Client/Subscriber & announce_* duplication, Watchdog/Monitor dead code + stale comments | ✅ (2.0d-bugfix) | TODO-70, TODO-71, TODO-72 |
| CLEAN-4 | Cleanup audit: job execution, event/reader & TestFile — dead exec paths, dead attributes, internal duplication, POD hygiene | ✅ (2.0d-bugfix) | TODO-73, TODO-74, TODO-75, TODO-76 |
| CLEAN-5 | Cleanup audit: preload subsystem — dead stubs/attributes, DEFAULT_STAGE type fix, closure/resolve duplication | ✅ (2.0d-bugfix) | TODO-77, TODO-78 |
| CLEAN-6 | Cleanup audit: resource classes — boilerplate/constructor consolidation, JobCount header fix, v5.38/signature normalization | ✅ (2.0d-bugfix) | TODO-79, TODO-80 |
| CLEAN-7 | Cleanup audit: IPC / Role::Service / Util-core — die-closure & byte-pump duplication, dead teardown/dispatch/spawn forms | ✅ (2.0d-bugfix) | TODO-81, TODO-82 |
| CLEAN-8 | Cleanup audit: Util modules, Directives & UUID — dead modules/members, gen_uuid unification, Directives duplication + oversized _record | ✅ (2.0d-bugfix) | TODO-83, TODO-84, TODO-85 |
| CLEAN-9 | Cleanup audit: Log/CoverageAggregator — duplication, finalize-shape bug, eval-error, POD | ✅ (2.0d-bugfix) | TODO-86 |
| CLEAN-10 | Cleanup audit: command layer — cli_args/doc_args wiring, base+test.pm dead code, render/helper duplication, persist-family fixes, import sweep | ✅ (2.0d-bugfix) | TODO-87, TODO-88, TODO-89, TODO-90, TODO-91, TODO-92 |
| CLEAN-11 | Cleanup audit: DB layer — dead Schema/imports/slots, sync/import & _find_or_create duplication, command-surface stubs & HTTP stack | ✅ (2.0d-bugfix) | TODO-93, TODO-94 |
| CLEAN-12 | Cleanup audit: client-lib/Discovery/Util — Pfile shim removal, walk/probe duplication, Tester/Finder/Script fixes | ✅ (2.0d-bugfix) | TODO-95, TODO-96, TODO-97 |
| CLEAN-13 | Cleanup audit: options & plugins — retire web/DB option modules, duplication helpers, dead options/markers, v5.38 sweep | ✅ (2.0d-bugfix) | TODO-98, TODO-99, TODO-100, TODO-101 |
| CLEAN-14 | Cleanup audit: standalone dead modules, stale docs & doc-status sync | ✅ (2.0d-bugfix) | TODO-102, TODO-103, TODO-104, TODO-105 |
| BUG-1 | Bug audit: P0 fixes — service select-set poisoning wedges the runner; Git plugin infinite merge-base loop | ✅ (2.0d-bugfix) | TODO-106, TODO-107 |
| BUG-2 | Bug audit: P1 service/IPC core — EAGAIN false EOF, silent client submission loss, unguarded handler dispatch | ✅ (2.0d-bugfix) | TODO-108, TODO-109, TODO-110 |
| BUG-3 | Bug audit: P1 runner/preload/reload — reload duplication/wedges, scheduler crash & hangs, retry misreport, directive validation | ✅ (2.0d-bugfix) | TODO-111, TODO-112, TODO-113, TODO-114, TODO-115, TODO-116, TODO-117, TODO-118 |
| BUG-4 | Bug audit: P1 spawn — supervisor pgroup leak kills detached sessions on stage stop/reload | ✅ (2.0d-bugfix) | TODO-119 |
| BUG-5 | Bug audit: P1 command lifecycle — watch/stop/kill/run/start/failed/interactive Ctrl-C | ✅ (2.0d-bugfix) | TODO-120, TODO-121, TODO-122, TODO-123, TODO-124, TODO-125 |
| BUG-6 | Bug audit: P1 options/plugins — dead --notify-email-fail, -f fields truncation | ✅ (2.0d-bugfix) | TODO-126, TODO-127 |
| BUG-7 | Bug audit: P1 DB logger/sync correctness — project attribution, non-transactional sync, drain stall, aborted-job & failure finalization, teardown reporting | ✅ (2.0d-bugfix) | TODO-128, TODO-129, TODO-130, TODO-131, TODO-132, TODO-133 |
| BUG-8 | Bug audit: P2/P3 service + runner-core bundles — IPC hardening, state/scheduler, preload, job env, resources/sampler | ✅ (2.0d-bugfix) | TODO-134, TODO-135, TODO-136, TODO-137, TODO-138 |
| BUG-9 | Bug audit: P2/P3 spawn + interactive bundles | ✅ (2.0d-bugfix) | TODO-139, TODO-140 |
| BUG-10 | Bug audit: P2/P3 renderer/formatter/log-renderer bundles | ✅ (2.0d-bugfix) | TODO-141, TODO-142, TODO-143 |
| BUG-11 | Bug audit: P2/P3 finder + command-surface bundles — selection, discovery/start races, persist-command UX, replay, rc parsing, speedtag/times | ✅ (2.0d-bugfix) | TODO-144, TODO-145, TODO-146, TODO-147, TODO-148, TODO-149 |
| BUG-12 | Bug audit: P2/P3 plugins + coverage bundles | ✅ (2.0d-bugfix) | TODO-150, TODO-151 |
| BUG-13 | Bug audit: P2/P3 DB layer + web-client commands (web-parked; rework in place) | ✅ (2.0d-bugfix) | TODO-152, TODO-153 |
| BUG-14 | Bug audit: P2/P3 util/tester fixes + dead-seam cross-refs | ✅ (2.0d-bugfix) | TODO-154, TODO-155, TODO-156 |
| BUG-15 | Latent findings surfaced during 2026-07-02 Fable/Opus spec resolution (new, not in the 126-finding audit) — blocking-connect timeout, aborted-run drain, TODO-113 premise conflict, hidden-output renderers, discovery-link unlinks | ✅ (2.0d-bugfix) | TODO-157, TODO-158, TODO-159, TODO-160, TODO-161, TODO-162 |

The **Tasks** column points at the well-defined tickets in `TODO_TASKS.md` that
implement (part of) a step. A step is "broad"; its tickets are "specific."

## Done (summary)

Full history is in git and in the snapshot commit that preceded this refactor.
Compact record of what landed:

- **1-2** — `*2` namespace + version renames; option machinery → `Getopt::Yath`.
- **3-4** — collector swap to `Test2-Collector`; runner **and** preload stages each
  run under their own collector writing `events.jsonl.zst`.
- **5 (5a-5g) + 6a** — runner is a collected **socket service** (`runner.socket`)
  with an **in-process scheduler**; commands submit/subscribe over the socket;
  stages are socket services; collectors stream transitions folded into
  `Runner::Monitor`; the yath-side **gatherer is deleted**; transient + persistent
  paths both on the socket model (§6.1 = "serialized + per-run routing"). All the
  1.0 coordination files (`dispatch.jsonl`/`.lock`, `queue.jsonl`, `jobs.jsonl`,
  `run_queue.jsonl`) are gone.
- **6 (§4.5)** — reusable `Renderer::Base` (state mirror + by-path events read +
  rollup + sink fan-out); `watch` is a global socket subscriber; `output.log`/
  `error.log` retired → **the only IPC files are `events.jsonl.zst`**.
- **8a** — DB/UI inlined on interim DBIx::Class (SQLite default).
- **9** — unified bidirectional RPC `Role::Service::Connection` (identity handshake,
  request_id-correlated, no ordering); runner↔stage collapsed onto it; commands are
  peers.
- **14** — `TestFile` split: `App::Yath2::TestFile`/`Finder` (reader) +
  state-only `Test2::Harness2::TestFile`.
- **17** — plugin `setup`/`teardown` run in the runner; aux output → collectors
  (`run_collected`); `aux_logs` retired.
- **18** — every runner-spawned collector `watch_parent_pid`s the **runner**;
  `agent_scripts/audit-collector-watch-parent` gate enforces it.
- **19** — preload-root extracted: a separate `Test2::Harness2::Preload` process
  hosts the stages; the runner is a pure scheduler-only orchestrator (no preloads,
  no in-process stage, no `BEGIN`). Crash/race de-flake machinery landed (generation
  stamping, busy-channel retention, lifecycle enum) — **this is the chunk-19 residue
  that TODO_TASKS now cleans up and supersedes** (connection-currency replaces
  generation, etc.).
- **DB-1..DB-5 + DB-Jsonl** — the from-scratch DB-layer rewrite (DBIx::QuickORM `autofill`;
  artifact-blob + folded-row canonical record, **no transitions table**) landed on `2.0d`:
  DB-1 old DBIC/web layer → `reference/old_db`, `db`/`server`/`recent` stubs (`647b55466`);
  DB-2 PostgreSQL-first schema (`966eb6516`); DB-3 SQLite/MySQL/MariaDB/Percona port
  (`e6ec83c61`); DB-Jsonl jsonl-renderer + `mod_adds_options` (`597a86e9b`/`03ac4243c`);
  DB-4 opt-in `-L` DB-logger process + derived UUIDs (`bf75f888c`..`a8b5dab7c`); DB-5
  `yath db sync` + `import` (`df7b8863a`/`c05e9b8d9`). Multi-flavor test matrix = ticket TODO-63
  (`t/AI/lib/App/Yath2/Test/DBMatrix.pm`). **TODO-57 (try-uuid start-stamp) stays optional/deferred.**
- **REF-PORT** — five reference-port features (`b756025da`/`0e93506b0`/`fdec15e72`/`d5baf0e0b`/
  `409f4fc8c`): HARNESS2 directives parser + legacy compat (TODO-58), UnixLimits+Disk resources
  (TODO-59), Units helpers (TODO-60), ResetTerm renderer (TODO-61), `yath list`/`ping` (TODO-62).
- **CLEAN-1..14 + BUG-1..15** — the 2026-07-01 maintainability cleanup audit (tickets TODO-64–TODO-105)
  and bug audit (TODO-106–TODO-162) all landed on `2.0d-bugfix`; per-ticket detail + commit shas
  are in `TODO_DONE.md`.

## Pending steps (detail)

Steps still to do. Each notes its dependencies and the TODO_TASKS tickets that
carry the specifics.

- **Chunk 7 — system-load service (needs 9). ✅ DONE.** Its own global process with a
  reliable 0.2s tick (the runner loop can exceed the sample interval), a full service
  on the §5.2 channel: own listen socket, dials the runner to push change-gated load
  updates, which the runner stores + broadcasts globally as a `harness_system`
  transition. Ported `SystemLoad.pm` + the sampler shape (dropped the run-vs-global
  split; adopted the §5.2 channel). Opt-in throttling resources (`-R CPU`/`-R Memory`,
  `--utilize`) compose the TODO-24 Resource Role + a new `Role::Resource::Utilizer` and
  read the runner's shared snapshot (cross-platform). See ticket TODO-43,
  `AI_DOCS/2026-06-21-system-load-throttling.md`, and the ARCHITECTURE.md §4.4 addendum.

- **Chunk 10 — preload stage lifecycle states + stage-owned restart (§4.7). DONE.**
  Registration + dispatch-over-registered-channel landed in 9. The explicit
  **`starting`/`up`/`restarting`/`down`** enum (TODO_TASKS **TODO-2**) and the
  collector-driven self-termination + connection-currency that replaces
  generation-stamping (TODO_TASKS **TODO-3**) are both done. **Stage-owned restart** is
  also done — it landed as a side effect of the chunk-19 split, not as separate work:
  the preloader monitor no longer drives reload-respawn through the runner's
  `set_proc_exit`. A named stage's own preloader-monitor detects a watched-file change
  *inside the stage process* (`Preload::Host::end_test_loop` → `Preloader::check`),
  sets its own `SIGNAL`, ends its run loop, reports `stage_restarting`, and exits; the
  **preload-root** (the stage's parent and reaper, `Preload::Host::set_proc_exit`'s
  `StageProcess` branch) respawns the exited stage via `_preload_stages`. The runner's
  `set_proc_exit` has **no stage branch** — it forks no preload stages (TODO_TASKS
  **TODO-22**). `yath reload` is routed to the live base-stage channel, which translates it
  into the same in-run respawn (TODO_TASKS **TODO-34**); the runner's own self-restart was
  deleted (TODO_TASKS **TODO-4**). So §4.7's "restart is stage-initiated; respawned by the
  preload-root" is fully realized.

- **Chunk 11 — preload as a resource (§4.7a) — needs 10, 23.** Model preload
  availability as a single scheduler **resource** with the standard
  `available`/`assign`/`release` contract. `available($task)` is tri-state over the
  stage lifecycle (`1` up; `0` starting/restarting; `-1` permanent/absent for a
  required stage); `assign` records the chosen stage; `release` ~no-op; the
  assign→launch race **requeues** (TODO_TASKS **TODO-3** requeue primitive). It consumes
  the three job fields chunk 23 produces (no resolver). Resource interface hardening
  is TODO_TASKS **TODO-24**.

- **Chunk 12 — discovery via a runner-socket symlink (§5.3). DONE.** Replaced
  `yath-persist.json` with a well-known symlink to `runner.socket` (follow it → socket
  + workdir) in `App::Yath2::Discovery` (wrapped by `App::Yath2::Pfile`;
  `App::Yath2::Util::find_runner_link` resolves the path). The flat workdir `PID`-file
  is the signal fallback for a wedged runner whose socket is unresponsive; a
  dangling/connect-fail symlink ⇒ runner absent ⇒ the stale symlink is cleaned.
  Settled at implementation time: symlink basename
  `.<user>-<host>-<project>-yath-runner.sock` (legacy project-prefix / tempdir-vs-cwd
  rules; one runner per project), no explicit symlink perms (the link mode is not
  meaningful; access is governed by the workdir/socket), and the version stamp was
  dropped (liveness is the socket connect; the runner's `settings.json` carries
  config). See ARCH §5.3 "Implemented (chunk 12)".

- **Chunk 13 — `spawn` bypasses the runner (§4.8) — needs 12, 29, 30. ✅ DONE**
  (`680c6d9c5` / `f5b85aca6` / `fa751c2df`). `spawn`
  discovers + connects **directly** to an available preload stage (`Preload::Host`,
  which gains a new `request_handler_spawn` that async-double-forks a supervisor and
  acks `{ok=>1}`). IO sharing is **SCM_RIGHTS fd-passing** (chunk 29): the command
  **listens**, the spawned side **dials back**, the command `send_fds` its real
  STDIN/OUT/ERR, the child `recv_fds` + `dup2`s them — the command leaves the byte
  path (no proxy; replaces 1.0 `/proc`). The supervisor (holds the preloaded image)
  forks a script child that **must not `exec`** — it sanitizes (close inherited
  sockets, Test2 reset, stage hooks) and **unwinds into the preloaded interpreter via
  `Long::Jump`/`goto::file`** (preserving the preload), then `waitpid`s + reports raw
  wait status over a **dedicated control protocol** (same socket, post-fd phase). The
  child runs under **no collector**, detached from the harness but **bound to the
  command** (supervisor kills it on command-EOF). TODO_TASKS **TODO-39**; design record
  `AI_DOCS/2026-06-21-spawn-interactive-client-render-spec.md` §2/§8. (Interactive,
  chunk 20, reuses the chunk-29 primitive.)

- **Chunk 15 — final renderer ordering.** `Renderer::Driver` still pins the interim
  per-job 3-phase ordering on `Renderer::Base`; the final cross-job ordering
  guarantees are not yet defined (§4.5 stays authoritative).

- **Chunk 16 — concurrent run execution + run-scoped preload stages (needs 9,10).**
  §6.1 routes per run but execution stays serialized. Make the persistent runner run
  multiple runs at once (the **earlier-run-priority + backfill** goal, ARCH §6.1) and
  build run-scoped preload stages (`runs/<run_id>/preload-<stage>.socket`, the
  `run_id` hook — TODO_TASKS **TODO-16**). The concurrent-run scheduler change touches
  the per-run scheduling structures (TODO_TASKS **TODO-13** `%SORTED`; **TODO-12** run
  lifecycle is related but its primary home is chunk 22).

- **Chunk 20 — interactive mode IO (§4.10) — needs 29, 13. ✅ DONE.** Replaced the
  FIFO IO-proxy with **STDIN-only SCM_RIGHTS fd-passing** (chunk 29 primitive): the
  command (`App::Yath2::Options::Debug::_post_process_interactive`) **opens a listen
  socket only in interactive mode** (`$ENV{YATH_INTERACTIVE}` carries the **socket
  path**), forks, and runs a per-test accept loop. The test **dials in, `recv_fds`
  the real STDIN fd, `dup2`s it onto fd 0** through
  `Test2::Harness2::Interactive::connect_stdin` (preload: the `goto::file` filter in
  `Runner::JobLauncher`; no-preload: `-MTest2::Harness2::Interactive` injected by
  `Runner::Job::cli_options`, whose `import` connects before the test body).
  **Output stays with the collector** (STDOUT/STDERR not shared) → normal §4.5
  render; `--live`/`-v` default on. The command keeps the listener open and passes
  the fd **once per sequential test** (`-j1` via the isolation category), with a
  select-bounded accept that ends when the run does. No control channel (a normal
  collected job). FIFO machinery (`POSIX::mkfifo`, the open-retry loop) removed;
  tty/controlling-terminal limitation documented. TODO_TASKS **TODO-7** (7b), **TODO-40**.

- **Chunk 21 — collapse the IPC controller (§5.4) — needs 6. ✅ DONE (base slimmed,
  not dismantled).** The substantive collapse landed across TODO-6 (`cat`-waits +
  `PROCS_BY_CAT` deleted), TODO-8 P1-3 (die-on-unmonitored→skip, debug-gated warns,
  command inline reaper), and TODO-27/TODO-28/TODO-29 (reap-driven verdicts removed — completion
  rides EOF; no-preload `set_proc_exit` is zombie cleanup + A3 only). The chunk-21
  re-audit (2026-06-21) found little net-new remained: it deleted the dead
  `set_sig_handler` and corrected the §5.4 framing. **The base class is NOT
  dismantled and the three-pass reaper (`_check_if_dead_yet`/`_ex_parrots`) stays:**
  `Test2::Harness2::Preload::Host` (created by the chunk-19/22 split) is a THIRD
  co-equal multi-child consumer — it `use parent 'Test2::Harness2::IPC'` and runs its
  own `run_stage`/`run_job` loop with `wait()` + `set_proc_exit` + named-stage
  `longjump` relaunch — and is **out of scope** per chunk 26/TODO-29. `Util::IPC`
  (`run_cmd`/`swap_io`/`set_cloexec`/`USE_P_GROUPS`) + the thin `IPC::Process` value
  object stay. The `yath test`/`start` commands already inline their one-child
  spawn+wait on `Util::IPC::run_cmd` (TODO-8 P3). TODO_TASKS **TODO-6** (wait params) +
  **TODO-8** (the collapse). Full dismantling waits on `Preload::Host` collapsing its
  own stage machinery.

- **Chunk 22 — run state lifecycle (§4.2).** Fold the raw queue item onto the `Run`
  object (drop the leaking `run_items` hash); retain/purge run state per the
  **queuing client connection** (finished + owner-gone → purge); **abort-on-disconnect**
  (default true; flag to detach for a future `yath queue`). TODO_TASKS **TODO-12**.

- **Chunk 23 — client-side stage assignment (§4.7/§4.7a).** Eliminate the file→stage
  **resolver**, `resolve_file_stages` round-trip, preload-side `file_stage` callbacks,
  and **`eager`** stages. Stage choice is decided **at queue time** from test
  directives (`# HARNESS-NO-PRELOAD`, `# HARNESS-STAGE A B C`,
  `# HARNESS-STAGE-REQUIRE A B C`) + plugin hooks, written as three validated job
  fields (`no_preload`, `require_preload`, `preload_list`). Preloads only report the
  **map** (stages, `default`, live state) and launch on demand; the runner/preload
  resource resolves from the **local map** (first listed `up`; else wait; else
  `default` if advisory, skip/fail if required; **absent-from-map = permanent-unavailable**).
  Cleanup: delete the `eager` loop in `State::_stage_order`; rewrite/delete
  `file_stage`/`eager` tests; expand `HARNESS-STAGE` to multi-arg (1 = back-compat).
  Folds into chunk 11. TODO_TASKS **TODO-10**, **TODO-20**, **TODO-21**, **TODO-2**, **TODO-23**.

- **Chunk 24 — transition-driven test completion (§5.4).** The runner decides a
  test's outcome **only** from its collector's transitions (`harness_final_state`
  `pass`, plus a new early **`halt`/bail transition`** carrying the reason), and learns
  the collector is gone from the **EOF on its transition connection** to
  `runner.socket` — never from a `waitpid` status or a pid check. Decision: final_state
  seen → pass / fail⇒retry-if-tries-left (re-queue same `job_id`, new `job_try`) /
  `halt`⇒bail (halt run + terminate active under `--abort-on-bail`); final_state
  **absent at EOF → fail**, flagged possible-harness-internal (even on exit 0).
  **Invariant:** collector problem or missing final_state ⇒ fail, never a false pass.
  **Test2-Collector side:** emit the `halt` transition on first halt facet; make the
  collector parent exit **health-only** (0 = collector OK regardless of test verdict,
  non-zero = collector malfunction) — stop forwarding the child's verdict; ensure the
  `starting`/`harness_collector` handshake carries the collector pid. **Harness side:**
  delete `Job::_collector_exit_code` verdict-layering + the `bail` file; remove the
  reap-driven retry/stop/bail from `Runner::set_proc_exit` **and**
  `Preload::Host::set_proc_exit`; drop `StageDelegate`/`Runner::Client` verdict
  reporting. Every connection handshake reports its pid; a test collector adds
  `job_id`+`job_try`. TODO_TASKS **TODO-27**.

- **Chunk 25 — runner as child subreaper + detached preload collectors (§4.1/§5.4) —
  needs 24.** New pure-Perl `Test2::Harness2::Util::SubReaper` (no XS, no dep): Linux
  `prctl(PR_SET_CHILD_SUBREAPER,1)` + FreeBSD/DragonFly `procctl(...PROC_REAP_ACQUIRE)`
  via `syscall()` with a per-(OS,arch) number table; unknown/failed ⇒ graceful
  unsupported no-op. The runner acquires subreaper at startup. **Preload-spawned
  collectors double-fork + detach** so they re-parent to the runner (supported) or init
  (unsupported); the preload tree reaps no collectors. Port the local
  `Test2-Harness2-ChildSubReaper` `40-subreaper-behavior.t`. The reparenting logic must
  live in the util, not inlined in `Runner.pm`. TODO_TASKS **TODO-28**.

- **Chunk 26 — one run path (§5.4) — needs 24, 25.** With completion + reaping off the
  reap, `run_scheduler_only` becomes the runner's **only** run loop. Delete the
  in-runner `run_tests`/`run_stage`/`run_job` stage machinery and
  `_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS`; the no-preload dispatch forks a
  collector child and decides via transitions/EOF exactly like the preload path.
  Completes the **TODO-22 residual** (run_scheduler_only-as-only-path) + **TODO-4 Part 4** +
  **TODO-8 Part 4**. TODO_TASKS **TODO-29**.

- **Chunk 27 — generic `collector_transition` facet (deferred) — needs 24.** A test
  emits an event carrying a `collector_transition` facet; the collector forwards it
  verbatim as a transition to the runner, which routes any **non-builtin** transition
  to a **plugin hook** (`handle_transition` or similar). The extensible substrate for
  custom harness-significant signals. TODO_TASKS **TODO-30**.

- **Chunk 28 — runtime retry-request helper (deferred) — needs 24, 27.** A test-facing
  helper module a test calls to request a retry at runtime; emits an event the
  collector turns into a `retry` transition (rides the generic facet or a dedicated
  `control.retry`); the runner retries via the normal re-queue path. The retry
  *count/no-retry* file directive already exists (`# HARNESS-retry N` /
  `# HARNESS-no-retry`); this adds the runtime-request channel. TODO_TASKS **TODO-31**.

- **Chunk 29 — socket FD-pass primitive (§4.8/§4.10).** New
  `Test2::Harness2::Util::FdPass`: SCM_RIGHTS `send_fds`/`recv_fds` over **optional
  `IO::FDPass`** (a Recommends, **not** a hard requires — spawn + interactive error
  early if absent; the lean `test`/`run`/`start` path never loads it). Both ends
  agree on one backend (IO::FDPass = one fd per call, looped; old3's `Socket::MsgHdr`
  wrapper is the fallback reference). The choreography is **command-listens /
  target-dials**. Command-side **and** target-side `require` guards turn a missing
  module into a structured spawn rejection / clean interactive failure, never a raw
  post-accept crash. Shared by chunks 13 + 20. TODO_TASKS **TODO-38**.

- **Chunk 30 — harness-client library (§4.11).** Grow `App::Yath2::Client` into the
  bridge between `App::Yath2` and `runner.socket`: a **runner-lifecycle mode enum**
  (transient = spawn+own+reap+signal-trap; attach = discover+`kill(0)`; start =
  spawn-daemon), **finders + job-spec building** (absorb `RunPlan`), and **state-query
  accessors** over the mirrored `Monitor` (`jobs_in_state`, `events_file_for`). Thin
  `test`/`run`/`start` onto the mode; collapse the `run extends test` override pile +
  the inline runner spawn/reap/signal in `test.pm`. Does **not** own renderers (chunk
  31). `spawn` uses it only for stage discovery. TODO_TASKS **TODO-41**.

- **Chunk 31 — render-loop library (§4.12).** New `App::Yath2` `RenderLoop` that
  **owns dispatch + sink lifecycle + the run rollup** and takes an injected
  **pure-source `Producer`** (`poll`→ordered events, `done`). `iterate()` +
  `start()`/`start(sub{})` entry points. `LiveProducer` (extracted from the current
  `Subscriber`/`Monitor`/`Driver` mechanics — the `Driver`'s dispatch + `compute_final`
  + bounded `wait_terminal` move into the loop) and `JSONLFileProducer` (keeps
  `replay` working) land now; `ArchiveProducer` (DB log) is deferred to the DB-layer
  rewrite, when the `JobReader`/`RunnerReader` byte-source generalization (§4.5) and
  the `JSONLFileProducer` deletion happen. Sinks fed self-contained events for future
  child-process relocation. TODO_TASKS **TODO-42**.

## Cross-references

`ARCHITECTURE.md` carries the target-state detail these steps build toward:
§4.2 (runner service + run lifecycle), §4.3 (transition channel), §4.5 (renderers),
§4.7/§4.7a (preload stages + preload resource), §4.8 (spawn), §4.10 (interactive),
§4.11 (harness-client library), §4.12 (render-loop library),
§5.2/§5.3 (socket wire form + naming), §5.4 (spawn/reap), §6.1 (multi-run).
Reference prototypes live under `reference/` (`2.0b`, `harness_service`,
`dbix_quickorm`, `painter`, `io_events`).
