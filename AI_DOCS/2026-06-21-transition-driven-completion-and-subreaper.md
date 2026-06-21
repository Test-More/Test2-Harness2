# Transition-driven test completion + runner-as-subreaper (design, 2026-06-21)

**Status:** design agreed with the owner (Chad Granum); **no code written yet.**
This doc is the context for a review pass — read it, then critique the design and
the ticket breakdown before implementation starts.

Spec lives in `ARCHITECTURE.md` §4.1 / §4.7 / §5.4 (rewritten this session).
Steps: `TODO_STEPS.md` chunks **24–28**. Tickets: `TODO_TASKS.md` **#27–#31**.

## What triggered this

The session was working the `TODO_TASKS` cleanup backlog. The last substantive
item was **#8 Part 4** — "migrate no-preload job completion onto the collector
socket report + delete `Runner::set_proc_exit`'s job branch (§5.4)." It had been
deferred as "a rewrite, not a cleanup." Discussing it with the owner turned it
into a larger, coherent redesign of how the harness learns a test's outcome and
who owns the process tree. The old #8-Part-4 framing is superseded by the five
tickets #27–#31.

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
This absorbs the **#22 residual**, **#4 Part 4**, and **#8 Part 4**.

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
   reporter preamble (#9's `socket_reporter`) and extend.
4. Fire-once / ordering: the decision keys on EOF (drain frames first); the reap
   (when it happens) must be pure zombie cleanup. Make sure a reparented collector's
   reap cannot double-fire a decision.

## Reviewer questions (please weigh in)

- Is **EOF on the transition connection** a sound universal "collector gone" signal
  in this architecture, including the persistent-runner case where the same socket
  carries many connections? Any path where a collector dies but its connection does
  **not** EOF promptly (e.g. an inherited dup of the socket fd in a grandchild)?
- Is **collector-exit-health-only** the right call, or is there value in keeping the
  child's OS exit available as a secondary signal somewhere?
- Pure-Perl `syscall()` subreaper: acceptable maintenance risk vs XS header
  correctness? Any (OS,arch) we should table beyond Linux x86_64/aarch64 + FreeBSD?
- The `halt`/bail transition: new `state => 'halt'` on `harness_state_transition`
  (carry `details`) vs a dedicated facet — preference?
- Sequencing #27→#28→#29 across two repos (Test2-Collector + harness) while keeping
  both green at each step — is the chunk split right, or should the collector-side
  (`halt` transition + health-only exit) land and install first as its own step?
