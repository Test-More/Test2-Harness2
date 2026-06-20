# TODO_TASKS.md — Specific tickets

Well-defined, **decided** tasks — tickets ready to implement. Each has a parent
**step** (`TODO_STEPS.md`) and target-state detail in `ARCHITECTURE.md`.

These started as a consolidated audit (four model audits of the IPC / service-loop /
shared-state subsystem) and were turned into decisions through a working session
plus two plan reviews (Gemini, GPT). The audit framing is gone — what remains is the
decision + concrete steps. Full provenance is in git (the pre-refactor snapshot
commit and the prior `bloat.md` history).

**How to read a ticket:** `Status` (Decided / Deferred / Rejected) · `Step` (parent
chunk) · `Depends` · Problem · Steps. "Rejected" = the audit was wrong or superseded;
do **not** re-fix it.

---

## Context (read before acting)

- **Branch `2.0d`.** Test (both must pass, always `AUTHOR_TESTING=1`):
  `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`.
  Skip `yath test` only for interim-broken steps. No repo-local `scripts/yath`. See
  AGENTS Testing.
- **Root cause of most tickets:** chunk-19 residue (the preload-root extraction
  landed; crash/race/de-flake machinery + stale comments lag the architecture) and
  1.0 carryover superseded by collectors+sockets. Recurring lens: **state flows over
  sockets (collector transition reports); reaping is mere zombie cleanup, not a
  scheduling signal.**
- **Foundational mechanism (review as a set): connection identity = source of
  truth.** #1 adds **`pid` to the identity handshake** (every peer's pid via
  `$conn->peer_pid`). #3 replaces generation-stamping with **connection-currency** (a
  report is honored only from the connection currently registered for that identity).
  This underpins #1, #2 (real stage pid in status), #3 (stale-incarnation race), #9
  (reporter args), #12 (run owner connection).
- **`requeue_task` (introduced in #3) is a prerequisite** for stages self-restarting
  and for the preload resource's assign→launch race. Specified in #3.
- **Real-world context that drove the big calls:** the 1.0 preload-side `file_stage`
  auto-assignment + `eager` stages were added but never effectively used; people use
  the harness directive + a custom plugin to assign stages at queue time (#10/#23
  codify that, stages **advisory** unless `REQUIRE`). At least one deployment has
  preload stages that take **2+ minutes** to start (root <1 min) → no fixed
  named-stage startup timeout, configurable deadlines, generous/off-by-default hung
  backstop (#21). A vanished `run`/`test` command = crash/user-kill → **abort the run
  by default**, flag to detach (#12).

## Dependency / ordering

- **Early, independent, behavior-preserving:** #1, #6, #7(a,d), #19, #24.
- **#1 → #2 → #3** in order: peer_pid → 4-state lifecycle → self-termination +
  connection-currency (introduces `requeue_task`).
- **#5 first among SharedJobSlots-touching items** — it deletes the subsystem,
  mooting parts of #7 and #25.
- **#6 before #8** — `cat`-waits go, then the IPC controller collapses.
- **#4 / #8 / #20 / #23 reshape the Runner**, so **#15, #22, #23(rename)** defer until
  after them.
- **#23(resolver elimination) supersedes #10/#20/#21's resolver discussion** — the
  resolver is deleted, not fixed.

> Numbering note: ticket numbers (#1-#25) are stable identifiers from the audit
> consolidation; they are **not** the same as TODO_STEPS chunk numbers. Each ticket's
> `Step:` line names its parent chunk.

---

## TIER 1 — High-consensus, behavior-preserving

### #1 — Remove `poll`/`_enqueue`/`%ACTIONS` + bogus `$$`; pid via handshake
**Status:** ✅ DONE (batch 3, `9a1196e14`) — see TODO_DONE.md · **Step:** 10/19 · **Depends:** —

**Problem:** `sub poll {return}` (State.pm) is a dispatch.jsonl fossil called from ~6
sites. Every mutator routes `method → _enqueue → %ACTIONS → _do_*` (pure in-process
indirection, defeats grep). `_enqueue` threads `$$` to every handler; only
`_stage_ready` reads it — storing the **runner's own** pid as the stage "readiness
pid" (and `_set_stage_lifecycle` gets the same bogus `$$`).

**Steps:**
- Delete `poll` + its 6 call sites; delete `_enqueue` + `%ACTIONS`; mutators call
  their `_*` impls directly.
- Delete the `$$` arg. State stores **no pid**.
- Recover the **real** stage pid as a **connection property**: `Connection::send_identity`
  sends `{identity => {name, pid => $$}}`; receive stores `IDENTITY_PID`; add a
  `peer_pid` accessor. The runner knows every peer's pid via `service_peers` →
  `$conn->peer_pid`. `no_reply` collector reporters carry `pid => $$` in the recorder
  preamble (do it in the #9 helper).
- `yath status`/`ps` show each **connected** stage's real pid from its
  `preload-<stage>` peer (`StatusReport`/`request_handler_status`/`ps` build the map
  from `service_peers`). A down/restarting stage has no connection → no pid (correct).
- Fold-in: `truncate`'s real work is the `halt_run` loop; delete the empty
  `_truncate` + its enqueue.

### #2 — Converge stage state into one 4-state lifecycle
**Status:** ✅ DONE (batch 4, `a86f0273e`) — see TODO_DONE.md (kept generation for #3) · **Step:** 10 · **Depends:** #1

**Problem:** `STAGE_READINESS` (`{stage=>pid}`) and `STAGE_LIFECYCLE`
(`{state,generation,pid,stamp}`) are redundant; every transition writes both.

**Steps:**
- Converge on the single richer structure; delete `STAGE_READINESS`. Scheduler gate
  (`_stage_order`, `spawn_stage_ready`) reads `state eq 'up'`.
- **No pid/generation in State.** Lifecycle = `{state, stamp}`. Status pid comes from
  the connection (`peer_pid`, #1); stale-incarnation rejection is connection-currency
  (#3), **not** a wire generation.
- **State machine (implement all four now):** `starting` (committed/known, not yet
  reported — set from the reported stage map), `up` (reported ready, dispatchable),
  `restarting` (temporarily down, coming back), `down` (permanent — **setter =
  "absent from the stage map"**: never configured, misspelled, or removed by a
  refresh). The current non-reload exit maps to `restarting`.
- These states feed the future preload resource (#11/§4.7a): `available()` maps
  up→1, starting/restarting→0, down/absent→-1.
- `StatusReport` drops `stage_readiness`, returns `stage_lifecycle` + peer pids;
  `status.pm`/`ps.pm` read lifecycle. Status output need not be byte-preserved.
- Free fold-in (after #1): stage methods take plain `($stage)` args; delete
  `_stage_action_parts` (the dead bare-string branch).

### #3 — Collector self-termination + connection-currency; `requeue_task`
**Status:** ✅ DONE core (batch 6, `4d83fb849` + Test2-Collector `680e751`) — see TODO_DONE.md; 2 residuals: harness preload-root-watch wiring + Part-5 explicit-ack · **Step:** 10/11 · **Depends:** #1, #2

**Problem:** chunk-19 grew three overlapping defenses against "reports from a
dead/replaced preload-root incarnation": generation stamping, `%busy` busy-channel
retention in `_drop_preload_peers`, and the parallel `STAGE_LIFECYCLE`. The runner
eagerly drops channels of stages that are themselves still alive.

**Steps (all three defenses collapse into one):**
- **Multi-pid `ChildMonitor` (Test2-Collector).** Extend `watch_parent_pid` from a
  scalar to a **list** (preserve scalar back-compat: `ref eq 'ARRAY' ? @$v : ($v)`);
  if **any** watched pid is gone, self-terminate (the existing TERM→KILL escalation +
  signal-forwarding already handle it). **Stage** collectors watch their full ancestor
  set (runner + parent stage(s) + preload-root); **test-job** collectors keep watching
  the **runner only** (a forked test doesn't die with its stage).
- **Stage graceful shutdown:** catch the forwarded TERM → stop accepting requests,
  drain, finish already-requested spawns, report state, exit → socket EOF.
- **Runner stops managing stage lifecycle:** delete `_drop_preload_peers` + `%busy`.
  Stages drop themselves; EOF removes the peer. The runner only starts the
  preload-root and tracks state.
- **Connection-currency replaces generation.** `handle_request($payload,$conn)`
  already passes the source connection; honor a stage report only if `$conn` is the
  connection currently registered for that identity. Delete `PRELOAD_ROOT_GENERATION`,
  the per-report `generation`, `_stale_stage_generation`.
- **Preload-root crash = fatal.** Runner does **not** respawn it. On a **persistent**
  runner an unexpected preload-root exit **terminates the runner** (§4.2). HUP reload
  is the only restart, and the **preload-root re-execs itself** (it TERMs its own
  stages first — `exec` keeps the same pid, so multi-pid watch is the crash backstop,
  not the HUP path). Delete the runner-side crash-respawn apparatus
  (`preload_root_respawn_limit`, `_handle_dead_preload_root` respawn branch, the
  `'respawn'` path in `run_scheduler_only`).
- **Broken-preload resilience (reload mode):** a stage whose preload fails to load
  **stays alive and reloads when the file is fixed**, rather than dying (§4.7).
- **`requeue_task` primitive (prerequisite).** Today a stage-gone-at-dispatch job is
  `abort_job`'d (failed). Add `requeue_task`: RUNNING→PENDING, release slot/resources,
  **no retry consumed**, re-resolve next tick.
  - **Safety:** requeue only **before** a stage accepts (after fork the collector owns
    completion — requeueing would duplicate-run). `service_send` must return **false**
    on no-peer/write-fail. "Accepted" is an **explicit stage ack**, not a successful
    write; the runner announces `dispatched` only after the ack.
  - **State contract:** reuse the same `job_id`/try number; clear the assigned
    `stage`; delete any `job_pids` entry; call resource `release` (fresh
    `assign`/`record` on re-dispatch); emit no terminal subscriber transition (a
    `requeued` mutation or none); clear the task's `%SORTED` bucket memo (#13).
- **Repo-side (same chunk as the collector change):** bump `dist.ini`/`cpanfile`/
  generated `Makefile.PL` floors off `Test2::Collector = 0.000001`; update
  `agent_scripts/audit-collector-watch-parent` for scalar-vs-list.

### #4 — Dual preload architecture + lying "DORMANT" comments; delete runner self-restart
**Status:** ✅ DONE — Parts 1-4 (`5dacdf749`) + Part 5 satisfied by #22 (`4fa8f9a3a`); see TODO_DONE.md

**Problem:** stale comments in `Runner.pm` claim certain paths are "DORMANT" when
they are actually **live** (the chunk-19.3 flip already happened — `_preload_root_hosts_stages`
is true for preload runs). They fooled an auditor. Separately, the runner is now
scheduler-only, so reload/respawn and in-process stage-hosting logic should leave the
main runner entirely. Verified: the *only* reason the runner was restartable is
preloads, and post-flip no preloaded state lives in the runner.

**Steps:**
- **Fix the lying comments first** (cheap, high-value — they cause wrong audits):
  rewrite `Runner.pm:661,1178,1231,1273` (and 182-191) to state the gate is live for
  preload runs; delete the "DORMANT/NOT YET TRIGGERED" claims.
- **Split job launch by preload-ness:** no-preload job launch becomes a plain
  collector **fork+exec** of the test file — no `goto::file`, `Long::Jump`, or `BEGIN`
  in the runner. `goto::file` + `Long::Jump` live **only** in the preload tree
  (`Preload.pm`/`JobLauncher.pm`).
- **Delete the runner's self-restart:** the `setjump "Test-Runner"` frame + its
  `$action` dispatch, `respawn_runner_callback`, the `'respawn'` exec branch, the
  `RESPAWN_RUNNER_CALLBACK` plumbing, and the respawn trigger in `end_test_loop`.
  (Verified unreachable for preload runs — scheduler-only — and vestigial for
  no-preload.)
- **HUP becomes a pure forward:** on SIGHUP the runner only `service_send('preload-root',
  'reload')` and continues — no `SIGNAL`, no winddown, no exec. The preload-root owns
  reload (it re-execs itself, #3). No-preload run → HUP is a no-op.
- Then resolve the **dead in-runner named-stage path** (the `else` branches in
  `dispatch_pending`, `set_proc_exit`'s stage branch, `launch_stage` forking named
  stages, `_stage_transition_reporter`) — unreachable for preload runs; delete (keeps
  the no-preload base job path).

### #5 — Delete SharedJobSlots
**Status:** ✅ DONE (batch 1, `6bd15d6b6`) — see TODO_DONE.md · **Step:** 11-area · **Depends:** —

**Problem:** the cross-runner shared-slot coordinator has dead internals + a real
`mod2file` import bug — but it is being replaced by a future system-usage resource.

**Steps:** delete `Runner/Resource/SharedJobSlots.pm`, `.../SharedJobSlots/State.pm`,
`.../SharedJobSlots/Config.pm`, its unit test(s), the option wiring in
`App/Yath2/Options/Runner.pm:581-607`, the `resources.pm` branch, and reference
mentions (`Runner.pm:219` comment, `test.pm`/`projects.pm`/`start.pm`/
`RunProcessor.pm` — confirm option/config-only). Single-runner job limiting is
unaffected (that's `JobCount`, kept). Removes multi-runner slot coordination until
the system-usage resource lands.

### #6 — Delete dead `wait()` params (`cat`/`all_cat`/`block`)
**Status:** ✅ DONE (batch 1, `d6f3135fb`) — see TODO_DONE.md · **Step:** 21 · **Depends:** —

**Problem:** `wait()` accepts `cat`/`all_cat`/`block`/`all`/`timeout`; the four call
sites use only `all`/`timeout`/none. `cat`/`all_cat`/`block` are 1.0 category-scoped
scheduling primitives — superseded by the in-process tick scheduler fed by socket
reports; reaping is now zombie cleanup.

**Steps:** delete `cat`/`all_cat`/`block` (+ POD); drop the `$cat_total` bookkeeping
and `PROCS_BY_CAT` (if `cat` was its only consumer). `_wait_done` collapses to:
nothing-left / timeout / `all`-mode-remains / default-single-pass.

### #7 — Misc dead lines / fossils
**Status:** ✅ 7a/7d/7e/7f DONE (batch 1) — see TODO_DONE.md; 7b → chunk 20; 7c moot via #5 · **Step:** various · **Depends:** —

- **7a — delete:** Reloader.pm dup `$MASK |= IN_MOVE_SELF()` line.
- **7d — delete:** unused `use Atomic::Pipe` in `Renderer/DB.pm`.
- **7c — moot:** the unread `$c` counter lives in SharedJobSlots (#5 deletes).
- **7b — replace (→ chunk 20):** the broken FIFO open-retry is part of interactive
  mode; do **not** patch it — the whole FIFO proxy is replaced by socket-shared IO
  (§4.10 / TODO_STEPS chunk 20).
- **7e — REJECT (keep):** DepTracer `add_callback` is **live** — fired by
  `Preloader::_reload_cb_reload` via `$dtrace->callbacks` on reload. Add a comment
  pointing there so it isn't re-flagged.
- **7f — delete:** Role::Service `run()` has **zero callers** (consumers drive their
  own `service_io` loops); `reap_children` is only reached from `run()`. Both, plus
  the Runner no-op override and the `service_on_start/stop/reap` hooks (no
  implementers), are a dead chunk-9/harness-service-MVP artifact. Keep `service_tick`
  (live, called from the Runner loop).

### #8 — Collapse the `Test2::Harness2::IPC` controller
**Status:** 🟡 Parts 1-3 DONE (`280720efb`) — die→next, warns debug-gated, command inline reaper; Part 4 (no-preload completion→socket / delete set_proc_exit job branch) DEFERRED as a rewrite (§5.4 follow-up). See TODO_DONE.md

**Problem:** the IPC controller does spawn + zombie-reap + category tracking +
reap-driven scheduling. Only the first two should survive. Two real consumers: the
Runner (multi-child) and `test.pm` (one child — the runner). `Job::set_exit` says
results already come from the collector, not the reap.

**Steps:**
- Migrate **no-preload** job completion onto the collector socket report (like the
  preload path), then delete `Runner::set_proc_exit` (its job branch → socket; its
  stage branch is the dead in-runner named-stage path, #4).
- Delete `PROCS_BY_CAT`/`cat`-waits (#6), the `_check_if_dead_yet` process-group wait
  (runner reaps only single collector pids now), `_ex_parrots`, die-on-unmonitored.
- **Keep** `Util::IPC` (`run_cmd`/`swap_io` — the real reusable primitive) and a thin
  `IPC::Process` value object (drop its exit-tracking). Runner keeps a minimal
  `waitpid` zombie-reaper; the command inlines its one-child spawn+wait. Dismantle
  the `IPC` base class.

### #9 — Factor the collector-reporter boilerplate into `Util::socket_reporter`
**Status:** ✅ DONE (batch 2, `fca4f3e42`) — see TODO_DONE.md · **Step:** foundation · **Depends:** —

**Problem:** 4 identical `Recorder::Socket->new(... no_reply, drain_input ...)`
reporter-construction sites + the same TCP-RST rationale comment (Runner.pm:1039,
Job.pm:319, Preloader.pm:293, **Plugin.pm:59** — the non-runner site).

**Steps:** keep the `no_reply`/`drain_input` fix (load-bearing). Add **standalone**
`Test2::Harness2::Util::socket_reporter($identity, $socket)` (not a Runner method —
`Plugin` is runner-decoupled, derives the socket from `$ENV{T2_HARNESS_WORKDIR}`)
that builds the reporter with `no_reply`, `drain_input`, **and `pid => $$`** (the #1
handshake pid). The 4 sites call it. Mark `identity_timeout` a backstop; don't grow it.

---

## TIER 2 — Consolidate / over-built

### #10 — Resolver retry → resolver ELIMINATED
**Status:** Decided · **Step:** 23 · **Depends:** #3

**Problem:** the scheduler-only runner resolves file→stage by a blocking per-file
round-trip to the base stage, retry-bounded by `preload_root_respawn_limit` (wrong
dimension; #3 deletes that limit). `_drop_preload_peers` busy-retention → see #3.

**Decision:** the resolver is **eliminated**, not fixed (chunk 23 — client-side stage
assignment). Delete `resolve_file_stage`, `resolve_file_stages`, `request_preload_sync`
(resolver use), `_resolver_identity`, the `file_stage` callbacks, and `eager`. Stage
choice is decided client-side at queue time (see #23 / §4.7a).

### #11 — Overlapping terminate/reap/timeout layers
**Status:** ✅ DONE — subsumed by #3/#4/#22 (single teardown path, watchdog narrowed); see TODO_DONE.md

**Decision:** after #3/#4/#8 the four "layers" become distinct: ChildMonitor multi-pid
self-termination (#3), a minimal zombie-reaper (#8), `Watchdog` narrowed to wind-down
abort (stage-gone → `requeue_task`, #3), and `check_timeouts` kept as a **thin,
debug-logged backstop** (TERM→KILL a reaped collector whose group lingers). Two
teardown paths → one: `stop_stages` (in-runner `Preloader::Stage`) is deleted by #4;
`stop_preload_stages` (socket peers) survives.

### #12 — Run state lifecycle: fold onto `Run`, connection-gated retention
**Status:** ✅ DONE (batch 5, `5ac411700`) — see TODO_DONE.md · **Step:** 22 · **Depends:** #1

**Problem:** `RUN_ITEMS` keeps a raw copy of every queued run forever (leak;
unbounded on a persistent runner); `run_item` returns only the active one.

**Steps:**
- Store the raw queue hash **on the `Run` object** (`$run->raw_item`); `run_item`
  returns `$RUN->raw_item`. One structure, auto-pruned with the run.
- **Retention gated on the queuing client connection** (recorded at `queue_run` from
  `$conn` + its `peer_pid`, #1) + an `abort_on_disconnect` flag (default true):
  finished+owner-connected → retain; finished+owner-gone → purge; running+owner-drops
  & flag true → **abort** (halt pending, kill jobs via watchdog `abort_remaining`,
  advance); running+owner-drops & flag false → detach, purge on completion (future
  `yath queue`).
- `queue_task`/`stop_run` are accepted from **any** command connection; only
  retention/abort is owner-gated.

### #13 — `%SORTED` → instance field, stable key, pruned
**Status:** ✅ DONE (batch 5, `44d4f1aa1`) — see TODO_DONE.md · **Step:** 16 · **Depends:** —

**Problem:** package-global `%SORTED` (sort memo keyed by arrayref address) leaks
forever, has a ref-reuse correctness bug (reused address skips the conflict sort), and
bleeds across State instances. It is a real optimization (re-sorting is O(N²logN) on a
big single bucket), so keep it.

**Steps:** make it an **instance field**; key by the **stable path tuple**
(`"$run_id\0$smoke\0$stage\0$cat\0$dur"`); clear a bucket's key on add in
`_queue_task`; clear keys matching `^<run_id>\0` in `_stop_run`. Comment the clear
sites: assumes a single active run — revisit for concurrent multi-run (chunk 16).

### #14 — Deep task partitioning + `prune_hash`
**Status:** ✅ DONE (rejected-keep + comment added, `next commit`) — the nesting is the priority index

The 5-level `PENDING_TASKS` nesting **is the scheduler's priority index** — it mirrors
`_next`'s nested priority traversal (smoke→stage→cat→dur); flattening would slow the
hot loop. `prune_hash` is justified GC. Keep as-is; add a comment that the nesting is
the priority index so it isn't re-flagged. (`run_id` outer key is already multi-run
forward-compatible.)

### #15 — Chunk-comment archaeology
**Status:** ✅ DONE (`97f51134a`) — 109 chunk-comments → 0; per-comment judgment (strip-current / delete-historical). See TODO_DONE.md

127 `# Chunk N.M` comments (Runner.pm 47, Handlers.pm 32). **Defer the bulk sweep**
until #1-#13 rewrite the heavily-commented code (sweep the final code). **Not a
blanket delete** — keep current-invariant explanations (strip the chunk prefix),
delete purely-historical ones. The lying `DORMANT` comments are fixed **now** as step
1 of #4.

### #16 — `run_ord` → rename `run_id` (keep the seam)
**Status:** ✅ DONE (batch 2, `212aca276`) — see TODO_DONE.md · **Step:** 16 · **Depends:** —

**Problem:** `run_ord` is the dormant socket-naming seam for run-scoped preload stages
(`runs/<run_ord>/preload-<stage>.socket`), needed once run-scoped stages + concurrent
runs combine (§6.1). The name is overloaded — `run_ord` means a run *ordinal* in the
UX/DB.

**Steps:** keep the seam (reject "remove"); **rename `run_ord` → `run_id`** in
`Role::Service` (`->can('run_id')`, doc, `service_socket_path`) and the Runner seam
comment. The value is always the run's UUID (never an integer); global preloads leave
it undefined (flat socket). Only used in Role/Service.pm + Runner.pm (clean rename).

### #17 — `scheduler_tick` fixes
**Status:** ✅ DONE (batch 3, `bb3830e96`) — see TODO_DONE.md · **Step:** 21-area · **Depends:** —

- **Bare hash keys:** `scheduler_tick`/`service_tick`/`check_timeouts` use
  `{'rootpid'}`/`{'signal'}`/`{'active_run'}`/`{'resource_timeout'}`/
  `{'scheduler_errors'}`/`{run_reached_timeout}` — convert to HashBase constants
  (`{+ROOTPID}` etc.) for compile-time/grep safety.
- **Retry-5 → fail-fast:** drop `SCHEDULER_MAX_ERRORS`; a `poll`/`advance`/
  `dispatch_pending` throw is a real in-process bug (the separate-process retry
  rationale died with the IPC model, #8). Resources own their own transient-error
  resilience inside `tick()`.
- **Reject** the two-level `service_tick`→`scheduler_tick` merge — `service_tick` has
  real logic (signal on `service_stopped`).

### #18 — Handler boilerplate + duplicated stale-generation guard
**Status:** ✅ DONE — guard-dup dissolved via #3 (connection-currency replaced _stale_stage_generation); factory rejected (kept explicit handlers)

The duplicated `_stale_stage_generation` guard dissolves via #3 (connection-currency,
one check). **Reject** the generic `action_handler` factory — it re-introduces the
command-string→method dispatch-table indirection #1 deletes; the thin explicit
decode-then-forward handlers are the right RPC surface (`submit_action` also isn't a
passthrough — it buffers until the base stage is ready).

### #19 — Delete stale stage-report methods from `Runner::Client`
**Status:** ✅ DONE (batch 1, `3d3e28d61`) — see TODO_DONE.md · **Step:** — · **Depends:** —

`Stage->_report` uses `service_send` directly, so `Runner::Client`'s `stop_task`/
`retry_task`/`reload`/`stage_ready`/`stage_down`/`job_pid` have **0 callers**. Delete
them; keep `Client` a command/query/subscription client. Fix the stale comment at
Runner.pm:333 (folds into #15).

### #20 — Preload `require` happens outside the guard
**Status:** Decided · **Step:** 19/23 · **Depends:** —

**Problem:** `Preload::_load_preloads` does a full `require` of preload modules at the
**handshake** (for metadata) **before** `test2_start_preload` — so require-time Test2
side effects escape the guard, and modules load twice.

**Decision (lightweight handshake):** handshake = dial + identify + `get_preload_list`
only (no `_load_preloads`, no `set_stage_data`). Load preloads **once under the
`test2_start_preload` guard** in the stage-host flow (which already builds the
`staged` meta); report `set_stage_data` + preload warnings **after** the guarded load.
The runner already blocks scheduling until the map arrives (`_ready_to_schedule`) — no
runner change. Deletes `Preload::_load_preloads` + the duplicate load; moves warning
capture to the single guarded load (shrinks #21).

### #21 — Preload failure: detection (done) vs diagnostics (simplify)
**Status:** Decided · **Step:** 11/23 · **Depends:** #3, #20

**Reframe — two concerns:**
- **Detection ("don't wait forever") — solved.** A crashed stage EOFs its socket (#3);
  `done()` stays 0 while tasks pend, so a legitimately slow (2+ min) named stage just
  waits — **no per-named-stage timeout**. Fixes: make the **map/base-stage readiness
  deadline configurable** (it's hardcoded 60s); add an **optional, configurable,
  generous/off-by-default per-stage startup timeout** (covers both `starting` **and**
  `restarting`/hung-reload) enforced by the preload resource — too-long → `available`
  = `-1` (skip/fail/abort). Closes the hung-stage (alive-but-never-ready) gap.
- **Diagnostics ("show why") — simplify.** The dead process's error is already
  recorded by its collector and surfaced by the renderer (tagged INTERNAL). The runner
  only needs to **know there was a problem** (fail the run) — **delete
  `_emit_preload_failure_output`'s inline zstd/jsonl scrape** (control-plane class
  carrying event-file decode).

---

## TIER 3 — Lower priority / deferred / rejected

### #22 — Fully untangle the runner from the preload-root (two independent classes)
**Status:** ✅ CORE DONE (`f23ceb44c`+`b628a3728`) — Preload::Host extracted, runner has ZERO rootpid guards; residuals: setjump-loop flatten + run_scheduler_only-as-only-path (see TODO_DONE/AI_DOCS). Unblocks #4 P5, #8, #23

**Owner directive (2026-06-20):** the runner and the preload-root are **completely
different concepts** entangled into one `Runner` class only because 1.0 grew organically.
**Make them two fully independent classes** — neither inherits from the other, and there
is **no shared base class or role designed just for them** to work around it. They share
**only** that both implement the **service role** (`Role::Service`) — both have a listen
socket + manage connections. Do **not** preserve the entanglement (the `~16 ROOTPID==$$`
guards + `Preload::_run_stage_host` building a `Runner` with `rootpid != $$` to reuse the
stage machinery is exactly what to remove).

- **The runner** = the harness **scheduler** + primary server/socket. Schedules, owns
  canonical state, serves clients/stages, launches tests **only as clean-slate fork+exec**
  (the no-preload path, #4 P4). No preloading, hosts no stage in-process.
- **The preload-root + stages** = preload + launch tests. **No scheduler**, no canonical
  run state — they preload, fork/host stages, and launch tests (goto::file) on dispatch.
  The stage-host machinery currently reused out of `Runner.pm` (`run_tests` staged loop,
  `Preloader::launch_stage` of named stages, `_stage_transition_reporter`, the
  `set_proc_exit` stage-relaunch branch, `dispatch_pending`'s in-process-stage branches)
  moves into this independent preload-host class.

After this the runner carries **only** scheduler + server + clean-slate exec; the
`ROOTPID==$$` role guards disappear. **Unblocks** #4 P5, #8's full `set_proc_exit`
removal, and #23. Big structural refactor of the most-depended-on file — green-first,
expect iteration.

### #23 — Three classes named "Stage" — rename
**Status:** ✅ DONE (`2de1be5d3`) — StageDelegate/StageProcess/StageConfig; `done` kept (live caller post-#22). See TODO_DONE.md

`Runner::Stage` (in-stage delegate), `Runner::Preloader::Stage` (`IPC::Process` proc
tracker), `Runner::Preload::Stage` (DSL config) collide (two differ by one letter).
All thin under #4/#8/chunk23 (eager/file_stage removed). **Defer; then rename** →
`StageDelegate` / `StageProcess` / `StageConfig`; coordinate with #22's split. Plus:
`Runner::Stage::done` always returns 0 → `die "impossible"` or drop.

### #24 — Resource base → Role with `requires available, assign`
**Status:** ✅ DONE (batch 2, `38f6b00a9`) — see TODO_DONE.md · **Step:** 11 · **Depends:** #5

**Problem:** the Resource base has 9 no-op methods; `available` defaults to `-1`
(forgetting it silently all-skips). `scope_global/host/run` are dead after #5 (only
SharedJobSlots overrode them) — remove.

**Steps:** make `Runner::Resource` a **`Role::Tiny` role that `use`s Object::HashBase**
with `requires 'available', 'assign'` (load-time enforcement). Object::HashBase has
first-class Role::Tiny integration — consumers compose via
`use Object::HashBase qw{ &Test2::Harness2::Runner::Resource ... }`, getting both the
`requires` and the HashBase attrs (no `use parent` breakage; see
`~/projects/Test2/Object-HashBase`). Keep no-op defaults for the optional hooks;
update POD away from inheritance. Implementers: `JobCount` + the future preload
resource (both define `available`+`assign`).

### #25 — Smaller notes (triage)
**Status:** ✅ DONE (batch 3, quick+verify fixes) — see TODO_DONE.md; moot items via #5/#8 · **Step:** various · **Depends:** —

- **Moot via #5/#8:** `_runner_todo` sentinel + `_redistribute_fair` "Yikes!" comment
  (SharedJobSlots, #5); `check_timeouts` base stub + `set_sig_handler` (IPC controller,
  #8); `min(grep)` clamp (only `JobCount` copies remain after #5 — leave).
- **Quick fixes:** `_drain_transitions` 50× spin → drain-until-deadline
  (`Time::HiRes`); `Preloader::_monitor` `Carp::longmess` → plain `die`;
  `Job::bailed_out` legacy out_file scan (dead since chunk 3) → delete; dead
  `Reloader::_can_reload`/`_find_loaded` → delete.
- **Verify-then-fix:** `find_churn` sleep-retry (confirm inotify covers it, remove);
  two file-watch loops (`Reloader` owns watching; `Preloader::check` calls it);
  `Util/IPC` IO-swap dup (`_run_cmd_fork`/`_run_cmd_spwn` — extract shared pre-exec).
- **Keep (decided):** bad-frame tolerance of 3 (`Connection.pm`); DepTracer dual hook
  (`@INC` + `CORE::GLOBAL::require` — useful belt-and-suspenders).

### #26 — Simplify `App::Yath::Script::V2`: drop the BEGIN hack, refactor into subs
**Status:** ✅ DONE (`12e20db92`) — see TODO_DONE.md

**Problem:** `do_begin` runs in the `yath` script's **BEGIN** phase, and its body is a
set of inline `# ==START/END TESTABLE CODE <NAME>==` marker blocks
(`PARSE_CONFIG_FILES`, `PRE_PARSE_D_ARGS`, `CLEANUP_PATHS`, `CREATE_APP`). Both are
1.0 artifacts: the logic lived in the `scripts/yath` script, all in BEGIN, in the
**`main`** namespace (which it must not contaminate) — so the blocks were
marker-delimited so `t/yath_script.t` could extract and run them in isolation. In 2.0
none of that holds: the `yath` script is only a command dispatcher; the preload
goto-file path runs in the **preload tree** (`perl -MTest2::Harness2::Preload=launch`),
**never** through a `yath ...` command — so nothing needs the yath-script BEGIN
environment — and `App::Yath::Script::V2` is a proper module, not `main`.

**Steps:**
- Move `do_begin`'s work **out of BEGIN** to plain early runtime; keep only the
  ordering that must precede loading command modules (`-D`/`--dev-lib` into `@INC`
  before `require App::Yath2` + command/plugin modules) and the `ORIG_*`
  (tmp/sig/argv/inc) capture, which only needs "early," not "BEGIN."
- Refactor the four `==TESTABLE CODE==` marker blocks into **clean named subs**
  (e.g. `_parse_config_files`, `_pre_parse_dev_libs`, `_realpath_paths`,
  `_build_app`) — real methods, droppable the marker-comment extraction hack.
- Update **`t/yath_script.t`** to call those subs directly instead of extracting the
  marker blocks.
- Collapse the `do_begin`/`do_runtime` split where it no longer earns its keep.
- Scope to `App::Yath::Script::V2` (our handler); the external `App::Yath::Script`
  dispatcher namespace is unchanged.

---

## Explicitly justified — do NOT cut

Load-bearing, all auditors agree: the unified `Role::Service`/`Connection` framing
layer; `Runner::Subscriber` parking deltas until after the snapshot;
`Runner::Monitor`'s render mirror; `stop_preload_root` not killing the collector
parent (the ChildMonitor backstop); the `no_reply`/`drain_input` fix (#9 — dedup, not
delete). Known migration gaps (not bloat): pfile discovery (ch12), `yath spawn`
(ch13), system-load (ch7), run-scoped stages.
