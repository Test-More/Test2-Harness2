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
| 7 | System-load service (own process, reliable tick → reports load) — needs 9 | ⬜ | — |
| 8a | Database + UI inline (interim DBIx::Class, SQLite logs) | ✅ | — |
| 8b | Convert inlined UI schema DBIx::Class → DBIx::QuickORM (§2.4/§4.6) | ⬜ (deferred) | — |
| 9 | Unified service channel — full bidirectional RPC (§5.2) | ✅ | — |
| 10 | Preload stage lifecycle states + stage-owned restart (§4.7) — needs 9 | ⬜ (residual) | #2, #3 |
| 11 | Preload as a scheduler resource (§4.7a) — needs 10, 23 | ⬜ | #24 (resource iface), #2, #3 |
| 12 | Discovery via runner-socket symlink + PID-file fallback (§5.3) | ✅ (`App::Yath2::Discovery`) | — |
| 13 | `spawn` bypasses runner: direct `Preload::Host` socket, **SCM_RIGHTS fd-pass** of real STDIN/OUT/ERR, supervisor (no exec → longjump preload path) + dedicated control protocol, kill-on-command-EOF, no collector (§4.8) — needs 12, 29, 30 | ⬜ | #39 |
| 14 | Split `Test2::Harness2::TestFile` → `App::Yath2` reader + state-only object (§1) | ✅ | — |
| 15 | Final renderer ordering (cross-job, post-§4.5 interim) | ⬜ | — |
| 16 | Concurrent run execution + run-scoped preload stages (§6.1) — needs 9,10 | ⬜ | #13 (%SORTED concurrency); #12 (run lifecycle, primary home ch22) |
| 17 | Plugin setup/teardown move to the runner; aux output → collectors; retire aux_logs flat files | ✅ | — |
| 18 | Collectors watch the runner pid → self-terminate if runner dies (§4.1) + audit gate | ✅ | — |
| 19 | Extract the preload root out of the runner; runner goes scheduler-only (§4.2/§4.7) — needs 14 | ✅ (residuals → 20-23 + tasks) | #1–#4, #8, #10, #11, #26 |
| 20 | Interactive mode IO: replace FIFO proxy with **STDIN-only SCM_RIGHTS fd-pass** (output stays with collector), command-listens/per-test-accept (§4.10, reuses §4.8 primitive) — needs 29, 13. May be temporarily disabled / xfail until this lands (do not block #4-task) | ⬜ | #7 (7b), #40 |
| 21 | Collapse the `Test2::Harness2::IPC` controller → spawn + zombie-reap on `Util::IPC` (§5.4) — needs 6 | ✅ (base class slimmed, not dismantled — `Preload::Host` is a 3rd consumer, out of scope per 26/#29) | #6, #8, #11 |
| 22 | Run state lifecycle (§4.2): fold raw item onto `Run`, connection-gated retention, abort-on-disconnect | ✅ (via #12 `5ac411700`; status cell was stale) | #12 |
| 23 | Client-side stage assignment; eliminate the resolver / `resolve_file_stages` / `file_stage` / `eager` (§4.7/§4.7a). Folds into 11 | ⬜ | #10, #20, #21, #2, #23 |
| 24 | Transition-driven test completion (§5.4): pass/fail/retry/bail from transitions + connection EOF; collector exit health-only; bidirectional conns + runner→collector terminate; fd hygiene. Spans Test2-Collector. | ✅ | #32, #27 |
| 25 | Runner as child subreaper + preload collectors double-fork/detach (§4.1/§5.4); new `Test2::Harness2::Util::SubReaper` (pure-Perl `syscall`). Lets the preload tree reap nothing. — needs 24 | ✅ | #28 |
| 26 | Collapse to one run path (§5.4): `run_scheduler_only` becomes the runner's only run loop; delete the in-runner `run_tests`/`run_stage`/`run_job` stage machinery. Completes #22 residual + #4 P4 + #8 P4. — needs 24, 25 | ✅ | #29 |
| 27 | Generic `collector_transition` event facet (Test2-Collector forwards verbatim) + runner→plugin hook for non-builtin transitions. — needs 24 | ⬜ (deferred) | #30 |
| 28 | Runtime retry-request: a test-facing helper emits an event → collector `retry` transition → runner retries via normal re-queue. — needs 24, 27 | ⬜ (deferred) | #31 |
| 29 | Socket FD-pass primitive `Test2::Harness2::Util::FdPass` (SCM_RIGHTS; optional `IO::FDPass`; command-listens) — shared by spawn (13) + interactive (20) | ✅ (primitive only; consumers 13/20 separate) | #38 |
| 30 | Harness-client library: grow `App::Yath2::Client` to own runner-lifecycle modes + finders/specs + state queries; thin `test`/`run`/`start` (§4.11) | ✅ | #41 |
| 31 | Render-loop library: `RenderLoop` (owns dispatch+rollup) + pure-source `Producer`; `LiveProducer` + `JSONLFileProducer` now, `ArchiveProducer` deferred to DB rewrite (§4.12) | ✅ (ArchiveProducer deferred) | #42 |

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

## Pending steps (detail)

Steps still to do. Each notes its dependencies and the TODO_TASKS tickets that
carry the specifics.

- **Chunk 7 — system-load service (needs 9).** Its own global process with a
  reliable tick (the runner loop can exceed the sample interval), a full service on
  the §5.2 channel: own listen socket, connects to the runner to push updates,
  broadcasts load changes; the in-runner scheduler consumes them to gate
  concurrency. Port `reference/harness_service/.../SystemLoad.pm` + its sampler
  service shape (drop the run-vs-global split; adopt the §5.2 channel).

- **Chunk 8b — QuickORM conversion.** Migrate the inlined DB/UI schema from interim
  DBIx::Class to DBIx::QuickORM (§2.4/§4.6), keeping the default SQLite path on
  `DBD::SQLite`. Until this lands, DBIx::Class is an interim import.

- **Chunk 10 — preload stage lifecycle states + stage-owned restart (§4.7).**
  Registration + dispatch-over-registered-channel landed in 9. Residual: the
  explicit **`starting`/`up`/`restarting`/`down`** enum (TODO_TASKS **#2**) and the
  collector-driven self-termination + connection-currency that replaces
  generation-stamping (TODO_TASKS **#3**); plus giving the stage ownership of its
  restart decision (the preloader monitor currently drives reload-respawn through
  `set_proc_exit`).

- **Chunk 11 — preload as a resource (§4.7a) — needs 10, 23.** Model preload
  availability as a single scheduler **resource** with the standard
  `available`/`assign`/`release` contract. `available($task)` is tri-state over the
  stage lifecycle (`1` up; `0` starting/restarting; `-1` permanent/absent for a
  required stage); `assign` records the chosen stage; `release` ~no-op; the
  assign→launch race **requeues** (TODO_TASKS **#3** requeue primitive). It consumes
  the three job fields chunk 23 produces (no resolver). Resource interface hardening
  is TODO_TASKS **#24**.

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

- **Chunk 13 — `spawn` bypasses the runner (§4.8) — needs 12, 29, 30.** `spawn`
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
  command** (supervisor kills it on command-EOF). TODO_TASKS **#39**; design record
  `AI_DOCS/2026-06-21-spawn-interactive-client-render-spec.md` §2/§8. (Interactive,
  chunk 20, reuses the chunk-29 primitive.)

- **Chunk 15 — final renderer ordering.** `Renderer::Driver` still pins the interim
  per-job 3-phase ordering on `Renderer::Base`; the final cross-job ordering
  guarantees are not yet defined (§4.5 stays authoritative).

- **Chunk 16 — concurrent run execution + run-scoped preload stages (needs 9,10).**
  §6.1 routes per run but execution stays serialized. Make the persistent runner run
  multiple runs at once (the **earlier-run-priority + backfill** goal, ARCH §6.1) and
  build run-scoped preload stages (`runs/<run_id>/preload-<stage>.socket`, the
  `run_id` hook — TODO_TASKS **#16**). The concurrent-run scheduler change touches
  the per-run scheduling structures (TODO_TASKS **#13** `%SORTED`; **#12** run
  lifecycle is related but its primary home is chunk 22).

- **Chunk 20 — interactive mode IO (§4.10) — needs 29, 13.** Replace the FIFO
  IO-proxy with **STDIN-only SCM_RIGHTS fd-passing** (chunk 29 primitive): the
  command **opens a listen socket only in interactive mode** (`$ENV{YATH_INTERACTIVE}`
  carries the **socket path**), the test **dials in, `recv_fds` the real STDIN fd,
  `dup2`s it onto fd 0** (preload: goto-file filter; no-preload: pre-exec connect).
  **Output stays with the collector** (STDOUT/STDERR not shared) → normal §4.5
  render. The command keeps the listener open and passes the fd **once per
  sequential test** (`-j1`), with timeout/cleanup, stopping after the run. The FIFO
  patch lives in the goto-file launcher that the no-preload-fork-exec task removes,
  so interactive may be **temporarily disabled / left xfail** until this lands.
  TODO_TASKS **#7** (7b), **#40**.

- **Chunk 21 — collapse the IPC controller (§5.4) — needs 6. ✅ DONE (base slimmed,
  not dismantled).** The substantive collapse landed across #6 (`cat`-waits +
  `PROCS_BY_CAT` deleted), #8 P1-3 (die-on-unmonitored→skip, debug-gated warns,
  command inline reaper), and #27/#28/#29 (reap-driven verdicts removed — completion
  rides EOF; no-preload `set_proc_exit` is zombie cleanup + A3 only). The chunk-21
  re-audit (2026-06-21) found little net-new remained: it deleted the dead
  `set_sig_handler` and corrected the §5.4 framing. **The base class is NOT
  dismantled and the three-pass reaper (`_check_if_dead_yet`/`_ex_parrots`) stays:**
  `Test2::Harness2::Preload::Host` (created by the chunk-19/22 split) is a THIRD
  co-equal multi-child consumer — it `use parent 'Test2::Harness2::IPC'` and runs its
  own `run_stage`/`run_job` loop with `wait()` + `set_proc_exit` + named-stage
  `longjump` relaunch — and is **out of scope** per chunk 26/#29. `Util::IPC`
  (`run_cmd`/`swap_io`/`set_cloexec`/`USE_P_GROUPS`) + the thin `IPC::Process` value
  object stay. The `yath test`/`start` commands already inline their one-child
  spawn+wait on `Util::IPC::run_cmd` (#8 P3). TODO_TASKS **#6** (wait params) +
  **#8** (the collapse). Full dismantling waits on `Preload::Host` collapsing its
  own stage machinery.

- **Chunk 22 — run state lifecycle (§4.2).** Fold the raw queue item onto the `Run`
  object (drop the leaking `run_items` hash); retain/purge run state per the
  **queuing client connection** (finished + owner-gone → purge); **abort-on-disconnect**
  (default true; flag to detach for a future `yath queue`). TODO_TASKS **#12**.

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
  Folds into chunk 11. TODO_TASKS **#10**, **#20**, **#21**, **#2**, **#23**.

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
  `job_id`+`job_try`. TODO_TASKS **#27**.

- **Chunk 25 — runner as child subreaper + detached preload collectors (§4.1/§5.4) —
  needs 24.** New pure-Perl `Test2::Harness2::Util::SubReaper` (no XS, no dep): Linux
  `prctl(PR_SET_CHILD_SUBREAPER,1)` + FreeBSD/DragonFly `procctl(...PROC_REAP_ACQUIRE)`
  via `syscall()` with a per-(OS,arch) number table; unknown/failed ⇒ graceful
  unsupported no-op. The runner acquires subreaper at startup. **Preload-spawned
  collectors double-fork + detach** so they re-parent to the runner (supported) or init
  (unsupported); the preload tree reaps no collectors. Port the local
  `Test2-Harness2-ChildSubReaper` `40-subreaper-behavior.t`. The reparenting logic must
  live in the util, not inlined in `Runner.pm`. TODO_TASKS **#28**.

- **Chunk 26 — one run path (§5.4) — needs 24, 25.** With completion + reaping off the
  reap, `run_scheduler_only` becomes the runner's **only** run loop. Delete the
  in-runner `run_tests`/`run_stage`/`run_job` stage machinery and
  `_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS`; the no-preload dispatch forks a
  collector child and decides via transitions/EOF exactly like the preload path.
  Completes the **#22 residual** (run_scheduler_only-as-only-path) + **#4 Part 4** +
  **#8 Part 4**. TODO_TASKS **#29**.

- **Chunk 27 — generic `collector_transition` facet (deferred) — needs 24.** A test
  emits an event carrying a `collector_transition` facet; the collector forwards it
  verbatim as a transition to the runner, which routes any **non-builtin** transition
  to a **plugin hook** (`handle_transition` or similar). The extensible substrate for
  custom harness-significant signals. TODO_TASKS **#30**.

- **Chunk 28 — runtime retry-request helper (deferred) — needs 24, 27.** A test-facing
  helper module a test calls to request a retry at runtime; emits an event the
  collector turns into a `retry` transition (rides the generic facet or a dedicated
  `control.retry`); the runner retries via the normal re-queue path. The retry
  *count/no-retry* file directive already exists (`# HARNESS-retry N` /
  `# HARNESS-no-retry`); this adds the runtime-request channel. TODO_TASKS **#31**.

- **Chunk 29 — socket FD-pass primitive (§4.8/§4.10).** New
  `Test2::Harness2::Util::FdPass`: SCM_RIGHTS `send_fds`/`recv_fds` over **optional
  `IO::FDPass`** (a Recommends, **not** a hard requires — spawn + interactive error
  early if absent; the lean `test`/`run`/`start` path never loads it). Both ends
  agree on one backend (IO::FDPass = one fd per call, looped; old3's `Socket::MsgHdr`
  wrapper is the fallback reference). The choreography is **command-listens /
  target-dials**. Command-side **and** target-side `require` guards turn a missing
  module into a structured spawn rejection / clean interactive failure, never a raw
  post-accept crash. Shared by chunks 13 + 20. TODO_TASKS **#38**.

- **Chunk 30 — harness-client library (§4.11).** Grow `App::Yath2::Client` into the
  bridge between `App::Yath2` and `runner.socket`: a **runner-lifecycle mode enum**
  (transient = spawn+own+reap+signal-trap; attach = discover+`kill(0)`; start =
  spawn-daemon), **finders + job-spec building** (absorb `RunPlan`), and **state-query
  accessors** over the mirrored `Monitor` (`jobs_in_state`, `events_file_for`). Thin
  `test`/`run`/`start` onto the mode; collapse the `run extends test` override pile +
  the inline runner spawn/reap/signal in `test.pm`. Does **not** own renderers (chunk
  31). `spawn` uses it only for stage discovery. TODO_TASKS **#41**.

- **Chunk 31 — render-loop library (§4.12).** New `App::Yath2` `RenderLoop` that
  **owns dispatch + sink lifecycle + the run rollup** and takes an injected
  **pure-source `Producer`** (`poll`→ordered events, `done`). `iterate()` +
  `start()`/`start(sub{})` entry points. `LiveProducer` (extracted from the current
  `Subscriber`/`Monitor`/`Driver` mechanics — the `Driver`'s dispatch + `compute_final`
  + bounded `wait_terminal` move into the loop) and `JSONLFileProducer` (keeps
  `replay` working) land now; `ArchiveProducer` (DB log) is deferred to the DB-layer
  rewrite, when the `JobReader`/`RunnerReader` byte-source generalization (§4.5) and
  the `JSONLFileProducer` deletion happen. Sinks fed self-contained events for future
  child-process relocation. TODO_TASKS **#42**.

## Cross-references

`ARCHITECTURE.md` carries the target-state detail these steps build toward:
§4.2 (runner service + run lifecycle), §4.3 (transition channel), §4.5 (renderers),
§4.7/§4.7a (preload stages + preload resource), §4.8 (spawn), §4.10 (interactive),
§4.11 (harness-client library), §4.12 (render-loop library),
§5.2/§5.3 (socket wire form + naming), §5.4 (spawn/reap), §6.1 (multi-run).
Reference prototypes live under `reference/` (`2.0b`, `harness_service`,
`dbix_quickorm`, `painter`, `io_events`).
