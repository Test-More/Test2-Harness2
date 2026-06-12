# RESUME: run-service aggregation + Observer role

Session: 2026-04-23 (follow-up). Branch: `2.0`. HEAD at pause: `d947345ef`.

Prior anchor was `2.0_rewrite @ a8ff9cae1`; work has been squashed onto the
`2.0` branch since, but the design anchor and code pointers below still
apply.

## COMPLETE (2026-04-23, autonomous pass finished)

All nine tasks done. See `AI_DOCS/2026-04-23-run-service-aggregation.md`
for the full write-up (decisions, alternatives, deviations, known
follow-ups). The checkpoint block below is left in place for the
historical log only.

## Progress checkpoint (2026-04-23 follow-up, autonomous pass)

Four commits landed since this file was last updated, all on `2.0`:

1. `cbfd777ab` Observer role + Collector pipeline slot (pure scaffolding,
   behaviour-preserving).
2. `7ff5dbd15` TestObserver emits the five IPC messages specified below
   (`test_job_started`, `_diagnosing`, `_failing`, `_completed` → run
   service, `job_release` → harness). Installed as default on
   `Collector::Test`. `collector_artifacts` routing unchanged (already
   goes to `ipc_run`).
3. `b3b4177cd` RunService grows `run_on_general_message` with handlers
   for the five messages above, mutates its `Run` (`mark_running` /
   `mark_done`), emits `job_started` / `job_diagnosing` / `job_failing`
   / `job_completed` / `job_loggers` onto the run emitter, and
   broadcasts every mutation as a `run_mutation` event plus a full-
   snapshot `run_state_update` IPC to the harness.
4. `d947345ef` Harness silently drops `run_state_update` / `job_release`
   during the transition (avoids warn spam). The harness is still
   wired to the LEGACY path: it consumes `test_job_completed` (sent
   by `RunService::run_on_pid` after the collector pid is reaped) and
   `collector_exiting` (sent by `Collector::_finalize_collection`).
   Both paths are running in parallel right now.

Tests passing as of the checkpoint: everything under `t/AI/unit/` other
than the pre-existing `t/AI/unit/Collector.t:23 'construction validation'`
failure (stale `output_file` required-spec assertion, unrelated to this
work).

Supersedes design questions in `docs/superpowers/plans/2026-04-22-logger-paths-RESUME.md` (logger-paths portion shipped; the topology section is now locked in by this file).

Reference brief from user: `run_service` at repo root (the short spec this session is designed against).

Prior topology map: `docs/review/2026-04-22-run-aggregation-topology.md` (frozen; decisions below override any open questions in that file).

---

## Design locked in this session

### Process / IPC topology

1. **Scheduler (harness) starts a run service for the run.**
2. **Scheduler sends `launch_job` requests to run service.** (Unchanged from today.)
3. **Resource-broken skip/fail:** harness still consumes `resource_*` state messages and decides per-pending-test that a given job is now broken. Harness sets a `skip_reason` attribute on the `launch_job` payload. Run service consults the `Run` object's `on_broken_resource` attribute (`skip` vs `fail`) and builds the matching `perl -e skip_all` / `die` payload. Harness itself no longer builds the synthetic payload.
4. **Job-id authority:** harness assigns `job_id` when the run is queued (before the run service starts), so the run service inherits ids.

### New `Observer` role

- `lib/Test2/Harness2/Role/Collector/Observer.pm`.
- Event flow in collectors: `Parser -> Auditor -> Observer(s) -> Logger(s)`.
- Optional, like Auditor. Plural, like Loggers.
- Consumes one event at a time; may inject additional events that Loggers then pick up.
- Purpose: watch the event stream for specific conditions and take action (typically: send IPC messages).
- Instantiation: default list only, no current override mechanism.
- **Only test-job collectors get an Observer by default.** Harness collector and run-service collector get none.

### `TestObserver` (new, for test-job collectors)

Emits IPC messages at specific stream conditions:

| Event | Target | Trigger |
|---|---|---|
| `test_job_started` | run service | collector has forked the test process. Payload: `run_id`, `job_id`, collector pid, test pid. |
| `test_job_diagnosing` | run service | first Info facet with `important` or `debug` set, or first STDERR message. |
| `test_job_failing` | run service | first failing assertion or error facet. |
| `test_job_completed` | run service | test process exited + reaped. Payload includes final auditor results (verdict merged in — see `collector_exiting` removal below). |
| `job_release` | harness service | sent at the same time as `test_job_completed`. Agnostic to outcome. Payload: `run_id`, `job_id` only — harness looks up held resources from its own bookkeeping. Wakes scheduler. |

### Run-service aggregation

- Run service owns the authoritative `Run` state for its run.
- Every IPC above **except `job_release`** mutates run-service run state.
- **On every mutation the run service does two things:**
  1. Emits a `run_mutation` event to its own collector (for loggers). Observer-less chain; loggers receive it. JSON logger treats it as an `output_file` overwrite (full `TO_JSON` payload each time).
  2. Sends a `run_state_update` IPC to harness with the full `Run->TO_JSON` payload (no diffs — full snapshot each time).
- On collector shutdown: one final `run_state_update` IPC to harness + one final `run_mutation` emitted event to its loggers.

### Harness-side responsibilities

- Harness keeps its own `Run` **as a mirror**. Mutates only from incoming `run_state_update` IPC. Stops mutating directly from test-outcome IPC (it no longer receives those).
- Scheduler still walks `run->pending` / `run->running` to pick the next job.
- **Harness still emits:**
  - `run_queued` — when the run is queued (harness constructor receives a run, or the add-run API is called).
  - `run_started` — when scheduler decides to start the run (first job about to launch).
  - `run_ended` — when harness decides the run is done (no more pending, final test completed).
- **Run service emits to its own collector (→ `run.jsonl`):**
  - `job_queued`, `job_started`, `job_completed`, `job_loggers`, plus `run_mutation`.
  - `job_loggers` moves here from harness.jsonl. Test collector now sends `collector_artifacts` to run service instead of harness.

### pid-liveness watchdog

- Moves harness → run service. Run service has all the pids (via `test_job_started`).
- **Fallback at harness:**
  - Harness mirrors running-job pids via the synced `run_state_update` payload.
  - If the run service itself exits early or badly, harness kills/waits on the mirrored test pids, then releases resources.
- Run service also watches the **collector pid** (not just test pid) since `collector_exiting` is being removed — if the collector dies without sending `test_job_completed`, watchdog must catch that.

### `collector_exiting` removal

- Drop entirely. Merge verdict into `test_job_completed` (post-reap only).

---

## Resolved questions (2026-04-23 follow-up)

**Q1 — pre-reap verdict: NO.** No verdict issued before reap. Collector must reap the test process and emit a synthetic event carrying a `harness_job_exit` facet. That event flows through the Auditor, which checks the exit code as part of final-verdict computation (non-zero exit → REASON/fail facet). Auditor emits `harness_job_end` facet with the finalized `fail` boolean. `TestObserver` keys `test_job_completed` off `harness_job_end`, not off an early/pre-reap signal.

Reference shape (from `reference/old2/lib/Test2/Harness2/Collector.pm:929-946`):

```perl
harness_job_exit => {
    job_id => $self->job_id,
    exit   => $exit,              # raw wait-status
    codes  => parse_exit($exit),  # {err, sig, dmp}
    stamp  => $exited,
    retry  => $self->should_retry($exit),
    times  => $times,
}
```

Reference auditor handling: `reference/old2/lib/Test2/Harness2/Collector/Auditor/Job.pm:347-374` (builds `harness_job_end`) and `:430-439` (fail-on-nonzero-exit).

**Q2 — grace window: YES, configurable, default 10s.** When the collector pid is gone and `test_job_completed` has not yet been seen, run service waits up to the grace window for the message to arrive, then synthesizes completion with a synthetic `harness_job_exit` carrying `exit=-1` / sig-death fields. Configurable via a run-service attribute (name TBD during implementation; default 10).

**Q3 — pid watchdog: collector pid only.** Run service only watches the collector pid. The collector watches the test pid; run service signals the test **through** the collector when it needs to. When the collector is a child of the run service, IPC::Manager already reaps it. When it is not (preload scenarios: the preload stage owns the collector fork and reap), the run service still needs an external liveness signal for the collector pid — track via periodic `kill(0, $pid)` or equivalent, since we can't `waitpid` something we don't own.

Note for later: preload implementation must ensure the preload stage still publishes `test_job_started` (with collector pid) and the collector's own reap message so the run service knows when grace should start ticking.

---

## Remaining work (the coupled flip + follow-ons)

Tasks 5-9 below still pending. Tasks 5 + 6 are tightly coupled: you
cannot remove the legacy harness-side handlers without wiring up the
new ones (harness would stop releasing resources entirely), and the
watchdog replaces a safety net the legacy path currently provides.

## Resume plan

Order:

1. **New role + class.**
   - `Test2::Harness2::Role::Collector::Observer` (parallel to Auditor).
   - `Test2::Harness2::Collector::Observer::TestObserver`.
   - Wire Observer chain into `Test2::Harness2::Collector::_process_event` between Auditor and Loggers. Injection semantics mirror Auditor's.

2. **IPC redirect.**
   - Test collector side: `collector_artifacts` target flips to run service.
   - TestObserver emits `test_job_started` / `test_job_diagnosing` / `test_job_failing` / `test_job_completed` → run service, plus `job_release` → harness.
   - Remove `_send_collector_exiting` path entirely.

3. **Run service aggregation.**
   - Handlers for `test_job_*` + `collector_artifacts`.
   - Mutate `$self->{+RUN}` per message.
   - On each mutation: emit `run_mutation` via EventEmitter; send `run_state_update` IPC (full snapshot) to harness.
   - Emit `job_queued` / `job_started` / `job_completed` / `job_loggers` log events on the run emitter.
   - On shutdown: one final `run_state_update` + final `run_mutation`.

4. **Harness-side changes.**
   - Drop `run_on_general_message` handlers for `test_job_completed` / `collector_exiting` / `collector_artifacts`.
   - New handler for `run_state_update`: replace mirror `Run`'s state wholesale (or merge if incremental).
   - New handler for `job_release`: release resources, wake scheduler. No outcome fields.
   - Keep harness-side emission of `run_queued` / `run_started` / `run_ended` only.
   - Drop emission of `job_queued` / `job_started` / `job_completed` / `job_loggers` from harness.
   - `_handle_broken_resource`: stop building synthetic payload; set `skip_reason` on the `launch_job` payload, let run service expand it using `Run->on_broken_resource`.
   - `Run` gets `on_broken_resource` attr (skip / fail). Default probably skip.
   - Drop `_check_running_job_pids`. Add fallback: on run-service exit, kill + wait mirrored pids + release their resources.

5. **pid-watchdog in run service.**
   - Track collector pid only (per Q3). `test_job_started` payload still carries the test pid so renderers/UIs can show it, but run service does not watch it.
   - When collector is run-service child: rely on IPC::Manager reap.
   - When collector is not run-service child (preload): external liveness (`kill(0, $pid)` poll).
   - On collector-gone without `test_job_completed`, start grace timer (configurable, default 10s). On expiry synthesize completion with `harness_job_exit { exit => -1, codes => {...}, stamp => $now }` so the auditor-equivalent path in the run service builds a correct `harness_job_end`.

6. **Logger::JSON update.**
   - Flip `log_events = 1`.
   - On `run_mutation` cache payload; on `startup` write first cached payload; on `shutdown` write last cached.
   - Drop `spec` attribute requirement.

7. **Run-service defaults.**
   - Re-add `Logger::JSON` to default `LOGGERS` (currently only JSONL after `a8ff9cae1`).
   - Remove `SNAPSHOT_FILE` slot + `_write_snapshot` + start/cleanup direct-write calls.

8. **Tests.**
   - `t/AI/unit/Harness2/RunService.t` — drop `snapshot_file` assertion; expect JSON + JSONL in `loggers`.
   - `t/AI/unit/Harness2.t` — update / remove assertions for harness-emitted `job_*` events that moved.
   - New coverage for TestObserver + Observer role.
   - New coverage for run-service aggregation (mutation → event + IPC).
   - New coverage for `skip_reason` / `on_broken_resource` path.

---

## Code pointers

- Collector base + event flow: `lib/Test2/Harness2/Collector.pm` — `_process_event` is where Auditor fires and where Observer must be inserted.
- Run-service collector subclass: `lib/Test2/Harness2/Collector/Service/Run.pm`.
- Run service: `lib/Test2/Harness2/RunService.pm` — `start()` interpose, EventEmitter, `_write_snapshot` wart to retire.
- Harness: `lib/Test2/Harness2.pm` — scheduler (`_try_launch_next_pending`), `_handle_job_complete` ~line 538, `_launch_job` ~line 1208, `_check_running_job_pids` ~line 835, `_handle_broken_resource` / `_launch_synthetic_job`.
- Existing Auditor (model for Observer): look for `Role::Collector::Auditor` and its wiring in `Collector.pm`.
- EventEmitter: `lib/Test2/Harness2/Util/EventEmitter.pm`.
- Logger role (path derivation done): `lib/Test2/Harness2/Role/Collector/Logger.pm`.
- Loggers: `lib/Test2/Harness2/Collector/Logger/{JSON,JSONL}.pm`.

## Worktree / branch

Working on `2.0_rewrite` head `a8ff9cae1`. No session worktree per saved preference. Rehydrate there.
