# Spawn / Interactive / Harness-Client / Render-Loop — design staging doc

**Status: DRAFT / discussion-in-progress. NOT authoritative.**

This document stages decisions for a conversation about four intertwined
subsystems so they can later be merged into `ARCHITECTURE.md` (the §-sections it
amends are marked **MERGE TARGET**) and `TODO_STEPS.md` / `TODO_TASKS.md` (the
chunks it amends/adds). Until merged, `ARCHITECTURE.md` remains the authority;
where this doc and `ARCHITECTURE.md` disagree, the disagreement is called out so
the merge can resolve it deliberately.

Source of the discussion: the working note `thoughts` (repo root, untracked) plus
a current-state code investigation. Every current-state claim below is cited to
`file:line`.

The four subsystems and the thought items (from `thoughts`) they map to:

1. **Socket IO sharing** — the common mechanism under spawn + interactive
   (thought 2).
2. **`yath spawn` redesign** (thoughts 1, 4) — MERGE TARGET §4.8, TODO chunk 13.
3. **Interactive mode redesign** (thoughts 1, 3, 4) — MERGE TARGET §4.10, TODO
   chunk 20.
4. **Harness-client library** (thought 5) — MERGE TARGET: new §4.11.
5. **Render-loop library** (thoughts 6, 7) — MERGE TARGET: new §4.12.

---

## 0. Corrections — where the thoughts misread today's code

These are places the `thoughts` note describes current behavior inaccurately, or
where the user's mental model conflicts with the *already-written*
`ARCHITECTURE.md`. Resolve these first; the designs below assume the corrected
picture.

- **C1 — "test jobs only connect STDIN because output goes to the collector" is
  the right intent but the wrong description of today.** Today, in *non*-interactive
  mode a test's STDIN/STDOUT/STDERR are *all* `swap_io`'d onto job files
  (`JobLauncher.pm:378-380`); the test "connects" nothing — it inherits dup2'd
  file handles. In *interactive* mode only STDIN is special (re-opened from a
  FIFO via the `goto::file` filter, `JobLauncher.pm:30-39`); STDOUT/STDERR are
  *still* `swap_io`'d to files (`JobLauncher.pm:379-380`). So the desired
  end-state ("interactive shares STDIN only, output stays with the collector")
  **matches what 1.0/today already does for output** — output is captured and
  rendered through the normal events-file path. Good; we keep that.

- **C2 — `ARCHITECTURE.md` §4.10 currently contradicts the user's STDIN-only
  intent.** §4.10 says interactive should `dup2` a socket onto the test's
  **STDIN/STDOUT/STDERR** (all three) — `ARCHITECTURE.md:859-865`. The user wants
  **STDIN only** for interactive (output keeps flowing to the collector). These
  conflict. **Decision IA-1 below resolves it in the user's favor; §4.10 must be
  amended.**

- **C3 — `yath spawn` does *not* bypass the runner today; it goes *through*
  `runner.socket`.** Current flow: `spawn.pm` → `submitter->queue_spawn`
  (`spawn.pm:92-97`) → runner `request_handler_queue_spawn` → `PENDING_SPAWNS` →
  `Runner::next_task`/`_dispatch_task` builds a `Runner::Spawn` job →
  `fork_spawn_callback` (= `JobLauncher::launch_spawn`, set in `Preload.pm`).
  Both `ARCHITECTURE.md` §4.8 (`:793-794`) **and** the user's thought 4 want spawn
  to bypass the runner and talk to a **stage** directly — so the *target* is
  agreed, but the *current code* implements neither. The redesign is real work,
  not a description of today.

- **C4 — current spawn IO is `/proc/<pid>/fd` proxying, not socket FD sharing.**
  The worker's STDOUT/STDERR are opened onto the *command's* `/proc/<owner>/fd/1`
  and `/2` (`Runner/Spawn.pm:16-18`); the command writes its STDIN into the
  launcher's pipe via `/proc/<mpid>/fd/<win>` (`spawn.pm:199`); the exit code is
  delivered through a tempfile (`ipcfile`) the launcher writes after `waitpid`
  (`spawn.pm:214`, launcher writes `$?`). No socket, no listen socket, Linux-only
  (`/proc`). This whole mechanism is what we are replacing.

- **C5 — "fd sharing over sockets" needs disambiguation (the user said they're
  unsure how it works).** There are two distinct techniques:
  - **(a) dup2-socket-onto-stdio** — *no descriptor is passed*. You connect a
    unix socket, then make the child's STDIN/STDOUT/STDERR *be* that socket
    (`dup2`/`open '>&'`). The connection itself is the byte pipe; the child reads
    fd 0 / writes fd 1 and the bytes flow over the socket. `swap_io`
    (`Util/IPC.pm:52-83`) already does exactly this kind of redirect and is
    already used before exec (`Util/IPC.pm:90-102`).
  - **(b) SCM_RIGHTS fd-passing** — pass a *real* open descriptor (e.g. the
    command's terminal fd, or a PTY master) across a unix socket as ancillary
    data (`Socket::MsgHdr` / `IO::FDPass`). Working code for this exists only in
    `reference/old3` (`App::Yath2::Spawn::FdPass`) and is **explicitly rejected**
    by `ARCHITECTURE.md` §4.8 (`:800-803`).

  **DECISION (2026-06-21): adopt technique (b), SCM_RIGHTS fd-passing — overriding
  §4.8's rejection.** The user wants the child to see the *real* terminal fd, with
  single keystrokes / raw-mode / debugger IO forwarded reliably, instead of a
  middle process proxying bytes. Technique (a) still proxies (the command reads its
  STDIN, copies bytes into the socket, the child reads the socket) — clunky, the
  exact thing being moved away from. Technique (b) hands the child a dup of the
  command's actual std fd, so the command leaves the IO path entirely (no pump
  loop). §4.8's stated objection was "no platform-dependent CPAN module"; we accept
  a focused dependency to get correctness — see the dependency decision in §1.
  Proven implementation to mine: `reference/old3` `App::Yath2::Spawn::FdPass`
  (`send_fds`/`recv_fds` over `Socket::MsgHdr`, ~90 lines) and its receiver
  `reference/old3` `PreloadService::_spawn_script_install_fds` (recv → `dup2` onto
  0/1/2). SCM_RIGHTS works on every real unix (Linux/\*BSD/macOS/Solaris) — same
  footprint the harness already assumes (`/proc`, `setsid`, process groups).

- **C6 — the events-file location is already delivered over the transition
  channel; the interactive side-channel need not carry it.** The `starting`
  transition carries the absolute `events_file` path
  (`Monitor.pm:484-489`); the command's monitor mirror already knows each job's
  events file. So thought 3's "use the socket / an env var to tell which
  events.jsonl matters" is unnecessary for the command — drop it. (Interactive is
  `-j1`, so job↔connection matching is trivial anyway.)

- **C7 — `App::Yath2::Client` already exists but is much thinner than thought
  5's "harness client library."** It owns only the submit transport
  (`Runner::Client`) and the subscribe transport (`Runner::Subscriber`), cached
  (`Client.pm:11-16,148-174`). It does **not** own finders or job-spec building
  (those are `App::Yath2::RunPlan`, `RunPlan.pm:121-157`), does not expose
  first-class state queries (callers drill `client->subscriber->monitor->…`), and
  does not own the runner lifecycle (that is inline in `test.pm`). So thought 5
  is "extend the existing thin Client," not "create from nothing."

---

## 1. Socket IO sharing (the shared mechanism)

**The only real overlap between spawn and interactive** (thought 1 is correct):
some socket setup + routing IO over a socket. Everything else differs. So we
define the shared primitive once, then each feature uses it differently.

**Mechanism: SCM_RIGHTS fd-passing (technique b)** (see C5). The command opens a
listen socket; the target process connects; the command `sendmsg`s its actual std
fd(s) across as `SCM_RIGHTS` ancillary data; the target `recvmsg`s them (fresh fd
numbers referring to the *same* open file descriptions) and `dup2`s them onto its
own 0 / 1 / 2. From then on the target reads/writes the command's real terminal
directly — no relay. `Test2::Collector::Util::Socket` (`connect_unix`,
`open_unix_listen`) provides the socket; the fd-pass primitive is new (see
dependency decision below); `swap_io` (`Util/IPC.pm`) still does the `dup2` once
the fd is in hand.

**Dependency decision — DECISION SIO-DEP (DECIDED 2026-06-21): `IO::FDPass`, but
OPTIONAL.** It is tiny, purpose-built, and the most portable/robust option; it
passes one fd per `send`/`recv` (3× for spawn, 1× for interactive). It is **not** a
hard requirement — spawn and interactive are little-used enough that the
distribution must not block on it:

- **`dist.ini`:** `IO::FDPass` is a **Recommends/Suggests**, not a `[Prereqs]`
  hard requires — the same treatment AGENTS.md prescribes for the non-default
  `DBD::*` drivers.
- **Runtime:** spawn and interactive `require IO::FDPass` dynamically
  (eval-guarded). Missing ⇒ **die early with an actionable message** (e.g.
  "`yath spawn` requires IO::FDPass; install it to use this feature"), surfaced at
  the **command** (spawn: at start before queueing; interactive: in the option
  post-process where the FIFO is set up today, `Options/Debug.pm`), never as a raw
  load failure deep in the runner. The send side (`App::Yath2`) and the receive
  side (`Test2::Harness2::Util::FdPass`) sit behind this one guard; they are only
  reached when spawn/interactive is active.
- **Net:** `Test2::Harness2` / `App::Yath2` install and run fully without
  `IO::FDPass`; only these two features error when it is absent. The lean
  `test` / `run` / `start` path never loads it.

Rejected alternatives: `Socket::MsgHdr` (what `reference/old3` used — all fds in one
atomic `cmsg`; kept as the fallback if `IO::FDPass` is ever unavailable on a target)
and a pure-perl `syscall()` `sendmsg` (no dep, matches the `SubReaper` precedent —
but ancillary-data struct packing is fiddly and a portability risk; not worth it
here, unlike the simpler `prctl` SubReaper case).

**Connection direction — DECISION SIO-1 (proposed): the command (the fd *sharer*)
listens; the target process dials in and receives the fd.** This matches the
user's model ("the process that shares its STDIN has a listen socket; the process
that needs it connects") and the fd-flow direction (command → child). The command
is long-lived and its listen socket is a stable rendezvous; the target learns the
path (env var for interactive, request payload for spawn) and connects when it is
ready. On the preload `goto::file` path there is **no exec**, so the test process
does its own `connect` + `recv_fds` + `dup2` inside the filter — exactly where the
current FIFO `open` already lives (`JobLauncher.pm:30-39`). Minimal change.

  **This reverses the direction in `ARCHITECTURE.md` §4.8/§4.10** ("the process
  that *launches* the test dup2s an *accepted* socket descriptor"), which has the
  launcher/stage listening and proxying. **Both §4.8 and §4.10 must be amended to:
  command listens, target dials, fds passed via SCM_RIGHTS.**

**The passed fds are raw; control data still needs a framed channel.** The passed
fds *are* the terminal — they carry no framing. Control data (the spawn exit code,
forwarded signals, window-size changes) needs a **framed control channel**. The
same socket used to pass the fds stays open and becomes that channel: phase 1 =
SCM_RIGHTS fd-pass, phase 2 = normal framed messages on the same connection. One
socket per target. (Interactive needs no control channel — see §3.)

---

## 2. `yath spawn` redesign — MERGE TARGET §4.8, TODO chunk 13

**Purpose (unchanged):** launch a single process from a preloaded interpreter,
attach it to the caller's terminal, detached from the harness lifecycle. Requires
a preload (meaningless without one).

**Current state (to be replaced):** through-runner queueing (C3), `/proc` IO +
`ipcfile` exit (C4), double-fork detached uncollected worker
(`JobLauncher::launch_spawn`; `Runner::Spawn` is not collector-wrapped). Note the
current worker *does* connect all three streams (via `/proc`) and *does* deliver
an exit code — both behaviors we must preserve.

**Proposed choreography (DECISION SP-* — for confirmation):**

- **SP-1 (agreed by §4.8 + user): bypass the runner; talk to a stage directly.**
  The command discovers the workdir via the runner-socket symlink (§5.3), inspects
  available `preload-<stage>.socket`s, and connects to the chosen stage.
- **SP-2 (user's model, recommended): the command listens; the spawned side dials
  back and receives the fds.** The command opens a listen socket, sends the stage a
  spawn request carrying `{file, args, env, listen_socket_path}`, then
  **disconnects from the stage** (the request channel is transient and separate
  from IO — thought 4). The stage double-forks a **detached supervisor** which
  connects back to the command's listen socket; the command `send_fds` its 0/1/2;
  the supervisor `recv_fds` them.
- **SP-3: a detached "supervisor" reaps the script and delivers its wait status.**
  The child is double-forked/detached and runs under **no collector** (§4.8
  invariant), so nothing in the harness `waitpid`s it. The supervisor (forked from
  the preloaded stage, so it *holds the preloaded image*) stays alive: it forks a
  script child; the **script child must NOT `exec`** — `exec` throws away the
  preload, defeating the entire point of `yath spawn`. Instead the script child
  `dup2`s the received fds onto 0/1/2, runs post-fork sanitization (SP-6), and
  **unwinds into the preloaded interpreter via the existing `Long::Jump` +
  `goto::file` path** (the same mechanism the current `launch_spawn` uses —
  `JobLauncher.pm:154-159,243-261` `longjump $label => ('run_test',…)`; old3's
  fd-pass spawn likewise ran the script in-process, not via `exec`). The supervisor
  `waitpid`s the script child and sends its **raw wait status** (so a
  signal-death is reported and re-raised on the command exactly like today —
  `parse_exit` + `kill`, `spawn.pm:214-225`) as a control frame on the same
  connection, then exits. "No collector" still holds; the supervisor is a tiny
  non-collected reaper — the socket+fd-pass analogue of today's `ipcfile`-writing
  launcher.
- **SP-6: the script child must be sanitized post-fork (fork-without-exec).**
  Because it inherits the stage's fds + Test2 state (no `exec` to wipe them), it
  must, before running the script: close inherited service/runner/collector sockets
  and the command listener (so it cannot break the EOF lifecycle model, §5.4),
  close the received fd duplicates after `dup2`, reset Test2
  (`test2_stop_preload` / `test2_post_preload_reset`), and fire the stage
  `do_post_fork` / `do_pre_launch` hooks — mirroring `JobLauncher` `cleanup_process`
  (`JobLauncher.pm:287-308`).
- **SP-7: the supervisor kills the script on command death (DECIDED Q2).** The
  supervisor watches its control connection; on **EOF** (the `yath spawn`
  command/terminal died) it kills the script's process group (`kill(-pgid)`; the
  detached child `setsid`s so it leads its own group) and exits. A spawned process
  is detached from the *harness* (survives runner/stage teardown — §4.8) but is
  **bound to its command** — it does not outlive the command. This prevents runaway
  orphans and matches today's "command waits for the child."
- **SP-4: spawn passes the command's actual STDIN+STDOUT+STDERR fds** (unlike
  interactive, which passes only STDIN) — thought 4. **The merge/split/PTY tension
  from the earlier draft dissolves with fd-passing:** the command passes *whatever
  its real 0/1/2 are*. If all three are the terminal, the child writes both streams
  to the tty (natural). If the user redirected (`yath spawn x 1>out 2>err`), the
  command's 0/1/2 are three distinct descriptors and they are preserved on the
  child **for free** — no merging, no demux, no PTY. A PTY would only be needed to
  give the child a *new* controlling terminal distinct from the command's; that is
  explicitly **not** wanted (the user wants the child on the *real* terminal).
- **SP-5: signals.** Today the command `kill`s the worker pid (`spawn.pm:138-149`).
  The detached supervisor `setsid`s (loses the controlling tty), so ctrl-C will not
  reach the child natively even though it holds the tty fd. The command traps its
  signals and forwards them over the control phase of the connection; the
  supervisor relays to the script's process group. Window-size (`SIGWINCH` /
  `TIOCSWINSZ`) can ride the same channel if needed. (Passing the tty fd already
  gives the child correct `isatty`/termios/raw-mode reads — the keystroke-fidelity
  goal — independent of controlling-terminal ownership.)

**Net:** spawn becomes `{request to stage}` (transient) + `{one connection,
command-listens}` that does SCM_RIGHTS fd-pass then flips to a framed control
channel (exit code, signals, winch). The command is **out of the byte path** — no
IO pump. §4.8's "dup2 the accepted request socket onto the child / stage proxies
IO" is dropped in favor of fd-passing + the user's clean request/IO separation.

---

## 3. Interactive mode redesign — MERGE TARGET §4.10, TODO chunk 20

**Purpose (unchanged):** connect the client terminal's **STDIN** to one test at a
time so prompts / `perl -d` / `$DB::single` work.

**Current state:** FIFO (`POSIX::mkfifo`) + `$ENV{YATH_INTERACTIVE}=<fifo path>`
(`Options/Debug.pm:310-318`); client pumps STDIN → FIFO (`Debug.pm:355-368`); test
re-opens STDIN from the FIFO in the `goto::file` filter (`JobLauncher.pm:30-39`);
`-j1` via `category='isolation'` set in `RunPlan.populate` (`RunPlan.pm:149`),
enforced in `State::_cat_order` (`State.pm:1107-1108`). Output is **not** touched —
it flows to the collector and renders normally.

**Decisions (IA-*):**

- **IA-1 (resolves C2): interactive shares STDIN ONLY.** STDOUT/STDERR keep going
  to the collector and render through the normal events-file path (§4.5). This
  matches 1.0/today and the user's intent. **`ARCHITECTURE.md` §4.10 must change
  from "STDIN/STDOUT/STDERR" to "STDIN only."** (Consequence: an interactive
  debugger's prompts appear via the rendered event stream, as in 1.0 — accepted.)
- **IA-2: socket + fd-pass replaces the FIFO; same direction as spawn (SIO-1).**
  The command opens a listen socket; `YATH_INTERACTIVE` carries the **socket path**
  instead of a fifo path; the test connects, `recv_fds` the command's **STDIN fd**,
  and `dup2`s it onto fd 0 — in the `goto::file` filter (preload path) or via an
  env-var-driven connect before the test runs (no-preload exec path — detail to
  settle). The test then reads the user's **real terminal** directly (single
  keystrokes, raw mode, debugger-correct), not a proxied byte stream. Removes the
  FIFO and its broken open-retry loop. Only **one** fd is passed; no control
  channel is needed (the test is a normal collected job — its verdict comes from
  its collector, and signals are handled by the existing job-signal machinery).
- **IA-3: `-j1` / one-at-a-time is already done** via the isolation category — no
  change (`RunPlan.pm:149`, `State.pm:1107-1108`).
- **IA-4 (resolves C6): the interactive socket does NOT carry the events-file
  path.** The command already learns it from transitions. Drop thought 3's
  "potentially also tell it which events.jsonl."
- **IA-5: the listen socket exists only in interactive mode** (thought 3) — agreed;
  no socket overhead on the normal path.

**Overlap with spawn:** only SIO-1 (command-listens choreography) + the socket
util + `dup2`-onto-stdio. Interactive shares **one** stream (STDIN), needs **no**
control connection (no detached exit code — the test is a normal collected job;
its verdict comes from its collector as usual), and is **collected** (output
recorded). Spawn shares **three** streams, needs a control connection, and is
**uncollected/detached**. Confirms thought 1: little overlap.

---

## 4. Harness-client library — MERGE TARGET: new §4.11

**Goal (thought 5):** one library, the bridge between `App::Yath2` and the
`Test2::Harness2` runner socket, that `test` / `start` / `run` (and `spawn`)
construct and use, so the commands get thin. It owns submission, the finders,
test-job-spec building, the local runner-state mirror (monitor), and query
methods (jobs-by-state, events-file-by-job). It does **not** own renderers.

**Current state (C7) and the gap:**
- `App::Yath2::Client` owns the submit + subscribe transports only
  (`Client.pm:11-16`).
- Finders + job specs live in `App::Yath2::RunPlan` (`RunPlan.pm:121-157`).
- The monitor is created/owned by `Runner::Subscriber` (`Subscriber.pm:105-107`);
  no first-class query API — callers drill `client->subscriber->monitor->…`.
- The **runner lifecycle is inline in `test.pm`**: spawn via `run_cmd`
  (`test.pm:949-1003`), reap/`waitpid` (`test.pm:167-206`), signal-forward
  (`test.pm:209-228`), `owns_runner` gating. `run.pm` overrides ~12 methods to
  re-point these at a pre-existing runner (`run.pm:67,72,87-98,100-108,227-260`);
  `start.pm` is independent and just spawns the daemon + writes the pfile + exits
  (`start.pm:111-189`); `spawn.pm` inherits `run` but overrides `run()` entirely
  (`spawn.pm:160-226`). This is the "repeat work / complex polymorphism" the user
  wants gone.

**Decisions (CL-*) — DECIDED 2026-06-21 (Option A + spawn-B):**

- **CL-1: grow `App::Yath2::Client` into the full harness-client (Option A — owns
  the runner lifecycle too).** Absorb: (a) `RunPlan` ownership (finders +
  job-spec/task building); (b) the runner-lifecycle as a **mode enum** on the
  client — *transient* (spawn the collector-wrapped runner via `run_cmd`, own +
  reap + signal it), *attach* (discover the persistent runner via pfile/symlink,
  `kill(0)` liveness, never reap it), *start* (spawn the daemon, write pfile,
  return); (c) first-class state queries over the mirrored monitor
  (`jobs_in_state`, `events_file_for($job)`, run/job rollup) so callers stop
  drilling `client->subscriber->monitor->…`.
- **CL-2: it does NOT own renderers** (thought 5) — those are the render-loop
  library's concern (§5 below). The client exposes *state*; the render loop
  *consumes* it.
- **CL-3: the three commands collapse onto the client mode.** `test` = client in
  *transient* mode + render loop; `run` = client in *attach* mode + render loop;
  `start` = client in *start* mode, no render loop. The transient-vs-persistent
  difference becomes a client mode, **not** a command-inheritance tree — the
  `run extends test` ~12-method override pile (`run.pm:67,72,87-98,100-108,
  227-260`) and the inline runner spawn/reap/signal in `test.pm`
  (`:167-228,949-1003`) **go away**.
- **CL-4: `spawn` uses the client only to discover stages (sub-question B).** It
  asks the client for the available preload stages (so it can connect directly to
  a `preload-<stage>.socket`, §2), then runs its own fd-pass + control-channel IO
  bridge in the command. It does **not** submit a run and does **not** use the
  render loop. The fd-pass/control loop stays in the spawn command — it is
  genuinely unlike a run; the client just helps it find the stage.

**Open placement question:** `Test2::Harness2::Runner::{Client,Subscriber,Monitor}`
already live on the harness side; `App::Yath2::Client` is the UI-side façade. The
grown client stays in `App::Yath2` (it's a UI/input concern per `AGENTS.md`), and
keeps delegating wire work to the `Test2::Harness2::Runner::*` transports.

---

## 5. Render-loop library — MERGE TARGET: new §4.12

**Goal (thought 6):** stop duplicating the render loop across commands. A generic
library, **separate from the harness-client**, that watches a monitor, gathers
events files, and feeds renderers. Commands either drive it per-iteration
(`->iterate()`) when they own their own loop, or hand it the loop
(`->start()` / `->start(sub {...})`, the sub running each iteration). Design it so
slow renderers can later run in their own process, and so it is reusable for
rendering from a log (thought 7).

**Current state and the gap:**
- The loop lives in commands and exists in **three variants**:
  - `test.pm::render_via_subscription` (`test.pm:413-456`) — subscription mirror +
    `Driver` + `subscription_complete`; reused by `run` via inheritance + the
    `subscription_complete` override (`run.pm:87-98`).
  - `watch.pm` (`watch.pm:60-77`) — `Renderer::Base` only (no `Driver`), only
    `step_runner_output`, different completion (count==0 / socket EOF / pfile gone).
  - `replay.pm` (`replay.pm:64-93`) — reads a JSONL log directly, no monitor, no
    driver, no subscription; dispatches straight to sink renderers.
- The mechanics are already factored into `Renderer::Base` (`feed_events_file`,
  `step_runner_output`, `dispatch`, `compute_final`, `render_run_start`) and the
  per-job ordering into `Renderer::Driver` — these are reusable; the **loop** is
  not.
- Sink renderers have a real lifecycle: `->step` (per iteration), `->finish`
  (end), `->signal` (`Renderer.pm` base; `Formatter.pm:69-73`; `test.pm:227-228,
  543`). The loop currently calls **two** step levels in order: `$_->step for
  @renderers` then `$driver->step($monitor)` (`test.pm:428-431`). `DB`/`Server`
  already spawn a child importer process (`DB.pm:90-143`) reaped in `finish` — so
  "renderer in its own process" partly exists today.

**Decisions (RL-*) — DECIDED 2026-06-21 (Option A, DB-aware seam, live-path-first):**

- **RL-1: new generic render-loop class** (place in `App::Yath2` — display is a
  UI concern — wrapping the `Test2::Harness2::Renderer::Base` mechanics).
  **The `RenderLoop` owns dispatch + the sink lifecycle + the run rollup/final-sweep**
  (DECIDED Q4); it holds the sink renderers and an injected **Producer**, and owns
  the `step`/`finish`/`signal` lifecycle and `compute_final`.
- **RL-2: the `Producer` is a PURE source** (DECIDED Q4) — `poll()` → *ordered
  events to render*, `done()` → bool (plus optional `finalize`). It does **not**
  dispatch or roll up; it only yields the right events in the right order. The
  current `Driver`'s per-job *ordering* becomes the `LiveProducer`; the `Driver`'s
  *dispatch* + `compute_final` + bounded `wait_terminal` (`Driver.pm:158-205`,
  `Base.pm:276-319`) move into the `RenderLoop` — **preserving the bounded-terminal
  wait + final sweep that fixed a prior false-FAIL.** Producers:
  - **`LiveProducer`** — subscription `Monitor` mirror + the per-job ordering, yields
    events read from on-disk `.jsonl.zst` by path. `done()` = socket-closed (`test`)
    / `run_done` (`run`). The `watch` variant yields runner/service output only (no
    per-job ordering).
  - **`JSONLFileProducer`** (DECIDED Q1) — wraps the existing flat-`.jsonl` reader
    (`poll`/`done`); ports `replay` onto `RenderLoop` **now** so it keeps working.
    **Throwaway** once the DB `ArchiveProducer` lands.
  - **`ArchiveProducer` (deferred seam — see RL-5)** — renders a *log database*.
  Composition, not inheritance — sidesteps the "polymorphic mess" risk.
- **RL-3: the two entry points** from thought 6:
  - `->iterate()` — one pass (poll producer → sink `->step` → dispatch →
    check `done`); for commands that own their loop and need other per-tick work.
  - `->start()` / `->start(sub {...})` — the library owns the loop; the optional
    sub runs each iteration. For the simple commands. Orthogonal to the producer.
- **RL-4: design for future child-process renderers** (thought 7) — a slow/blocking
  sink (DB writes) can later be moved to `->start` in a child. Don't implement
  yet, but keep the sink interface fed only self-contained `Event` objects (no
  shared in-memory command state), so a sink can be relocated to a forked child
  fed events over a pipe — the `DB`/`Server` importer-subprocess is the precedent.
- **RL-5: archive (render-from-log) is a DEFERRED SEAM, not built here.** The
  current DB layer is **legacy lifted for backcompat**; the real **DB-layer rewrite
  is not yet spec'd** (separate future work, §4.6). So this doc only *reserves the
  `ArchiveProducer` seam* and records the intended shape — it does **not** anchor
  to the current `Event`/`Job`/`Run` schema. Intended shape, to settle with the DB
  rewrite:
  - The log DB (sqlite file usually; importable into mysql/pg, possibly many runs
    per DB) holds run/job/collector **state** plus each collector's `.jsonl.zst`
    as an **artifact blob** (§4.6's self-contained log).
  - `ArchiveProducer` builds a `Monitor` snapshot from the state rows
    (`apply_snapshot` already exists) so the **same `Driver`** renders archived
    runs, and reads event bytes from the **artifact blob**. Faithful re-render uses
    the blob (raw recorded truth, exact decode path), *not* a row-level event
    projection (which stays the UI's queryable view).
  - This needs the collector-events reader (`JobReader`/`RunnerReader`, today
    path-only — `JobReader.pm:29` `open_zstd_reader($path)`) generalized to a
    **byte source** (path *or* DB blob). Also deferred to the DB rewrite.
  - **`replay` keeps working via `JSONLFileProducer` (DECIDED Q1)** — its bespoke
    loop (`replay.pm:62-91`) is replaced by `RenderLoop` + `JSONLFileProducer` in the
    first pass. The DB-backed `ArchiveProducer` supersedes that wrapper once the DB
    layer is rewritten (the wrapper is then deleted).

---

## 6. Proposed merge edits (for the later merge agent)

**`ARCHITECTURE.md`:**
- **§2.5 / new foundational note** — record that IO sharing for spawn + interactive
  uses **SCM_RIGHTS fd-passing** over a unix socket (`IO::FDPass`, an **optional**
  dep — SIO-DEP), *replacing* §4.8's explicit "no SCM_RIGHTS / dup2-socket-onto-stdio"
  stance. This is a deviation from a written decision and per `AGENTS.md` needs an
  addendum justifying it (the dup2-onto-stdio approach still proxied bytes; fd-pass
  gives the child the real terminal fd).
- **§4.8 (spawn)** — rewrite IO/choreography: command-listens / child-dials
  (SIO-1, SP-2); SCM_RIGHTS pass of the command's real 0/1/2 (SP-4); one
  connection that fd-passes then flips to a framed control channel for exit +
  signals (SP-3, SP-5); detached supervisor reaps + reports exit. Drop "dup2 the
  accepted socket onto the child / stage proxies IO" and the merge/split/PTY
  question (dissolved by fd-passing). Keep: bypass-runner, requires-preload,
  no-collector/detached.
- **§4.10 (interactive)** — change "STDIN/STDOUT/STDERR" → **STDIN only** (IA-1);
  FIFO → socket + SCM_RIGHTS pass of the single STDIN fd, command-listens/test-dials
  (IA-2); note output stays collector-recorded; drop the events-file-over-socket
  idea (IA-4); confirm `-j1` via isolation is already in place (IA-3).
- **§4.5 (renderers)** — generalize "locate a collector's events file from
  transition state" to "from the source: a **path** (live) or an **artifact blob**
  (archived DB log)" (RL-5). Forward-looking; the archive half lands with the DB
  rewrite.
- **§4.6 (logs/DB)** — note the RL `ArchiveProducer` is the **read/render**
  consumer of the artifacts-table log (the DB *sink* renderer is the write side);
  the concrete shape is deferred to the unspec'd DB-layer rewrite, not this doc.
- **New §4.11 (harness-client library)** — CL-1..CL-4 (Option A).
- **New §4.12 (render-loop library)** — RL-1..RL-5 (Option A; live producer now,
  archive producer a deferred DB-backed seam).
- **§5.2/§5.3** — note the client-facing listen sockets (interactive + spawn) and
  their direction (command listens), distinct from service sockets.

**`TODO_STEPS.md` / `TODO_TASKS.md`:**
- **Chunk 13 (spawn)** — re-scope to the §2 design; note dependency on the
  harness-client (CL) for stage discovery and on SIO-1.
- **Chunk 20 (interactive)** — re-scope to STDIN-only socket (IA-*); depends on
  SIO-1; can land independently of spawn's control-channel complexity.
- **New chunk — harness-client library (CL, Option A).** Prereq for thinning the
  commands; pairs with the §4.2 thin-client goal already in `ARCHITECTURE.md`.
- **New chunk — render-loop library (RL, Option A).** `RenderLoop` owns
  dispatch+rollup; `LiveProducer` = extraction of the `Base`/`Driver` mechanics
  behind `iterate()`/`start()`; `JSONLFileProducer` ports `replay` in the same pass
  (keeps it working). **`ArchiveProducer` + the byte-source reader generalization are
  deferred to the DB-layer rewrite chunk** (the `JSONLFileProducer` is deleted then).
- **Note: the DB-layer rewrite is its own future chunk** (not yet spec'd); the
  current DB layer is legacy lifted for backcompat. RL's archive seam plugs into it
  when it lands.

---

## 7. Open decisions needing the user

- **SIO-DEP:** DECIDED — `IO::FDPass`, optional (Recommends/Suggests), spawn +
  interactive error early if absent; lean path never loads it. (old3's
  `Socket::MsgHdr` wrapper is the fallback.)
- **SP-2 / §4.8:** confirm command-listens / child-dials, one connection that
  fd-passes then flips to a framed control channel, replaces §4.8's
  dup2-accepted-socket + the merge/split/PTY question (now dissolved).
- **IA-1:** confirm interactive is STDIN-only (amend §4.10), keeping output on the
  collector — i.e. the debugger UX is "type into the real terminal, see output via
  the rendered stream," as in 1.0.
- **CL scope:** DECIDED — Option A: the grown `App::Yath2::Client` owns the runner
  lifecycle (transient/attach/start modes) plus finders/specs + state queries;
  `spawn` uses it only for stage discovery (sub-question B).
- **RL:** DECIDED — Option A: one `RenderLoop` (owns dispatch+rollup) + injected
  pure-source `Producer` (`poll`/`done`). `LiveProducer` (test/run/watch) +
  `JSONLFileProducer` (replay, keeps it working) built now; `ArchiveProducer` is a
  DB-backed seam deferred to the (unspec'd) DB-layer rewrite. Sinks fed
  self-contained events for future child-process relocation.

---

## 8. External review feedback & dispositions (2026-06-21)

Two reviewers (`spawn_review_gemini.md`, `spawn_review_gpt.md`) reviewed an earlier
draft. **They had only the `thoughts` note + the codebase — not the locked decisions
in §0-§7** — so some feedback re-litigates settled points; those are marked
*context*. Verified current-code claims are noted.

**Incorporated — clear technical corrections (no user decision needed):**

- **R1 (Gemini G1 + GPT 1): `exec` would destroy the preload.** FIXED inline (SP-3):
  the script child unwinds into the preloaded interpreter via `Long::Jump`/`goto::file`,
  never `exec`. **Verified** — current `launch_spawn` already does this
  (`JobLauncher.pm:154-159`); the draft's "fork+exec" was the bug.
- **R2 (Gemini G3): `Preload::Host` needs a `request_handler_spawn`.** ADD to spec.
  **Verified** — `Preload::Host` composes only `Role::Service` and has
  `run_task`/`reload`/`reload_root` handlers, no spawn (`Preload/Host.pm:80,274-299`);
  ticket TODO-22 split it from the runner (`AI_DOCS/2026-06-20-ticket22-…`). The handler
  double-forks the supervisor async and acks `{ok=>1}` without blocking the host.
- **R3 (GPT 3): preserve raw wait status, not just an exit code.** FIXED inline
  (SP-3): control frame carries raw status / `{exit,signal,core}`; signal-deaths
  re-raise on the command as today (`spawn.pm:214-225`).
- **R4 (GPT 2): the post-fd control channel needs an explicit wire protocol.** ADD:
  spawn's control connection does the SCM_RIGHTS message (one `\0` payload byte +
  the fds) first; the receiver `recvmsg`s that, then the socket carries control
  frames. Recommend a **dedicated tiny protocol, NOT `Role::Service::Connection`**
  (which is identity-frame-first and would conflict with the raw fd-pass byte —
  `Role/Service/Connection.pm:70-82`). Name the frames: post-fd hello (supervisor
  pid), wait-status frame, signal-forward frame, EOF semantics. (See clarification
  Q3.)
- **R5 (Gemini G4 + GPT 8/12): unix socket path limits + perms.** ADD: command-side
  listen sockets live in a short private tmp dir via `File::Temp` (≤108/104-char
  cap), random names, `0600`/dir `0700`, `unlink` after accept. Not under the deep
  workdir.
- **R6 (Gemini G5 + GPT 8): fork-without-exec fd/state hygiene.** FIXED inline as
  SP-6 (close inherited sockets, close received dup fds post-`dup2`, Test2 reset,
  stage hooks).
- **R7 (Gemini G7): the client must trap+forward signals in transient mode.** ADD to
  CL-1: when the grown client owns the transient runner, it traps `INT`/`TERM`/`HUP`
  and forwards to the runner process group (today inline in `test.pm:209-228`).
- **R8 (GPT 4): interactive needs a per-test accept loop.** ADD to IA-2: with `-j1`
  there is no contention, but there are N sequential tests — the command keeps its
  listener open and passes the STDIN fd **once per test**, with connect timeout +
  cleanup, and stops accepting when the run ends.
- **R9 (GPT 6/11 + Gemini G9): soften the tty claims; state limitations.** AMEND
  §2/§3 wording: passing the tty fd gives `isatty`/termios/raw-mode + direct
  keystrokes, **but** a `setsid`'d child has no controlling terminal, so `/dev/tty`,
  foreground-pgrp checks, and terminal-generated `SIGINT`/`SIGTSTP`/`SIGWINCH` need
  explicit forwarding or are stated limitations. Command can't restore a corrupted
  termios (it is not proxying) — document "run `reset`." Add tests: `perl -d`, raw
  mode, `/dev/tty`, Ctrl-C, Ctrl-Z, WINCH.
- **R10 (GPT 7): spawn request payload + ack.** ADD: payload also carries `cwd` and
  an absolute/normalized script path (old3 sent `script_abs`+`cwd`) plus a
  correlation id; recommend the stage acks **after forking the supervisor** (the
  command then waits for the supervisor to dial back).
- **R11 (GPT 9): target-side `IO::FDPass` failure path.** ADD: a stage/test running
  under a different `@INC`/older install may lack `IO::FDPass` even when the command
  has it — the target-side `require` failure becomes a **structured spawn rejection /
  clean collected interactive failure**, not a raw post-accept crash. (Complements
  the command-side early check in SIO-DEP.)

**Incorporated — design refinement (recommend, flag for confirmation):**

- **R12 (GPT 10): the RL `Producer` boundary is inconsistent** (RL-1 "loop holds the
  driver" vs RL-2 "driver inside LiveProducer"). RESOLVE: the **`RenderLoop` owns
  dispatch + sink lifecycle + the run rollup/final-sweep**; the **`Producer` is a
  pure source** (`poll()` → ordered events, `done()`). The current `Driver`'s
  per-job *ordering* becomes the `LiveProducer`; its *dispatch + `compute_final` +
  bounded-terminal-wait* (`Driver.pm:158-205`, `Base.pm:276-319`) move into the
  loop. Must preserve the bounded `wait_terminal` + final sweep (they fixed a prior
  false-FAIL). (See clarification Q4.)

**Conflicts with a locked decision — reviewer lacked context:**

- **R13 (Gemini G6): keep `replay` alive via a `JSONLFileProducer`.** *Context:* the
  reviewer did not know jsonl-as-durable-log is being **retired** and that the user
  **accepted interim replay breakage** (RL-5). The suggestion is cheap, though — see
  clarification Q1.
- **R14 (Gemini G2): `IO::FDPass` vs `Socket::MsgHdr` 1-msg-vs-3-msg mismatch.**
  *Context:* mostly moot under SIO-DEP — `IO::FDPass` is **optional, not a runtime
  fallback**; if absent the feature errors, so both sides always use `IO::FDPass`
  (3× one-fd send/recv, receiver expects 3). The underlying rule (both ends agree on
  one backend + framing) is still recorded in the `FdPass` util contract.

**Resolved by the user (2026-06-21):**

- **Q1 (from R13): DECIDED — add the cheap `JSONLFileProducer`.** `replay` ports to
  `RenderLoop` now via a thin wrapper over the existing JSONL reader (`poll`/`done`),
  so it keeps working through the transition; it is throwaway once the DB-backed
  `ArchiveProducer` lands. (Updates RL-5: replay does **not** break in the interim.)
- **Q2 (from Gemini G8): DECIDED — kill on command EOF.** The supervisor watches its
  control socket; on EOF (the command/terminal died) it kills the script's process
  group and exits — no runaway orphans. So a spawned process is detached from the
  *harness* (survives runner/stage teardown) but **bound to its command**: it does
  not outlive the command. (Adds SP-7.)
- **Q3 (from R4): DECIDED — dedicated mini-protocol** for spawn's control channel,
  not `Role::Service::Connection`.
- **Q4 (from R12): DECIDED — `RenderLoop` owns dispatch + rollup; `Producer` is a
  pure source** (`poll` → ordered events, `done`). The `Driver`'s ordering becomes
  `LiveProducer`; its dispatch/`compute_final`/bounded-terminal-wait move into the
  loop (preserving the false-FAIL fix).
