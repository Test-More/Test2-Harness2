# Transition-driven test completion + runner-as-subreaper (design, 2026-06-21)

**Status:** design agreed with the owner (Chad Granum); **no code written yet.**
This doc is the context for a review pass — read it, then critique the design and
the ticket breakdown before implementation starts.

Spec lives in `ARCHITECTURE.md` §4.1 / §4.7 / §5.4 (rewritten this session).
Steps: `TODO_STEPS.md` chunks **24–28**. Tickets: `TODO_TASKS.md` **TODO-27–TODO-31**.

## What triggered this

The session was working the `TODO_TASKS` cleanup backlog. The last substantive
item was **TODO-8 Part 4** — "migrate no-preload job completion onto the collector
socket report + delete `Runner::set_proc_exit`'s job branch (§5.4)." It had been
deferred as "a rewrite, not a cleanup." Discussing it with the owner turned it
into a larger, coherent redesign of how the harness learns a test's outcome and
who owns the process tree. The old TODO-8-Part-4 framing is superseded by the five
tickets TODO-27–TODO-31.

## The problem with the current code

The runner decides a test's outcome from the **reaped collector's exit code**, and
the collector is deliberately rigged to carry the test verdict in that exit code:

- `Runner/JobLauncher.pm` (~L197): the test-job collector parent does
  `POSIX::_exit($job->_collector_exit_code($info))` — comment literally says "exit
  with the TEST child's verdict (not the collector's own health)."
- `Runner/Job.pm::_collector_exit_code`: layers the audited `final_state` onto the
  exit code (`return 1 if !$fs->{pass}`) and writes the bail reason to a `bail`
  file.
- `Util.pm::collector_exit_code`: even the base helper forwards the child's OS exit
  (`err`/`sig`), not collector health.
- `Runner.pm::set_proc_exit` + `Preload/Host.pm::set_proc_exit`: read `$exit` (the
  reaped wait status) and choose retry / stop / bail. `Job::bailed_out` reads the
  `bail` file.

Two problems the owner highlighted: (1) a **bail-out** cannot be expressed by an
exit code (it is a control event that must stop the whole run and terminate active
tests); (2) on the **preload path** the runner never sees the collector exit at all
— the stage reaps and decides, then reports `stop_task`/`retry_task` up the socket.

Meanwhile the audited result is **already on the wire**: every test collector
(preload and no-preload) streams its transitions — including `harness_final_state`
(carrying `pass` and `halt`) — to `runner.socket`, where `Runner::Monitor` stores
them. The runner already has the verdict over transitions for both paths; it just
decides on the reaped exit code instead.

## The agreed design (the model)

**Verdict source:** a test's outcome comes **only** from its collector's
transitions (`harness_final_state.pass`, plus a new early **`halt`/bail
transition**). The collector exit code is **never** the verdict.

**Gone signal:** the **EOF on the collector's transition connection** to
`runner.socket`. It fires on clean exit *and* hard crash (SIGKILL/segfault/OOM), on
every OS, with no pid-reuse race. This **replaces** the earlier pid-poll idea.

**pid handshake:** every connection to `runner.socket` (commands, stages,
collectors) reports its **pid** in the handshake — for status/diagnostics and to
map a connection to its job, **not** for liveness. A test collector additionally
carries **`job_id` (uuid) + `job_try`** (sufficient to map the connection/EOF to
the job).

**Decision (runner, identical both paths), on connection EOF after draining frames:**
- `final_state` seen → `pass` ⇒ complete; `!pass` ⇒ retry if tries left (re-queue
  same `job_id`, incremented `job_try`; scheduler picks it up) else fail; `halt` ⇒
  bail (halt run + terminate active jobs under `--abort-on-bail`).
- `final_state` **absent** at EOF → **fail**, flagged *possible harness/collector
  internal error, may not be the test* — **even on collector exit 0** (a healthy
  collector always emits a final state).
- **Invariant:** collector problem OR missing final_state ⇒ **fail**. Never a false
  pass.
- Retry *policy* stays runner-side: `--retry` + `# HARNESS-retry N` /
  `# HARNESS-no-retry` (both already exist; `retry_task` already re-queues with
  `is_try++`).

**Collector exit semantics:** the collector parent exits **health-only** — `0` if
the collector functioned (regardless of the test's pass/fail/signal, which is in
the transitions), non-zero only if the *collector* malfunctioned. A non-zero health
code (seen only when the runner reaps) is extra diagnostic, never a decision input.

**Process tree — runner is a child subreaper; preload collectors detach:**
- New pure-Perl `Test2::Harness2::Util::SubReaper` (no XS, no dep): Linux
  `prctl(PR_SET_CHILD_SUBREAPER,1)` + FreeBSD/DragonFly
  `procctl(P_PID,$$,PROC_REAP_ACQUIRE)` via `syscall()` with a per-(OS,arch) number
  table; unknown/failed ⇒ eval-guarded graceful unsupported. **Reparenting logic
  lives in the util, not inlined in `Runner.pm`** (owner directive).
- Preload-spawned collectors **double-fork + detach**: re-parent to the runner on a
  supported OS, to init otherwise. The preload tree reaps no collectors.
- No-preload collectors are the runner's direct children.
- The subreaper is about **process-tree ownership** (zombie reaping, kill-tree on
  shutdown, escalation) — **not** the decision, which rides EOF regardless of who
  reaps.

**Structural consequence:** no-preload and preload both reduce to "fork a collector
→ decide from transitions/EOF → runner owns reaping," so `run_scheduler_only`
becomes the runner's **only** run loop and the in-runner `run_tests`/`run_stage`/
`run_job` machinery + `_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS` are deleted.
This absorbs the **TODO-22 residual**, **TODO-4 Part 4**, and **TODO-8 Part 4**.

## Decisions made + alternatives rejected

- **Full transition-driven completion**, not a bail-only slice. (Owner chose the
  full model once it was clear the verdict is already on the wire.)
- **Socket EOF**, not pid-polling — no pid-reuse race, works on every OS, no
  reaping required. pid is still always reported, but only for identity/status.
- **The "harness internal error indicator"** (a reserved exit code vs a transition
  facet) was a real question because the exit code is only visible when the runner
  reaps (supported OS), and a hard crash can't self-report. **EOF mooted it:**
  no-final_state-at-EOF ⇒ fail is the universal rule; the exit code / a self-report
  are optional diagnostic enrichment only.
- **Pure-Perl `syscall()`, not XS.** The local `Test2-Harness2-ChildSubReaper` is
  XS, but XS would make Test2-Harness2 an XS distribution (compiler at install). The
  subreaper only covers Linux + FreeBSD/DragonFly anyway, both reachable from
  `syscall()`; everything else falls back to init. Keeping the dist pure-Perl won.
  Accepted cost: a small hardcoded `SYS_prctl`-by-arch table; safe fallback on an
  untabled (OS,arch).
- **Collector exit = health-only.** Even exit-0-without-final_state is treated as a
  collector problem (fail + flag), so we never report a pass we didn't see audited.

## Prior art (do not modify reference trees)

- **`~/projects/Test2/Test2-Harness2-ChildSubReaper`** — full local (unreleased)
  repo: `ChildSubReaper.xs`, portable `subreaper_impl.h` (Linux prctl + FreeBSD/
  DragonFly procctl; everything else returns 0), `t/40-subreaper-behavior.t`. Copy
  the platform logic + the behavior test; reimplement via `syscall()`.
- **`reference/old3`** — IPC::Manager-era attempt with the same subreaper idea:
  `AI_DOCS/2026-05-10-flatten-run-service.md` and `2026-05-10-preload-rework-design.md`
  (double-fork-then-reparent, harness-as-subreaper, init fallback on BSD/macOS).
  Conceptual reference only; the current architecture (no IPC::Manager, collectors
  from Test2-Collector) differs.

## Open / verify items for the implementer

1. Confirm the `starting`/`harness_collector` transition already carries the
   collector pid (it stamps "full start info on starting"); add it if not.
2. `Test2-Collector` is the **local checkout** (`t2clib` → `../Test2-Collector/lib`);
   change + reinstall, **no version bump** (unreleased).
3. The EOF→job mapping needs the test collector's transition connection to carry
   `job_id`+`job_try` in its handshake/preamble; verify the current `Recorder::Socket`
   reporter preamble (TODO-9's `socket_reporter`) and extend.
4. Fire-once / ordering: the decision keys on EOF (drain frames first); the reap
   (when it happens) must be pure zombie cleanup. Make sure a reparented collector's
   reap cannot double-fire a decision.

## Review outcomes (resolved with the owner, 2026-06-21)

Two reviews (`review_gemini.md`, `review_gpt.md`) were discussed item-by-item and
folded into ARCHITECTURE §5.4 + tickets TODO-27/TODO-28/TODO-32–TODO-37. Resolutions:

- **EOF soundness needs fd hygiene (both reviewers, P1) → new prerequisite TODO-32.** A
  forked-no-exec collector inherits other collectors' connection fds; the test child
  can inherit the reporter socket (esp. no-exec `goto::file`). Decision: `FD_CLOEXEC`
  at creation **plus** an explicit post-fork close-sweep (collector parent closes
  inherited runner conns + listen socket; the preload test-launch closes the
  collector's reporter/recorder sockets too). TODO-32 gates TODO-27. The reporter is mandatory;
  add `--collector-connect-timeout`.
- **Collector-exit-health-only — yes, but the work is harness-side (A8).** The local
  Test2-Collector is already health-only (`Runner->spawn_exit_code`); the harness
  reintroduces the verdict via `Job::_collector_exit_code`. Test jobs use the
  collector's helper; `Util::collector_exit_code` stays for non-test wraps.
- **Post-pass collector failure (A3):** a collector that fails *after* reporting `pass`
  keeps the test green; on supported platforms the reaped non-zero health exit ⇒
  harness-output error + **mark the suite failed** at command exit; unsupported may
  lose it (accepted). Exit code is consulted *only* for this suite-level escalation.
- **Bail/abort via a runner→collector terminate message (A4):** the test-collector
  connection becomes **bidirectional**; the runner messages all run collectors to
  terminate (they kill their child, record, exit→EOF), handles late-connecting
  collectors via an abort/bail **intent**, and `halt` wins over retry. The same
  primitive is the proper fix for owner-disconnect abort (B3) and the `yath abort`
  race (B4); pid/`kill(-pid)` is fallback only. Detached collectors `setsid`.
- **Connection identity / stale-try (A5):** store the full identity; `conn → job` map;
  idempotent close; ignore EOFs from a non-current `job_try`.
- **No-verdict render mutation (A6):** a runner-originated terminal `harness_runner_job`
  failed/aborted (job_id/run_id/file/job_try/reason), consumed once; reason = harness
  output. Watchdog-aborted jobs are recorded `aborted`, not "harness internal".
- **Pure-Perl `syscall()` subreaper — confirmed.** Table: Linux `SYS_prctl`
  x86_64=157, aarch64/riscv64=167, i386=172 (`PR_SET_CHILD_SUBREAPER`=36); FreeBSD
  `SYS_procctl`=548 (`P_PID`=0, `PROC_REAP_ACQUIRE`=2). Graceful unsupported elsewhere.
- **`halt` transition — `state => 'halt'` on `harness_state_transition`** carrying
  `details` (no new facet).
- **Cross-repo sequencing:** order matters — the harness must stop deciding on the exit
  code **before** anything relies on health-only — handled within TODO-27's harness-side
  steps; TODO-32 lands first (fd hygiene), then TODO-27, TODO-28, TODO-29.

### Review-driven standalone fixes (separate tickets, per owner: ticket-not-fix-now)

- **TODO-33** — `preload_stage_startup_timeout` is inert in the scheduler (the TODO-21
  safeguard never fires; `_next` never visits non-`up` buckets). Approach A: per-tick
  scan marks a timed-out stage `down` to re-resolve buckets. *(This is a real gap in
  the TODO-21 work just landed.)*
- **TODO-34** — `yath reload` ineffective during a persistent preload run (routed to the
  dormant `preload-root` peer). Approach A: route to the live base-stage connection.
- **TODO-35** — `halt_run`/`purge_run` leak `TASK_LOOKUP` entries.
- **TODO-36** — delete dead `reset_stage_readiness` (re-verify no consumers first).
- **TODO-37** — document the resource-skip `-e` executor assumption (doc-only).

The reviews' praise/verification of already-landed work (SharedJobSlots deletion, the
Stage-class rename, client-side stage assignment, the Runner/Preload::Host split,
connection-gated retention, stage-death resilience) needs no action.
