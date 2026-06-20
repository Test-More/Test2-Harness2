# Review guide — chunks 5, 6, and §6.1 (runner service + socket IPC + renderer)

Handoff document for code-review agents. It explains **what this branch does, how
to orient, where the risk is, and how to split the review**. Read this fully
before reviewing; it tells you what is deliberate (do not re-flag) and where to
dig.

## 0. Coordinates

- **Branch:** `chunk5-runner-service`, in worktree
  `/home/exodist/projects/Test2/Test2-Harness/worktrees/chunk5-runner-service`.
- **Merge base:** `a2e179e12` (the tip of `2.0d` this was cut from). Every diff
  below is against that base: `git diff a2e179e12..HEAD`.
- **Size:** 31 commits, 70 files, ~+8200/−2270.
- **Status:** not merged. Suite green: `Files=91, Tests=1662, Result: PASS`.
- **Dependency note:** `Test2::Collector` is a hard dep; the worktree loads it via
  the gitignored `t2clib` symlink → `../../../Test2-Collector/lib`. Do not review
  or modify anything under `reference/` (immutable history). `t2clib` is not part
  of the diff.

## 1. Read these first (in order)

1. `AGENTS.md` — workflow, the **mandatory pre-review gates** (§"Pre-review
   checks"), dependency rules, commit/worktree policy.
2. `STYLE_GUIDE.md` + `STYLE_GUIDE_AGENT_CHECKLIST.md` — the style rules the code
   must satisfy (eval patterns, `croak`/`die`, `<attr`, `//=`,
   `Time::HiRes::sleep`, methods-not-functions, POD layout, file/sub size).
3. `ARCHITECTURE.md` §2.5, §2.8, §4.1–4.7, §5.2–5.3, §6.1 — the authoritative
   target spec. §4.2 (runner service), §4.3 (transition channel), §4.5
   (renderers), §4.7 (preload stage services), §5.2–5.3 (wire form + socket
   naming), §6.1 (multi-run — now resolved-in-part) are the sections this branch
   implements.
4. `TODO_STEPS.md` — the "Done (summary)" section covers chunks 5 / §6.1 / 6; the
   per-chunk forward intent is under "Pending steps (detail)". (Note: this doc
   predates the 2026-06-19 restructure; TODO_STEPS no longer has the old "Current
   state" / "Chunks 4-6 detailed plan" sections — the deep history is in git.) Treat
   TODO_STEPS.md as the status-of-record.

## 2. The architecture delta (the mental model)

**Before (1.0, file-polling):** the runner forked a separate scheduler process;
run/task submission and dispatch flowed through `run_queue.jsonl` / `queue.jsonl`
/ `dispatch.jsonl` (+ a `dispatch.lock` flock); a standing yath-side **gatherer**
process (`Test2::Harness2::Collector`) polled those files, walked the workdir for
`events.jsonl.zst`, reconstructed state, and fed rendering. Persistent runner
output went to flat `output.log` / `error.log`, tailed by `yath watch`.

**After (this branch):** one **runner process is a collected socket service** on
`runner.socket` with an **in-process scheduler**. Commands are thin socket
clients. Every non-runner collector streams **transitions** (start / state-change
/ final / finalized facets) to `runner.socket`; the runner folds them into a
**per-run-keyed canonical state** (`Runner::Monitor`) and forwards them to
**subscribed clients** (snapshot + filtered forward). Preload stages are
**socket-dispatch services**. Rendering is **command-side**, driven by the
subscription + each job's `events.jsonl.zst` fetched by the path its transition
carries, via a reusable **base renderer** (`Renderer::Base`). `yath watch` is a
**global subscriber**. **The only IPC files anywhere are now `events.jsonl.zst`**
(the `aux_logs` plugin shell-call path is the lone remaining flat file, by
design). All wire traffic reuses `Test2::Collector::Util::{Socket, Zstd,
Zstd::FrameBuffer}` / `Recorder::Socket` — there must be **no harness-local
re-implementation** of framing/zstd/sockets (ARCH §2.8).

**Two invariants to hold the whole review against:**
- **Serialized execution.** A persistent runner runs **one active run at a
  time**. §6.1 routes transitions per-run so multiple `yath run` clients each see
  only their run, but it did **not** add concurrent execution. Do not expect (or
  require) multi-active scheduling.
- **The runner is the state authority; completion arrives as a transition, not a
  reap.** Reaping is a local detail of whoever forked a collector.

## 3. Commit map (grouped; oldest→newest)

Chunk 5 — transient `yath test` onto the socket model:
- `ceec15894` 5a runner as a collected `runner.socket` service (ports `Role::Service`)
- `24cb1e798` 5b scheduler → in-runner object (kills the scheduler process + `dispatch.lock`)
- `654a742b7` 5c run submission over the socket (`Runner::Client`; retires `run_queue.jsonl`)
- `c888157ad` 5d preload stages → socket-dispatch services (retires transient `dispatch.jsonl`)
- `625079b01` 5e transition channel (collectors report to runner; `Runner::Monitor` fold)
- `c6291a197` 5f client state sync (subscribe + snapshot + forward; `Runner::Subscriber`)
- `9c3ce01ae` 6a command-side renderer (`Renderer::Driver`; interim per-job ordering)
- `3b0704488` 5g retire gatherer on the transient path (`Runner::Watchdog`; move readers to neutral ns)

Refactor — shared command libs:
- `2222e3bef` `App::Yath2::Pfile` · `b1350c52d` `App::Yath2::RunPlan` · `84d88f06c` `App::Yath2::Client`

§6.1 — persistent path onto the socket model (serialized + per-run routing):
- `e881efa8f` per-run transition routing (key Monitor by run; run-filtered subscribe/forward)
- `f647c84c9` persistent collectors report + `harness_run_end` per-run completion
- `944757b05` run/spawn/stop on the socket + per-run stage socket naming
- `59210f9e2` persistent subscription-render + per-run routing test
- `fb5e07174` surface persistent runner/stage flat-log output in the Driver (interim)
- `5959fe720` delete the gatherer (now unspawned by anything)
- `6a0fdecc9` retire `run_queue.jsonl`/`queue.jsonl`; reload-state over the socket
- `3a4586b31` status/ps/abort over the socket (`Runner::StatusReport`); retire observe-State reads
- `a9ade9a7b` persistent preload stages → socket-dispatch services

Chunk 6 completion:
- `69ae0be63` drop dead `no_poll` State path
- `b33162faf` split `Runner.pm` → `Runner::Role::{Service::Handlers,Scheduler}` (1276→844 LOC)
- `4410c8105` §4.5 base renderer `Renderer::Base` (Driver → thin subclass)
- `f9142217c` collector-wrap persistent runner+stages, `watch` over the socket, retire flat logs
- `1b5373e1a` resources over the socket; retire `dispatch.jsonl`/observe machinery
- `3d9152cd1` fix: drain runner-events to terminal before finalize (resource.t flake)

Flake/test + docs: `ddaed0a0c` (smoke.t tie), and the `docs(...)` commits
(`722ae6566`, `0adb38b9b`, `2f004cc68`, `da97d3844`).

## 4. New modules — what each owns + what to scrutinize

Wire / service layer (`lib/Test2/Harness2/`):
- **`Role/Service.pm`** — service loop: non-blocking listen + `IO::Select` accept,
  per-connection `FrameBuffer`, frame **discriminator** (request `{request=>...}`
  vs transition facet), `request_handler_<type>` dispatch, `add_subscriber` /
  `forward_frame` (per-subscriber run filter + broadcast of global frames), socket
  cleanup. **Scrutinize:** the discriminator (could a transition ever look like a
  request or vice-versa?); broken-subscriber handling on `write_frame` failure;
  fd/socket cleanup on all exit paths; the inherited-listen-fd handling on fork
  (`reset_service`).
- **`Runner/Monitor.pm`** — canonical state fold, **keyed by run** (`run_uuid` ==
  `run_id`), plus a **global bucket** for runner/stage-lifecycle. `snapshot` /
  `apply_snapshot`, drain-on-call change-lists, jobs map (`harness_runner_job`),
  `run_done`. **Scrutinize:** run-key derivation (`run_for_payload`); that the
  global bucket vs per-run partition is correct; snapshot↔feed-mode round-trip
  fidelity; no `run_uuid`/proxy *filter framework* leaked in (only a single
  per-subscriber filter is intended).
- **`Runner/Subscriber.pm`** — client mirror: connect + subscribe (optionally
  scoped to a `run_id`; none = global), load snapshot into a feed-mode Monitor,
  `poll` forwarded frames, `closed` (EOF) / `run_done`. **Scrutinize:** EOF
  handling drains all buffered frames *before* flagging `closed`; the two-way
  `_request` reply read.
- **`Runner/Client.pm`** — low-level socket request client (`queue_run`/`queue_task`/
  `stop_run`/`end_queue`/`halt_run`/`queue_spawn`/`stop`/`reload_state`/`status`/
  `truncate`/`job_pid`/`resources`); bounded connect-retry with a caller liveness
  check. **Scrutinize:** the retry/liveness logic (a runner that dies during
  startup must make submission a clean no-op, not hang); EINTR/short-write paths.
- **`Runner/Stage.pm`** + **`Runner/Stage/Client.pm`** — the in-stage dispatch
  delegate and the runner→stage connect-out client (readiness = socket accepts).
- **`Runner/StatusReport.pm`** — builds the serializable status/ps/abort/resources
  report from canonical state + the job-pid map.
- **`Runner/Watchdog.pm`** — stalled-job abort (conservative: abort-on-wind-down).
- **`Runner/Role/Service/Handlers.pm`** + **`Runner/Role/Scheduler.pm`** — the
  pieces split out of `Runner.pm`. **Scrutinize:** constant/slot resolution — moved
  subs reference `$self->{'literal'}` HashBase slot keys; confirm each matches the
  constant value and that composition with `Role::Service` + `Object::HashBase` is
  clean.

Rendering (`lib/Test2/Harness2/Renderer/`):
- **`Base.pm`** — locates each collector's `.jsonl.zst` from transition state,
  reads by path (`JobReader`/`RunnerReader`), `step_runner_output` (runner/stage
  output), `compute_final`/`harness_final` rollup, `render_event` fan-out to sink
  renderers + logger, and `runner_output_done` (the drain predicate). **Scrutinize:**
  the events-file-by-path reads; the rollup (pass/failed/retried/halted/unseen,
  last-try-wins, retry-budget aware); `runner_output_done` correctness.
- **`Driver.pm`** — thin `Base` subclass pinning ONLY the interim per-job 3-phase
  ordering (lifecycle live → whole events file at completion → `harness_job_end`
  last) + `_render_aborted`.

Command-side libs (`lib/App/Yath2/`):
- **`Client.pm`** — command-side submit/subscribe wrapper (wraps
  `Runner::{Client,Subscriber}`; threads `run_id` for run-scoped subscribe).
- **`RunPlan.pm`** — run/run-dir/task-list construction from settings (unit-testable).
- **`Pfile.pm`** — persistent-runner discovery (`yath-persist.json` `{pid,dir}` +
  host/user/version/pid checks).

## 5. Deleted / moved / heavily-changed

- **Deleted:** `lib/Test2/Harness2/Collector.pm` (the gatherer) + its unit test.
  Confirm nothing references `Test2::Harness2::Collector` (grep → only comments/POD).
- **Renamed** (by-path readers, out of the deleted `Collector::*` namespace):
  `Collector/JobReader.pm` → `JobReader.pm`, `Collector/RunnerReader.pm` →
  `RunnerReader.pm` (+ their tests). Verify all callers updated.
- **Heavily changed:** `Runner.pm` (service-loop spine; now 844 code lines),
  `Runner/State.pm` (always `direct` in-memory; dispatch-file path gone),
  `Runner/Preloader.pm` (stages collector-wrapped, transient + persistent),
  `Runner/Job.pm` (socket reporter), `Command/test.pm` (subscription render loop;
  shrunk ~310 lines), `Command/{run,start,spawn,stop,watch,status,ps,abort,
  resources,reload,which}.pm` (socket clients / discovery role),
  `Runner/Resource/SharedJobSlots.pm` (dropped `observe`).

## 6. Review dimensions (the lenses) + hotspots

This branch's dominant risk is **concurrency / socket lifecycle**, not algorithmic
logic. Weight the review accordingly.

1. **Socket lifecycle & races (highest priority).**
   - Startup ordering: a client connecting before the runner binds `runner.socket`;
     the runner dispatching to a stage before its `preload-<stage>.socket` accepts
     (readiness handshake). Bounded `Time::HiRes::sleep` retries — confirm bounds
     exist and a dead peer surfaces as a clean error, never a hang.
   - **Completion vs flush race** (already bit us once — `3d9152cd1`): the runner
     closes the socket via the service loop while its trailing **stdout** is still
     draining through the **collector pipe** into `runner-events.jsonl.zst` (a
     different channel). Any "we're done, stop reading" path must drain
     events-files to their terminal first. Look for other places that stop on a
     socket/closed signal without a final by-path drain (job completion, stage
     teardown, run end).
   - Subscriber teardown: vanished subscriber dropped without killing the runner;
     `SIGPIPE` ignored; partial/short `write_frame` retried.
   - fd inheritance across `fork` (stages inherit the listen fd — must not accept;
     `reset_service`/rootpid gates).
2. **Per-run routing correctness (§6.1).** Each subscriber sees exactly its run +
   global; no cross-run leakage; a no-run-id (global, `watch`) subscriber sees all;
   snapshot is filtered consistently with the forward filter.
3. **Completion / verdict correctness.** Rollup matches the old gatherer's
   semantics (pass/failed/retried/halted/unseen); aborted-job verdict owned by the
   runner, pass/fail rollup by the Driver — confirm no double-owning, no dropped
   final state. `harness_run_end` fires once per run.
4. **Resource leaks.** Sockets unlinked on shutdown; no leaked fds per
   connection/stage; child reaping is still correct after the scheduler collapse
   (the `Test2::Harness2::IPC` `wait` path vs `Role::Service`'s own reaping — these
   were deliberately kept from racing; verify); temp/workdirs cleaned.
5. **Wire-util reuse (ARCH §2.8).** No harness-local copy of framing/zstd/socket
   logic — everything routes through `Test2::Collector::Util::*` /
   `Recorder::Socket`. Grep new files for `syswrite`/`sysread`/`IO::Socket`/zstd.
6. **Persistent path parity (gated).** `yath start`/`run`/`spawn`/`stop`/`watch`/
   `reload` still behave (persist.t). `reload` is SIGHUP to the **runner's own pid**
   (the collector parent ignores HUP — the pfile records the runner pid, written
   in two steps; review that sequence).
7. **Style / pre-review gates (mandatory; run them, treat hits as hard stops):**
   ```
   perl agent_scripts/audit-methods-not-functions lib
   perl agent_scripts/audit-readonly-attrs lib
   podchecker <each touched .pm>
   ```
   Plus the eval-return-value pattern, `croak` vs `die`, `<attr`, postfix
   single-statement conditionals, `push @x => $y`, no trailing whitespace, files
   <1000 / subs <75 LOC.
8. **Test coverage.** New unit tests exist for most new modules (`Role_Service`,
   `Runner_{Monitor,Subscriber,Client,Watchdog,resources_handler}`, `Renderer_Base`,
   `RunPlan`, `Client`, `Pfile`) and integration tests (`subscription_render`,
   `stage_dispatch`, `persist_subscription`, `watch_socket`). Look for **gaps**:
   concurrency/error paths (broken stage socket, runner death mid-run, subscriber
   disconnect), and cross-run isolation under a multi-run persistent runner.

## 7. Deliberate decisions — DO NOT re-flag these as bugs

- **Serialized execution** on the persistent runner (one active run). Concurrent
  execution is explicitly out of scope (future work).
- **`Renderer::Driver` still pins the interim per-job 3-phase ordering** on top of
  `Renderer::Base`. The final cross-job ordering is intentionally undefined
  (ARCH §4.5 authoritative). This is the one "interim" remnant in chunk 6.
- **`aux_logs`** (plugin shell-call path) is the lone remaining flat file, by
  design — not part of the IPC retirement.
- **`Runner::Watchdog` is conservative** (abort-on-wind-down, matching the old
  gatherer's real "abort once the runner is gone" semantics). Active mid-run
  stalled-kill was tried and dropped (it destabilized the nested-stage scheduler).
- **`resources.pm` auto-generated `OPTIONS` POD** lists its old narrower option set
  (it now inherits the full run/test set); refreshed by the author POD-regen tool,
  not asserted by any test.
- **Run-scoped preload stages** are not built as a user feature; only the
  `runs/<run_id>/preload-<stage>.socket` naming foundation is reserved.
- **Dead `State` dispatch-file plumbing** has already been removed (`1b5373e1a`);
  `State::poll` is a kept no-op the scheduling API still calls.
- **`Runner.pm` size** is under the 1000-line guide now (844). Several `Command/*.pm`
  files exceed 1000 lines but are ~95% auto-generated option POD, not code —
  pre-existing.

## 8. Running the suite + flake history

```
prove -Ilib -j16 -r t/        # the gate; -Ilib is mandatory
```
Suite is reliably green (`Files=91, Tests=1662`). Two flakes were found and
**fixed** this branch:
- `smoke.t` — start-stamp tie under `-j3` at the 3/4 smoke/non-smoke boundary
  (`ddaed0a0c`).
- `resource.t` — the completion-vs-flush race in §6 item 1 (`3d9152cd1`).

If you see an intermittent failure, first check you are **not running a second
suite in the same worktree** — concurrent runs collide on the shared
`runner.socket` / workdirs / `.immiscible-test.lock` and produce spurious
failures. Run from a separate checkout, or serialize. A genuine new flake (one
that reproduces in isolation under `-j16`) is in scope to fix, not mask.

## 9. Suggested multi-agent decomposition

Split the review along these mostly-independent seams (each agent reads §1–§3 +
§7 of this guide first):

- **Agent W — wire/service/concurrency:** `Role/Service.pm`, `Runner::{Client,
  Subscriber,Stage,Stage/Client}.pm`, the socket lifecycle/race hotspots (§6.1).
  Highest-value adversarial pass.
- **Agent S — runner core & state:** `Runner.pm` + `Runner/Role/*`,
  `Runner/Monitor.pm`, `Runner/State.pm`, `Runner/Watchdog.pm`, scheduler tick,
  reaping, per-run routing correctness (§6.2/6.4).
- **Agent R — rendering & completion:** `Renderer/{Base,Driver}.pm`, the
  `test.pm`/`run.pm` render loops, the drain-before-finalize fix, verdict rollup
  (§6.3), `JobReader`/`RunnerReader` by-path reads.
- **Agent C — commands & persistent path:** `App/Yath2/{Client,RunPlan,Pfile}.pm`,
  `Command/{test,run,start,spawn,stop,watch,status,ps,abort,resources,reload}.pm`,
  persist.t parity, the reload/pfile-pid sequence (§6.6).
- **Agent T — tests & style gates:** run the three pre-review scripts + podchecker
  over the whole diff, audit test coverage gaps (§6.8), check STYLE_GUIDE
  compliance across all touched files.

Each agent should **verify, not just read** — confirmed bug claims beat
speculation. Where a finding touches the socket-lifecycle invariants in §2, prefer
an adversarial "can this race / leak / hang?" framing.
