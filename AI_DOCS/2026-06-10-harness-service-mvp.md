# Harness service MVP

## What and why

First cut of the Test2::Harness2 service layer on the Test2-Collector
foundation, per the user's spec (and the `harness_service` notes file at
the repo root): a client handle starts a harness service process; the
service loops on a socket waiting for queued test runs and executes each
run's jobs one at a time, each under its own collector.

New modules: `Test2::Harness2` (client handle),
`Test2::Harness2::Run` + `Test2::Harness2::Run::Job` (final-form value
objects), `Test2::Harness2::Service::Harness` (the service loop).
Recorded as `ARCHITECTURE.md` §4.3.

## Decisions

- **Two sockets, not one.** `harness.socket` carries client request
  frames; `harness_transitions.socket` is the managed Monitor's
  listening socket that job-collector reporters connect to. Keeping
  them separate preserves §5.2's one-connection-per-collector contract
  and keeps the Monitor's wire format pure (plain stamped transition
  events, no envelopes) — no `transition_frame` wrapping or
  request/transition discrimination needed on a shared socket.
  Alternative rejected: one socket multiplexing both, with
  `transition_frame => 1` wrappers; it complicates the Monitor's proxy
  replay (frames would carry wrappers) for no benefit.
- **Request protocol** is zstd-compressed JSON object frames (identical
  framing to collector events): `{queue_run => ...}`, `{shutdown =>
  true}`. Unknown frames warn and drop; a bad `queue_run` payload warns
  and drops rather than killing the service.
- **Run/Job carry final data only.** Job: `job_uuid`, `try` (1),
  `test_file`, `env_vars`, `includes`, `via` (`fork_exec` only). Run:
  `run_uuid`, `jobs`. Modeled from `reference/old3`'s `Run` / `Run::Job`
  and `old4`'s launcher spec (`test_file` / `includes` / `env` / `cwd`),
  trimmed to what the current ask needs. Sniffing (shebang, `#
  HARNESS2:` directives — see old3's `App::Yath2::TestFile`) is
  explicitly the future App::Yath2 subclasses' job: they populate, then
  serialize; the harness rehydrates base classes only.
- **`env_vars`, not `env`.** `ENV` is a Perl superglobal: the bareword
  always resolves to `main::`, so an Object::HashBase `env` slot's
  `+ENV` constant is unusable inside the class. Same trap
  Test2-Collector dodged with `child_env`.
- **Completion via transitions.** The service marks a job done when the
  Monitor reports `harness_collector_finalized` for the job's uuid;
  `waitpid` afterward only reaps and health-checks (255 = collector
  failure → warn). This honors §4.2 (collectors may not be direct
  children forever).
- **Collector uuid = job uuid**, with `run_uuid` and `try` stamped, so
  Monitor state is keyed by job with no extra correlation table.
- **Events file path** is chosen by the harness:
  `<workdir>/<run_uuid>/<job_uuid>-<try>.jsonl.zst`. Consumers learn it
  from the `starting` transition, not by assuming the layout.
- **Scheduling is a cursor**, not a class. The notes file sketches a
  `Test2::Harness2::Scheduler`; today's ask is serial-only, so the
  logic is ~15 lines in `_advance`. Extract a Scheduler when
  concurrency/resources arrive.
- **Deferred** (in the notes, not in this ask): `connect()` to an
  already-running harness, client-side live state proxying
  (Monitor `add_proxy` machinery is ready for it), the `t2h2_run`
  script, run/job ordinals, retry.

## Verification

`t/AI/unit/Run.t`, `t/AI/unit/Run/Job.t`,
`t/AI/integration/harness_service.t` (full end-to-end: start, queue a
2-job run over the socket, shutdown, wait; asserts events files at the
documented paths with correct pass/fail content, plus the service's own
`harness.jsonl.zst`). Suite: 9 files, 72 tests passing.
