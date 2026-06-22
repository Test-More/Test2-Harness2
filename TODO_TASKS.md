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
  named-stage startup timeout, configurable deadlines, generous/off-by-default hung safeguard (#21). A vanished `run`/`test` command = crash/user-kill → **abort the run
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
  stages first — `exec` keeps the same pid, so multi-pid watch is the crash fallback,
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
**Status:** ✅ DONE (the substantive collapse). Parts 1-3 (`280720efb`); Part 4 (the
no-preload completion→socket / reap-driven verdict removal) was completed by #29
(`f7e836182` etc.) — that ticket states it "Completes #8 Part 4". Chunk 21 re-audit
(2026-06-21) closed the residual: deleted the dead `set_sig_handler` (`bc2cb3379`) and
corrected the §5.4 framing. **The base class is NOT dismantled** — `Preload::Host`
(created by #22) is a third co-equal multi-child consumer (its `run_stage`/`run_job`
loop), explicitly OUT OF SCOPE per #29, so the shared three-pass reaper +
`category`/`spawn`/`watch`/`killall`/`wait` all stay. See TODO_DONE.md.

**Problem (original framing — see Status for what actually happened):** the IPC
controller does spawn + zombie-reap + category tracking + reap-driven scheduling. Only
the first two should survive. The original audit assumed only two consumers — the
Runner and `test.pm` (one child — the runner) — but the #22 split added a third,
`Preload::Host`, which is still a genuine multi-child controller. `Job::set_exit` says
results already come from the collector, not the reap.

**Steps (outcome annotated):**
- ✅ Migrate **no-preload** job completion onto the collector socket report (like the
  preload path), then strip the reap-driven verdict from `Runner::set_proc_exit` — done
  by #29. (Its Job branch is now zombie cleanup + A3 health; the dead in-runner
  named-stage branch was removed in #4/#22, and the live named-stage relaunch lives in
  `Preload::Host::set_proc_exit`.)
- ✅ Delete `PROCS_BY_CAT`/`cat`-waits — done by #6. ❌ **NOT** removing the
  `_check_if_dead_yet` process-group wait or `_ex_parrots`: they are load-bearing for
  the watched no-preload reap (group-exit gate) and for `Preload::Host`'s `wait()` loop.
  ✅ die-on-unmonitored removed (Part 1, `f0c84daa9`).
- **Keep** `Util::IPC` (`run_cmd`/`swap_io`/`set_cloexec`/`USE_P_GROUPS` — the real
  reusable primitive) and a thin `IPC::Process` value object (exit-tracking retained —
  the croak-on-double-set is a reap-once guard, not a verdict input). Runner keeps a
  minimal `waitpid` zombie-reaper; the command inlines its one-child spawn+wait.
  **Dismantling the base class is deferred** until `Preload::Host` collapses its own
  `run_stage`/`run_job` machinery (a separate, larger piece).

### #9 — Factor the collector-reporter boilerplate into `Util::socket_reporter`
**Status:** ✅ DONE (batch 2, `fca4f3e42`) — see TODO_DONE.md · **Step:** foundation · **Depends:** —

**Problem:** 4 identical `Recorder::Socket->new(... no_reply, drain_input ...)`
reporter-construction sites + the same TCP-RST rationale comment (Runner.pm:1039,
Job.pm:319, Preloader.pm:293, **Plugin.pm:59** — the non-runner site).

**Steps:** keep the `no_reply`/`drain_input` fix (load-bearing). Add **standalone**
`Test2::Harness2::Util::socket_reporter($identity, $socket)` (not a Runner method —
`Plugin` is runner-decoupled, derives the socket from `$ENV{T2_HARNESS_WORKDIR}`)
that builds the reporter with `no_reply`, `drain_input`, **and `pid => $$`** (the #1
handshake pid). The 4 sites call it. Mark `identity_timeout` a fallback; don't grow it.

---

## TIER 2 — Consolidate / over-built

### #10 — Resolver retry → resolver ELIMINATED
**Status:** ✅ DONE (`af8153696`) — resolver/file_stage/eager eliminated; client-side 3-field assignment; full §4.7a preload Resource (= chunk 11). See TODO_DONE.md

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
debug-logged fallback** (TERM→KILL a reaped collector whose group lingers). Two
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
**Status:** ✅ DONE (`91afaac78`) — lightweight handshake; preloads load once under the guard; map+warnings reported from the stage host. See TODO_DONE.md · **Step:** 19/23 · **Depends:** —

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
**Status:** ✅ DONE (`419571793`) — zstd scrape deleted; `--preload-map-timeout` + off-by-default `--preload-stage-startup-timeout` (§4.7a safeguard). See TODO_DONE.md · **Step:** 11/23 · **Depends:** #3, #20

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
**Status:** ✅ CORE DONE (`f23ceb44c`+`b628a3728`); setjump-loop flatten DONE (`7e6ed23f8`) — Preload::Host extracted, runner has ZERO rootpid guards; remaining residual: run_scheduler_only-as-only-path (coupled with #8 Part 4 — see TODO_DONE). Unblocks #4 P5, #8, #23

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

## TIER 4 — Transition-driven completion + subreaper (designed 2026-06-21, reviewed)

> Replaces the old #8-Part-4 framing. Design context + rationale + the two-reviewer
> findings we resolved: `AI_DOCS/2026-06-21-transition-driven-completion-and-subreaper.md`
> (read it first). Authoritative spec: ARCHITECTURE.md §5.4 (+ §4.1/§4.7).
> Active sequence **#32 → #27 → #28 → #29**; deferred follow-ups #30/#31. They span the
> local `Test2-Collector` checkout (no version bump — unreleased). Review-driven
> standalone fixes: #33–#37.

### #27 — Transition-driven test completion; collector exit = health-only
**Status:** ✅ DONE — Phase 1 collector (`5c3ada3b` in Test2-Collector) + Phase 2a (`472946279`..`13c6f8b00`) + Phase 2b (`dba86899e`..`5dbfab743`). See TODO_DONE.md · **Step:** 24

**Problem:** the runner decides a test's outcome from the **reaped collector exit
code** (`JobLauncher` exits with `Job::_collector_exit_code`, which layers the audited
verdict + writes a `bail` file; `set_proc_exit` reads `$exit` to pick retry/stop/bail).
The exit code cannot express a bail-out, and on the preload path the runner never sees
it (the stage reaps). The audited result is already on the wire (`harness_final_state`
→ `runner.socket`) — decide from that.

**Decision (resolved with two reviews — ARCHITECTURE §5.4):**

*Collector side (`Test2-Collector`, local checkout):*
- Emit an early **`halt` transition** (`harness_state_transition` `state => 'halt'`,
  carrying the reason in `details`) the moment a halt/terminate control facet is seen
  (keep `final_state.halt`).
- **Child-fd hygiene:** the collector closes its reporter/recorder sockets in the test
  child (and the no-exec `goto::file` preload launch closes them + inherited runner
  conns) — see #32; sockets created `FD_CLOEXEC`.
- **Bidirectional connection:** the test-collector connection must **read inbound
  control messages** from the runner (the bail/terminate message) between events —
  today's reporters are one-way (`no_reply`); that changes.
- Handshake carries `pid` (already health-only exit via `Runner->spawn_exit_code`).

*Harness side:*
- Decide every outcome from transitions + **connection EOF** (drain frames on EOF):
  final_state seen → pass / `!pass`⇒retry-if-tries (re-queue same `job_id`, new
  `job_try`) / `halt`⇒bail; **absent ⇒ fail** (flag possible-harness-internal **unless**
  the runner deliberately terminated it ⇒ `aborted`). **Invariant:** collector problem
  or missing final_state ⇒ fail, never a false pass.
- **Connection identity / stale-try (A5):** store the full identity; register
  `conn → {pid, job_id, job_try, run_id}`; idempotent close; ignore an EOF/report whose
  `job_try` ≠ the current try (retire a superseded try's connection).
- **No-verdict render mutation (A6):** emit a runner-originated terminal
  `harness_runner_job` failed/aborted (`job_id`/`run_id`/`file`/`job_try`/reason),
  consumed once, for any completion with no collector `final_state`. Reason = harness
  output.
- **Bail + abort teardown (A4 / B3 / B4):** the runner→collector **terminate message**
  is the primary teardown. Bail (`--abort-on-bail`): stop dispatch for the run, message
  every run collector to terminate (kill child, record "external bail-out", exit→EOF),
  message late-connecting collectors too; `halt` wins over retry. `yath abort` +
  owner-disconnect abort use the **same** message via a recorded **abort intent** (no
  stale-pid snapshot). Pid/`kill(-pid)` is fallback only.
- **Exit handling (A8):** test-job parent exits via the collector's
  `Test2::Collector::Runner->spawn_exit_code` (health-only); **delete
  `Job::_collector_exit_code`** + the `bail` file; keep `Util::collector_exit_code` for
  **non-test** wraps (runner/stage/aux). Remove reap-driven retry/stop/bail from
  `Runner::set_proc_exit` **and** `Preload::Host::set_proc_exit`; drop
  `StageDelegate`/`Runner::Client` verdict reporting.
- **Post-pass collector failure (A3):** a collector that fails *after* reporting
  `pass` keeps the test green; on a **supported** platform the reaped non-zero health
  exit ⇒ report to harness output + **mark the suite failed** at `test`/`run` exit; on
  unsupported it may be lost (accepted). Mandatory reporter + `--collector-connect-timeout`
  (#32). Retry policy stays runner-side (`--retry` + existing directives).

### #28 — Runner child-subreaper + detached preload collectors
**Status:** ✅ DONE. Original code (`7952029e6`..`ab1a95865`) was DEAD on the preload
path (re-audit 2026-06-21); the two defects are now fixed standalone (no longer folded
into #29): **C2** — pid-keyed `collector_reap` map populated at the pass decision,
survives the collector's EOF, consumed by `_reaped_unwatched_pid` (`def11c2fe`);
**C1** — `run_scheduler_only` now calls `_bring_out_yer_dead`/`_check_if_dead_yet`
each tick + at wind-down, with a `PRELOAD_ROOT_REAPED` guard so the sweep's
`waitpid(-1)` can't hide a mid-run preload-root crash (`f03ff402c`); **M3** —
`t/AI/integration/Runner_scheduler_reap_a3.t` drives the REAL loop (`7e5394bc0`).
Both runners green. · **Step:** 25 · **Depends:** #27

**Problem:** to make the runner the sole reaper (and free the preload tree from any
reaping logic), preload-spawned collectors must detach and re-parent to the runner.

**Steps:**
- New **`Test2::Harness2::Util::SubReaper`** (pure-Perl, no XS, no dep): acquire/release
  child-subreaper via `syscall()` — Linux `prctl(PR_SET_CHILD_SUBREAPER)` (per-arch
  `SYS_prctl` table: x86_64=157, aarch64/riscv64=167, i386=172; `PR_SET_CHILD_SUBREAPER`=36),
  FreeBSD/DragonFly `procctl(P_PID,$$,PROC_REAP_ACQUIRE)` (`548`, `P_PID`=0,
  `PROC_REAP_ACQUIRE`=2); unknown OS/arch or failed call ⇒ eval-guarded graceful
  "unsupported". Reparenting logic lives in **this util, not inlined in `Runner.pm`**.
  Port the local `Test2-Harness2-ChildSubReaper/t/40-subreaper-behavior.t`.
- Runner acquires subreaper at startup. **Preload-spawned collectors double-fork +
  detach** (`setsid` ⇒ own process-group leader, so `kill(-pid)` reaches the subtree;
  re-parent to runner on supported OS, init otherwise). Preload tree reaps no
  collectors. **Runner learns pids from the collector handshake** (#27), so the stage
  tracks none — moots any double-fork pid-pipe. `job_pids` cleared on EOF. Decision
  rides EOF regardless of who reaps. ARCHITECTURE §4.1/§5.4.

### #29 — Collapse to one run path (run_scheduler_only only)
**Status:** ✅ DONE (`5729726d9` extract _launch_local_job + no-preload spawn reject;
`2f186de4d` port the no-preload run-loop duties; `371c82eab` no-preload e2e guard;
`f7e836182` the collapse — run_scheduler_only is the only loop, run_tests/run_stage/
run_job/end_test_loop deleted). Kept the flag name `_preload_root_hosts_stages` (still
accurate; the cosmetic `_has_preload_root` rename was skipped to avoid churning the
just-stabilized file). No-preload collectors stay WATCHED. Verified both runners 3×.
· **Step:** 26 · **Depends:** #27, #28

**Problem:** with completion + reaping off the reap, the in-runner stage machinery is
vestigial. **Steps:** make `run_scheduler_only` the runner's only run loop; the
no-preload dispatch forks a collector child and decides via transitions/EOF like the
preload path; delete `run_tests`/`run_stage`/`run_job` in-runner stage machinery and
`_preload_root_hosts_stages`/`PRELOAD_ROOT_HOSTS`. Completes the **#22 residual**,
**#4 Part 4**, **#8 Part 4**. ARCHITECTURE §5.4.

**Note:** the #28 C1/C2 reap defects are already fixed standalone (see #28 above), so
the per-tick reap is ALREADY in `run_scheduler_only` and is NOT part of this chunk.

**Vetted design (workflow map+design+adversarial-review, 2026-06-21 — the naive plan
had real blockers; these are the corrected requirements):**
- **Keep no-preload collectors WATCHED** (runner forks via `IPC::spawn`, in `{+PROCS}`,
  reaped via `set_proc_exit` with `job_id` from the proc's task). Do NOT detach them —
  it preserves the simpler A3 path and avoids forcing everything through C2. The unified
  loop runs BOTH reapers (already wired): `_bring_out_yer_dead` (unwatched/preload) +
  `_check_if_dead_yet` (watched/no-preload). A3-no-double-fire holds because
  `_check_post_pass_health` DELETE-consumes `job_passed`.
- **Single launch branch in `dispatch_pending`, keyed on `_has_preload_root`** (the
  renamed `_preload_root_hosts_stages`), **NOT** on live-peer presence — a transiently
  disconnected preload stage must still `requeue_task` (§4.7a), not local-fork. Preload
  run ⇒ `service_send`/requeue (unchanged); no-preload run ⇒ `_launch_local_job`
  (extracted `run_job` else/spawn body; preserve `$task->{via}` custom-job-class launch;
  drop only the dead `FORK_JOB_CALLBACK` arm).
- **Port into `run_scheduler_only` (no-preload-scoped) BEFORE deleting the in-runner
  loop:** `state->stage_ready('default')` (else no-preload tasks never bucket 'up' and
  the run HANGS — top blocker); `orphaned()`⇒`SIGNAL TERM` and `preloader->check`⇒HUP
  from `end_test_loop` (else a persistent no-preload runner never self-shuts-down);
  `killall($SIGNAL)` at wind-down (from `run_stage`); the `dump_depmap` write (or
  document --dump-depmap as preload-only).
- **No-preload spawn: REJECT cleanly.** `take_dispatch_tasks` never returns spawns
  (they live in `PENDING_SPAWNS`, drained only by `next_task` which `run_job` deletion
  removes); a no-preload spawn today crashes on an `undef FORK_SPAWN_CALLBACK`. Make
  `_launch_local_job`/`request_handler_queue_spawn` reject it with a clear error + a test.
- **Then delete** `run_tests`/`run_stage`/`run_job`/`end_test_loop` + the `<stage` slot;
  rename `_preload_root_hosts_stages`→`_has_preload_root` (readers: Runner 263/718/791 +
  `Handlers.pm:1085`); point `process` at `run_scheduler_only`.
- **Same-commit test edits:** `Runner_dispatch_abort.t` (discriminator), `Runner_orphan.t`
  (drop/rewrite the `end_test_loop` subtest — `orphaned` survives). ADD a no-preload
  end-to-end test that schedules+forks a job through `run_scheduler_only` (the existing
  M3 reap test stubs the scheduler, so it would NOT catch the `stage_ready` omission).
- **Order green-first:** keep the dual path real until the final commit — `run_job`
  delegates to `_launch_local_job` first; do `take_dispatch_tasks(undef)` + the
  discriminator + deletions + ports all in the LAST commit (single rollback point).
  Verify both runners 3× (flake) + `ps` zombie-free on a no-preload AND a `--preload` run.
- Completes the **#22 residual**, **#4 Part 4**, **#8 Part 4**. Host (`Preload::Host`, a
  sibling `IPC` subclass with its OWN run_tests/run_stage/run_job) is OUT OF SCOPE.

### #30 — Generic `collector_transition` facet + plugin hook
**Status:** Deferred · **Step:** 27 · **Depends:** #27

A test emits an event with a `collector_transition` facet; the collector forwards it
verbatim as a transition; the runner routes **non-builtin** transitions to a **plugin
hook**. Extensible substrate for custom harness-significant signals.

### #31 — Runtime retry-request helper
**Status:** Deferred · **Step:** 28 · **Depends:** #27, #30

A test-facing helper a test calls to request a retry at runtime; emits an event the
collector turns into a `retry` transition (generic facet or `control.retry`); the
runner retries via the normal re-queue path. Count/no-retry directive already exists;
this adds the runtime channel.

### #32 — FD hygiene: no socket-fd leaks across forks (prerequisite for EOF)
**Status:** ✅ DONE (`3dde68850`) — fd-hygiene core; mandatory-reporter + connect-timeout deferred to #27. See TODO_DONE.md · **Step:** 24 · **Gates:** #27

**Problem:** the EOF-as-gone-signal model (#27/§5.4) is only sound if **no other
process holds a dup** of a collector's connection fd — a UNIX socket EOFs only once
*all* holders close it. The runner forks a collector parent **without exec** (inherits
the listen socket + every other live collector's connection); the test child and its
descendants can inherit the collector's reporter socket (esp. the no-exec `goto::file`
preload launch). Any leaked dup ⇒ a dead collector's connection never EOFs ⇒ hang /
false "still running".

**Steps:**
- Create every harness/collector socket **`FD_CLOEXEC`** (covers exec paths).
- **Explicit post-fork close-sweep** for the no-exec forks: the collector parent closes
  all inherited runner connections + the listen socket; the **preload test-launch
  (`goto::file`)** path closes the collector's reporter/recorder sockets + any inherited
  runner connections before becoming the test.
- Make the **reporter mandatory** (#27): connect-failure ⇒ synchronously fail/abort the
  job (runner-visible), never silent recorder-only degrade. Add **`--collector-connect-timeout`**
  (on by default, ~30s) for "dispatched but no `starting` transition arrived".
- **Regression:** a preload test forks a long-lived descendant that outlives it ⇒ the
  runner still sees the collector's EOF promptly. ARCHITECTURE §5.4.

### #33 — Enforce `preload_stage_startup_timeout` in the scheduler (it is currently inert)
**Status:** ✅ DONE (`1b0a1312b`) — per-tick scan demotes timed-out stage to down + rebuckets; integration test. See TODO_DONE.md · **Step:** 11

**Problem:** the #21 safeguard never fires. The scheduler buckets a task via
`State::task_stage()` (no timeout) and `_stage_order`/`_next` only traverse **`up`**
stage buckets, so a task aimed at a stage stuck `starting`/`restarting` is never
visited and `Resource::Preload::available()`'s `-1` is never consulted. The #21 unit
test only drove `available()` in isolation.

**Steps (approach A):** a per-tick stage scan transitions a `starting`/`restarting`
stage that exceeds `preload_stage_startup_timeout` to **`down`** — which makes
`_stage_order` skip it **and** makes `task_stage` re-resolve its bucket (down ⇒ falls
to default if advisory, or the require path fails). Add an **integration test driving
the full scheduler path** (not just `available()`).

### #34 — `yath reload` ineffective during a persistent preload run
**Status:** ✅ DONE (`0b659a90f`) — reload routed to live base-stage channel; stop drops pending reload. See TODO_DONE.md · **Step:** 19

**Problem:** the runner forwards `reload` as a socket message to the **`preload-root`**
peer, but during a run the preload-root is blocked in `_run_stage_host` and does not
pump its own service loop until post-run idle — so the reload sits unread (or fires
late during shutdown, re-execing while stopping).

**Steps (approach A):** route `reload` to a **live-during-run** target — the active
base-stage connection (`preload-base`) owned by `Preload::Host`, which translates it
into its existing in-run respawn path (`SIGNAL=HUP` → end-loop → respawn the tree).
Make it idempotent/ordered so a pending reload is dropped once `stop` is queued.

### #35 — `halt_run`/`purge_run` leave stale tasks in `TASK_LOOKUP`
**Status:** ✅ DONE (`e4e64f6b8`) — clear TASK_LOOKUP on halt_run+purge_run + test. See TODO_DONE.md · **Step:** 22

**Problem:** `halt_run`/`purge_run` delete the run's buckets but not its `TASK_LOOKUP`
entries. `_queue_task`'s duplicate guard checks `TASK_LOOKUP` before `HALTED_RUNS`, so
stale entries stay addressable (can block a same-`job_id` task) and a persistent runner
retains task hashes indefinitely after aborts/truncates.

**Steps:** clear the run's `TASK_LOOKUP` entries in `halt_run` **and** `purge_run`. Add
a test assertion that the run's tasks are gone from `task_lookup` after abort/purge.

### #36 — Delete dead `reset_stage_readiness`
**Status:** ✅ DONE (`4403aa4c0`) — verified zero callers, deleted sub + test. See TODO_DONE.md · **Step:** 10

**Problem:** `State::reset_stage_readiness` was for a respawned crashed preload-root,
but preload-root crashes are fatal/never respawned (#3) — verified zero production
callers (only `t/AI/unit/State_stage_lifecycle.t:62`).

**Steps:** **re-verify no consumers**, then delete the sub + the test subtest that
exercises it.

### #37 — Document the resource-skip `-e` executor assumption
**Status:** ✅ DONE (`e29259adc`) — comment added. · **Step:** 11 · **Doc-only**

**Problem:** the permanent `resource_skip` path runs a dummy via `perl -e '...'`,
assuming a Perl-compatible `-e` executor. Safe today (non-Perl/binary jobs do not run
under preloads, so cannot trigger a `Preload` resource skip), but undocumented.

**Steps:** add a comment at the skip-command assembly noting the `-e` assumption and
that a future resource-skip on a non-Perl/custom executor must supply its own skip
representation. No behavior change.

---

## TIER 5 — Spawn / interactive / client / render-loop (designed 2026-06-21, reviewed)

> Design context + rationale + the two-reviewer findings we resolved:
> `AI_DOCS/2026-06-21-spawn-interactive-client-render-spec.md` (read it first).
> Authoritative spec: ARCHITECTURE.md §4.8 (spawn), §4.10 (interactive), §4.11
> (harness-client), §4.12 (render-loop), with §4.5/§4.6 amendments. Sequence
> **#38 → #39 → #40** (fd-pass primitive, then spawn, then interactive); **#41** and
> **#42** (client + render-loop refactors) are independent of the IO work. Steps
> 29/13/20/30/31.

### #38 — Socket FD-pass primitive `Test2::Harness2::Util::FdPass`
**Status:** ✅ DONE (`2feed5304` + `59dd29a05`) — `Test2::Harness2::Util::FdPass`
(SCM_RIGHTS `send_fds`/`recv_fds` + `command_listen`/`target_connect`; optional
`IO::FDPass`, actionable die when absent) + unit test (round-trip gated on the module;
the guard/absent path is always exercised). No consumers yet (#39 spawn / #40
interactive). · **Step:** 29 · **Gates:** #39, #40

**Problem:** spawn + interactive need to give a child the user's *real* terminal fd
(single keystrokes, raw mode, debugger-correct), not a byte proxy. The 1.0 `/proc`
proxy and the earlier "dup2-socket-onto-stdio" idea both still copy bytes through a
middle process.

**Steps:**
- New **`Test2::Harness2::Util::FdPass`**: `send_fds($sock,\@fds)` / `recv_fds($sock,$n)`
  via **SCM_RIGHTS** ancillary data, over **`IO::FDPass`** (one fd per call, looped;
  the receiver knows the expected count). Port the proven shape from
  `reference/old3/lib/App/Yath2/Spawn/FdPass.pm` (it used `Socket::MsgHdr` — keep that
  as the fallback reference). Both ends MUST use the same backend.
- **`IO::FDPass` is OPTIONAL** — a Recommends/Suggests in `dist.ini`, **not** a hard
  requires. spawn + interactive `require` it dynamically and **error early with an
  actionable message** if absent (spawn: at command start; interactive: in the option
  post-process where the FIFO is set up today). The lean `test`/`run`/`start` path
  never loads it. The **target side** (`Preload::Host` / the test) must also guard the
  `require` and turn a failure into a **structured spawn rejection / clean collected
  interactive failure**, never a raw post-accept crash (a stage under a different
  `@INC`/older install may lack it even when the command has it).
- Choreography is **command-listens / target-dials** (the fd flows command→child).
  Command-side listen sockets live in a short private tmp dir via `File::Temp`
  (≤108/104-char `sun_path` cap), random names, `0600` (dir `0700`), `unlink`ed after
  accept; created `FD_CLOEXEC`; the received dup fds are closed after `dup2`.
  ARCHITECTURE §4.8/§4.10, §5.2/§5.3.

### #39 — `spawn` redesign: direct-to-stage, fd-pass, supervisor (no exec)
**Status:** Decided · **Step:** 13 · **Depends:** #38, #12 (discovery), `Preload::Host`

**Problem:** today `yath spawn` goes *through* `runner.socket`, proxies IO via
`/proc/<pid>/fd`, and delivers exit via an `ipcfile`. Target: bypass the runner, pass
the real terminal fds, preserve the preload, deliver real wait status.

**Steps:**
- **`Preload::Host` gains `request_handler_spawn`** (it composes only `Role::Service`,
  so it must learn the command): accept `{file, args, env_vars, cwd, abs_path,
  correlation_id, listen_socket_path}`, **async double-fork** a detached supervisor,
  and ack `{ok=>1}` without blocking the host loop. The command discovers the stage
  via the §5.3 symlink + `preload-<stage>.socket` and connects **directly** (not the
  runner).
- **Supervisor (holds the preloaded image):** dials the command's listen socket,
  `recv_fds` STDIN/OUT/ERR, forks a **script child**. The script child **must NOT
  `exec`** (exec wipes the preload — the whole point of spawn): it `dup2`s the fds
  onto 0/1/2, runs **post-fork sanitization** (close inherited service/runner/collector
  sockets + the command listener — preserve the §5.4 EOF model — close the recv'd dup
  fds, `test2_stop_preload`/`test2_post_preload_reset`, `do_post_fork`/`do_pre_launch`),
  and **unwinds into the preloaded interpreter via `Long::Jump`/`goto::file`** (the
  mechanism current `launch_spawn` already uses, `JobLauncher.pm`). No collector wraps
  it.
- **Control channel = dedicated mini-protocol** on the same socket *after* the
  SCM_RIGHTS message (whose one `\0` payload byte the receiver consumes). **Not**
  `Role::Service::Connection` (identity-first framing collides with the fd-pass byte).
  Carries: supervisor pid; forwarded signals/winch (command traps + forwards — a
  `setsid` child has no controlling tty); and the child's **raw wait status** at exit
  (signal-death reported + re-raised on the command, the 1.0 `parse_exit` behavior —
  not just an exit code).
- **Detached from harness, bound to command:** the supervisor watches the control
  connection; on **EOF** (command/terminal died) it `kill(-pgid)`s the script child
  and exits. The spawned process survives runner/stage teardown but **does not outlive
  the command**.
- **Cleanup:** retire the `/proc/<pid>/fd` proxy + `ipcfile`; `spawn` no longer routes
  through `runner.socket`. ARCHITECTURE §4.8.

### #40 — interactive redesign: STDIN-only fd-pass, per-test accept
**Status:** Decided · **Step:** 20 · **Depends:** #38, #39 (shares the primitive) · **Note:** supersedes the old #7 (7b)

**Problem:** the 1.0 FIFO STDIN-proxy (`POSIX::mkfifo`, `$ENV{YATH_INTERACTIVE}`,
`goto::file` re-open) is clunky and has a broken open-retry loop.

**Steps:**
- **STDIN only** — `STDOUT`/`STDERR` stay with the collector (recorded + rendered via
  §4.5); only STDIN is shared. (Corrects §4.10's earlier "all three streams".)
- The command **opens a listen socket only when `--interactive`**; `$ENV{YATH_INTERACTIVE}`
  carries the **socket path**. The test **dials in, `recv_fds` the real STDIN fd,
  `dup2`s it onto fd 0** — preload path in the `goto::file` filter; **no-preload path**
  via a **pre-exec connect+recv+dup2(0)** in the collector/launch setup gated on the
  env var (name the exact hook in both paths).
- **One pass per test:** `-j1` (isolation category, already in place) means N
  sequential tests; the command keeps the listener open, passes the fd **once per
  test**, with connect timeout + cleanup, and stops accepting when the run ends.
- No control channel (the test is a normal collected job — verdict from its collector,
  signals via the existing job-signal machinery). Same controlling-terminal limitation
  as §4.8 (no `/dev/tty`/job-control without forwarding). Add tests: `perl -d`, raw
  mode, `/dev/tty`, Ctrl-C, Ctrl-Z, WINCH. Remove the FIFO patch. ARCHITECTURE §4.10.

### #41 — Harness-client library (grow `App::Yath2::Client`, Option A)
**Status:** ✅ DONE (`d3f4800e8` + `8e23cd887`) — `App::Yath2::Client` owns the
runner-lifecycle mode enum (transient/attach/start), absorbs `RunPlan` (finders +
job-spec), exposes state queries over the mirrored Monitor; `test`/`run`/`start`/`watch`/
`stop`/`abort`/`kill`/`status`/`resources` thinned onto it (the `run extends test`
override pile + inline runner spawn/reap/signal gone, ~250 lines). Dead IPC imports
dropped from run/start (ch21 follow-up). No backend changes needed. · **Step:** 30

**Problem:** `test`/`run`/`start` repeat work and lean on complex polymorphism
(`run extends test` with ~12 overrides; runner spawn/reap/signal inline in `test.pm`).
`App::Yath2::Client` exists but only wraps the submit + subscribe transports.

**Steps:**
- Grow `App::Yath2::Client` into the bridge between `App::Yath2` and `runner.socket`,
  owning: (a) a **runner-lifecycle mode enum** — *transient* (spawn the
  collector-wrapped runner, own+reap, trap+forward `INT`/`TERM`/`HUP` to the runner
  process group), *attach* (discover the persistent runner via §5.3, `kill(0)`
  liveness, never reap), *start* (spawn the daemon, write discovery state, return);
  (b) **finders + job-spec building** (absorb `RunPlan`); (c) **state-query accessors**
  over the mirrored `Monitor` (`jobs_in_state`, `events_file_for`, run/job rollup).
- **Thin the commands:** `test` = client *transient* + render loop; `run` = client
  *attach* + render loop; `start` = client *start*, no render loop. Delete the
  `run extends test` override pile + the inline runner lifecycle in `test.pm`.
- Does **NOT** own renderers (#42). `spawn` uses the client only for stage discovery.
  ARCHITECTURE §4.11.

### #42 — Render-loop library (`RenderLoop` + `Producer`, Option A)
**Status:** ✅ DONE (`33f5a59ec` + `7a2e6bf9b`) — `App::Yath2::RenderLoop` (owns dispatch
fan-out + sink lifecycle + rollup; `iterate()`/`start()`) + pure `Producer` role;
`LiveProducer` (Driver in collect mode — per-job ordering + bounded-terminal false-FAIL
fix preserved) + `JSONLFileProducer` (replay). `test`/`run`/`watch`/`replay` drop their
bespoke loops. Backend seam: `Renderer::Base` `dispatch_cb`. `ArchiveProducer` deferred
to the DB rewrite. · **Step:** 31

**Problem:** the render loop is duplicated across `test`/`run` (inherited),
`watch` (own loop), and `replay` (own loop, bypasses `Renderer::Base`). RL-1/RL-2 of
the draft were internally inconsistent about who owns the `Driver` (reviewer flagged).

**Steps:**
- New `App::Yath2` **`RenderLoop`** that **owns dispatch + the sink lifecycle
  (`step`/`finish`/`signal`) + the run rollup (`compute_final`)**, wrapping the
  `Test2::Harness2::Renderer::Base` mechanics. Entry points: **`->iterate()`** (one
  pass) and **`->start()` / `->start(sub {…})`** (loop owns the iteration).
- A **`Producer` is a pure source** (`poll()`→ordered events, `done()`, optional
  `finalize`). Extract: **`LiveProducer`** (the `Subscriber`/`Monitor` mirror + the
  current `Renderer::Driver`'s per-job *ordering*; the `Driver`'s dispatch +
  `compute_final` + **bounded `wait_terminal`** move into the loop — **preserve** the
  false-FAIL fix) with `done()` = socket-closed (`test`) / `run_done` (`run`); the
  `watch` variant yields runner/service output only; **`JSONLFileProducer`** wrapping
  the existing flat-`.jsonl` reader to keep `replay` working.
- **`ArchiveProducer` (DB log) is deferred** to the DB-layer rewrite (build a `Monitor`
  snapshot from state rows + read events from artifact blobs; needs the
  `JobReader`/`RunnerReader` **byte-source generalization**, §4.5). The
  `JSONLFileProducer` is deleted when it lands.
- Sinks fed only self-contained `Event` objects, so a slow sink can later run in its
  own process (not built now). ARCHITECTURE §4.12 (+ §4.5/§4.6).

### #43 — System-load service + throttling resources (chunk 7)
**Status:** ✅ DONE (2026-06-21) — built & green · **Step:** 7 ·
**Depends:** #24 (Resource Role, done), chunk 9 (done)

**Landed:** `Test2::Harness2::SystemLoad` (sampling primitive) +
`Test2::Harness2::Service::Sampler` (always-on dedicated sampler the runner spawns
under a collector with `watch_parent_pid`, change-gated 0.2s reporting, one-way
`system_load` over `runner.socket`); runner-side `request_handler_system_load` →
`State::set_system_load` + `announce_system_load` (`harness_system` broadcast
globally, latest retained in `Runner::Monitor`); throttling resources
`Resource::CPU` / `Resource::Memory` composing the #24 Resource Role +
`Role::Resource::Utilizer` (min_concurrent floor), reading the shared snapshot
(cross-platform Linux+BSD); `--utilize`/`-U` + `-R CPU[=70]` / `-R Memory[=20%|512mb]`
wiring; reap-at-stop handled (`Runner::stop_sampler`). See
`AI_DOCS/2026-06-21-system-load-throttling.md` and the ARCHITECTURE.md §4.4 addendum.

**Goal:** a dedicated system-load sampler service + opt-in CPU/memory throttling
resources. The sampler design is locked (ported verbatim-in-spirit from
`reference/harness_service`); the throttling-resource model is ported from
`reference/old3` `Resource::CPU`/`Resource::Memory`, rewired to read the sampler's
snapshot. (Sampler half was previously prototyped exactly as wanted; only the
resource-consumption half was deferred there.)

**Decided design:**
- **Sampler** = port `reference/harness_service` `Test2::Harness2::SystemLoad` (sampling
  primitive: cpu_pct/mem_pct/load_avg/mem_*; Linux `/proc`, BSD `sysctl`) +
  `Service::Sampler` (dedicated process, steady **0.2s** tick → meaningful CPU delta;
  one-way `system_load` reports to the runner). **Reporting is change-gated:** round
  **UP to 5%**, CPU & memory tracked independently; an **increase reports immediately**,
  a **decrease only after it holds `decrease_delay` (1.0s ≈ 5 ticks)**, unchanged →
  nothing; a message carries both rounded values. Runner stores the snapshot in a
  `system_load` slot + announces a `harness_system` transition to the Monitor, broadcast
  globally (latest retained for late subscribers).
- **Always-on:** the sampler runs whenever the runner runs (NOT only when a throttling
  resource is requested) — its transitions are logged so the rendered/archived run shows
  system load at each point, independent of gating. (User decision.)
- **Throttling = Resource classes** (the model — resources, NOT an ad-hoc scheduler
  check; needs only the #24 Resource Role, NOT chunk 11), ported from `reference/old3`
  via a `Role::Resource::Utilizer`, but reading the sampler's `system_load` snapshot
  (cross-platform: Linux+BSD) instead of inline `/proc` sampling (drops old3's Linux-only
  limit):
  - **`Resource::CPU`** — defer new test starts when `cpu% >= utilize_percent`
    (**default 80**), gating on the rounded reported value. Opt-in `-R CPU[=70]`.
  - **`Resource::Memory`** — defer when free memory `< min_free` (**default 5%** of total,
    or absolute `512mb`); conservative-wins when layered with `--utilize`. Opt-in
    `-R Memory[=20%|512mb]`.
  - **Utilizer safety floor:** defer only when `in_flight >= min_concurrent` (**default
    1**) — at least one job always runs even when saturated (never stalls). Gate = defer
    (a transient "wait"), **off by default** (opt in with `-R`).
- Lifecycle gotcha (from the reference AI_DOC): the sampler inherits the service's
  std fds → reap it in `service_on_stop` before the service exits (else its collector
  stalls on the orphan timeout). The 30s `_read_one_frame` EOF-busy-spin bug it
  surfaced is already addressed on 2.0d (verify).
- Record an ARCHITECTURE §4.4 addendum (fill the previously-undefined gating policy) +
  an AI_DOC.

### #44 — Final renderer ordering + `--live` feeder (chunk 15)
**Status:** ✅ DONE (2026-06-21) — contract pinned (ARCHITECTURE §4.5), `--live` flag
+ LiveProducer tail mode landed; `Renderer::Driver` "interim" framing flipped · **Step:** 15 ·
**Depends:** #42 (render-loop, done)

**Decided contract (the previously-undefined §4.5 "final ordering guarantees"):**
- **Ordering guarantee = per-JOB chronological only, NOT cross-job.** A job's own events
  always render in order; events from *different* jobs may interleave. (Cross-job
  chronological is explicitly NOT a guarantee.)
- **Default (non-live) feed = transitions-live, events-at-end.** The feeder reports each
  job's transitions as they arrive, then renders that job's full event stream just
  before its end is reported (this is the current `Renderer::Driver` per-job
  render-on-completion shape — now FORMALIZED as the default, no longer "interim TBD").
- **New `--live` flag** (default OFF; **default ON in interactive mode**): the feeder
  **tails ALL `events.jsonl.zst` logs as they appear** and streams each event to the
  renderers in arrival order — like 1.0 did with the files it wrote. Under concurrency
  this **interleaves** job output; that is fine because every event already carries its
  job / process / collector identity, so a renderer that cares marks them distinctly
  (the default renderer already shows a per-output-item **job index** — verify + reuse).
- **Interactive mode** (chunk 20 / #40, separate) by nature needs live event feeding +
  `-v` + `-j1`; it therefore turns `--live` ON and, being single-job, never interleaves.
  Wire the interactive⇒`--live` default as a hook now even though #40 lands later.

**Implementation:** add the `--live` option; give `App::Yath2::RenderLoop::LiveProducer`
a live/tail mode (poll + tail every appearing `events.jsonl.zst`, emit events as read,
vs the default complete-on-end read); confirm events carry job/collector identity end to
end and the default renderer's job-index marking is present (add if missing); keep the
per-job-in-order / cross-job-interleave invariant. Tests: `--live` interleaved multi-job
stream with correct per-item job attribution + ordering-within-job; default mode
unchanged. Record an ARCHITECTURE §4.5 addendum (the now-pinned contract) + flip
`Renderer::Driver`'s "interim" framing.

---

## Explicitly justified — do NOT cut

Load-bearing, all auditors agree: the unified `Role::Service`/`Connection` framing
layer; `Runner::Subscriber` parking deltas until after the snapshot;
`Runner::Monitor`'s render mirror; `stop_preload_root` not killing the collector
parent (the ChildMonitor fallback); the `no_reply`/`drain_input` fix (#9 — dedup, not
delete). Known migration gaps (not bloat): pfile discovery (ch12), `yath spawn`
(ch13), system-load (ch7), run-scoped stages.
