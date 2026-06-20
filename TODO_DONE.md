# TODO_DONE.md — Completed tickets

Tickets from `TODO_TASKS.md` that have landed, with review notes. Each entry: what
was done, commit(s), test result, and anything the implementer flagged for review.

Newest first.

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
