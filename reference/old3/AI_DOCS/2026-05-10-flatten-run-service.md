# Flatten RunService into Harness — Implementation Plan

Date: 2026-05-10
Scope: architectural — eliminates `Test2::Harness2::RunService` as a separate
process; folds its responsibilities into `Test2::Harness2`. Multi-run support
(serial today, concurrent later) preserved through explicit per-run pid
bookkeeping in the harness.

Companion analyses: `claude-run-service.md`, `gemini-run-service.md`.

## Goals

- One service process. Test processes are grandchildren of harness
  (Harness → Collector → test); orphans reparent to harness as sub-reaper.
- Direct in-process scheduler ↔ run-state ↔ resource-state access. No more
  `run_state_update` mirror messages on the hot path. Bus-level
  `run_state_update` broadcasts to external subscribers (UI/replay) preserved.
- Per-run pid bookkeeping good enough to: (a) signal/kill every process tied
  to a single run without touching others, (b) attribute every reaped pid to
  the run that owned it, (c) sustain concurrent runs later without touching
  this code again.
- Net deletion: `lib/Test2/Harness2/RunService.pm` (1221 lines), the
  `run-$run_id` IPC bus, `_wait_for_run_service_ready`, the lazy run-service
  spawn handshake, `RUN_SERVICES` tracking.

## Non-goals

- Concurrent runs are NOT enabled in this plan. The bookkeeping must support
  it; the scheduler still walks the queue head serially. Flipping the switch
  is a follow-up (single-line change to `_try_launch_next_pending` selection).
- No changes to Collector internals, fork/exec path, event framing, or
  on-disk schema beyond the `runs/<id>/services/run.jsonl` decision below.
- No changes to the preload-as-resource model. Once preload services land,
  they spawn under harness like any other resource service.

## Final architecture (target state)

- Harness owns:
  - `RESOURCES` (today) + per-run resources spawned via
    `start_resource_services(... scope => 'run', run => $run)` (the role
    already supports this; only the host gains a second scope).
  - `RUN_STATES` (today, but populated directly instead of via IPC mirror).
  - `RUNNING_JOBS` (today) plus a new `RUN_PIDS` map: `run_id → { pid → meta }`.
  - All collector spawning. The Collector ipc_parent is the harness's own
    bus name; auditor target is the harness.
  - All reaping via `run_on_pid`, with attribution to a run via `RUN_PIDS`.
  - Watchdog (`pending_synth_completions`) keyed by run_id.
  - Run-level event emission: `run_queued`, `run_started`, `run_failing`,
    `run_completed`, `job_started`, `job_completed`. All flow through
    `emit_service_event` on the harness bus.

- Removed: `Test2::Harness2::RunService`, `RUN_SERVICES`, the `run-$run_id`
  bus, `_ensure_run_service_started`, `_run_service_handle`,
  `_wait_for_run_service_ready`, `_teardown_run_service`,
  `YATH_RUN_SERVICE_READY_TIMEOUT`, the orphan-test branch in `run_on_pid`
  (becomes the normal collector-exit branch).

## Multi-run readiness (the key design point)

Single new structure on the harness, indexed by run_id at the top:

```perl
RUN_PIDS => {
    $run_id => {
        $pid => {
            kind     => 'collector' | 'resource_service',
            job_id   => $job_id,           # collector only
            job_try  => $job_try,          # collector only
            res_name => $resource_name,    # resource_service only
            res_svc  => $service_name,     # resource_service only
            started_at => $time,
        },
    },
}
```

Every spawn (collector or resource service) registers into this map under
its run_id (or under a synthetic `__global__` key for global resource
services). Every reap looks up by pid here first to attribute the exit.

Helpers (new, on `Test2::Harness2`):

- `_register_run_pid($run_id, $pid, %meta)`
- `_forget_run_pid($run_id, $pid)` (returns the meta entry)
- `_run_for_pid($pid)` → `($run_id, \%meta)` or `(undef)`
- `_pids_for_run($run_id)` → list of pids
- `_kill_run($run_id, $signal)` — `kill $signal => @pids` for that run only
- `_await_run_exit($run_id, $deadline)` — block-with-timeout for all pids in
  the run to leave `RUN_PIDS` (called from per-run teardown / hard-stop)

`hard_stop_pids` (already in `Harness2.pm:1013`) folds in: union all
collectors in `RUNNING_JOBS` + all entries from `RUN_PIDS` + global resource
services. A single dedup keeps it correct.

This is the bookkeeping concurrent runs will need. We build it now, use it
for serial runs to prove it works, and the concurrent-runs follow-up is then
purely about lifting the queue-head-only restriction in
`_try_launch_next_pending` (`Harness2.pm:1316`).

## Stages

Each stage is a single commit, leaves the suite green, and is independently
revertable. Tests are run with
`AUTHOR_TESTING=1 perl -Ilib scripts/yath test -D -j24 [files]`.

### Stage 0 — branch + safety net

- New worktree under `.claude/worktrees/flatten-run-service/`, branch
  `flatten-run-service` off `2.0`.
- Mirror `.claude/` per CLAUDE.md "Worktree Config Inheritance" snippet.
- Establish baseline: full `t/AI/` suite passes on the branch starting point.
- Capture a few `yath test ... --keep-dirs` log dirs from the baseline for
  later replay-compatibility checks.

Commit: `chore: branch baseline before RunService flatten`

### Stage 1 — `RUN_PIDS` bookkeeping (additive, no behavior change)

Add the new map and helpers listed above. Do not reroute anything yet — just
mirror existing tracking into the new structure so we can audit it.

Sites that must register/forget into `RUN_PIDS`:

- `_launch_job` (`Harness2.pm:1691`) — register the collector pid returned
  in the launch_job IPC response under the run_id.
- `_ensure_run_service_started` (`Harness2.pm:1583`) — register the
  RunService pid itself for the duration this stage exists; this entry will
  vanish in Stage 9 along with RunService. Tag `kind => 'run_service'`.
- `start_resource_services` callbacks (the harness's own
  `track_resource_service` path via `Role::ResourceServiceHost`) — register
  global resource services under the synthetic `__global__` key.
- `run_on_pid` (`Harness2.pm:1064`) — call `_forget_run_pid` for every
  branch (run-service exit, orphan-test exit, resource-service exit).

Tests:

- `t/AI/unit/Harness2/run_pids.t` (new) — direct tests of register/forget,
  `_pids_for_run`, `_kill_run`, dedup with `RUNNING_JOBS`.
- Existing harness/integration tests must continue to pass unchanged.

Commit: `feat(Harness2): per-run pid bookkeeping (no behavior change)`

### Stage 2 — `start_resource_services` becomes multi-scope-capable

Current state: `Test2::Harness2` has `service_host_scope => 'global'`,
`service_host_run => undef` (`Harness2.pm:80-81`). RunService has
`'run'` + the bound run object. The role's reservation logic in
`_assert_service_name_unused`
(`lib/Test2/Harness2/Role/ResourceServiceHost.pm:202`) keys reservations off
`(host_scope, host_run)`.

Required changes to the role:

- Allow a host with `service_host_scope => 'global'` to call
  `start_resource_services(scope => 'run', run => $run)`.
- The reservation rule "name X reserved by host's own log" only applies in
  the host's own scope; cross-scope calls already pass through. Still need
  to verify `_assert_service_name_unused` accepts the cross-scope case
  (read the role through carefully — minor edit if any).
- `_resource_service_log_path` already chooses `runs/<run_id>/services/<name>`
  vs `services/<name>` from the per-call `scope` arg, not from
  `service_host_scope`. No change needed there.

Required changes to `handle_resource_service_exit` consumer side: the role's
`resource_services` hash entries are tagged with `scope` and `run`; the
exit handler in harness will key off those to update the right `Run::State`
when a per-run resource flips broken.

Tests:

- `t/AI/unit/Role/ResourceServiceHost/multi_scope.t` (new) — one host,
  global + per-run resources side by side, name collisions across scopes
  permitted, name collisions within a scope rejected.

Commit: `feat(Role::ResourceServiceHost): allow one host across scopes`

### Stage 3 — Harness spawns per-run resource services directly

Move the body of `RunService::service_on_start`'s
`start_resource_services(... scope => 'run', run => $run)` call
(`RunService.pm:378-380`) into `Harness2.pm`'s
`_ensure_run_service_started`. Order: harness spawns the per-run resource
services first, *then* delegates to RunService for collector launches.

At this stage RunService still exists and still spawns collectors. The only
change is who hosts the per-run resource services. RunService stops calling
`start_resource_services` for `scope=>'run'`.

Cross-cutting:

- Per-run resource services now register into `RUN_PIDS` under the run_id
  (Stage 1 already wired the registration callback, just confirm it fires
  for both global and run scopes).
- `_teardown_run_service` (`Harness2.pm:1660`) gains a per-run resource
  teardown step: walk the run's resource services and TERM them, then await.
  Today RunService does this in its own `run_on_cleanup`.
- `hard_stop_pids` (`Harness2.pm:1013`) gets the per-run resource services
  via `RUN_PIDS` for free.

Tests:

- Existing per-run resource integration tests pass without modification.
- `t/AI/integration/resource_per_run_under_harness.t` (new) — verify the
  per-run resource service is parented by harness pid (`getppid` from the
  service prints harness pid), survives RunService crash, is killed when
  the run ends.

Commit: `refactor(Harness2): host per-run resource services on harness`

### Stage 4 — Move event handlers + Run::State mutations into Harness

Today:
- `_handle_gen_msg_test_job_started/diagnosing/failing/completed` live in
  RunService (`RunService.pm:507-721`).
- They mutate the RunService-owned `Run::State` and emit events into
  `runs/<run_id>/services/run.jsonl` via the RunService `EMITTER` slot
  (`RunService.pm:43, 1020`).
- A `run_state_update` IPC then fans the new state to harness, which mirrors
  it into `RUN_STATES` (`Harness2.pm:884-905`) and re-broadcasts on its bus
  for external subscribers (`Harness2.pm:707-740`).

After this stage:
- **Auditor target flip (must not be missed).** The Collector spawn args
  in `RunService::request_handler_launch_job` (`RunService.pm:177-285`)
  pass an `auditor` field naming the **RunService bus** (`run-$run_id`).
  When the spawn moves into harness in Stage 5, this field MUST become the
  harness bus name. Do the flip in this stage as part of the handler move,
  even though the spawn site itself moves in Stage 5: the inbound route
  for `test_job_*` messages must already point at harness when those
  handlers start firing on harness. If this is missed, the harness never
  sees `test_job_completed`, every test triggers a watchdog synth
  completion (Stage 6 logic), and runs appear to "complete" with all-
  fail verdicts. Symptom is silent and uniform — easy to miss in a quick
  smoke. Gate Stage 4 with a green run that asserts `pass_count > 0` for
  a known-passing test.
- The four event handlers move verbatim from `RunService.pm` to `Harness2.pm`.
  They mutate `RUN_STATES->{$run_id}` directly. Each one ends with a call to
  the existing fan-out emitter that puts a `run_state_update` envelope on
  the harness bus for external subscribers (preserve the message — gemini's
  audit explicitly flags this risk).
- **Per-run EventEmitter map.** RunService had a single `EMITTER` slot
  bound to its own `runs/<run_id>/services/run.jsonl` log
  (`RunService.pm:43, 1020`, used at `:597, 620, 636, 736, 834, 989`).
  Harness now writes to multiple per-run logs in the same process, so add
  `RUN_EMITTERS => { $run_id => $emitter }` on harness, populated at run
  enqueue / first-event-for-run, torn down in `_teardown_run_service`
  successor (Stage 8). All moved handlers + the `_emit_run_log_event`
  helper take `run_id` as input and look up the emitter by key.
  **This map exists only between Stage 4 and Stage 7.** Stage 7 drops
  the per-run `run.jsonl` artifact entirely; events flow through the
  single harness emitter tagged with `run_id`, and `RUN_EMITTERS` goes
  away with the per-run file.
- The `run_state_update` IPC handler (`Harness2.pm:884`) becomes
  unreachable from RunService (since RunService no longer originates it),
  but stays in place for now to absorb any in-flight messages during
  rollout. Gets deleted in Stage 9.

Cross-cutting:

- The `_emit_run_log_event` helper (`RunService.pm:733`) moves to harness
  alongside the handlers; in Stage 4 it writes via the per-run emitter map
  above; in Stage 7 it folds into `emit_service_event` on the single
  harness emitter (with `run_id` in the payload).
- `run_failing` first-fail latch logic (`RunService.pm:560-589`) moves
  intact into harness; the latch lives on `RUN_STATES->{$run_id}`, not on
  a global, so multi-run safety is automatic.
- Per-job `completed_job_states` cache (`RunService.pm:41`) moves to
  harness, keyed by `(run_id, job_id)`.

Tests:

- Existing job lifecycle tests must keep passing (they're behavior tests).
- `t/AI/integration/external_run_state_subscriber.t` (new) — spawn a
  passive IPC subscriber to the harness bus, run a small test set, assert
  one `run_state_update` per state-changing event, with correct payload.

Commit: `refactor(Harness2): own Run::State mutations + auditor target`

### Stage 5 — Inline `launch_job`

Replace the sync IPC call in `_launch_job` (`Harness2.pm:1734-1750`) with a
direct call to a new private method `_spawn_collector_for_job($run, $job, %args)`
that encapsulates exactly what `RunService::request_handler_launch_job`
(`RunService.pm:177-285`) does:

- Resolve the launch command (default `perl -Ilib $test_file_abs` or the
  caller-supplied override).
- Build the Collector with `ipc_parent => $self->name` (harness bus),
  `ipc_run` likewise, `auditor => $self->name`, the env hash, log paths.
- Call `Test2::Harness2::Collector->spawn(...)`. Returns
  `(collector_pid, log_file)`.
- Register the collector pid into `RUNNING_JOBS` and `RUN_PIDS`
  (`kind => 'collector'`).

`_launch_job` no longer needs `_wait_for_run_service_ready` for this path.
The lazy-spawn block in `_ensure_run_service_started` (Stage 3 already moved
its resource bits over) still runs RunService for collector ownership in
this stage if you take it incrementally; the cleanest cutover does the
collector-ownership move in this same stage and reduces RunService to a
no-op shell that we delete in Stage 9. **Recommendation: do it in one stage.**

Cross-cutting:

- Collector's `become_sub_reaper`/parentage moves: the test process becomes
  a grandchild of harness. Verify on Linux (sub_reaper) and confirm graceful
  fallback on platforms without `prctl(PR_SET_CHILD_SUBREAPER)`.
- `RUNNING_JOBS->{$job_id}{pid}` is now the *collector* pid, same as before
  — no change to consumers.
- The `auditor` arg to `Collector->spawn` here is the harness bus name (the
  Stage 4 flip already pre-positioned the handlers; this stage closes the
  loop by stopping spawn at the harness with the matching target).
- The "orphan test pid" branch in `run_on_pid` (`Harness2.pm:1086-1122`)
  becomes the *normal* collector-exit branch. It already does the right
  thing (release resources, mark done, stamp synth completion, finalize
  run). Promote the warning to debug-only, drop the "its run service died"
  wording.
- Drop the run-service exit branch in `run_on_pid` (`Harness2.pm:1072-1077`).

Tests:

- Full `t/AI/` suite must pass. This is the highest-blast-radius stage.
- Run a manual `yath test` on at least 50 mixed pass/fail/skip tests with
  `-j24` and `-j1`, then with `--retry`, then with a per-run resource that
  blocks/unblocks slots, then with `--keep-dirs` and replay the artifact.

Commit: `refactor(Harness2): inline launch_job, drop run-service spawn`

### Stage 6 — Watchdog consolidation

Move `pending_synth_completions` (`RunService.pm:42, 117`) and the grace-timer
logic in `run_on_interval` (`RunService.pm:435-483`) into harness's
`run_on_interval`. Keys become `(run_id, job_id)` tuples. Iterate all runs
each tick (cheap; scales with active job count, not with run count).

Synthesis path: when a collector pid exits via `run_on_pid` *without* a
prior `test_job_completed`, arm an entry. After the grace window, emit a
synthesized `test_job_completed` into the same handler chain Stage 4 added.

Tests:

- `t/AI/integration/collector_kill_dash9.t` — `kill -KILL` a collector mid
  test, verify run finishes with the job marked failed via synth completion,
  and that exit math accounts for it.

Commit: `refactor(Harness2): own collector watchdog + synth completion`

### Stage 7 — Per-run event log decision

User direction: `runs/<run_id>/services/run.jsonl` events stream goes away.
Run-level lifecycle events (`run_queued`, `run_started`, `run_failing`,
`run_completed`, `job_started`, `job_completed`) flow through the regular
harness event log only, tagged with `run_id`.

Changes:

- Drop the interpose call in RunService that creates `run.jsonl`
  (`RunService.pm:1033-1052`) — already gone if Stage 5 deleted RunService;
  if not, drop here.
- `_emit_run_log_event` (moved in Stage 4) writes only to the harness
  service event stream.
- Replay/log-iter code: any path that opens `runs/<id>/services/run.jsonl`
  must tolerate it being absent for newly produced logs and present for
  legacy logs. Audit:
  - `lib/Test2/Harness2/LogLayout.pm`
  - `lib/Test2/Harness2/Collector.pm` (interpose chain)
  - `lib/App/Yath2/Command/replay.pm`
  - `lib/App/Yath2/Command/extract.pm`
  - `lib/App/Yath2/Renderer/*`
- For each, either filter harness events by run_id at read time or keep the
  legacy path active when the file exists.

Tests:

- `t/AI/integration/replay_legacy_log.t` — checks that a captured
  pre-flatten log dir still replays.
- Existing renderer tests rerun against new logs to confirm they reconstruct
  per-run views from harness-bus events alone.

Commit: `refactor: drop per-run events stream, route via harness bus`

### Stage 8 — Tear-down + lifecycle simplification

- Replace `_teardown_run_service` body (`Harness2.pm:1660-1689`) with:
  per-run resource service TERM via `_kill_run($run_id, 'TERM')`, await
  exit via `_await_run_exit($run_id, $deadline)` with the existing
  `kill_timeout`. No more SIGTERM-to-RunService dance.
- `run_on_cleanup` (`Harness2.pm:1160`) drops the `_teardown_run_service`
  loop and replaces it with a per-leftover-run resource teardown.
- `run_should_end` (`Harness2.pm:1133`) — already correct; revisit only to
  ensure it considers `RUN_PIDS` not just `RUNNING_JOBS` for the
  per-run-resource-services edge case.
- Drop `RUN_SERVICES` field, the `run-$run_id` bus name, and the cached
  `_handle` from the run-services entry.

Commit: `refactor(Harness2): per-run teardown via RUN_PIDS`

### Stage 9 — Delete RunService

Remove:

- `lib/Test2/Harness2/RunService.pm`
- `_ensure_run_service_started`, `_run_service_handle`,
  `_wait_for_run_service_ready`, `_teardown_run_service` (now empty/dead)
- `RUN_SERVICES` HashBase field
- `_handle_run_state_update` (`Harness2.pm:884`) — no inbound
  `run_state_update` messages anymore
- `YATH_RUN_SERVICE_READY_TIMEOUT` env var
- The orphan-test "its run service died" warning text
- Any `Test2::Harness2::RunService` references in:
  - `lib/Test2/Harness2.pm`
  - `lib/Test2/Harness2/LogLayout.pm`
  - `lib/App/Yath2/**`
  - `t/**` (move tests under `t/AI/` if AI-edited beyond trivial)
- `cpanfile` / dist metadata: nothing to drop (RunService had no unique deps).

Tests:

- Full `t/AI/` suite + author tests + a `prove -r t/` for the human-authored
  side. `AUTHOR_TESTING=1` everywhere.

Commit: `refactor(Harness2): remove RunService`

### Stage 10 — Docs + cleanup

- Update `ARCHITECTURE.md`:
  - Part I: rewrite the "process topology" + "run service lifecycle"
    sections to reflect single-service model.
  - Append an addendum section at the bottom explaining the deviation
    rationale (per CLAUDE.md rule).
- Update `PLAN` if it still references RunService stages.
- Add this AI_DOC's path to any RESUME files in `docs/superpowers/plans/`
  that referenced the old design (`2026-04-23-run-service-aggregation-RESUME.md`).
- Run `perltidy` on every file touched in stages 1-9.
- Remove `do_we_need_run_service` scratch file from the repo root (or
  archive into `AI_DOCS/` if the framing is worth keeping).

Commit: `docs: update ARCHITECTURE for single-service flattening`

## Cross-cutting risks (audit checklist before each merge to 2.0)

These are the items where mistakes are silent. Verify explicitly.

1. **`run_state_update` broadcast preservation.** Bus subscribers (UI,
   replay drivers, external observers) currently get one update per state
   change. After Stage 4, harness must still emit them — they just no longer
   originate from RunService. Test with a passive subscriber.
2. **Auditor address.** Today the Collector's auditor field points at the
   RunService bus name. Must flip to the harness bus name in Stage 5. Easy
   to miss; the symptom is silent loss of `test_job_completed` events,
   which then trigger watchdog synth completions for every test.
3. **Sub-reaper invariant.** Harness must keep `become_sub_reaper => 1`
   (already set in `Test2::Harness2`). On platforms without `PR_SET_CHILD_SUBREAPER`
   (BSDs, macOS), reparenting falls back to init — orphans become unreapable.
   Check existing per-platform handling in `Role::Service`.
4. **Reaping zombie risk.** Harness `run_on_pid` is now the single point
   of attribution for *every* exit. Any pid we forgot to register into
   `RUN_PIDS` becomes a "fall through to handle_resource_service_exit" — and
   if it isn't a resource service either, it silently disappears. Add an
   assertion in non-prod builds that every reaped pid was attributable.
5. **Hard-stop blast radius.** With one process owning everything, a
   runaway hard-stop affects all in-flight runs. Verify that `_kill_run`
   targets only the requested run's pids, and that `hard_stop_pids` (the
   nuclear path) is only triggered from the cleanup path, not from per-run
   teardown.
6. **Concurrency regression hidden by serial execution.** Even with one
   run active at a time, the harness loop now does work it used to delegate.
   Watch scheduler tick latency (it was: pick + sync_request roundtrip;
   becomes: pick + fork). Forks are cheap; should be a net win, but profile
   a `-j24` run before/after.
7. **Forked-child env hygiene.** Harness now forks Collectors directly.
   Any global state (open file handles, signal handlers, IPC sockets) that
   should not survive the fork must be cleaned up in the child before
   `exec`. Audit `Collector._launch_child_unix` (`Collector.pm:1083-1103`)
   for completeness — likely already correct since RunService used the same
   path, but confirm.
8. **`run_started`/`run_queued` ordering.** RunService emitted `run_queued`
   in `init` and `run_started` in `service_on_start`. The natural harness
   equivalents are: `run_queued` when the run is enqueued, `run_started`
   when the first job is dispatched. Renderers depend on seeing
   `run_queued` before any `job_*` event for that run.
9. **Multi-run pid attribution under sub-reaper.** When Run A's preload
   service double-forks an escapee that drifts up to harness, attribution
   must use the spawning service's `run_id`, not the closest still-living
   ancestor. `RUN_PIDS` lookup by pid handles this if registration is
   complete; the only failure mode is genuine third-party orphans, which
   should warn and be reaped silently.
10. **Replay compatibility.** Stage 7 changes the on-disk shape (no
    `run.jsonl`). Captured logs from before the cutover must still replay.
    Keep the read path forgiving; do not delete the legacy reader code.
11. **Sticky `permanent_broken` across scopes.** `is_permanent_broken` lives
    on the Resource object itself
    (`lib/Test2/Harness2/Role/Resource.pm:34, 53`,
    flipped via `mark_permanent_broken` in
    `Role/ResourceServiceHost.pm:344, 447, 467`). The flag is sticky —
    once set, no resource_ready or restart event clears it. After
    flattening, the harness hosts both global and per-run resource
    services; key the `resource_services` tracking entry on
    `(scope, run_id, name)` (the role already records `scope` + `run`,
    `Role/ResourceServiceHost.pm:227-231`) so that:
    - A resource_ready / restart for a per-run service updates only that
      scope's tracking entry, never reaches across to clear a global
      object's broken flag (or vice versa).
    - If the same resource object is referenced from both scopes (rare
      but possible), respawning its per-run service does NOT call
      `mark_unbroken` or any equivalent on the shared object — the
      stickiness must hold even when the scope that broke it is not the
      scope that's restarting. There is no `mark_unbroken` today; ensure
      no new code path adds one as part of this work.
    Add a regression test
    (`t/AI/integration/permanent_broken_scope_isolation.t`) that breaks a
    global resource, starts a per-run resource of the same class, and
    asserts the global one stays broken.

## Test strategy

- Per-stage gate: `AUTHOR_TESTING=1 perl -Ilib scripts/yath test -D -j24`
  against `t/AI/` plus any unit tests added in that stage.
- Cumulative gate before each merge: full `t/` plus a manual smoke run of
  `yath test t/AI/integration/ -j1`, `-j24`, `--retry`, `--keep-dirs` then
  `yath replay`, and `yath extract`.
- Pre-Stage-10 gate: a "concurrent runs" smoke that today is impossible
  (because the queue serializes) but exercises the bookkeeping by
  programmatically forcing two runs into `_try_launch_next_pending`'s
  consideration in a unit test. This validates `RUN_PIDS` keys, isolation
  of `_kill_run`, and per-run teardown without enabling concurrent runs in
  product code.
- New tests, all under `t/AI/`:
  - `unit/Harness2/run_pids.t` (Stage 1)
  - `unit/Role/ResourceServiceHost/multi_scope.t` (Stage 2)
  - `integration/resource_per_run_under_harness.t` (Stage 3)
  - `integration/external_run_state_subscriber.t` (Stage 4)
  - `integration/collector_kill_dash9.t` (Stage 6)
  - `integration/replay_legacy_log.t` (Stage 7)
  - `integration/permanent_broken_scope_isolation.t` (Stage 3 or later)
  - `integration/multi_run_pid_isolation.t` (pre-Stage-10)

## Cutover / rollback

- Each stage is its own commit. Rollback = `git revert` of the offending
  commit; the next stage assumes the prior stage's invariants but does not
  cross-depend on its specific implementation, so reverts are local.
- The risky cliffs are Stages 4 and 5. Tag commits there
  (`pre-stage-4-flatten`, `pre-stage-5-flatten`) for fast rollback during
  bake-in.
- Bake on `flatten-run-service` branch for at least one full author-test
  cycle before merging to `2.0`. Run the integration suite under load
  (`-j24` on a moderately busy machine) and on at least one CI run.

## Estimated impact

- Lines removed: ~1200 (RunService) + ~150 (harness IPC plumbing for run
  service spawn/wait/teardown).
- Lines added: ~250 (RUN_PIDS bookkeeping + helpers + multi-scope role
  tweak + watchdog migration into harness + per-run teardown).
- Net: ~1100 fewer lines, one fewer process per run, one fewer IPC bus,
  one fewer sync request on the test-launch hot path.

## Follow-up (out of scope here)

- Enable concurrent runs: change the queue-head-only restriction in
  `_try_launch_next_pending` (`Harness2.pm:1316`) to round-robin across
  active runs (or pick any non-blocked run). Resource arbitration already
  spans all runs because resources live in harness.
- Land the preload-as-resource service. Once landed, the parentage story
  is uniform: preload is a resource service under harness; tests it spawns
  reparent to harness via sub-reaper just like collector children do today.
