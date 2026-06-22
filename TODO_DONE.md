# TODO_DONE.md — Completed tickets

Tickets from `TODO_TASKS.md` that have landed, with review notes. Each entry: what
was done, commit(s), test result, and anything the implementer flagged for review.

Newest first.

---

## #29 — Collapse to one run path; run_scheduler_only is the runner's only loop — DONE

The runner's no-preload and preload runs converge onto a single loop. Designed via a
map+design+adversarial-review workflow (the naive plan had real blockers -- deleting
run_stage drops stage_ready('default') => the no-preload run hangs; the discriminator
must key on the preload flag, not live-peer presence; orphaned/HUP/spawn must be
ported). Landed green-first in 4 commits:

- **`5729726d9`** -- extract `_launch_local_job` from `run_job` (single local-launch
  impl, `$task->{via}` preserved); reject a no-preload spawn at queue time
  (`request_handler_queue_spawn`) -- a spawn needs a real preload stage, and once
  `run_job` is gone an accepted no-preload spawn would sit unran in PENDING_SPAWNS.
- **`2f186de4d`** -- port the no-preload run-loop duties into `run_scheduler_only`,
  no-preload-scoped: `stage_ready('default')` (else nothing schedules -> hang),
  `orphaned`=>TERM / `preloader->check`=>HUP (from end_test_loop), killall + wait at
  wind-down to reap the runner's own forked collectors.
- **`371c82eab`** -- `t/AI/integration/no_preload_scheduler.t`, a real no-preload run
  e2e guard (the M3 reap test stubs the scheduler, so it would not catch a stage_ready
  omission).
- **`f7e836182`** -- the collapse: `process` -> `run_scheduler_only` directly;
  `dispatch_pending` takes every started task and branches once on
  `_preload_root_hosts_stages` (service_send vs `_launch_local_job`); delete
  `run_tests`/`run_stage`/`run_job`/`end_test_loop` (net -96 lines).

**Key decision:** a no-preload collector stays a WATCHED runner child (reaped via
`set_proc_exit` with job_id known) rather than detaching -- simpler, and completion
still rides EOF; only preload collectors detach (#28). The discriminator keys on the
preload flag (NOT live-peer presence) so a transiently-disconnected preload stage still
requeues (§4.7a). The cosmetic `_has_preload_root` rename was deliberately SKIPPED
(`_preload_root_hosts_stages` is still accurate; not worth churning the file). Updated
tests: `Runner_dispatch_abort.t` (preload + new no-preload arm), `Runner_orphan.t`
(end_test_loop subtest dropped; orphaned() still unit-tested), `Runner_queue_spawn_handler.t`
(no-preload reject). Completes the #22 residual + #4 Part 4 + #8 Part 4.

Verified: prove -j16 3× (119 files, 1803 tests, 0 silence-timeouts) + yath test -D (120)
green; no leaked/zombie runner/collector processes after a no-preload AND a preload run.
Preload::Host (a sibling IPC class with its OWN run_tests/run_stage/run_job) untouched.

---

## #28 — Runner child-subreaper + detached collector reap, now WORKING (C1/C2/M3) — DONE

The original #28 code (subreaper + double-fork/detach, `7952029e6`..`ab1a95865`) was
DEAD on the preload path (re-audit finding). Fixed standalone — `run_scheduler_only`
now actually reaps the detached collectors and runs A3:
- **C2 (`def11c2fe`)** — pid-keyed `collector_reap` map set at the pass decision
  (`decide_collector_outcome`), survives the collector's EOF (which clears `job_pids`,
  the status map), consumed by `_reaped_unwatched_pid` by pid (try-safe), swept at run
  end. The reverse-scan-of-`job_pids` (which the EOF had already emptied) is gone.
- **C1 (`f03ff402c`)** — `run_scheduler_only` calls `_bring_out_yer_dead` +
  `_check_if_dead_yet` each tick and at wind-down. Guard: `_bring_out_yer_dead`'s
  `waitpid(-1)` can reap the preload-root before `_preload_root_dead`'s targeted
  `waitpid`; it now flags `PRELOAD_ROOT_REAPED` so a mid-run root crash is still
  detected (verified: `preload_root_crash.t` / `preload_root_kill_midrun.t` still pass).
- **M3 (`7e5394bc0`)** — `t/AI/integration/Runner_scheduler_reap_a3.t` drives the REAL
  loop (only socket/scheduler I/O stubbed): an unwatched detached child is reaped, a
  post-pass non-zero health exit fires A3, a clean exit does not. This is the coverage
  the prior helper-only unit test lacked (it green-lit code that never ran).

Both runners green (`prove` 118 files / 1801 tests, `yath test -D` 119). The decision
to keep no-preload collectors WATCHED (not detached) is recorded in #29's design — the
chunk-26 collapse no longer carries any #28 work.

---

## Re-audit follow-ups (2026-06-21) — post-effort-raise recheck of the day's commits

A multi-agent re-audit (the user raised the effort level mid-session and asked for a
recheck of all of today's commits) plus a clean bisect. Most of the day's work verified
correct at HEAD; the findings that needed action:

- **#27 silence-timeout flake — FIXED (`6827decca`).** Bisected to the first #27 commit
  (`472946279`): it flipped `no_reply` OFF for `read_control` reporters, so the runner
  echoed its identity back to every test-job collector. Under `prove -j16` the write-back
  to a collector busy draining its child stalls the runner's single-threaded loop ⇒ a 60s
  collector silence-timeout kills an otherwise-instant preloaded test (`preload/slow.tx`),
  ~60% of full runs. Pre-#27 (`5edf2ab20`) 3/3 clean; fixed HEAD 6/6 clean. Fix: `no_reply`
  and `read_control` are orthogonal — set `no_reply` always; terminate rides the separate
  `send_control`. `IPC.md` reconciled.
- **#27-2b late-connect orphan — FIXED (`fb8496c86`).** `_enforce_collector_connect_timeout`
  failed a never-connected job but recorded no intent, so a collector that connected
  *after* its slot was reclaimed orphaned its test child (the block comment falsely claimed
  it was torn down). Added a per-job `terminated_jobs` intent; `service_identified` tears
  down a late collector for that job+try; `announce_run` sweeps at run end. Per-job, not
  run-scoped (the run continues; a retry is spared). Tests added.
- **style-purge `backstop` survivor — FIXED (`fc9904e98`).** `954f6476d` banned the term
  but left `startup_timeout_backstop` at `Resource_Preload.t:91`; renamed `_safeguard`.

**#28 (chunk 25) — code landed but DEAD on the preload path; NOT done; fix folded into
#29.** The runner's `_bring_out_yer_dead` override is unreachable on the preload path
(`run_scheduler_only` never calls `wait()`; PROCS empty) ⇒ detached collectors are never
reaped and A3 never fires (C1); and `collector_conn_eof` deletes `job_pids` before the
reap so the A3 reverse-map can't match (C2). The unit test only drives the helper, masking
both. SubReaper.pm itself is correct. Fix plan: TODO_TASKS #28/#29.

---

## #27 — Transition-driven test completion (the §5.4 core) — DONE (3 agent phases)

The crux rewrite: a test's verdict now comes from its collector's socket transitions
+ connection EOF, never the reaped exit code. Three phases, each integrated on 2.0d
and verified green at the canonical `-j16` (final: `prove` 1780, `yath test -D` 1786).

**Phase 1 — collector additive (Test2-Collector `5c3ada3b`, installed, no version bump).**
Early `halt`/bail transition (`harness_state_transition {state=>'halt', details, stamp}`,
before `completed`/`final_state`); bidirectional reporter connection — the collector
reads inbound `control` frames when built `read_control=>1` and on `{control=>{control
=>'terminate', reason}}` kills its child + records a `harness_terminated` events-file
event + exits health-only → EOF (NO `final_state`); collector pid added to the
`starting` transition. All additive/dormant — harness stayed green.

**Phase 2a — harness completion core (`472946279`..`13c6f8b00`).** Reporter built
`read_control` + carries `job_id`/`job_try`/`run_id`; `Connection` stores the full
identity; runner registers a `conn→job` map. **EOF-driven decision** (`collector_conn_eof`,
draining frames first): `final_state` pass→pass / fail→retry-if-tries / `halt`→bail;
absent→fail (aborted if deliberately terminated, else possible-harness-internal).
**Fire-once** via a shared `(job_id,job_try)` `decided_jobs` ledger consulted by both
the EOF path and the watchdog; **stale-try guard** via `collector_current_try`. Bail:
on a `halt` for run X, stop dispatch + `terminate` every run-X collector + terminate
late-connecters (`bail_runs` intent); halt wins over retry. Removed the reap-driven
retry/stop/bail from `Runner`+`Preload::Host` `set_proc_exit` (reap = zombie-only);
deleted `Job::_collector_exit_code` + `bail_file` + `bailed_out`; test-job parent exits
via the collector's health-only `spawn_exit_code` (`Util::collector_exit_code` kept for
non-test wraps); dropped `StageDelegate`/`Client` verdict reporting. No-verdict render
mutation (terminal `harness_runner_job` aborted/failed, reason = harness output).

**Phase 2b — abort/terminate + reporter guards (`dba86899e`..`5dbfab743`).** `yath abort`
+ owner-disconnect now route through the terminate primitive (`aborting_runs` intent +
`abort_run_collectors` + terminate-on-late-connect + a `_enforce_terminate_grace`
`kill(-pid)` hard-kill fallback) — **fixes B3** (owner-disconnect left processes alive)
and **B4** (the abort/pid-snapshot race). Mandatory reporter: `run_under_collector`
fails the job if the required reporter can't connect; new `--collector-connect-timeout`
(on, 30s) fails a dispatched job whose collector never connects (the no-EOF→hang guard),
enforced per scheduler tick. Post-pass collector failure (A3): a non-zero **health** exit
after a recorded pass keeps the test green but emits `announce_run_health` → the suite
is flagged failed at command exit (runner-reaped/no-preload path now; preload covered
once #28 reparents).

**Notes for #28/#29:** the `kill(-pid)` hard-kill fallback needs detached preload
collectors to `setsid` (#28). A3 currently only fires on the runner-reaped path; #28's
subreaper reparenting will extend it to preload collectors (the `job_passed` ledger +
`announce_run_health` are path-agnostic). **Correction (2026-06-21 re-audit):** the
`-j16` silence-timeout flake first dismissed as concurrent-machine-load was in fact a
**#27 code regression** (the `read_control` reporter dropped `no_reply`, so the runner's
identity echo wedged its single-threaded loop) — fixed in `6827decca`; see the re-audit
section at the top of this file.

---

## Batch (2026-06-21) — review-driven fixes #32–#37 (parallel agents, integrated on 2.0d)

Six tickets from the two-reviewer pass, run as 3 parallel worktree agents and
cherry-picked onto 2.0d; combined suite green at each integration (final: `prove`
1769, `yath test -D` PASSED). All AGENTS.md audits + `podchecker` clean per agent.

- **#32 (`3dde68850`) — fd hygiene (core).** `Util::IPC::set_cloexec`; `FD_CLOEXEC`
  on every harness socket (listen, peer connect, accepted, collector reporter via the
  recorder's `connections` accessor); `Role::Service::close_all_connections`
  post-fork close-sweep wired into both no-exec forks (`JobLauncher::launch_via_fork`
  collector parent + `cleanup_process` goto::file child, which also closes the
  inherited reporter sockets stashed on the job). Test `Role_Service_fd_hygiene.t`.
  **No Test2-Collector change needed.** Mandatory-reporter + `--collector-connect-timeout`
  deferred to #27.
- **#37 (`e29259adc`) — doc.** Comment at the resource-skip `-e` assembly in
  `Job::collector_target`.
- **#36 (`4403aa4c0`) — delete dead `reset_stage_readiness`** + its test subtest
  (re-verified zero production callers).
- **#35 (`e4e64f6b8`) — `TASK_LOOKUP` leak.** `_drop_run_task_lookup` from `halt_run`
  + `purge_run`; `State_run_retention.t` asserts removal.
- **#33 (`1b0a1312b`) — enforce `preload_stage_startup_timeout`.** Per-tick
  `_expire_stale_stages` in `advance` demotes a timed-out `starting`/`restarting`
  stage to `down`, **plus `_rebucket_stage_tasks`** (demotion alone strands tasks
  already bucketed under the stage — `_next` only walks `up` buckets) drains the
  bucket back through `task_pending_lookup` so `task_stage` re-resolves (advisory→default,
  required→`resource_skip`). Integration test `scheduler_stage_startup_timeout.t`.
  (Fixes the inert #21 safeguard.)
- **#34 (`0b659a90f`) — `yath reload` during a preload run.** HUP routes a
  `reload_root` request to the base/default stage's **live** channel (peer matched by
  `peer_pid == PRELOAD_ROOT_PID`); `Preload::Host::request_handler_reload_root` sets a
  `pending_reload` → `longjump 'preload-root' 'respawn'` at stage end; a queued `stop`
  drops the pending reload (no re-exec mid-shutdown). Removed the unreachable
  `Preload::request_handler_reload`. `IPC.md` updated. Tests
  `Runner_reload_routing.t` + `reload_command_respawn.t`.

**Flags for later (pre-existing, not from this batch):** `State.pm` 1257 LOC + `_next`
93 lines (over thresholds); `Runner.pm` 1296 LOC + `run_scheduler_only` 79 lines.
`reload_command_respawn.t` uses a fixed `sleep 3` for the async respawn (possible slow-CI
flake). The fd-hygiene regression is the close-sweep unit test (a true EOF regression
lands with #27's EOF-decision logic).

---

## #22 residual — flatten the vestigial no-preload Stage-Runner loop — DONE (`7e6ed23f8`)

Done directly on 2.0d (no worktree). Both suites green (`prove` 1748 · `yath test -D`
1754). The runner only reaches `run_tests`'s in-runner path on a no-preload run, and
since #22 moved all stage hosting to `Preload::Host` the runner never relaunches a stage
— so nothing ever longjumps `"Stage-Runner"`. Replaced the single-pass setjump/relaunch
loop with a direct `run_stage('default')` call and removed the now-dead `reset_stage`
method, the write-only `can_stage` slot, and the unused `Long::Jump` import. Also fixed
the stale `Scheduler.pm` comment that described dispatch as a dial to
`preload-<stage>.socket` (it is `service_send` over the registered channel).

**Remaining #22 residual — `run_scheduler_only` as the runner's ONLY run path** — is
coupled with #8 Part 4 (the no-preload fork path can only collapse into the
scheduler-only loop once no-preload completion no longer drives scheduling off the local
reap). See the #8 Part 4 note below.

**Finding on #8 Part 4 (recorded for whoever picks it up):** `Runner::Job::_collector_exit_code`
shows the no-preload collector deliberately encodes the **audited** `harness_final_state`
(pass/fail, audit-only failures, and the bail `halt`) into its **OS exit code** before
exiting — and persists the bail reason to `bail_file`. So the runner's reap-driven
`set_proc_exit` decision already acts on the audited verdict; the exit status *is* the
collector's report, not a lossy waitpid status. That makes #8 Part 4 a lateral
architectural move (drive the same decision off the `harness_final_state` transition
instead of the exit code) rather than a correctness fix, and it carries real
fire-exactly-once race risk on the hottest path (the transition and the reap both signal
completion; a collector that crashes before emitting `harness_final_state` still needs
the reap as the fire-once fallback). Recommend treating it as its own reviewed effort,
not a blind cleanup. NOT attempted this session.

---

## #21 — Preload failure: diagnostics simplify + configurable timeouts — DONE (`419571793`)

Depends #20 (landed first). Done directly on 2.0d (no worktree). Both suites green
(`prove` 1748 · `yath test -D` 1754). Conforms code to the already-written
ARCHITECTURE.md §4.7a (no doc change needed).

**Diagnostics:** deleted the inline `Zstd::FrameBuffer` events-file scrape in
`Runner::_emit_preload_failure_output`. The method now just re-emits the errors the
preload-root hands over via `stage_host_exited` / `preload_warnings`; each failed
process's own collector already records its output and the renderer surfaces it, so the
runner only needs to know a stage failed. A hard SIGKILL crash hands nothing over → the
generic "died unexpectedly" message stands alone. (`preload.t`'s "This is broken" /
"Can't locate Does/Not/Exist" assertions still pass — they ride the handed-over
`stage_host_errors`, not the scrape.)

**Timeouts (two new runner options, `App/Yath2/Options/Runner.pm`):**
- `--preload-map-timeout` (default 60) replaces the hardcoded 60s map/base-stage
  readiness deadline in `Runner::run_scheduler_only` AND the preload-root's 30s handshake
  RPC wait (`Preload::_request_sync`, fallback 30s before settings.json is readable). The
  preload-root now loads `settings.json` once via a cached `settings` accessor (reused by
  the handshake + the stage host; removes a double-load).
- `--preload-stage-startup-timeout` (default 0 = off) is the §4.7a per-stage startup
  safeguard, enforced in `Resource::Preload::available()`: a stage stuck
  `starting`/`restarting` past the timeout is treated as permanently gone (→ `-1` for a
  required stage, falls to `default` for advisory) instead of waited on forever. Reads
  the lifecycle stamp age via new `State::stage_state_age`.

**Tests:** added a `startup_timeout_safeguard` subtest to `t/AI/unit/Resource_Preload.t`
(backdates a stuck stage's lifecycle stamp; verifies -1 required / 1 advisory / 0 when
off). **Flag for review:** the map timeout and the preload-root handshake RPC share one
knob (`preload_map_timeout`) — semantically both are "preload bring-up patience," but
they live at different layers (runner-waits-for-tree vs root-waits-for-runner). Splitting
into two settings is trivial if the owner prefers.

---

## #20 — Preload `require` happens outside the guard — DONE (`91afaac78`)

Done directly on 2.0d (no worktree). Both suites green (`prove` 1747 · `yath test -D`
1753). Conforms code to the already-written ARCHITECTURE.md §4.7 (no doc change needed).

**Problem:** `Preload::_load_preloads` ran a full `require` of every preload module at the
handshake, BEFORE `test2_start_preload` — so require-time Test2 side effects escaped the
guard and every module loaded twice (handshake + the stage host's guarded preload).

**Fix (lightweight handshake):** `Preload::_handshake` now only dials, identifies, and
calls `get_preload_list` (for `runner_pid` + `monitor_preloads`). Deleted
`Preload::_load_preloads` and `Preload::stage_data` (+ the now-dead `mod2file` /
`Runner::Preload` imports). The stage host loads the preloads once under the guard
(`Preload::Host::run_tests`, wrapping `$preloader->preload()` in a `local $SIG{__WARN__}`
to capture preload-time warnings); the base/default stage then reports `set_stage_data`
(built from the guarded preloader's `staged` meta via the new
`Preload::Host::stage_data`) + `preload_warnings` over its channel, BEFORE its
`stage_ready`. The runner's dispatch gate already requires both the map and the base
stage, so the map still lands before any task schedules.

**Test:** rewrote `t/AI/integration/preload_root_handshake.t` — the bare handshake no
longer reports the stage map (that is the stage host's job, covered by the preloaded
end-to-end runs), so it now asserts the new lightweight-handshake contract (handshake
completes, the channel is bidirectional via `stage_host_exited`, no map from the bare
handshake). The `preload_root_crash` fixture comment still references `_load_preloads`
but the crash now fires during the guarded load instead — same observable outcome
(abrupt preload-root death before any stage registers); test passes unchanged.

---

## #10 / chunk 23 + chunk 11 — Client-side stage assignment + §4.7a preload Resource — DONE (`af8153696`)

Two sequential agents, all parts green. Net resolver/file_stage/eager elimination
(-559 lines) + the preload Resource (+362).

**Producer (Agent A, `489baac07`):** `App::Yath2::TestFile` reads directives →
3 validated task fields: `# HARNESS-NO-PRELOAD`→`no_preload`; `# HARNESS-STAGE A B C`
(multi-arg; 1-arg back-compat)→`preload_list`; `# HARNESS-STAGE-REQUIRE A B C`→
`require_preload`+`preload_list`. Validation croaks if `no_preload` conflicts. Plugin
override via the existing `munge_files` hook (`set_no_preload`/`set_require_preload`/
`set_preload_list`). Fields flow `queue_item`→Finder→RunPlan→task; `Test2::Harness2::TestFile`
gained accessors.

**Consumer + Resource (Agent B, `560788b37`/`7c74efc48`/`af8153696`):**
- **Eliminated** (25 files, -559): `resolve_file_stage`/`resolve_file_stages`/
  `request_preload_sync`/`_resolver_identity`/`service_on_response`/`eager_from_stage_map`,
  the `file_stage_resolver`/`eager_stages` slots, the `file_stage` + `eager` preload DSL
  (+ `add_file_stage`), the eager fan-out in `_stage_order`, the resolver handlers (Host +
  runner), `can_run` in the map. `_ready_to_schedule` now gates on map + a live stage peer
  (`_has_live_stage_peer`). The stage MAP (`set_stage_data`) is kept.
- **`State::task_stage` field-based:** `no_preload`→`NOPRELOAD`; first `up` listed stage;
  else first listed stage in the map (waits); else `default`. (Fixed a mid-impl hang: an
  early `!use_preload`→`NOPRELOAD` short-circuit bucketed no-preload-run tasks to a stage
  the runner never schedules → winddown hang; fixed by letting the preloader own
  NOPRELOAD-vs-default on the no-preload path.)
- **`Resource::Preload`** (§4.7a) composes the Role (`&`-prefix, JobCount model); built
  specially in `State::init` with a State backref (scheduler-only path only) to read
  `stage_map`/`stage_is_up`/`stage_state`. `available($task)` tri-state: `up`→1;
  `starting`/`restarting`→0 (wait); all absent-from-map/`down` → `-1` if `require_preload`
  (skip/fail), else advisory→`default`. `assign` records the chosen stage; `release` no-op
  (unbounded). assign→launch race already requeues via `dispatch_pending`→`requeue_task` (#3).
- **Legacy `stage` field KEPT** (producer sets `stage //= preload_list->[0]`; consumer
  reads `preload_list` first, falls back) — removing it touches every producer for no gain.
- **Tests:** deleted `stage_dispatch.t`/`preload_crash_midrun.t` + file_stage fixtures;
  reworked `t/integration/preload` to route via `HARNESS-STAGE` directives (no more
  file_stage/eager-TRIGGER); added `State_task_stage.t`, `Resource_Preload.t`,
  `preload_require_skip.t` (end-to-end: require-missing → genuinely SKIPPED; advisory →
  default; present → runs there).

This completes chunk 23 (client-side stage assignment) AND chunk 11 (preload as a
resource). **Note:** require-skip integration shows a cosmetic "stage exited abnormally
signal 9" teardown line — normal SIGKILL stage teardown at winddown; run PASSES exit 0.

---

## #15 — Chunk-comment archaeology sweep — DONE (`97f51134a`, 7 commits)

Suite green: `prove` Files=108 Tests=1731 · `yath test` PASSED 109/1736. Comments
only. **`grep '# *[Cc]hunk [0-9]' lib/` → 0** (and a broader inline/POD `chunk N`
sweep → 0). Per-comment judgment: purely-historical comments deleted; current-invariant
explanations kept with the `Chunk N.M` prefix stripped; `§X.Y` / `ARCHITECTURE.md`
cross-refs and `(ticket #N)`/`bloat #N` refs preserved. Rough: Runner.pm ~30 stripped /
~4 deleted; Handlers.pm ~28 stripped; State.pm stripped + 1 deleted; rest per-file.
**Flag for a future code-accuracy pass (not this comments-only ticket):**
`Scheduler.pm:~120` comment still says tasks dispatch to "preload-<stage>.socket"
whereas the code dispatches over the registered channel via `service_send` — wording
only, left as-is.

---

## #8 — Collapse the IPC controller (simplify) — Parts 1-3 DONE; Part 4 DEFERRED (`280720efb`)

Suite green: `prove` Files=108 Tests=1730 · `yath test` PASSED.
- **P1 (`f0c84daa9`):** `IPC::_bring_out_yer_dead` die-on-unmonitored-waitpid → `next`
  (a plugin/3rd-party child reaped here is benign, not fatal).
- **P2 (`e894886c4`):** gated the `_ex_parrots` "vanished!"/"escaped the wait cycle"
  warns behind a `T2_HARNESS_IPC_DEBUG` env flag. **Kept** the `_ex_parrots` sweep
  itself (a real cross-platform fallback; `Preload::Host` shares this base for genuine
  multi-child reaping) — only demoted the always-on warns.
- **P3 (`9924a1d2e` + IPC.md `a1b2444b3`):** `test.pm` no longer uses an `IPC`
  *controller instance* for its one child (the runner) — inline spawn+reap+signal on
  `Util::IPC::run_cmd` (`reap_runner`/`wait_for_runner`/`signal_runner` + an
  `owns_runner` flag so the persistent `run`/`spawn` paths don't reap/signal a
  pre-existing runner). Collector-wrap via `start_collected` unchanged. **Subtlety:**
  the old `killall` under `USE_P_GROUPS` did `kill(-pid)` but the runner is spawned
  `no_set_pgrp` so it wasn't a group leader — that was a no-op; `signal_runner` now does
  a correct direct `kill($sig, $pid)` (signals/integration tests pass).
- **P4 DEFERRED (migrate no-preload job completion to the collector socket + delete
  `Runner::set_proc_exit` job branch):** too invasive for cleanup. The runner makes the
  **retry-vs-stop-vs-bail** decision from runner-side proc state (`is_try`/`retry`/
  `bailed_out`/`RUN_REACHED_TIMEOUT`) that does **not** exist in the collector; the
  preload path only works because the *stage* owns the proc + decides locally before
  sending an already-decided `stop_task`/`retry_task`. The no-preload runner owns both
  the proc and the socket fold — driving completion off the terminal transition needs
  the retry/bail decision relocated + a fire-exactly-once transition-vs-reap ordering
  fix = a rewrite. Left as a follow-up (§5.4 target). `Preload::Host`'s own
  `set_proc_exit` (legitimate multi-child reaping) untouched. **Note:** P2's debug gate
  uses an env var because the IPC base class has no settings/debug handle — flag if you
  want it on the standard debug convention.

---

## #23 — Rename the three colliding "Stage" classes — DONE (`2de1be5d3`)

Suite green: `prove` Files=108 Tests=1730 · `yath test` PASSED 109/1736. All via
`git mv` (history preserved); zero stale refs.
- `Runner::Stage` → **`Runner::StageDelegate`** (in-stage delegate)
- `Runner::Preloader::Stage` → **`Runner::StageProcess`** (`IPC::Process` proc tracker)
- `Runner::Preload::Stage` → **`Runner::StageConfig`** (preload DSL config)

**`StageDelegate::done` KEPT** (not died/deleted — the audit's "always returns 0 =
dead" was pre-#22): post-#22 it has a live polymorphic caller —
`Preload::Host::end_test_loop` calls `$state->done` where `state` is the stage
delegate; the constant `return 0` keeps the stage serving dispatches until the runner
stops it. A `die` would crash every stage loop.

---

## #22 — Untangle runner / preload-root into two independent classes — CORE DONE (residuals)

Suite green: `prove` Files=108 Tests=1730 · `yath test` PASSED. Commits `f23ceb44c`
(the 3 agent commits `48b55e4ae`/`0331e86e5`/`5a5f77a67`) + `b628a3728` (dead-guard
cleanup).

**The split (owner directive — two fully independent classes, share only `Role::Service`):**
- **New `lib/Test2/Harness2/Preload/Host.pm`** (~747 lines) — independent stage-host
  class. Composes `Role::Service` (+ `parent IPC`); does **NOT** compose the runner's
  `Scheduler`/`Service::Handlers` roles; neither class inherits the other. Owns the
  stage-host machinery moved out of `Runner.pm`: `process`/`run_tests`/`run_stage`/
  `run_job`/`set_proc_exit`/`reset_stage`/`stop_stages`/`_connect_runner`/
  `stage_delegate`/`preloader`/`check_timeouts` + its **own** stage handlers
  (`run_task`/`resolve_file_stages`/`reload`). `Preload::_run_stage_host` now builds a
  `Preload::Host`, not a `Runner`.
- **`Runner.pm`** is now always the root scheduler (~290 lines lighter): deleted the
  in-process-stage machinery, the `Preloader::Stage` relaunch branch, `is_stage_service`/
  `stage_delegate`/`_connect_runner`/`stop_stages`, and **all `ROOTPID==$$` role guards**
  (18 → 0; the last always-true guard in `scheduler_tick` removed in `b628a3728`). The 4
  remaining `ROOTPID` refs are **value-uses** (the runner's own pid passed to children as
  `runner_pid`/`watch_parent_pid`), not guards. Keeps the scheduler-only preload path
  (`run_scheduler_only`, `spawn_preload_root`, stage-map + `resolve_file_stage`) + the
  no-preload fork+exec path.
- **Bug fixed mid-task:** the first `Preload::Host` cut lacked stage handlers, so the
  runner's dispatches were silently dropped (hung the eager/nested-stage path) — caught
  by running `preload.t` in isolation (the `-j16` suite masked it). Folded in.

**Residuals (documented in `AI_DOCS/2026-06-20-ticket22-runner-preload-host-split.md`):**
the no-preload `run_tests` still wraps `run_stage('default')` in a now-pointless
`setjump "Stage-Runner"` loop (nothing longjumps it — flatten later); and the directive's
*ideal* end state — `run_scheduler_only` as the runner's ONLY run path, collapsing the
no-preload fork path into it and deleting `_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS`
— deferred (larger, green-first). `preload.t` remains `-j16`-contention-flaky (pre-existing
de-flake theme); clean in isolation + both full suites at each commit.

**This unblocks #4 Part 5, #8 (full set_proc_exit removal), #23 (Stage rename).**

**Follow-on cleanups landed (`4fa8f9a3a`):** removed 3 dead imports from Runner.pm
(`Preload`/`Preloader::Stage`/`DepTracer` — no longer referenced after the split).
This + #22 **completes #4 Part 5** (no in-runner named-stage path remains; Runner's
`set_proc_exit` is job-only, the stage branch lives in `Preload::Host`) and **#11**
(only `stop_preload_stages` remains; `_drop_preload_peers` gone via #3; watchdog
narrowed). **#14** — added the priority-index comment to `task_pending_lookup`
(rejected-keep: the 5-level nesting mirrors `_next`'s traversal; don't flatten).

---

## #26 — Simplify App::Yath::Script::V2 — DONE (`12e20db92`, orig `50f86d212`)

Suite green: `prove` Files=108 Tests=1722 · `yath test` PASSED 109/1728.

`do_begin`'s body moved out of BEGIN into a runtime `setup` method (only the
dev-lib-before-load ordering + `ORIG_*` capture needed "early," not BEGIN). The four
`# ==TESTABLE CODE==` marker blobs became real `$class->` methods
(`_parse_config_files`/`_pre_parse_dev_libs`/`_realpath_paths`/`_build_app`); the
marker-extraction hack is gone. **Dispatcher contract kept:** the external
`App::Yath::Script` dispatcher still calls `do_begin` (now a one-line delegate to
`setup`) in its BEGIN + `do_runtime` after. `t/yath_script.t` rewritten to call the
real methods directly (and fixed a latent bug — the old extracted test asserted
settings group `yath`; the real code emits `harness`). **Note:** kept `setup` as a
public method beside `do_begin`; trivial to inline if you'd rather drop it.

---

## Batch 7 (2026-06-19) — runner self-restart removed (#4 Parts 3-4)

Combined suite green: `prove` Files=108 Tests=1740 · `yath test` PASSED 109/1746.

### #4 — Parts 3 & 4 DONE (Part 5 deferred → needs the #22 role-split)
Decided resolution "delete entirely" (no-preload `yath reload` dropped).
- **Part 3 (`7dcb243db`) — runner self-restart deleted.** Removed the `'respawn'` exec
  branch + `respawn_runner_callback` (`runner.pm` command), the `RESPAWN_RUNNER_CALLBACK`
  plumbing + the `end_test_loop` respawn trigger (`Runner.pm`), and the stage-host's
  `respawn_runner_callback` (`Preload.pm`). HUP: preload runner forwards `reload` to the
  preload-root (landed in #4 P2); the no-preload root runner is a **no-op** on HUP.
  Updated `persist.t` + `watch_socket.t` to drop the no-preload-reload assertions
  (no-preload daemons no longer `yath reload`).
- **Part 4 (`8c375b53f`) — no-preload job launch is plain fork+exec under a collector.**
  `generate_run_sub` no longer builds the `setjump "Test-Runner"` frame / `goto::file`
  dispatch / fork-job callbacks — it runs the runner inline; with no fork-job callback each
  test goes the spawn path = **fork+EXEC of a clean perl under its own collector**.
  `goto::file`+`Long::Jump` now live ONLY in the preload tree. **Bug fixed:**
  `Job::collector_target` now passes the test path relative to `ch_dir` (the collector
  chdirs before exec) — `yath projects` was broken without it. Updated `plugin/test.tx`
  (child no longer inherits the runner's `%INC`). **Interactive mode not preserved** (its
  FIFO patch lived in the goto-file launcher) — no test runs a test in interactive mode, so
  nothing needed skipping; the rewrite is the deferred #20 / chunk-13 conversation.
- **Part 5 (delete dead in-runner named-stage path) — DEFERRED, premise is wrong.** The
  targeted code is **NOT dead**: the **preload-root's stage-host** (`Preload::_run_stage_host`)
  is an ordinary `Runner` with `rootpid != $$`, so `_preload_root_hosts_stages` is **false**
  for it → it runs the full `run_tests`/`Preloader::launch_stage`/`_stage_transition_reporter`/
  `set_proc_exit`-stage-relaunch path to host + reload its stages (`reload.t` exercises it).
  Removing it requires the **role-split (#22)** — lift the stage machinery out of `Runner.pm`
  into a stage-host class so the scheduler-only root no longer carries it. **This same fact
  blocks the full `set_proc_exit` removal in #8.** So: do #22 (role-split) to unblock #4 P5 +
  #8's set_proc_exit-stage removal.
- **Follow-ups:** base/default-stage mid-run reload now flows through the preload-root's
  `request_handler_reload` (no `end_test_loop` self-re-exec) — worth a confirming test;
  `watch_socket.t`'s events-file check was relaxed (no-preload runner is silent on reload).

---

## Batch 6 (2026-06-19) — the preload self-management keystone

Combined suite green: `prove` Files=108 Tests=1740 · `yath test` PASSED.

### #9 follow-up — restore connect-failure warn — DONE (`74ee07d8e`)
Per review: `Util::socket_reporter` now `warn`s on a connect failure (the file recorder
still captures the full stream) so a silently-non-connecting reporter is visible.

### #3 — Collector self-termination + connection-currency; `requeue_task` — DONE (core; 2 deferrals)
Cross-repo. **Test2-Collector** commit `680e751` (`ChildMonitor` `watch_parent_pid` accepts
a scalar OR list — any gone pid → terminate; version-bumped). **Harness** (`4d83fb849` and
the 4 before it):
- **Part 1 (collector DONE; harness preload-root-watch DEFERRED):** the multi-pid capability
  is in place + the Test2::Collector dep floor bumped to 0.000002. Wiring the **preload-root**
  into the *stage* collectors' watch list caused a teardown race (the preload-root exits
  during clean shutdown and races stage finalization → stages TERM'd, sig 15) — deferred. The
  **crash case is still covered transitively**: a preload-root crash terminates the runner
  (Part 4) and stages already watch the runner. Test-job collectors watch the runner only.
- **Part 2 DONE — connection-currency replaces generation.** `_stale_stage_report` checks the
  report's `$conn` against the registered `preload-<stage>` peer; deleted `_stale_stage_generation`,
  the per-report `generation`, `PRELOAD_ROOT_GENERATION`/`PRELOAD_GENERATION` (slots + handshake
  field + Preload capture), and the `generation` field from `STAGE_LIFECYCLE` (now `{state, stamp}`
  — completing #2's deferral).
- **Part 3 DONE** — deleted `_drop_preload_peers` + `%busy`.
- **Part 4 DONE** — preload-root crash is **fatal** (persistent runner terminates); deleted
  `preload_root_respawn_limit`, the respawn branch, the `'respawn'` paths, the respawns slot;
  `resolve_file_stage` retry now bounded by mapped-stage-count.
- **Part 5 DONE (safe subset; explicit-ack DEFERRED):** `State::requeue_task` + `Runner::requeue_task`
  (RUNNING→PENDING, no retry, clears `job_pids`/`%SORTED` memo, non-terminal `requeued`);
  `service_send` returns **false** on no-peer/write-fail; `dispatch_pending` requeues (not aborts)
  on the stage-gone no-send path — safe since a false send means the stage never got the task. The
  explicit stage-ack (deferring `dispatched` until ack) is **deferred** (the no-send requeue needs
  no new wire protocol; a successful send still announces `dispatched` immediately).
- **Part 6** — already satisfied (`reload_syntax_error.t` proves a stage survives a broken-preload
  reload + recovers).
- **Tests updated:** `preload_root_crash.t` (startup crash → run fails), `preload_root_kill_midrun.t`
  (mid-run kill → persistent runner terminates, no respawn), `State_stage_lifecycle.t` ({state,stamp}),
  `Runner_dispatch_abort.t` (requeue not abort), new `State_requeue_task.t`.
- **Residual follow-ups (2):** (1) the Part-1 harness preload-root-watch needs the stage/preload-root
  shutdown ordering reworked so the preload-root reliably outlives stage finalization; (2) the Part-5
  explicit-ack protocol (full assign→launch requeue safety once a send succeeds). Both noted; the
  requeue primitive + `service_send` semantics they need are in place.

---

## Batch 5 (2026-06-19) — run lifecycle + scheduler memo

Combined suite green: `prove` Files=107 Tests=1740 · `yath test` PASSED.

### #12 — Run state lifecycle: fold onto `Run`, connection-gated retention — DONE (`5ac411700`, orig `215336f6e`/`248212d0b`)
Part 1: added `raw_item` to the `Run` object (`{%$run}` at queue); `run_item` returns
`$RUN->raw_item`; deleted the leaking `RUN_ITEMS` hash. Part 2: owner-gated retention —
`request_handler_queue_run` records `run_owners{run_id} => {conn, peer_pid (#1),
abort_on_disconnect (default true)}`; a new `Role::Service::service_conn_closed($conn)`
hook (called from the single `_drop_conn` path) sweeps owned runs on disconnect:
finished→`purge_run`; running+flag→run-scoped `Watchdog::abort_remaining(run_id=>…)` +
`abort_run` (halt pending, stop, advance); running+!flag→detach. State keeps finished
runs in `retained_runs` until owner-drop (was: discarded immediately); `announce_run`
purges unowned finished runs (bounded retention). `queue_task`/`stop_run` still any-conn.
Added `State_run_retention.t` (8 subtests). **Notes:** abort-on-disconnect default true
(transient `yath test` relies on it — green); the detach path (flag false) is implemented
+ unit-tested but not exercised e2e (no `yath queue` command sets the flag yet).

### #13 — `%SORTED` → instance field, stable key, pruned — DONE (`44d4f1aa1`, orig `bd011cfe5`)
Made `%SORTED` an instance `{+SORTED}` slot keyed by the stable path tuple
`join("\0", run_id, smoke, stage, cat, dur)` (was the arrayref address → leak +
ref-reuse bug). Clears the bucket key on add (`_queue_task`) and all `^<run_id>\0` keys
on `_stop_run`; comment flags the single-active-run assumption for chunk 16. Conflict-
priority sort verified still once-per-bucket.

---

## Batch 4 (2026-06-19) — stage lifecycle + runner rework (partial)

Combined suite green: `prove` Files=106 Tests=1732 · `yath test` PASSED.

### #2 — Converge stage state into one 4-state lifecycle — DONE (`a86f0273e`, orig `ce391d9cc`)
Deleted `STAGE_READINESS`; `STAGE_LIFECYCLE` is the single source (`stage_is_up` helper;
scheduler gate reads `state eq 'up'`). 4 states wired in State.pm: `starting` (from
`set_stage_map` — mapped-but-not-up), `up` (`stage_ready`), `restarting` (stage exit
while still mapped — both reload + non-reload), **`down` = absent-from-map** (a refresh
that drops a previously-tracked stage marks it `down` — fully reached, tested). Status
drops `stage_readiness`, returns `stage_lifecycle` + `stage_pids` (#1). **Kept
`generation` + `_stale_stage_generation` guard** (scope: #3 removes them with
connection-currency). Updated `State_stage_lifecycle.t`.

### #4 — Runner rework — PARTIAL (Parts 1+2 done; 3/4/5 DEFERRED — NEEDS A PRODUCT DECISION)
- **Part 1 DONE (`4f4898a09`):** fixed the lying DORMANT comments in `Runner.pm`
  (`_preload_root_hosts_stages`/`dispatch_pending`/`run_tests`/`run_scheduler_only`) →
  state the gate is LIVE for preload runs, in-runner paths are the no-preload fallback.
  Correctly **left** the `Runner.pm:181` comment — it is the run-scoped-stage SEAM
  (chunk 6.1-2), genuinely unbuilt, accurately "NOT YET TRIGGERED" (not a stale claim).
- **Part 2 (partial) DONE (`42a788d46`, orig `08d7307db`):** the **preload** (scheduler-only)
  runner's SIGHUP no longer winds down — it `service_send('preload-root','reload')` and
  continues; added `Preload::request_handler_reload` → `longjump 'preload-root' => 'respawn'`.
  Updated IPC.md.
- **Parts 3 (delete runner self-restart), 4 (no-preload fork+exec, remove goto::file/Long::Jump
  from runner), 5 (delete dead in-runner named-stage path) — DEFERRED.**

> ⚠️ **NEEDS YOUR DECISION (#4 — blocks Parts 3/4/5, and tickets #8, #26).** The ticket's
> premise that the runner self-restart is "vestigial for no-preload" is **false against the
> suite.** `t/integration/persist.t` and `t/AI/integration/watch_socket.t` `yath start` a
> **no-preload** persistent runner, `yath reload` it, and assert it reloads via exactly the
> `setjump "Test-Runner"` self-restart Part 3 would delete (the agent confirmed the only HUP
> delivery is to a `rootpid==$$`, `stage=default`, no-preload-root runner). So no-preload
> persistent `yath reload` is a **tested, user-facing feature**, not vestigial. Pick one:
> **(a)** accept that a no-preload persistent runner loses `yath reload` self-restart (update/
> retire those two tests) → Parts 3/4/5 proceed as written; or **(b)** keep the no-preload
> self-restart and rescope #4 (HUP-forward stays preload-only, as landed; the runner's
> `setjump`/goto::file stays for the no-preload path). This is a product call I should not make
> unilaterally — it changes a human-authored test's asserted behavior.
> Also (minor): the socket `reload` forward in Part 2 is best-effort — the preload-root also
> gets HUP via the shared process group (it's an `is_test=>0` collector in the runner's
> pgroup); the socket forward only lands in the post-run idle window. If the socket forward
> should be the *primary* mechanism, that needs servicing the Preload connection mid-run
> (a larger change).

---

## Batch 3 (2026-06-19) — foundation + scheduler + quick fixes

Three parallel tickets onto 2.0d. Combined suite green: `prove` Files=106 Tests=1731 ·
`yath test` PASSED (both `AUTHOR_TESTING=1 -j16`).

### #1 — Remove `poll`/`_enqueue`/`%ACTIONS` + bogus `$$`; pid via handshake — DONE (`9a1196e14`, orig `defeb8dda`/`376aedf54`/`8e2adada7`)
Deleted `poll` + its 6 call sites, `_enqueue`+`%ACTIONS`, the bogus `$$` arg (State stores
no pid; readiness is a truthy gate); folded `truncate`/`_halt_run`/`_end_queue`.
`Connection::send_identity` now carries `pid => $$`, stores `IDENTITY_PID` on receive,
added `peer_pid`. New `Runner::stage_peer_pids` builds `{stage=>pid}` from `service_peers`;
`StatusReport`/`status`/`ps` show each connected stage's real pid (down/restarting → N/A).
Did **not** converge READINESS/LIFECYCLE (ticket #2). Updated IPC.md + added `peer_pid`
assertions. **Integration note:** the State `poll`-call removal in `scheduler_tick`
conflicted with #17's fail-fast rewrite of the same method — resolved by keeping #17's
fail-fast structure and dropping the `poll` call.

### #17 — `scheduler_tick` fixes — DONE (`5525f532f`,`bb3830e96`, orig `4cc1a1a4f`/`5f8336cb6`)
Bare hash keys → HashBase constants (`{+ROOTPID}`/`{+SIGNAL}`/`{+ACTIVE_RUN}`/
`{+RESOURCE_TIMEOUT}`/`{+RUN_REACHED_TIMEOUT}`; declared the constants on the Scheduler
role). Dropped `SCHEDULER_MAX_ERRORS` + the eval-retry + the `scheduler_errors` slot →
**fail-fast** (a `poll`/`advance`/`dispatch_pending` throw propagates). Kept `service_tick`
separate (rejected the merge). Updated `scheduler_death.t`: crash → fail-fast; the recover
case re-modeled so the resource absorbs its own transient error inside `tick()`.

### #25 — Smaller notes (quick fixes + verify-then-fix) — DONE (`1acb653b5`,`babce0e64`,`72fb81211`,`b52823f51`,`ac4274db9`)
Quick fixes: `_drain_transitions` → deadline-based drain (early-exit on a quiet
`can_read(0)`, ~0.5s cap); `Preloader::_monitor` longmess → plain `die`; `Job::bailed_out`
legacy out_file scan deleted (structured bail kept); dead `Reloader::_can_reload`/
`_find_loaded` deleted (`init` now `croak`s if cbs missing). `Util/IPC` IO-swap extracted
into a shared `_swap_in_io`. **Verify-then-fix — LEFT (with reasons):** `find_churn`
sleep-retry (covers non-atomic save / stat-poll paths the inotify mask doesn't); the two
file-watch loops (not dups — different throttle levels; merging changes cadence). Moot
items (SharedJobSlots/IPC-controller) skipped; bad-frame tolerance + DepTracer dual-hook
left (decided keep).

---

## Batch 2 (2026-06-19) — dedup + interface

Three parallel tickets, integrated onto 2.0d. Combined suite green: `prove` Files=106
Tests=1731 · `yath test` PASSED (both `AUTHOR_TESTING=1 -j16`).

### #24 — Resource base → Role::Tiny role (`requires available, assign`) — DONE (`38f6b00a9`, orig `0a979a4093`)
Converted `Runner::Resource` to a **Role::Tiny role that `use`s Object::HashBase**
(`use Role::Tiny;` before `use Object::HashBase;` so HashBase suppresses `new` for the
role; then `requires 'available','assign'`). Consumers compose via the `&` prefix
(`use Object::HashBase qw/&Test2::Harness2::Runner::Resource .../`); `JobCount`
predeclares `sub new;` to keep its own `new`. Removed dead `scope_global/host/run` and
the `available`/`assign` no-op defaults; kept the optional no-op hooks (+
`sort_weight`/`job_limiter*`/`discharge` — called on every resource). Converted the 4
integration-test resources to `&`-composition; POD → composition.
**Review notes:** (1) `requires` enforcement is a **load-time WARN, not a hard die**
(HashBase's role-applier `warn`s on a missing required method) — JobCount + all test
resources satisfy it, so moot in practice; flag if fatal enforcement was wanted.
(2) no-op defaults got explicit invokants (`my $self = shift; return`) to satisfy the
methods-not-functions audit now that the file `use`s Object::HashBase. (3) kept the
existing `strict/warnings` headers (v5.38 is for new modules only).

### #16 — `run_ord` → rename `run_id` (keep the seam) — DONE (`212aca276`, orig `9369a5f22`)
Renamed the dormant socket-naming seam everywhere (`Role/Service.pm` `->can`/POD/
`service_socket_path`, `Runner.pm` seam comment, and the `Role_Service.t` consumer
test). `grep run_ord lib/ t/` → zero hits. Fixed the doc ("per-run numeric subdir" →
"the run's run_id (UUID) subdir"). Seam intact, behavior identical (no consumer defines
the hook). The unrelated real `run_id` run-identifier API was untouched.

### #9 — Factor collector-reporter boilerplate → `Util::socket_reporter` — DONE (`fca4f3e42`, orig `beb44ecd5`)
Added exportable `Test2::Harness2::Util::socket_reporter($identity, $socket)` (returns
undef unless `-S $socket`; builds `Recorder::Socket` with `no_reply`, `drain_input`,
**`pid => $$`** — the #1 handshake pid; eval-guarded). Swapped the 4 sites (Runner.pm
preload-root, Job.pm, Preloader.pm, Plugin.pm), identity strings preserved. **Review
note:** Job.pm/Preloader.pm previously `warn`ed on connect failure; the helper swallows
the error + returns undef (the file recorder still produces a complete stream), so those
two warns are gone — the one behavioral delta beyond the dedup. Flag if the warn should
be restored (e.g. socket-reporter failure now goes silent).

---

## Batch 1 (2026-06-19) — behavior-preserving deletes

Four independent tickets, each implemented by a fresh agent in an isolated worktree,
integrated onto 2.0d. Combined suite green: `prove` Files=106 Tests=1731 · `yath test`
PASSED 107 files / 1737 assertions (both `AUTHOR_TESTING=1 -j16`).

### #5 — Delete SharedJobSlots — DONE (`6bd15d6b6`, orig `5a999eeae`)
Deleted the 3 modules + their unit tests/fixture, the `--shared-jobs-config` option +
`fix_job_resources` SharedJobSlots logic in `Options/Runner.pm` (kept JobCount
default-add + slot defaulting/clamp), the `resources.pm` `shared_resources` branch, and
all POD/comment mentions (`test.pm`/`projects.pm`/`start.pm`/`Runner.pm`/`Resource.pm`).
`JobCount` independent + kept. **Review notes:** left `t/AI/fixtures/ui/sample-run.jsonl`
(frozen serialized settings containing `shared_jobs_config` — test data, not a code ref)
and `Makefile.PL` (auto-generated; its stale `Test2/Harness/.../SharedJobSlots/*.t` globs
now match nothing) untouched — both intentional/out-of-scope. POD was surgically removed,
not regenerated (a future full POD regen is consistent either way).

### #6 — Delete dead `wait()` params (`cat`/`all_cat`/`block`) — DONE (`d6f3135fb`, orig `ed1317240`)
Removed the 3 dead params + POD from `IPC.pm::wait`, the `$cat_total` bookkeeping, the
`cat`-delta branch, and collapsed `_wait_done` to its 4 real cases (dropped its unused
`$found` arg). **Dropped `PROCS_BY_CAT` entirely** — verified `cat`/`all_cat` were its
sole consumers (all refs were inside IPC.pm). Kept the `category` method on
`IPC::Process`/`Job`/`Preloader::Stage` (public, used by Monitor/Renderer; #8 may revisit).
Behavior-preserving (no caller used the removed params).

### #7 — Misc dead lines (7a/7d/7e/7f) — DONE (`9b4a96252`,`0aed56cf3`,`662e073f3`,`88bf6e12a`)
- 7a: removed the duplicate `IN_MOVE_SELF` inotify-mask line in `Reloader.pm`.
- 7d: removed unused `use Atomic::Pipe` in `Renderer/DB.pm` (verified unused).
- 7e: kept `DepTracer::add_callback`; added a comment pointing at its consumer
  (`Preloader::_reload_cb_reload` via `$dtrace->callbacks`) so it isn't re-flagged dead.
- 7f: deleted Role::Service `run()`/`reap_children` + the `service_on_start/stop/reap`
  hooks + POD + the Runner no-op `reap_children` override (kept `service_tick`).
  **Review note:** the ticket said "zero callers" but `t/AI/unit/Runner_Subscriber.t:104`
  called `$hub->run` — the agent migrated that test to drive the loop inline via the
  public `service_io`/`service_tick`/`service_stopped`/`close_service` primitives
  (faithful to `run()`'s former body), consistent with the ticket's intent.

### #19 — Delete dead `Runner::Client` stage-report methods — DONE (`3d3e28d61`, orig `cce2eb191`)
Deleted the 6 dead stage-report methods (`stop_task`/`retry_task`/`reload`/`stage_ready`/
`stage_down`/`job_pid`) + POD from `Runner/Client.pm` (zero callers confirmed — only the
POD `=item`s referenced them; `reload_state` is distinct and kept). Fixed the stale
`stage_delegate` comment at `Runner.pm:~331` (it uses `service_send`, not a Client).

**Orchestration note:** every agent's worktree was created from a stale 1.0-era base
(`00ee6f7f3`); each adapted by advancing to `2.0d` (`31013c21d`) before working, so all
commits are based on 2.0d and cherry-picked cleanly. Worth fixing the worktree base for
future batches if possible.
