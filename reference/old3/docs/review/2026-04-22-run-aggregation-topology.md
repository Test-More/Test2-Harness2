Topology map (current):

### Harness-emitted log events (→ `harness.jsonl`)

| Event | Where | Trigger |
|---|---|---|
| `service_started` | Role::Service | harness collector starts |
| `service_stopped` | `run_on_cleanup` | harness service stops |
| `run_queued` | `request_handler_queue_test_run` | yath queues a run |
| `job_queued` | same (per job) | every job in the queued run |
| `run_started` | `_launch_job` (first job) | first test job in a run launches |
| `job_started` | `_launch_job` | each successful launch |
| `job_completed` | `_handle_job_complete` | harness consumes `test_job_completed` IPC |
| `run_ended` | `_handle_job_complete` when `run->is_complete` | last job done |
| `job_loggers` | `run_on_general_message` `collector_artifacts` | test collector reports logger metadata |

### RunService-emitted log events (→ `run.jsonl`)

| Event | Where | Trigger |
|---|---|---|
| `service_started` | Role::Service | run collector starts |
| `service_stopped` | `run_on_cleanup` | run service stops |

### IPC messages (not log events)

| Kind | From → To | Purpose |
|---|---|---|
| `launch_job` | harness → run service (sync_request) | harness asks run service to spawn a test |
| `test_job_completed` | run service → harness (`run_on_pid`) | test collector pid reaped; harness releases resources + advances scheduler |
| `collector_exiting` | test collector → harness (with auditor verdict) + brief version → run service | pre-reap pass signal + grace timer |
| `collector_artifacts` | test collector → harness | logger metadata → becomes `job_loggers` event |
| `job_complete_notify` | (wake-only) | wakes scheduler tick |
| `resource_*` | resource service → harness | resource state transitions |
| `terminate` | harness → run service | stop cascade |

### Scheduler state in harness

`_handle_job_complete` mutates harness's `Run`: `mark_done`, checks `is_complete`, teardown. `_try_launch_next_pending` walks `run->pending`. `_handle_broken_resource` / `_launch_synthetic_job` skip/fail paths run **inside the harness** today — harness builds the `perl -e skip_all`/`die` command and sends it as a `launch_job` payload.

---

### Your proposal, translated

1. **Move `test_job_completed` target**: run service consumes test exit instead of forwarding raw to harness. Run service also consumes `collector_exiting` from the test collector (for auditor verdict).
2. **Run service aggregates**: owns the authoritative `Run` for its own run. Mutates on each test's outcome (`mark_done` etc).
3. **Run service re-emits** as log events on its own emitter: `run_queued`, `run_started`, `job_queued`, `job_started`, `job_completed`, `run_ended` → flow to the run collector → `run.jsonl`.
4. **Run service forwards up** only what harness needs for scheduling. Minimum: `job_completed` (with pass + exit so harness can release resources + decide next). Likely also `run_ended` so harness can retire the run from its own queue + tear down.
5. **Skip/fail-on-broken-resource**: harness decides, sends a `launch_job` with the synthetic one-liner payload (this is already the mechanism — just keeps happening).
6. **`spec_state_change` event**: run service emits after every aggregate mutation. JSON logger's `log_events = 1`, watches for that kind, overwrites its snapshot. Also emit one at startup so no `spec` attribute needed.

**Name suggestion**: I'd avoid `spec_aggregation` (noun-ish, unclear). Options:
- `spec_snapshot` — emphasizes "here is the latest full state".
- `spec_update` — flags it as a change notification.
- `snapshot_update` — drops the "spec" jargon.

I'd go with `spec_snapshot` — each event carries a full `TO_JSON` payload, easy for the JSON logger to just dump. Generic enough to apply to other aggregate-carrying services later.

### Topology concerns

- **Harness scheduler still needs `Run` state**: `_try_launch_next_pending` walks `run->pending` and `run->running`. If aggregation moves to the run service, the harness's Run also needs to mutate for the scheduler. Fine — harness keeps its own `Run` and mutates on the forwarded `job_completed` IPC from run service (exactly what happens today, just the sender changes).
- **`collector_exiting` auditor verdict**: currently test collector sends to `ipc_harness` (harness). Change: send to `ipc_run` (run service) only. Run service then bundles verdict into its forward to harness (or into its own `job_completed` emission for `run.jsonl`).
- **pid-liveness watchdog**: currently harness's `_check_running_job_pids` stamps `pid_gone_since` and synthesizes `test_job_completed` if grace expires. With tracking in run service, watchdog moves there. Natural — run service already holds `TEST_JOBS` with pids.
- **`collector_artifacts`/`job_loggers`**: low-priority. Could move to run service too, or keep harness-only since it's for global job-log enumeration.
- **Resource `resource_*` state messages**: orthogonal; resource services are global or run-scoped. Keep harness receiving global ones; run service already would receive run-scoped ones. No change needed.

### Confirming before I cut

- (a) Minimum forward RunService→harness: `job_completed` payload (with pass + exit + run_id + job_id). Sufficient for harness scheduler. Also need `run_ended`-equivalent so harness tears down run service? Actually harness learns run is done when its own `run->is_complete` flips from the forwarded `job_completed` messages. No separate IPC needed. Confirm?
- (b) Run-service also takes over emitting `run_queued` / `job_queued` / `run_started` / `job_started` — harness stops emitting those? (harness.jsonl would lose those lines.) Or harness still emits for its own log + run service also emits for run.jsonl? I lean toward "run service owns those emissions; harness does not duplicate" — harness.jsonl becomes purely about harness-service-level lifecycle (service_started/stopped, maybe a top-level `run_forwarded`/`run_finalized`). Your call.
- (c) Event name: `spec_snapshot`?
- (d) Drop the Aggregator role idea entirely, go with your simpler flow. Confirm?
