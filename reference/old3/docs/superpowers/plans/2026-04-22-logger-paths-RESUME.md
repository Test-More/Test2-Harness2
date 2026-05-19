# RESUME: logger path derivation + run-service aggregation

Last session: 2026-04-22. Branch: `2.0_rewrite`. HEAD at pause: `a8ff9cae1`.

---

## What shipped this session

Commits (oldest → newest on `2.0_rewrite`):

1. `9324a137a` TestFile: add minimal concrete class consuming Role::TestFile.
2. `dc66d3717` test: replace `App::Yath2::Command::test` with minimal role-based skeleton.
3. `32e8f200d` test: spawn `Test2::Harness2` and tally pass/fail.
4. `6335a8908` test: read pass verdict from `facet_data.harness` in JSONL log.
5. `7bdd56c99` Workspace: drop missing-import `chmod_tmp` / `find_libraries` (compile unblock).
6. `b323972c3` test: place harness JSONL under `logs/services/` (superseded by #8).
7. `84ab9cd7d` RunService: inject TestFile spec into per-job Logger::JSON (superseded by #8 + #9).
8. `435b0ec31` Loggers: derive default output path from identity attrs. Role now owns `output_file_basename`, `output_files`, `prepare_output_locations`. JSON/JSONL got the six data attrs (`logdir`, `service_name`, `job_id`, `run_id`, `job_try`, `is_run`). Collector base propagates identity + calls `prepare_output_locations`.
9. `f905246c5` Callers: supply identity attrs, drop `%VAR%` placeholders and `output_file` overrides. Harness2 + RunService + `App::Yath2::Command::test`.
10. `ba2b185e7` RunService: place JSONL at `logs/runs/<run_id>.jsonl` (pre-interpose hack, now moot).
11. `a8ff9cae1` RunService: interpose a collector; route JSONL through the logger. New `Test2::Harness2::Collector::Service::Run`. `start()` mirrors harness interpose. `.json` snapshot stays a direct write from the service side — **this is the remaining design wart**.

Plan file the stack originally executed: `docs/superpowers/plans/2026-04-22-minimal-test-command.md`.

## Layout produced (verified via smoke)

```
logs/services/harness.jsonl                     (harness collector → Logger::JSONL)
logs/runs/<run_id>.jsonl                        (run collector → Logger::JSONL)
logs/runs/<run_id>.json                         (run snapshot — direct write from RunService)
logs/runs/<run_id>/tests/<job_id>.{json,jsonl}  (test collector)
logs/runs/<run_id>/services/<name>.{...}        (reserved for resource services under the run)
```

Smoke checks (from session):
- `yath -D test /tmp/yath-smoke/pass.t` → exit 0
- `yath -D test /tmp/yath-smoke/fail.t` → exit 1
- Both files → exit 1
- Per-test `.json` carries `file` / `absolute` / `relative` + TestFile role fields (spec auto-inject in `RunService._maybe_inject_test_file_spec`).

`t/AI/unit/Harness2/RunService.t` updated for new defaults (9/9 pass). `t/AI/unit/Harness2.t` still 54/54 pass.

## Known issue left open

`logs/runs/<run_id>.json` is written by `RunService._write_snapshot` directly, not through the JSON logger. Reason: run-service collector is the parent of the interpose fork; its `Run` object is a pre-fork copy that never observes job completion in the collector process, so running the snapshot through `Logger::JSON.shutdown` would only ever capture initial state. Commit `a8ff9cae1` documents this.

User wants this wart eliminated.

## In-flight discussion (paused)

Aggregation-topology discussion. Full detail + topology map in `docs/review/2026-04-22-run-aggregation-topology.md`. TL;DR:

- Current: harness aggregates Run mutations (scheduler drives `_handle_job_complete` → `mark_done`). Collector process never sees these mutations. Hence `.json` wart.
- User's proposed fix: **route test-state-change messages to the run service, not the harness**. Run service aggregates its own Run, forwards to harness only what the scheduler needs. Run service emits a new log-event kind (`spec_snapshot` suggested) every time the aggregated Run mutates; run-service collector's `Logger::JSON` listens (`log_events = 1`, override output on each event) and writes final `.json` at shutdown.
- No `Aggregator` role needed in that flow.

### Questions awaiting user answer

(a) Confirm `job_completed` alone is sufficient forward RunService→harness (harness's own `Run.is_complete` still flips correctly once all jobs are forwarded). No separate `run_ended` IPC?

(b) Who emits `run_queued` / `job_queued` / `run_started` / `job_started` post-refactor? Leaning: run service owns those emissions, harness.jsonl becomes service-lifecycle-only. Needs sign-off.

(c) Event kind name: `spec_snapshot` (vs `spec_update` / `snapshot_update` / user's original `spec_state_change`).

(d) Confirm: drop the `Aggregator` role idea entirely; go with the simpler flow described above.

User's pause message: *"Write your last response to a file for me to review, we will put this on hold for now"* — the last response IS the topology doc.

## Resume plan (once above answered)

Order of work:

1. **IPC redirection**. Change `collector_exiting` (auditor verdict, brief) and `test_job_completed` routing so they target `ipc_run` (run service) instead of `ipc_harness`. Sites:
   - `Test2::Harness2::Collector::_send_collector_exiting` (already sends brief to ipc_parent — good; the richer version currently goes to ipc_harness — redirect to ipc_run).
   - `Test2::Harness2::RunService::run_on_pid` — already sends `test_job_completed` to harness. Flip the destination: consume locally, then forward only what harness needs.
   - Harness `run_on_general_message`: stop handling `test_job_completed` / test-side `collector_exiting` directly. New handler for the forwarded `job_completed` from run service.
   - pid-liveness watchdog moves from harness `_check_running_job_pids` to RunService.

2. **Aggregation in RunService**. On each incoming test-state message:
   - Mutate `$self->{+RUN}` (`mark_running`, `mark_done`, etc.).
   - Emit the matching log event (`job_started`, `job_completed`, …) via `emit_service_event` → EventEmitter → run collector.
   - Emit `spec_snapshot` immediately after (payload = `$run->TO_JSON`).
   - Forward the minimum-needed subset to harness (probably just `job_completed` with `pass` + `exit`).

3. **Harness-side de-dup**. Harness stops emitting `run_queued`/`job_queued`/`run_started`/`job_started`/`job_completed`/`run_ended`. Its scheduler still mutates its own `Run` off the forwarded `job_completed` IPC.

4. **Logger::JSON updates**. Flip `log_events` to true. On each `spec_snapshot`, cache payload. `startup` writes first cached payload (seeded by aggregator sending a `spec_snapshot` at start). `shutdown` writes last cached payload. Drop the `spec` attribute requirement (or keep it as an optional seed).

5. **Run-service collector default loggers**. Add `Logger::JSON` back into `RunService` default LOGGERS (currently JSONL-only per commit `a8ff9cae1`). Remove `SNAPSHOT_FILE` slot + `_write_snapshot` + init/cleanup snapshot calls.

6. **Synthetic skip/fail path**. Harness already builds the one-liner + sends `launch_job`. No change expected. Verify.

7. **Tests**: update `t/AI/unit/Harness2/RunService.t` for new defaults (JSON logger back in, no `snapshot_file`). Update `t/AI/unit/Harness2.t` to the extent it asserts on harness-emitted events that have moved.

## Handy pointers

- Role: `lib/Test2/Harness2/Role/Collector/Logger.pm` — path derivation rules live in `output_file_basename`.
- Collector base: `lib/Test2/Harness2/Collector.pm` — `_instantiate_loggers` (mutex on service_name vs job_id), `_process_event` (where Auditor fires; where Aggregator would have fired if we'd kept that design).
- RunService: `lib/Test2/Harness2/RunService.pm` — `start()` does the interpose; `_write_snapshot` is the wart to retire.
- Harness2: `lib/Test2/Harness2.pm` — `_handle_job_complete` line ~538, `_launch_job` line ~1208, `_check_running_job_pids` line ~835 (watchdog to move).
- Event emit helper: `Test2::Harness2::Util::EventEmitter` (shape matches both harness + run service emitters).
- Topology doc: `docs/review/2026-04-22-run-aggregation-topology.md`.
- Original fix-log-paths brief: `fix_log_paths` (repo root).

## Worktree / branch

Working directly on `2.0_rewrite` per the saved worktree-policy preference (no session worktree for normal changes). User rehydrates at `2.0_rewrite` head `a8ff9cae1`.
