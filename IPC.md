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
For a **non-test** wrap (runner / stage / aux) the collector parent `POSIX::_exit`s
with the wrapped child's exit (`Util::collector_exit_code`), so reaping that process
carries a meaningful exit. A **test-job** collector parent instead exits
**health-only** (`Test2::Collector::Runner->spawn_exit_code`: 0 if the collector
functioned, non-zero only if the collector itself malfunctioned): the test's verdict
rides its transitions, which the runner decides on the collector's **connection EOF**
to `runner.socket` (§5.4), never the exit code. Reaping a test-job collector is
therefore pure **zombie cleanup**.

- Runner + preload stages run under **non-test** collectors.
- Test jobs run under **test** collectors. The test-job reporter connection is
  **bidirectional** (built `read_control`): besides streaming transitions it reads
  the runner's inbound `terminate` control (the bail/abort message). Its identity
  preamble carries `job_id` + `job_try` + `run_id` so the runner maps the connection
  (and its EOF) back to the job.

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
                                 │  with a preload-root: SCHEDULER-ONLY -- holds NO preloaded state, hosts NO stage;
                                 │  in-process scheduler (in-memory State); Runner::Monitor = canonical state;
                                 │  dispatches each task over the ONE channel the hosting stage opened to it
                                 │
                                 ├─ spawn ─ [collector:preload-root] ─► preload-root
                                 │     (perl -I... -MTest2::Harness2::Preload=launch,runner.socket -e 1;)
                                 │     │  dials runner.socket as 'preload-root'; handshake: get_preload_list / set_stage_data
                                 │     │  drives a stage host (Test2::Harness2::Preload::Host; rootpid = the REAL runner pid) -- an independent class, NOT a Runner
                                 │     │  HOSTS the base/default/NOPRELOAD stage in-process (dials runner.socket as 'preload-<base>')
                                 │     │
                                 │     └─ fork ─ [collector:stage-<name>] ─► preload stage  (binds preload-<name>.socket, reserved for spawn)
                                 │                                           │  dials runner.socket as 'preload-<name>'; reports up + receives dispatch
                                 │                                           └─ fork ─ [collector:job] ─► test job (longjump+goto-file via JobLauncher)
                                 │
                                 └─ no-preload / below-threshold: fork ─ [collector:job] ─► test job   (collector fork+EXECs a clean perl)
```

The preload-root level exists **only when preloads are configured** (and not below
`preload_threshold`); otherwise the runner forks the test-job collector itself and
the collector **fork+execs a clean perl** for the test (the no-preload path -- no
`goto::file` / `Long::Jump` / in-process launch; the test child does NOT inherit the
runner's `%INC`). `goto::file` + `Long::Jump` live **only** in the preload tree
(`Test2::Harness2::Preload` + `Test2::Harness2::Runner::JobLauncher`), where a
preloaded test must run in-process with its stage's modules already loaded. The
base/default/NOPRELOAD stage runs **in-process** in the preload-root; named stages
are forked as its children.

Lifespan: the transient runner shuts down and closes `runner.socket` once the run
is done and its job children are reaped; the command's render loop ends on that
socket EOF. The runner reaps the preload-root at wind-down (`stop_preload_root`).

---

## 3. Process tree — persistent `yath start` / `run`

```
yath start  (writes yath-persist.json {pid,dir}; spawns the runner; then exits)
   │
   └─ [collector:runner] ─► persistent runner  (service; stays up on runner.socket)
                            │  serialized: one active run at a time
                            │  scheduler-only when a preload-root hosts the stages
                            │  Runner::Monitor keyed by run; routes each client only its run
                            ├─ [collector:preload-root] ─► preload-root (dials runner.socket as 'preload-root';
                            │                              │              drives a stage host (Test2::Harness2::Preload::Host), rootpid = real runner)
                            │                              ├─ in-process base/default/NOPRELOAD stage (dials runner.socket)
                            │                              └─ fork ─ [collector:stage-<name>] ─► preload stage
                            │                                        │  dials runner.socket as 'preload-<name>';
                            │                                        │  binds preload-<name>.socket (reserved for spawn)
                            │                                        └─ [collector:job] ─► test job
                            └─ no-preload: ─ [collector:job] ─► test job

clients connecting IN to runner.socket:
   yath run     submit run(run_id) + subscribe(run_id)   → renders its run via Renderer::Driver
   yath watch   subscribe (no run_id = global)           → renders runner/stage output via Renderer::Base
   yath status / ps / abort / resources   request → Runner::StatusReport reply
   yath spawn   submit a spawn over the socket (acknowledged: fails fast if no live stage)
   yath stop    'stop' request (graceful shutdown)
   yath reload  SIGHUP → the runner's own pid (from yath-persist.json). On a
                preload run the (scheduler-only) runner does NOT wind down: its HUP
                handler forwards a 'reload_root' request to the base/default stage's
                LIVE service channel (the `preload-<base>` peer whose announced pid
                equals the preload-root pid). That stage is hosted in the preload-root
                process and is the one connection the runner services for the whole
                run, so the reload is read promptly; it ends its run loop and re-execs
                the whole preload tree from the 'preload-root' Long::Jump frame. The
                reload is NOT sent to the preload-root's dormant handshake channel
                (which is only serviced at post-run idle, so a reload there would sit
                unread, or fire late during shutdown). A queued 'stop' cancels a
                pending reload so a stale reload cannot re-exec the tree mid-shutdown.
                The runner never self-restarts: it holds no preloaded interpreter
                state. A no-preload runner has nothing to reload, so HUP is a no-op (to
                pick up code changes a no-preload persistent runner must be stopped and
                started again).
```

`yath run`/`spawn`/`stop`/`status`/`ps`/`abort`/`resources`/`which`/`watch`
discover the runner via `yath-persist.json` (read through `App::Yath2::Pfile`).
The persistent runner stays listening until a `stop` request.

---

## 4. Who reaps whom

Reaping is local to whichever process forked the (collector-wrapped) child.
`Test2::Harness2::IPC` is the multi-child reaper for the two genuinely
multi-child forkers -- the runner (its own no-preload job collectors) and
`Test2::Harness2::Preload::Host` (its forked stages + jobs). The `yath test`
command, which forks exactly one child (the runner), reaps it inline on
`Util::IPC` without the controller (§4 table). The runner's
`Role::Service::reap_children` is a deliberate **no-op** so it does not race
`Test2::Harness2::IPC`.

| Forks / spawns | Reaps | Notes |
|---|---|---|
| `yath test` command | the runner (its collector) | transient only; `start`/`run` do not reap the persistent runner. The command owns exactly this one child, so it spawns it on `Util::IPC::run_cmd` and reaps/signals it with a direct `waitpid`/`kill` (no `Test2::Harness2::IPC` controller instance) |
| runner | the **preload-root** (its collector); on the no-preload path, the test job (its collector) it forked directly | the preload-root pid is tracked **outside** the runner's `{+PROCS}` (so it never trips `IPC::_bring_out_yer_dead`'s `waitpid(-1)`) and reaped explicitly at wind-down (`stop_preload_root`) |
| preload-root | each preload stage (its collector) it forked | the base/default/NOPRELOAD stage runs in-process in the preload-root and is not forked/reaped |
| preload stage | each test job (its collector) it forked | the stage's reap is **pure zombie cleanup** — it reports NO verdict. The runner decides the job's outcome from the collector's transitions + connection EOF on `runner.socket` (§5.4). The stage still reports the forked job's `job_pid` and any `reload` up the one service channel it opened to the runner |

**`stop_preload_root` must not kill the collector parent (leak fix, chunk 19.4d).**
`spawn_collector` returns the *collector parent* pid; the actual preload-root is the
`-e` child it exec'd. `stop_preload_root` sends a graceful socket `stop` and reaps
over a generous window; if that does not land in time it **leaves the collector
parent alone** rather than `TERM`/`KILL`ing it. Killing the collector parent would
destroy its `ChildMonitor` (which is exactly what kills the preload-root tree when
the runner vanishes) and orphan the `-e` child. Instead the runner exits moments
later; the `ChildMonitor` (watch_parent_pid → runner) then terminates the `-e`
child + its stage/job descendants, and the collector parent finalizes and exits.

**Completion is decided on the collector's connection EOF, not from reaping (§5.4).**
A test job's collector streams its verdict transitions (`harness_final_state`, plus
an early `halt` transition on a bail) to `runner.socket`; when the collector exits,
its connection EOFs. The runner decides the outcome on that EOF (after draining the
connection's pending frames): `final_state` pass ⇒ complete; `!pass` ⇒ retry while
tries remain else fail; `halt` ⇒ bail; no `final_state` ⇒ fail (a terminated job is
recorded *aborted*, otherwise flagged possible-harness-internal — never a false
pass). The decision is **fire-once per `(job_id, job_try)`**: a shared ledger the EOF
path and the `Runner::Watchdog` both set, so an EOF and an abort that race converge to
one completion; a superseded try's late EOF is ignored (stale-try guard). Reaping is
pure zombie cleanup afterward. The `Runner::Watchdog` still aborts a job whose
dispatch to a stage failed and any still-running jobs at run wind-down.

**Bail/abort teardown rides a runner→collector terminate control.** On a `halt`
transition the runner stops dispatching new jobs for the run and (with
`--abort-on-bail`) sends a `terminate` control to every live test collector of the
run over its bidirectional connection; each kills its child and exits → EOF (decided
*aborted*). A job that connects *after* the bail is terminated on connect (the runner
tracks the run's bail/abort intent). `halt` wins over retry.

**Collectors self-terminate if the runner dies.** Every preload-root, stage, and
job collector is started with `watch_parent_pid => <root runner pid>` (the runner
conveys its pid to the preload-root via `get_preload_list`, and the preload-root
passes it down to the stage/job collectors it spawns). `Test2::Collector` kills the
collector's child and finalizes/exits if the runner disappears while the child runs
— so a runner that dies without signaling (crash / `SIGKILL`) leaves no orphaned
collectors, stages, preload-root, or test processes. A collector watches the
**runner only**, never an intermediate stage or the preload-root (a stage reload —
or a preload-root respawn — gets a new pid and must not kill the in-flight test).
The runner-wrap collector is exempt (its child is the runner). Enforced by
`agent_scripts/audit-collector-watch-parent`.

---

## 5. Sockets

All sockets live in the **workdir**, are unix-domain `SOCK_STREAM`, and carry the
same wire form: each message is a JSON object, zstd-compressed into one
self-contained frame, via `Test2::Collector::Util::Socket` (`open_unix_listen` /
`connect_unix` / `write_frame`) + `Test2::Collector::Util::Zstd` /
`...Zstd::FrameBuffer`. The harness keeps no copy of this machinery.

| Socket | Server (accepts) | Clients (connect out) | Carries |
|---|---|---|---|
| `runner.socket` | the runner | `test`/`run`/`spawn`/`stop`/`status`/`ps`/`abort`/`resources`; the **preload-root** (handshake: `get_preload_list` / `set_stage_data` / `resolve_file_stages` / `preload_warnings`); every non-runner collector's reporter; each preload stage (its registered service channel) | control **requests** (+ replies); **transitions** from preload-root, stage & job collectors; the bidirectional runner↔stage channel (see below) |
| `preload-<stage>.socket` (one per preload stage) | that preload stage | nothing yet (**reserved** for `yath spawn`, ARCHITECTURE.md §4.8) | — |

The **preload-root dials** `runner.socket` (it does not listen on a socket of its
own; its own output goes to `preload-root-events.jsonl.zst` and its collector's
`Recorder::Socket` reporter streams to `runner.socket`). The runner is the
**server** on `runner.socket`. It no longer connects out to the
`preload-<stage>.socket`s; a stage dials the runner and the runner dispatches back
over that one channel.

### Wire protocol (`Test2::Harness2::Role::Service::Connection`)

Every connection is a `Connection` object that owns the framing. Five frame kinds,
distinguished by their top-level key:

- **`{ identity => { name => <id>, pid => <pid> } }`** — sent on open (see lifecycle
  below). The announced `pid` is the peer process's real pid; the receiver stores it
  (`$conn->peer_pid`). `status`/`ps` read each connected `preload-<stage>` peer's pid
  this way (the scheduler State stores no pid).
- **`{ request => { request_id => <uuid>, command => <cmd>, ... } }`** → dispatched
  to `request_handler_<cmd>`; the handler's return value is sent back as a
  `response` echoing the `request_id`, or no reply when the handler returns `undef`
  (one-way).
- **`{ response => { request_id => <uuid>, ... } }`** → matched to the outstanding
  request by `request_id`. An unmatched response (fire-and-forget reply) is
  discarded.
- **`{ transition => ... }` / `{ facet_data => { ... } }`** — a collector
  transition/event; folded into `Runner::Monitor` and forwarded to subscribers.

There is **no ordering assumption**: an endpoint may send a request and then
receive unrelated messages before the matching response. Correlation is by
`request_id` (a v7 UUID), never by arrival order.

### Connection lifecycle

- **Identity exchange.** A connection that **dials** announces its identity
  immediately; one that **accepts** replies with its identity only after seeing the
  peer's. **Every** connection must identify first — including collector reporters,
  which send an identity as their first frame via the `Recorder::Socket` `preamble`.
  A reporter's identity carries `no_reply` so the runner sends nothing back (the
  reporter is one-way and never reads — an unread reply would become a TCP-RST on
  close and discard in-flight transitions); it sets `drain_input` defensively. A
  non-identity first frame, or no identity before the timeout (~30s), drops the
  connection.
- **Bad-frame policy.** After identity, **3 consecutive corrupt/invalid frames**
  (no valid frame between) close the connection; any valid frame resets the count.
  A fatal `sysread` error (ECONNRESET/EBADF) drops it at once.

### Connection model — one bidirectional set (ARCHITECTURE.md §5.2)

`Role::Service` keeps **one** connection set. Every connection — whether the
service **accepted** it or **dialed** it via `service_connect_peer` — lives in the
same `service_select` (`IO::Select`) and `service_conns` (each fd → its
`Connection`), and the service reads off all of them. A dialed connection is
**not** write-only: **either end may send requests**. The peer registry
(`service_peers{<identity>}`) backs `service_send($identity, $command, %args)` and
`service_connect_peer`'s reuse (an existing connection to a peer is reused, never
duplicated). `service_subs` is the subset flagged as subscribers (pushed
`forward_frame` deltas).

So **runner ↔ stage is one bidirectional channel**, not two one-way ones. The
stage dials `runner.socket`, identifies as `preload-<stage>`, and that single
connection carries both directions:

```
stage  --[dials runner.socket, identity 'preload-<stage>']--> runner's set
        reports UP   (stage_ready / stage_down / job_pid / reload)
        dispatch DOWN (run_task / stop)  — runner service_send's by peer identity over the SAME fd
```

Commands (`test`/`run`/`status`/...) are full peers too: each connects, identifies,
and issues `request`s, matching `response`s by id. A collector's `Recorder::Socket`
reporter is a **separate** connection that also identifies first (via its
`preamble`). A **non-test** reporter sets `no_reply` and streams transitions only
(one-way). A **test-job** reporter is built `read_control`, so it is bidirectional:
it streams transitions up *and* reads the runner's inbound `terminate` control, and
its preamble carries `job_id` + `job_try` + `run_id` for the connection→job map.
**Subscribers** connect, send a `subscribe` request, get the
snapshot as its `response`, then receive forwarded transition frames pushed over
the same fd
(`forward_frame` over `service_subs`).

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
| `preload-root-events.jsonl.zst` | the preload-root's non-test collector | workdir | the command renderer (`RunnerReader`); `watch` | preload-root + in-process base-stage stdout/stderr/exit as events (also streamed to `runner.socket`) |
| `stage-<name>-events.jsonl.zst` | each forked preload stage's non-test collector | workdir | the command renderer (`RunnerReader`); `watch` | stage stdout/stderr/exit as events |
| `events.jsonl.zst` (per job) | each test job's test collector | the job's run dir | the command renderer (`JobReader`, by the path a transition carries) | the test's full event stream |
| `aux-<name>-<uuid>.jsonl.zst` | a plugin's `shellcall`/`run_collected` aux collector (chunk 17) | workdir | the command renderer (`RunnerReader`, by the path a transition announces); `watch` | plugin-emitted aux output as events |
| `yath-persist.json` | `yath start` | workdir | `run`/`spawn`/`stop`/`which`/`watch`/`reload` via `App::Yath2::Pfile` | persistent-runner discovery: `{pid, dir, ...}` |
| `PID` file | the runner | workdir | discovery / liveness; `start` records the runner pid into `yath-persist.json` | the runner's own pid |
| `settings.json` | `yath start` (persistent) | workdir | `yath run` (merged into its settings on connect) | run configuration carried to clients |

The `*.jsonl.zst` events files are the only files on the IPC/detail path; all
decision and dispatch traffic is on the sockets in §5. (Chunk 17 retired the last
non-events flat file: plugin `shellcall`/`run_collected` aux output is now a
collector events stream like any other, reported over `runner.socket`.)

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
