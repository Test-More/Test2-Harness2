# IPC.md — current IPC, process, and artifact reference

**This document describes the system as it is RIGHT NOW**, on this branch. It is a
living map of how processes talk, who reaps whom, and what files exist and who
reads them.

Rules for this file:

- **Current state only.** It must match the code as committed. When IPC, the
  process tree, reaping, sockets, or on-disk artifacts change, update this file in
  the same change.
- **Nothing that is gone.** Do not describe retired files, removed processes, or
  old mechanisms. If it no longer exists, it does not appear here.
- **Nothing aspirational.** Target/end-state design lives in `ARCHITECTURE.md`.
  Planned-but-unbuilt features do not appear here until they exist.

If `ARCHITECTURE.md` (target) and this file (current) disagree, that gap is the
remaining migration work — this file still describes what is actually true today.

---

## 1. The collector-wrapping model (read first)

Every process yath starts — the runner, each preload stage, and each test job —
runs **under its own `Test2::Collector` parent**. The collector is the parent
process; it execs/forks the real work as its child, records the child's
stdout/stderr/exit as timestamped events into a `*.jsonl.zst` file, and (for every
process except the runner) its reporter streams **transitions** to `runner.socket`.
The collector parent `POSIX::_exit`s with the child's verdict, so **reaping a yath
process means reaping its collector wrapper**.

- Runner + preload stages run under **non-test** collectors.
- Test jobs run under **test** collectors.

Below, `[collector:NAME] → proc` means "proc runs under a non-test/test collector
labelled NAME".

---

## 2. Process tree — transient `yath test`

```
yath test                          COMMAND: client + renderer host
│   connects to runner.socket: submit run + subscribe(run_id)
│   renders via Renderer::Driver (reads each *.jsonl.zst by path)
│
└─ spawn ─ [collector:runner] ─► runner  (service; binds runner.socket)
                                 │  in-process scheduler (in-memory State)
                                 │  Runner::Monitor = canonical state
                                 │  connects OUT to each preload-<stage>.socket
                                 │
                                 ├─ fork ─ [collector:stage-<name>] ─► preload stage  (service; binds preload-<name>.socket)
                                 │                                     └─ fork ─ [collector:job] ─► test job ─ exec test file
                                 │
                                 └─ no-preload path: fork ─ [collector:job] ─► test job   (runner forks the job collector itself)
```

Lifespan: the transient runner shuts down and closes `runner.socket` once the run
is done and its job children are reaped; the command's render loop ends on that
socket EOF.

---

## 3. Process tree — persistent `yath start` / `run`

```
yath start  (writes yath-persist.json {pid,dir}; spawns the runner; then exits)
   │
   └─ [collector:runner] ─► persistent runner  (service; stays up on runner.socket)
                            │  serialized: one active run at a time
                            │  Runner::Monitor keyed by run; routes each client only its run
                            ├─ [collector:stage-<name>] ─► preload stage (service on preload-<name>.socket)
                            │                              └─ [collector:job] ─► test job
                            └─ ...

clients connecting IN to runner.socket:
   yath run     submit run(run_id) + subscribe(run_id)   → renders its run via Renderer::Driver
   yath watch   subscribe (no run_id = global)           → renders runner/stage output via Renderer::Base
   yath status / ps / abort / resources   request → Runner::StatusReport reply
   yath spawn   submit a spawn over the socket (acknowledged: fails fast if no live stage)
   yath stop    'stop' request (graceful shutdown)
   yath reload  SIGHUP → the runner's own pid (from yath-persist.json)
```

`yath run`/`spawn`/`stop`/`status`/`ps`/`abort`/`resources`/`which`/`watch`
discover the runner via `yath-persist.json` (read through `App::Yath2::Pfile`).
The persistent runner stays listening until a `stop` request.

---

## 4. Who reaps whom

Reaping is local to whichever process forked the (collector-wrapped) child;
`Test2::Harness2::IPC` owns it in each forking process. The runner's
`Role::Service::reap_children` is a deliberate **no-op** so it does not race
`Test2::Harness2::IPC`.

| Forks / spawns | Reaps | Notes |
|---|---|---|
| `yath test` command | the runner (its collector) | transient only; `start`/`run` do not reap the persistent runner |
| runner | each preload stage (its collector); on the no-preload path, the test job (its collector) it forked directly | |
| preload stage | each test job (its collector) it forked | the stage reports the job's `stop_task`/`retry_task` back to `runner.socket` |

**Completion is learned from transitions, not from reaping.** A job's collector
emits its final-state transition to `runner.socket`; the runner folds it into
canonical state. Reaping is just local cleanup afterward. The runner's
`Runner::Watchdog` aborts a job whose dispatch to a stage failed (so the run does
not stall) and aborts any still-running jobs at run wind-down.

---

## 5. Sockets

All sockets live in the **workdir**, are unix-domain `SOCK_STREAM`, and carry the
same wire form: each message is a JSON object, zstd-compressed into one
self-contained frame, via `Test2::Collector::Util::Socket` (`open_unix_listen` /
`connect_unix` / `write_frame`) + `Test2::Collector::Util::Zstd` /
`...Zstd::FrameBuffer`. The harness keeps no copy of this machinery.

| Socket | Server (accepts) | Clients (connect out) | Carries |
|---|---|---|---|
| `runner.socket` | the runner | `test`/`run`/`spawn`/`stop`/`status`/`ps`/`abort`/`resources`; every non-runner collector's reporter; each preload stage (reporting back) | control **requests** (+ replies); **transitions** from job & stage collectors; stage→runner `stop_task`/`retry_task`/`stage_ready`/`stage_down` |
| `preload-<stage>.socket` (one per preload stage) | that preload stage | the runner (via `Runner::Stage::Client`) | job dispatch: `run_task`, `stop` |

The runner is both a **server** (on `runner.socket`) and a **client** (out to each
`preload-<stage>.socket`).

### Frame discrimination on `runner.socket`

`Role::Service` distinguishes two frame kinds on the one socket:

- **Request frame:** `{ request => <type>, ... }` → dispatched to
  `request_handler_<type>` (a reply frame is written back for two-way requests;
  one-way requests get no reply).
- **Transition frame:** carries `facet_data` with one of `harness_collector` /
  `harness_state_transition` / `harness_final_state` / `harness_collector_finalized`
  → folded into `Runner::Monitor` and forwarded to subscribers.

Requests carry no `facet_data`, so the two never collide.

### Connection model — inbound vs outbound are separate

A process that both serves a socket and connects out to others keeps **two
unrelated connection structures**; they are not one shared pool, and a connection
is never reused for the opposite direction.

- **Inbound (server side, from `Role::Service`):** `service_select` (an
  `IO::Select`), `service_conns` (each accepted fd → its `FrameBuffer`), and
  `service_subs` (the subset of accepted conns that sent `subscribe`). Every peer
  that connects *to* this process lands here, multiplexed by `select`. The server
  only **reads** framed requests/transitions off these — except subscriber conns,
  which it also **pushes** forwarded frames to (the one bidirectional case, see
  below).
- **Outbound (client side):** discrete cached client objects, one per peer, each
  holding a single connection this process opened *out*. They are **not** in the
  select set and are write-only (their requests are one-way / read only an
  explicit reply). On the runner: `stage_clients` (`stage → Runner::Stage::Client`,
  out to each `preload-<stage>.socket`). On a stage: one `Runner::Client` (out to
  `runner.socket`) plus its collector's `Recorder::Socket` reporter (also out to
  `runner.socket`).

So runner ↔ stage traffic is **two independent one-way channels**, each its own
connect-out → accept pair — not one bidirectional connection reused both ways:

```
runner --[Stage::Client: connect-out, one-way run_task/stop]--> stage's accept set   (dispatch)
stage  --[Runner::Client: connect-out, one-way stop_task/...]--> runner's accept set  (report back)
```

The runner never reads from its outbound stage connection; the stage never writes
back on the inbound dispatch connection it accepted. Each fd is single-purpose and
single-direction.

**The one bidirectional fd — subscribers.** A subscriber connects *out* to
`runner.socket` (inbound to the runner), sends `subscribe`, and the runner then
**pushes** forwarded transition frames back over that same fd (`forward_frame`
over `service_subs`). So a subscriber connection carries both directions on one
accepted fd — but it still lives in the inbound accept set, just flagged in
`service_subs`.

---

## 6. Transition channel, canonical state, and subscriptions

```
test-job collector ─┐
stage collector ────┤  reporter (Recorder::Socket) streams TRANSITIONS ──► runner.socket
                    │  (the runner's OWN collector does not report to itself;
                    │   its transitions go to its own events file)
                    ▼
        runner: Runner::Monitor  (fold by run; run_uuid == run_id)
                    │  per-run buckets + a global bucket (runner/stage lifecycle)
                    │  jobs map (runner-originated job mutations)
                    │
                    ▼  forward_frame: each subscriber receives ITS run + the global bucket
        subscribers: one Runner::Subscriber per command
                    │  snapshot on connect, then forwarded deltas → a feed-mode Monitor mirror
                    ▼
        command-side renderer reads full detail BY PATH ──► the relevant *.jsonl.zst
```

A subscribe request may carry a `run_id` (scoped: that run + global) or none
(global: everything — used by `watch`).

---

## 7. Where renderers live

Rendering happens **inside the command process** (`test` / `run` / `watch`) — there
is no separate renderer/gatherer process.

```
command (test / run / watch)
└─ Renderer::Base                       reusable base
   ├─ transition-state mirror (Monitor, fed by Subscriber)
   ├─ locates a collector's *.jsonl.zst from transition state, reads BY PATH
   │     via Test2::Harness2::JobReader / Test2::Harness2::RunnerReader
   ├─ rolls up the run verdict → harness_final
   └─ render_event fan-out to SINK renderers + the logger:
        ├─ Test2::Harness2::Renderer::Formatter  → Test2::Formatter::*  (terminal)
        ├─ App::Yath2::Renderer::DB              (sqlite log / UI store)
        ├─ App::Yath2::Renderer::Server         (DB + live web server)
        └─ logger (plain filehandle, JSONL)

Test2::Harness2::Renderer::Driver  — subclass of Base used by test/run; orders each
                                     job as: lifecycle live → whole events file at
                                     completion → job-end last. Settles a job's
                                     verdict from the events-file terminal.
yath watch                         — uses Renderer::Base directly as a global
                                     subscriber to render runner/stage output.
```

`JobReader` / `RunnerReader` are by-path readers of a single `*.jsonl.zst` — they
do not discover or orchestrate.

---

## 8. On-disk artifacts and their consumers

| Artifact | Created by | Where | Consumed by | Purpose |
|---|---|---|---|---|
| `runner-events.jsonl.zst` | the runner's non-test collector | workdir | the command renderer (`RunnerReader`, by path); `watch` | runner stdout/stderr/exit as events |
| `stage-<name>-events.jsonl.zst` | each preload stage's non-test collector | workdir | the command renderer (`RunnerReader`); `watch` | stage stdout/stderr/exit as events |
| `events.jsonl.zst` (per job) | each test job's test collector | the job's run dir | the command renderer (`JobReader`, by the path a transition carries) | the test's full event stream |
| `aux_logs/*.log` | plugin shell-call paths (outside the collector pipeline) | `workdir/aux_logs` | the renderer's aux-log tail; `watch` | plugin-emitted output |
| `yath-persist.json` | `yath start` | workdir | `run`/`spawn`/`stop`/`which`/`watch`/`reload` via `App::Yath2::Pfile` | persistent-runner discovery: `{pid, dir, ...}` |
| `PID` file | the runner | workdir | discovery / liveness; `start` records the runner pid into `yath-persist.json` | the runner's own pid |
| `settings.json` | `yath start` (persistent) | workdir | `yath run` (merged into its settings on connect) | run configuration carried to clients |

The `*.jsonl.zst` events files are the only files on the IPC/detail path; all
decision and dispatch traffic is on the sockets in §5. (`aux_logs` is a plugin
shell-call side channel, not part of socket IPC.)

---

## 9. Commands as clients of the runner service

| Command | Reaches the runner via | Action |
|---|---|---|
| `test` | spawns the runner, then `runner.socket` | submit run + subscribe(run_id) + render |
| `run` | discover (Pfile) + `runner.socket` | submit run(run_id) + subscribe(run_id) + render |
| `spawn` | `runner.socket` | submit a spawn (acknowledged — errors fast if the runner has no live stage for it), then attach to the spawned worker's IO |
| `watch` | `runner.socket` | subscribe (global) + render runner/stage output |
| `status` / `ps` / `abort` / `resources` | `runner.socket` | request → `Runner::StatusReport` reply |
| `stop` | `runner.socket` | graceful `stop` request |
| `reload` | `yath-persist.json` → SIGHUP the runner pid | trigger a preload reload |
| `which` | `yath-persist.json` | print the discovered persistent runner |
