# 2026-04-23 -- Run-service aggregation + Observer role

## Trigger

Design brief at repo root `run_service` and RESUME file
`docs/superpowers/plans/2026-04-23-run-service-aggregation-RESUME.md`.
The 2.0 rewrite had the harness owning authoritative Run state and
consuming per-test `test_job_completed` / `collector_exiting` IPC
directly. The user wanted to invert that: the per-run RunService
owns the Run, and the harness mirrors its state from a single
`run_state_update` channel.

## What landed

Seven commits on `2.0` (cbfd777ab..42ed58e91).

### New: Observer role and TestObserver

- `lib/Test2/Harness2/Role/Collector/Observer.pm` -- parallel to
  Auditor. Observers sit between the auditor and loggers in the
  collector event pipeline. They cannot mutate the stream; the
  collector forwards every event unchanged and appends whatever
  observers return as synthesized events.
- `lib/Test2/Harness2/Collector/Observer/TestObserver.pm` --
  default observer on `Collector::Test`. Watches the post-auditor
  event stream and emits IPC messages at specific transitions:
  - `test_job_started` -> run service (startup)
  - `test_job_diagnosing` -> run service (first STDERR / important
    info facet)
  - `test_job_failing` -> run service (first failing assertion /
    error facet)
  - `test_job_completed` -> run service (on harness_job_exit
    facet, i.e. post-reap) -- carries auditor's final verdict
  - `job_release` -> harness (same moment; outcome-agnostic)

### Collector wiring

- Observer chain threaded through `_process_event` after the
  auditor, before loggers. `_normalize_observers` /
  `_instantiate_observers` mirror the logger plumbing.
- `_send_collector_exiting` and `_extend_exiting_payload_for_harness`
  dropped entirely. TestObserver's messages carry everything
  upstream services need.
- `Collector::Test._default_observers` returns `TestObserver` so
  every test-job collector gets one automatically. Callers can
  override via `observers => ...`.

### RunService aggregation

`lib/Test2/Harness2/RunService.pm`:

- `run_on_general_message` dispatches the five incoming kinds.
- `_handle_test_job_started` marks the job running in the Run,
  emits `job_started` on the run emitter, and broadcasts.
- `_handle_test_job_completed` is idempotent (observer + watchdog
  race) via `completed_job_ids` flag. Marks done, emits
  `job_completed`, broadcasts.
- `_broadcast_run_state` fires `run_mutation` on the run emitter
  (which the JSON logger consumes) AND sends `run_state_update`
  IPC with the full `Run->TO_JSON` to the harness. Full
  snapshots, not diffs.
- `run_on_pid` no longer emits `test_job_completed` to the
  harness. When a collector pid reaps without a completion
  message, the job goes into `pending_synth_completions`.
- `run_on_interval` is the watchdog: after `collector_grace_secs`
  (default 10s, configurable) without a real completion, synthesize
  one by calling `_handle_test_job_completed` with `synth => 1`.
- `service_on_start` and `run_on_cleanup` each call
  `_broadcast_run_state` so the JSON logger has an initial and a
  terminal snapshot to cache.
- `SNAPSHOT_FILE` / `_write_snapshot` / `write_json_file_atomic`
  removed. The JSON sidecar path is handled entirely by the JSON
  logger now.

### Harness mirror

`lib/Test2/Harness2.pm`:

- `_handle_run_state_update` replaces the shadow Run's `pending` /
  `running` / `done` with the snapshot. On completion: drop from
  queue, tear down run service, emit `run_ended`, maybe
  `finishing`.
- `_handle_job_release` releases the job's resources and drops
  its `running_jobs` entry.
- `_handle_job_complete`, `_handle_collector_exiting`,
  `_check_running_job_pids`, `run_on_interval`,
  `JOB_PID_GRACE_SECS` all dropped.
- Harness now emits only `run_queued` / `run_started` /
  `run_ended`. The per-job lifecycle (`job_queued` / `job_started`
  / `job_completed` / `job_loggers`) lives in the run's own
  `.jsonl` via the run service's emitter.
- Orphan-pid fallback in `run_on_pid` still handles the edge
  case where the run service died before reporting: local
  resource release + mark_done + run_ended.

### Logger::JSON

- `log_events = 1`. Consumes `run_mutation` events and caches the
  latest `run_data` payload.
- Startup writes `spec->TO_JSON` if a spec was supplied, else an
  empty stub.
- Shutdown writes the cached payload (or falls back to
  `spec->TO_JSON` / empty), stamped with exit + auditor pass.
- `output_file` and `spec` are both fully optional now.

## Design decisions and alternatives considered

**Q1: drop pre-reap verdict?** Yes. The user was explicit that
no verdict should be issued before reap -- a test file exiting
non-zero is a failure, and that check is only meaningful after
the process is waited on. The collector emits
`harness_process_exit` after reap, the auditor synthesizes
`harness_job_exit` with the parsed exit code, and TestObserver
keys completion off that. Pattern taken from
`reference/old2/lib/Test2/Harness2/Collector.pm:929-946`.

**Q2: grace window on collector death?** Yes, 10s default, lives
on the run service. Configurable via `collector_grace_secs`.
Rejected: no-grace (synthesize immediately). The grace covers the
common case where a collector crashes mid-flush -- its
test_job_completed may already be in the IPC queue waiting for
delivery. 10s is enough for that, short enough that a truly-dead
collector doesn't hang the run.

**Q3: who watches what pid?** Run service watches collector pid
only, via IPC::Manager's normal reap when the collector is its
direct child. Collector watches test pid (existing behaviour).
If the run service needs to signal the test, it goes through the
collector. Rejected: run service directly watching test pid --
wrong scope once preload enters the picture (the preload stage
forks the collector, not the run service).

**Observer contract: append-only vs transform.** Went with
append-only: the collector forwards every event itself, and
whatever the observer returns is appended. Safer: observers
cannot accidentally drop or mutate. Transform-capable observers
(like auditors) would have made it easy to introduce
logger-visible bugs.

**Full-snapshot run_state_update vs diffs.** Full snapshots.
`Run->TO_JSON` is tiny (job_id lists plus a handful of scalars);
diff machinery would cost more complexity than it saves.

**JSON logger feed: event stream vs direct write from service.**
Event stream (run_mutation). Direct writes from RunService would
require it to own path derivation, atomic-write, etc. -- all of
which the JSON logger already does. By routing through the
existing logger the interpose collector stays the single source
of truth for all on-disk artifacts.

## Deviations from ARCHITECTURE.md

None introduced by this work. The existing
`ARCHITECTURE.md` already describes the Observer slot in the
collector pipeline (§7) and the aggregation pattern (§9-10);
this commit set implements those sections rather than changing
them.

## Commit list

```
b8be1469a Collector: add Observer chain + TestObserver, drop collector_exiting
9ea82b795 RunService: aggregate test_job_* + broadcast run_state
e08b1a28f Harness: mirror Run from run_state_update; drop legacy completion paths
e73d63086 Logger::JSON: consume run_mutation events for the sidecar snapshot
67c4c2077 Integration tests: adjust for the run-service aggregation topology
d25324e53 Command::test: get pass/fail from harness IPC, not log files
```

## Known follow-ups

- The design calls for the harness to carry a `skip_reason`
  attribute on `launch_job` and have the run service build the
  synthetic skip/fail payload via the Run's
  `on_broken_resource` attribute (skip / fail / abort). Not yet
  implemented: the existing `_handle_broken_resource` /
  `_launch_synthetic_job` path still lives on the harness and
  builds the synthetic launch locally. Works, but runs against
  the "run service owns the synthetic shape" design. Flagged for
  a follow-up pass.
- Run service does not yet emit `job_queued` events for each job
  at service_on_start; the spec lists that as run-service
  territory. Low priority -- the harness's `run_queued` event
  already carries the full `Run->TO_JSON` with the jobs list, so
  consumers can derive the per-job queue stream from there if
  needed.
