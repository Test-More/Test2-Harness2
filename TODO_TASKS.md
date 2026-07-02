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
**Status:** ✅ DONE (`680c6d9c5` harness-side supervisor + `Test2::Harness2::Util::FdPass::Control`;
`f5b85aca6` command direct-to-stage + retired the runner-routed `queue_spawn` path;
`fa751c2df` end-to-end tests) · **Step:** 13 · **Depends:** #38, #12 (discovery), `Preload::Host`

`yath spawn` now `require_fdpass('yath spawn')`s up front, discovers the workdir via
the §5.3 symlink, connects **directly** to a live `preload-<stage>.socket` (bypassing
the runner), and sends a `spawn` request that the stage's `request_handler_spawn` acks
`{ok=>1}` after async double-forking a detached, preload-holding supervisor. The
supervisor dials back to the command's listen socket, `recv_fds` the command's real
STDIN/OUT/ERR, forks a script child that dup2s them onto 0/1/2, sanitizes, and unwinds
into the preloaded interpreter (`Long::Jump`/`goto::file`, **no exec**, **no
collector**); the same socket then carries the dedicated control mini-protocol
(`Test2::Harness2::Util::FdPass::Control`) for forwarded signals + the child's raw wait
status, and a control EOF ⇒ `kill(-pgid)`. The `/proc/<pid>/fd` proxy + `ipcfile` exit +
the runner-routed `queue_spawn`/`PENDING_SPAWNS` machinery were retired. Tests
(`t/AI/integration/spawn_direct_to_stage.t`, `t/AI/integration/spawn_stdin_and_kill.t`,
`t/AI/unit/Util_FdPass_Control.t`) prove preload-preserved, fd round-trip (stdin + std
out/err), correct exit/raw-wait status, kill-on-EOF, and clean rejection.

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
**Status:** ✅ DONE — interactive shares only the command's real STDIN, passed over
a Unix socket (`SCM_RIGHTS`, via `Test2::Harness2::Util::FdPass`) instead of a FIFO.
The command (`App::Yath2::Options::Debug::_post_process_interactive`) opens a listen
socket only in `--interactive`, advertises its path in `$ENV{YATH_INTERACTIVE}`,
forks, and runs a per-test accept loop that passes its STDIN fd once per sequential
test (`-j1` via the isolation category, already in place) and stops when the run
ends. The test dials in and `dup2`s the received fd onto fd 0 via
`Test2::Harness2::Interactive::connect_stdin` — the **preload** path calls it from the
`goto::file` filter (`Runner::JobLauncher`); the **no-preload** path injects
`-MTest2::Harness2::Interactive` into the exec'd test (`Runner::Job::cli_options`), and
its `import` runs `connect_stdin` before the test body. STDOUT/STDERR stay with the
collector (rendered normally); `--live`/`-v` default on. No control channel (a normal
collected job). The FIFO machinery (`POSIX::mkfifo`, the open-retry loop) is removed.
Tty/controlling-terminal limitation documented (no `/dev/tty`, job control, or
terminal-generated signals without forwarding; run `reset` after an abrupt raw-mode
death). · **Step:** 20 · **Depends:** #38, #39 (shares the primitive) · **Note:**
supersedes the old #7 (7b)

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

## TIER 6 — DB-layer rewrite (DBIx::QuickORM, transition-driven logger, multi-DB sync — designed 2026-06-21/22, reviewed)

> Design context + decisions + the two-reviewer (Gemini/GPT) findings we resolved:
> `AI_DOCS/2026-06-21-db-layer-rewrite-quickorm-spec.md` (read it first — decisions §1-§10,
> revisions §R R1-R16). A **from-scratch** rewrite of the DB layer, **not** a DBIC→QuickORM
> refactor; the old DBIC/web layer is retired to `reference/old_db` and the webapp is rebuilt
> later (its own future spec). Canonical record = **artifact blobs + folded summary rows**,
> **no transitions table** (R6). DB chunks: **DB-1** (retire old layer) → **DB-2** (PostgreSQL
> schema) → **DB-3** (port flavors) → **DB-Jsonl** (jsonl renderer + renderer-owned options,
> lands **before** DB-4 to free the "logger" concept) → **DB-4** (DB logger process) → **DB-5**
> (sync + import). Suggested sequence **#45 → #46 → #47 → #48 → #50 → #51 → #53 → #54**, with
> **#49/#52** (backend producer changes) independent, **#55 → #56** (DB-Jsonl) independent and
> landing before #50, and **#57** deferred (optional). **DB layer is OPTIONAL** — core
> `yath test` (no logging) loads zero DB modules (R11).

### #45 — Move old DBIC DB/web layer to `reference/old_db`
**Status:** Decided · **Step:** DB-1 · **Depends:** —

**Problem:** the current DBIx::Class schema + web UI + DB commands are being replaced
from scratch (spec §0/§1); they must move out of `lib/` so the runner's `yath test`
critical path imports **zero** DB code, while staying visible as a reference to port
behaviour from. Verified DB-free: `test.pm` + `Test2::Harness2/*` have no
`App::Yath2::Schema`/`RunProcessor` imports, so the move keeps the runner suite green.

Steps:
- `git mv` (preserve history) into `reference/old_db/`, **preserving relative paths**:
  `lib/App/Yath2/Schema/` (~210 files), `lib/App/Yath2/Server/` + `Server.pm`,
  `lib/App/Yath2/Renderer/{DB,Server}.pm`, `lib/App/Yath2/Command/{db.pm, db/*, server.pm,
  recent.pm}`, `lib/App/Yath2/Options/DB.pm`, `lib/App/Yath2/Plugin/DB.pm`,
  `share/schema/*.sql`, `author_tools/regen_schema.pl`, and the web assets
  (templates/JS/CSS — locate at execution).
- Make the `db` / `server` / `recent` commands (+ DB renderer/plugin) **stubs that error
  if used** (command surface stays visible but inert, §1d); their tests become
  **`SKIP_ALL`** until the rewrite lands.
- Add **`exclude_match = ^reference`** to `dist.ini [GatherDir]` (R15 — fixes pre-existing
  bloat: 3744 `reference/` files ship today) **before** the `git mv`.
- **Remove the `DBIx::Class*` prereqs** from `dist.ini` (`dist.ini:123-130`) — safe once
  DBIC leaves `lib/` (reference isn't loaded/shipped) — and **demote `DBD::SQLite` from
  Requires to Suggests** (R11). Core `yath test` must stay green, **verified DB-free**.

### #46 — New schema, PostgreSQL-first (QuickORM `autofill`)
**Status:** Decided · **Step:** DB-2 · **Depends:** #45

**Problem:** the new schema must be authored as hand-written DDL (source of truth) and
reflected by QuickORM (`autofill`), with the accurate column set lifted from the
current-branch DBIC and the mechanics from `reference/dbix_quickorm` (spec §0 hybrid
principle, §2/§4/§5). No Perl table/result classes, no codegen.

Steps:
- **PREREQ (R13):** replace ARCHITECTURE §2.4's "schema-as-Perl, **not** hand-written
  DDL" wording with "hand-written per-flavor DDL + QuickORM `autofill` (reflect-from-DB)" —
  prerequisite for this chunk.
- Hand-write `share/schema/PostgreSQL/log.sql` (PostgreSQL-first, most capable); build
  `App::Yath2::Schema` using QuickORM `orm` + `autofill` (autotype JSON/UUID/DateTime),
  `App::Yath2::Schema::Row::*` (DCI **dumb** rows — algorithms live in functions/modules,
  not row classes, §2b), and `App::Yath2::DB::Flavor`. **No `regen_schema.pl`.**
- Tables: `runs, jobs, job_tries, artifacts, users, machine_users, projects, test_files,
  hosts, schema_meta` (§4/R12). **No** `transitions`/`events`/`binaries`/`log_files`/
  `collector` tables (R6, §4). Fold `run_fields` → `runs.fields` JSON and `job_try_fields`
  → `job_tries.fields` JSON; **drop the `mode` enum** (no event rows to prune, §4).
  Core columns per §4 (e.g. `runs.ran_by`→`machine_users`, `runs.submitted_by`→`users`
  nullable, version stamp in `schema_meta`).
- **`job_tries` verdict columns (survey #5)** (reference-port spec items 3/5): `try_ord`
  (**1-based**, R10); **`result`** (tri-state verdict — null = in-flight / true = pass /
  false = fail, distinct from the counts); `assertion_count`, `pass_count`, `fail_count`
  (assertion counts — NOT old4's `passed`/`failed`, which collide with the `result` bool);
  `subtests` (= top_level_subtests count), `subtests_passed`, `subtests_failed` (the split,
  derived from the auditor's `subtests[]`); `status` enum, `exit_code`, `started`/`finished`
  (+ `duration`); `parameters` JSON (GPT4 — align to the spec, **not** `params`); `fields`
  JSON (directives, #58). **DROP `stdout`/`stderr` columns** — read on demand from the
  artifact blob (R6); no duplicating large output already in the blob.
- **Retry recording / fold rules (survey #3)** (reference-port spec items 3/5 + GPT4):
  `jobs.passed` = **any-try-passed** (resolved true); `jobs.failed` = **resolved &&
  !passed**; `runs.passed`/`runs.failed`/`runs.retried` aggregate over the run's resolved
  jobs. `should_retry` is **runtime-only — NOT a persisted column**; `retry_limit` is input
  in the job's `parameters` JSON.
- Add **`DBIx::QuickORM` + `DBIx::QuickDB` to `dist.ini` RuntimeSuggests** (NOT Requires —
  R11); nothing always-loaded may `use` them at compile time.

### #47 — Port schema to SQLite / MySQL / MariaDB / Percona
**Status:** Decided · **Step:** DB-3 · **Depends:** #46

**Problem:** the PostgreSQL-first schema (#46) must be ported to the other engines with
correct per-engine UUID storage (spec §3, §0.2), since no single UUID representation is
portable across all five flavors.

Steps:
- Per-engine UUID PK storage: **native `uuid`** on PostgreSQL + MariaDB (**MariaDB 10.7+
  hard minimum** — native `uuid` is 10.7+ only; R8 — document in cpanfile/Makefile note +
  Flavor/DDL comment); **`BINARY(16)`** on MySQL + Percona; **`BLOB(16)`** on SQLite.
- On the engines lacking a native string form (mysql/percona/sqlite), add a **STORED
  generated lowercase `*_uuid_string` mirror column + index on the `runs` + `jobs` tables
  only** (the two IDs a human pastes from CI; §3b/§3c). Wrap SQLite's generated mirror in
  `lower(...)` (its `hex()` is uppercase) so the canonical form is lowercase everywhere.
- Carry the reference's column-ordering convention (fixed-width → variable →
  generated-last) per §3e.

### #48 — Derived-UUID function (v7-preserving) + central UUID lowercasing
**Status:** Decided · **Step:** DB-4 · **Depends:** #46

**Problem:** some run-data UUIDs are **derived** from a base UUID so every logger/DB
computes the same value with no coordination (required for sync idempotency + portable
binary-extraction facet-rewrites). Every implementation MUST use exactly one algorithm
or sync keys + facet-rewrites diverge (spec §3.1, R2/R4).

Steps:
- Implement one centralized, well-tested **`derive(base_uuid, offset)`** per §3.1:
  interpret `base_uuid` as a 128-bit big-endian int, take `rand_b` = the low 62 bits, set
  `new_rand_b = (rand_b + offset) mod 2^62` (**add-with-wrap** — carry never leaves
  `rand_b`, so timestamp/version/`rand_a`/variant are preserved byte-for-byte; still a
  valid **v7** UUID).
- Apply it: **`job_try_uuid = derive(job_uuid, try_ord)`** (`try_ord ≥ 1`); the
  artifact `events` blob = **`derive(collector_uuid, 0)`**, extracted **binaries** =
  `derive(collector_uuid, 1, 2, …)` in extraction order (NOT from `job_try_uuid` — would
  collide with sibling tries; R2/R4/§3.1).
- **Centralize UUID lowercasing at the boundary (R9):** `App::Yath2::Util::UUID` exports a
  `gen_uuid()` returning **lowercase** and normalizes wire UUIDs to lowercase on ingest;
  no scattered `lc()` at comparison sites (derive math is on the integer, case-irrelevant).
- Tests: **wrap at `rand_b` max** (wraps within the 62-bit field, does not flip
  variant/version/timestamp); **no self-collision for `offset ≥ 1`**; **two independent
  imports of a run produce identical** derived UUIDs + identical facet-rewrites.

### #49 — Producer emits 1-based try ordinals
**Status:** Decided · **Step:** DB-4 (backend) · **Depends:** —

**Problem:** §3.1 requires `try_ord ≥ 1` **at the source** so wire == db with no ingest
translation. Today the backend producer starts `try_ord`/`is_try` at 0; change it to
start at **1, never 0** (R10), rather than mapping `wire 0 → db 1` at ingest.

Steps:
- Change the backend so `try_ord`/`is_try` starts at **1**: `Job.pm` `is_try`
  default/init + the retry increment, and the `job_dir` naming (`job_id + is_try`,
  `Job.pm:508`).
- Audit **all** `is_try` uses: any `is_try == 0` "first try" checks, the wire `try`
  field, and the POD that documents it starting at 0.
- Tests for first try / first retry. This is a **backend** change (App-side ingest needs
  no translation afterward).

### #50 — DB logger process
**Status:** Decided · **Step:** DB-4 · **Depends:** #46, #47, #48, #49

**Problem:** the largest net-new component (spec §5/§7). A standalone App-side process
that subscribes to a run's transitions, **folds them into run/job/job_try ROW STATE**
(via the Monitor's folded state — **no transitions table**, R6) and imports each
collector's `events.jsonl.zst` **whole** as an artifact blob. All DB-side; the backend
stays DB-free (§2c).

Steps:
- Standalone `App::Yath2` process owning its **own `App::Yath2::Client` + `Subscriber`**
  to `runner.socket`, run-scoped via `connect_subscriber(run_id)` (N loggers → N DBs;
  runner stays the sole hub). Exit on socket-close (transient) or
  `run_done`/`harness_run_end` (persistent).
- **Fold-into-rows:** seed run/job/job_try summary rows from the Monitor **subscribe
  snapshot** (initial state), then upsert from the Monitor's folded state each `poll()`
  (no per-frame Subscriber tap, no per-event rows — 1.0's per-event rows were the "major
  db issue").
- **Retry recording (survey #3)** (reference-port spec items 3/5): write **one
  `job_tries` row per `is_try`** (1-based, R10/#49 — the producer prerequisite); **fold
  `jobs.passed` from the tries** (any-try-passed); `should_retry` stays **runtime-only**
  (the runner owns *when* to retry — DB-free, never a persisted column).
- **Blob import:** store each collector's `events.jsonl.zst` whole as an artifact blob,
  importing each **as that collector finalizes** (`wait_terminal`), not batched at run-end.
  **Binary-extraction (§5):** split embedded binary facets out of the event stream into
  their own **binary artifact rows** (`artifact_uuid = derive(collector_uuid, idx≥1)`) and
  **rewrite the source event's facet** to reference the new `artifact_uuid` (binary bytes
  removed, event retained).
- **Spawn early** — harness → logger → queue run (§6d) — fork+exec'ing the logger with
  `workdir` + `run_id` + DB config via a temp-JSON settings file (the
  `Renderer::DB._start_process` plumbing pattern; reuse the plumbing, not the per-event
  ingestion).
- **Enable option `-L` / `--logger`** (R16): **repeatable**, value-polymorphic — bare =
  default **SQLite** at the default location, `=path` = sqlite file, `=$DSN` = remote DB;
  one logger process per `-L`. Reuse the current logger's naming machinery
  (`log_file_format` + `%!` escapes, dir + temp-dir fallback, `lastlog` symlink when
  asked) with a DB extension; **no compression** (blobs are already zst).
- **Logging is OPT-IN (default OFF, R11);** DB modules are **lazily `require`d** with an
  **actionable** "install DBIx::QuickORM + DBD::<engine>" error; nothing always-loaded
  `use`s a DB module at compile time.

### #51 — Runner defers workdir cleanup + vanished-workdir detection
**Status:** Decided · **Step:** DB-4 · **Depends:** #50

**Problem:** a `data`-null artifact whose workdir is deleted before import is dangling
(spec §5/§7e). The logger must finish importing before the runner cleans the workdir;
conversely a logger must detect a workdir that vanished early (runner crash/force-kill).

Steps:
- The persistent runner **defers shutdown + workdir cleanup until all run-scoped
  subscribers disconnect** (a bounded loop **excluding global subscribers**); loggers are
  subscribers and stay subscribed until their imports finish, then disconnect → the runner
  cleans. The **default local sqlite logger is the durability anchor**; additional/remote
  loggers are best-effort and never gate cleanup (they recover via sync, #53).
- **Workdir-vanished-early detection:** if a logger/command detects the workdir
  disappeared before its import completed (runner crash/force-kill), report a **terminal
  error** and mark the log **incomplete and possibly corrupt**. (`Runner.pm:1316` already
  handles workdir-removed-out-from-under; the defer-cleanup requirement is new.)

### #52 — Sampler emits `system_load` into its own events stream
**Status:** Decided · **Step:** DB-4 · **Depends:** —

**Problem:** with no transitions/metrics table (R6), `system_load` snapshots need a
durable home. Have the sampler emit each snapshot into its own collector events stream so
it rides into `sampler-events.jsonl.zst` (a blob) like everything else (spec R6 (b)).

Steps:
- `Service::Sampler` additionally **emits each `system_load` snapshot into its own
  collector events stream** so it is captured in `sampler-events.jsonl.zst`. Small change;
  no metrics table. (The existing one-way `system_load` report to the runner for live
  throttling/render is unaffected.)

### #53 — `yath db sync` command
**Status:** Decided · **Step:** DB-5 · **Depends:** #50

**Problem:** moving runs between databases (sqlite log → postgres, DB → DB) needs a
from-scratch QuickORM sync engine (spec §8) — the old raw-SQL `Sync.pm` (now in
`reference/old_db`) carries inapplicable int-remap machinery; only its algorithm
(run_delta, per-run dump/load, get_or_create, datetime normalize) informs the new one.

Steps:
- New sync module under the DB namespace (DCI; reusable by the command). `yath db sync`
  moves a `run_uuid` list or a `run_delta`-style "runs in A not in B" set; **per-run
  granularity**, **idempotent uuid-upsert** keyed on `run_uuid` (runs are immutable once
  complete; distinct runs → distinct uuids → conflicts impossible).
- Run-data **UUID PKs copy verbatim**, but **natural-key FK columns are host-local ints
  and MUST be remapped** (R5): resolve each on the **destination** via `find_or_create` on
  its natural key — `users`→**username**, `machine_users`→**(host, username)**,
  `projects`→**name**, `hosts`→**hostname**, `test_files`→**path** — then rewrite the FK
  before writing.
- Artifacts: **copy the `data` blob, skip `local_path`** (host-local, §5; transition
  detail rides inside the blobs so it syncs automatically). QuickORM autotypes handle
  per-engine UUID storage + datetime. Not synced: sessions/auth/config (local).
- **`submitted_by` attribution flag** (R7): default **carry-original** (`find_or_create`
  by username on the destination); `--as-user`/`--override-user` attributes to the user
  performing the sync (the common cross-DB case — don't sync foreign accounts).

### #54 — `import` command
**Status:** Decided · **Step:** DB-5 · **Depends:** #53

**Problem:** the common case is importing the single run contained in one sqlite log file
into another database; requiring a `run_uuid` is friction (spec §8). It replaces the old
`db-publish`/upload role for the sqlite-log → DB path.

Steps:
- `import` imports the **single run** in a sqlite log file into another DB,
  **auto-selecting the only run** (no `run_uuid` needed) — a convenience wrapper over the
  #53 sync engine.
- Support the **same `submitted_by` attribution flag** (`--as-user`/`--override-user`,
  default carry-original; R7).

### #55 — Convert current logger → jsonl renderer
**Status:** Decided · **Step:** DB-Jsonl · **Depends:** —

**Problem:** the new DB logger (#50) takes over the "logger" concept, so the old jsonl
logger **must** become a plain renderer to make room (land **before** #50). It already
speaks our event shape, so CONVERT it rather than porting old3 (spec §10a, R16).

Steps:
- Wrap the existing logger logic — `test.pm::logger()` FH construction + the
  `dispatch_to_sinks` `as_json` write + `Options/Logging` — as a renderer:
  `render_event` writes `as_json`; `start` opens the FH (+ compression); `finish` writes
  the `null` terminator + close + `lastlog` symlink + "Wrote log file".
- **Promote into the renderers list; delete the inline `logger` sink** in
  `Renderer::Base::dispatch_to_sinks`.
- Own `option_group`: `--jsonl-file` / `--jsonl-dir` / `--jsonl-format` +
  `--bzip2` / `--gzip` (renderer keeps compression). **No `log` in names, no short
  forms** (R16 frees `-L`/`-F`/`-B`/`-G`).
- **Rewire implicit-enable** (the old `Logging` post_process + the YathUI force-enable) to
  **inject the renderer** instead of setting `logging->log`.

### #56 — Renderer-owned options via `mod_adds_options`
**Status:** Decided · **Step:** DB-Jsonl · **Depends:** #55

**Problem:** the jsonl renderer's option_group (#55) must auto-load when the renderer is
named; live already does this for **Finder** (`Options/Finder.pm:580`) but **not
renderers**. Use the pre_ai_2.0 model — `mod_adds_options => 1` on the `renderers` option
(spec §10b).

Steps:
- Add **`mod_adds_options => 1`** to the Display `renderers` option (pre_ai_2.0 model,
  `Options/Renderer.pm:82`) so each named renderer's `option_group` auto-loads.
- **Audit the other pluggable sources** (plugins / finders / schedulers / resources) and
  bring them all up to the pre_ai standard (the old3 `args_from_settings` hook) so they
  contribute options automatically.
- **Verify** live `Getopt::Yath` `mod_adds_options` works on the **renderers Map** option
  (pre_ai's renderers was map-ish and used it; chunk-2 migrated the Getopt::Yath
  machinery) — small fix if the Map case differs from the List case.
- Test that **`--renderers +My::Renderer`** with a renderer-defined flag parses.

### #57 — (OPTIONAL) try-uuid start-stamp
**Status:** Deferred · **Step:** DB-4 · **Depends:** #48

**Problem:** nice-to-have time-sortability — overwrite the derived `job_try_uuid`'s
high-48-bit timestamp with the **try's start time** (the first collector transition's
`stamp`) so try uuids sort by actual try start instead of inheriting the job's creation
time (spec §6c). Not required; depends on effort.

Steps:
- Only if **cheap**, and only if the Monitor's initial-state snapshot **preserves the
  original transition `stamp`** (a late-joining logger must compute the same value —
  **verify first**): overwrite the derived `job_try_uuid`'s high-48-bit timestamp with the
  try's start stamp. Reproducibility holds iff that stamp is stable across loggers.

### #63 — Multi-flavor / multi-version DB test matrix via DBIx::QuickDB
**Status:** DONE · **Step:** DB-3 · **Depends:** #47

**Landed:** shared helper `t/AI/lib/App/Yath2/Test/DBMatrix.pm` discovers every
`~/dbs/<engine>-<version>` install (+ a system fallback when `~/dbs` lacks a
flavor) and drives `Schema_quickorm.t` (DDL+autofill+per-engine UUID/JSON/datetime
round-trip), `db_sync.t` (cross-flavor: the sqlite log source → each server
flavor/version), and `db_logger.t` (end-to-end `yath test -L=<server DSN>` per
version) over it. SQLite is always-on (inline); server cells are gated on
`AUTHOR_TESTING` and **forked per cell** — DBIx::QuickDB resolves each driver's
binary paths into file-scoped lexicals at first load per process, so without
process isolation every version of a flavor would silently reuse whichever loaded
first. `has_string_mirror`/`json_autotype` are self-calibrated off the live
autofilled schema (the JSON-autotype claim varies by DBD). A cell skips with a
clear flavor+version reason when below the flavor minimum (pg 10+ / mariadb 10.7+
/ mysql+percona 8.0+) or when the server/driver is unavailable; a schema failure
on a *supported* version is a real failure, not a skip. Required a fix to
`build_connection` (derive the ORM `db_name` from the DSN — see the `fix(db):
derive ORM db_name from the DSN` commit) so the DB logger autofills a server whose
database is not named `yath`.

**Problem:** the DB tests (`Schema_quickorm.t`, `db_logger.t`, `db_sync.t`, etc.)
currently exercise only SQLite always + PostgreSQL when a connection happens to be
available. The 6 flavor DDLs (PostgreSQL/SQLite/DuckDB/MySQL/MariaDB/Percona) and the
autofill ORM + cross-DB sync must be proven against **every flavor AND every installed
version**, not one ambient server. (DuckDB, like SQLite, is an inline embedded-file
cell -- always on, self-skipping when `DBD::DuckDB` is absent; it is excluded from
the `servers_only` logger/sync matrices because a `.duckdb` file is single-writer.) `~/dbs` has multiple versions of all flavors
installed (plus some under `legacy/` and on other branches); the test suite must spin
each up, run against it, and skip a specific flavor/version **only** when neither
`~/dbs` nor a system install provides it.

**Reference (read first):** `~/projects/DBIx-QuickDB` and `~/projects/DBIx-QuickORM`
have working examples of using **DBIx::QuickDB** to launch every available version of
each flavor (server discovery, per-version spin-up, teardown). Mirror that pattern —
do not reinvent discovery.

Steps:
- Add a shared test helper (e.g. `t/lib` DB-matrix module) that, per flavor, asks
  QuickDB for **all installed versions** under `~/dbs` (incl. `legacy/`), yields a
  ready connection per (flavor, version), and tears it down after. Fall back to a
  system install if `~/dbs` lacks that flavor.
- Drive every DB test over that matrix: load the flavor's DDL, run the existing
  assertions per (flavor, version). The cross-DB sync test (#53) should also cover
  **cross-flavor** pairs (e.g. sqlite-log → each server flavor).
- **Skip granularity:** skip a single (flavor, version) cell only when QuickDB cannot
  provide it AND no system binary is found — never skip the whole flavor blanket.
  Emit a clear `skip` reason naming the missing flavor+version so CI/log shows the gap.
- Keep SQLite always-on (no server needed). Gate server spin-up on `AUTHOR_TESTING`
  to keep the default user install fast.
- Confirm autofill + per-engine UUID storage (BLOB(16)/BINARY(16)/native uuid),
  datetime, and JSON round-trip on each real server version — the bug class these
  catch is per-version SQL/typing drift the single-engine run hides.

---

## TIER 7 — reference-port features (selected reference-survey ports — resolved 2026-06-22)

> Source of truth (read it first):
> `AI_DOCS/2026-06-22-reference-port-features-spec.md` — the resolved ticket-level detail
> for the 7 reference-survey features the user selected to port (survey `wkg6c1k4p`),
> the gemini/gpt Review refinements, and the Escalation resolutions **E1–E5**. The two
> DB-impacting items (#3 retry recording, #5 verdict columns) FOLD into the existing
> DB-layer tickets (#46/#50) rather than landing as new tickets; the five subsystem items
> land here as **#58–#62** on step **REF-PORT**. After E4/E5, items #1 and #10 are **no
> longer DB-impacting** (resource tables re-deferred; directive meta/feature persistence
> deferred). **#60 (Units helpers) blocks #59 (resources).**

### #58 — Structured directives parser (HARNESS2 grammar + legacy compat)
**Status:** Decided · **Step:** REF-PORT · **Depends:** —

**Problem:** `App::Yath2::TestFile::_scan` inline-scans `HARNESS-…` lines into a
`_headers` hash via a split-based if/elsif loop — no block form, quoting, sigils, nested
keys, or reuse, and no `Directives` module exists (spec item 1, "Current state"). The
reference `harness_service` carries a richer, field-agnostic `HARNESS2:` grammar parser
(431 lines) plus a producer-side `_apply_directives` mapping worth porting.

Steps:
- New **`Test2::Harness2::Util::Directives`** — a pure, field-agnostic `HARNESS2:` grammar
  parser ported from `reference/harness_service/lib/Test2/Harness2/Util/Directives.pm`:
  block form (`key { … key }`), boolean sigils (`@on/@off/@yes/@no/@true/@false/@default`),
  dotted keys folded into a nested subtree, double-quoted values with escapes,
  **line-numbered `croak`** on collision/unterminated/bad quote, multi-comment-leader
  (`['#','//']`). Bring **old3's unit test**
  (`reference/old3/t/AI/unit/Harness2/Util/Directives.t`) (spec item 1).
- A **SEPARATE legacy compat module** (e.g. `…::Directives::Legacy`) that parses the 1.0
  `HARNESS-…` lines and converts them to the **same new internal representation** the new
  grammar emits (spec item 1 resolution).
- Replace `App::Yath2::TestFile::_scan` with **detect-and-parse** (new grammar or legacy
  compat) → `_apply_directives` mapping the nested hash onto harness fields (port the
  `harness_service` `App/Yath2/TestFile.pm::_apply_directives` mapping, lines 133–345).
- **Precedence — HARNESS2 presence wins; legacy ignored; silent (E2):** if a file has any
  `HARNESS2:` directive, parse with the new grammar and ignore all legacy `HARNESS-` lines
  with **no warning** (E2 = B, silent); otherwise run the compat parser over its `HARNESS-`
  lines. Either path yields the new internal representation.
- **Only `App::Yath2::TestFile` reads files** (the file-reading object, GPT1): keep the
  O(1) header scan — **early-terminate at the first real code line** outside an open block
  (like current `_scan`'s `last unless …`) plus a ~500-line safety ceiling (G1).
  `Test2::Harness2::TestFile` stays **file-free / state-only** (post chunk-14 split); it
  never loads the parser or reads files (GPT1).
- **Parse errors (E1 = A):** the new parser `croak`s; `App::Yath2::TestFile` **catches**,
  marks that file **invalid**, and **queueing it emits a synthetic harness-visible test
  FAILURE** — the run continues, never aborts; the broken file fails.
- **Structural fields flow as today** (retry/timeout/category/duration/stage/conflicts/
  slots → the task); **arbitrary `meta.*`/`feature.*` persistence is DEFERRED (E5)** — the
  durable task-payload/snapshot/logger path is a future spec, so this ticket has **no new
  DB-schema impact**.
- Tests: bad quote, mismatched block, and a mixed good/bad-files run (E1 cases).

### #59 — OS-limit throttle resources (UnixLimits + Disk)
**Status:** Decided · **Step:** REF-PORT · **Depends:** #60

**Problem:** the pipe-heavy architecture (sockets + SCM_RIGHTS fd-pass + collectors
everywhere) makes `nofile`/RLIMIT and disk-pressure exhaustion under high `-j` a real
unthrottled failure mode (spec item 10). old3 carries `UnixLimits`/`Disk` resources worth
porting onto the current `Role::Resource` contract; **`PipeLimits` is dropped (E3)**.

Steps:
- Port **`UnixLimits`** (cap by RLIMIT `nproc`/`nofile`/`as`, count or %-of-limit) and
  **`Disk`** (throttle/abort on low free space per mount) from old3 into
  `Test2::Harness2::Runner::Resource::` on the current `Role::Resource` contract
  (`available`/`assign` + `tick`/`refresh`/`job_limiter*`/`record`). **Drop `PipeLimits`**
  (E3).
- **Read volatile/process-local metrics in-resource, runner-local at assign time** (E3):
  `nofile`, `/proc/self/fd`, etc. are read by the resource on tick — **NOT** via the
  system-load sampler (reading `/proc/self` in the sampler would count the *sampler's* fds
  and a 0.2s snapshot races burst spawns). Static kernel caps are read **once**. (CPU/Memory
  keep using the sampler snapshot as before; the "extend the sampler to carry pipe/rlimit/
  disk metrics" lean is dropped.)
- **`is_supported` hook (G4):** on a non-Linux host (no `/proc`) gracefully **deactivate
  with no constraint** (infinite / no-throttle) + a **verbose log**; never crash.
- **Off-Linux RLIMIT (G5):** Linux reads `/proc` (no dep); off-Linux RLIMIT support uses
  **optional `BSD::Resource`** (Suggests, lazy-`require`d, **disable + warn** if missing
  *and* requested).
- **`Filesys::Df` (GPT8, supersedes #10.3):** **optional dep, lazy-required whenever the
  `Disk` resource is requested at all** — both absolute and percent thresholds need
  free/total bytes (no portable core statvfs); actionable error if missing.
- **NO DB impact (E4):** resource telemetry tables (`resources`/`resource_types`) stay
  **deferred** (d4) — this is **pure runtime throttling**; persistence rides the later
  deferred resources-table work.

### #60 — Units helpers `parse_count_or_pct` + `parse_duration`
**Status:** Decided · **Step:** REF-PORT · **Depends:** —

**Problem:** the OS-limit resources (#59) need `parse_count_or_pct` (count vs %-of-limit),
and the `timeout` directives (#58) need a duration parser; neither exists in current's
`Units` (spec item 11). Both live in `reference/old3/.../Util/Units.pm` and port cleanly.

Steps:
- Port **both** `parse_count_or_pct` and `parse_duration` from
  `reference/old3/.../Util/Units.pm` into `lib/Test2/Harness2/Util/Units.pm` in current's
  signature style (`sub parse_count_or_pct ($raw, %opts)`); add both to `@EXPORT_OK`.
- `parse_count_or_pct` = `"NUMBER"` → count / `"NUMBER%"` → pct, built on the existing
  `parse_quantity` (spec item 11).
- **Scope `parse_duration` to TIMEOUT values** (`timeout.event`/`timeout.postexit` →
  seconds) (GPT9); the `duration short|medium|long` directive stays a scheduling **LABEL**,
  **not** parsed as seconds.
- **Blocks #59.** No DB impact.

### #61 — ResetTerm renderer
**Status:** Decided · **Step:** REF-PORT · **Depends:** —

**Problem:** a misbehaving test can leave the terminal in a weird color/mode state; old3's
16-line `ResetTerm` renderer (a no-op `render_event` whose `finish` prints a terminal
reset only on a TTY) undoes it (spec item 13). Current has no such renderer.

Steps:
- New **`App::Yath2::Renderer::ResetTerm`** with parent `Test2::Harness2::Renderer` (not
  old3's `App::Yath2::Renderer`); swap `Object::HashBase` → `Test2::Harness2::Util::HashBase`;
  **drop `desired_filters`** (no Filter machinery). `render_event` is a no-op; `finish`
  prints `\e[0m\e[?25h` (attributes + cursor; avoid `\e[=l`) **only when `-t STDOUT`**
  (spec item 13 + GPT10).
- **Default-on when STDOUT is a TTY (Q13.1):** auto-add to the renderer list, **injected
  LAST** in the renderer `'@'` list (current has no `weight` sorting — list order, GPT10);
  no-op otherwise.
- **Fire on abnormal exit (G6):** ensure the harness abort/teardown path calls the
  renderer `finish()`, **plus an `END`-block fallback** in `ResetTerm`, so the reset prints
  on Ctrl-C / panic — **not** a renderer-owned signal handler (the harness owns signals).
- No DB impact.

### #62 — `yath list` + `yath ping` commands
**Status:** Decided · **Step:** REF-PORT · **Depends:** —

**Problem:** there is no way to enumerate live persistent runners or measure runner
round-trip latency; `reference/pre_ai_2.0` carries `list.pm`/`ping.pm` worth adapting to
the current Discovery + `App::Yath2::Client` (spec item 15).

Steps:
- New **`App::Yath2::Command::list`** + **`App::Yath2::Command::ping`**.
- **`list` = a Discovery enumeration API** (GPT11), not a naive glob: add
  `Discovery->list` / `find_runner_links` that **reuses `find_runner_link`'s dir/name
  rules** (persist_file / persist_dir / `YATH_PERSISTENCE_DIR` / cwd-walk / synthesized
  user+host+project basename); probe liveness; print live **persistent** runners grouped.
  **Persistent-only** (Q15.1 = a) — one-off `yath test` runs have no well-known marker, so
  `list` won't show them (documented limitation).
- **Multi-user safe (G7):** catch `EACCES`/`ECONNREFUSED` → show "inaccessible (other
  user)"; clean only dangling links owned by the **current UID**.
- **`ping` needs runner-side support (GPT12):** add a **no-side-effect ping request
  handler** on the runner service returning `{ok=>1, pid, stamp}`; expose it via
  `Test2::Harness2::Runner::Client` / `App::Yath2::Client`, then build the latency-loop
  command (round-trip `ping()`, print latency, sleep).
- No DB impact.

---

> **Deferred to their own separate efforts (NOT numbered tickets in this effort):**
> the **artifact-download controller** (`GET /artifact/<uuid>.<ext>` — strip ext, fetch
> by uuid, verify ext matches the stored filename, stream `data` with `Content-Type` +
> `Content-Disposition`; §5) lands with the **future webapp UX-migration spec** (§9); the
> **junit renderer** import (old3 base, optional `XML::Generator` guard; §10c) is **its
> own separate effort**.

---

## TIER 8 — Maintainability cleanup audit (2026-07-01, multi-agent, adversarially verified)

A full-lib maintainability audit (20 auditors over all 160 modules, ~25k code
lines; every finding attacked by an accuracy skeptic + a value skeptic, then a
coverage critic ran a second gap pass): 177 raw findings → 136 confirmed, 10
refuted (refuted = factually wrong, load-bearing-on-purpose, or already covered
by a pending chunk — do not re-file). Full finding-level provenance (evidence,
reviewer corrections, rejected list) is in
`AI_DOCS/2026-07-01-cleanup-audit-findings.json`.

**Status `Proposed` = found + verified, not yet decided.** Iterate over these,
promote to Decided (or Rejected) as they are reviewed. Parent chunks are the
CLEAN-1..CLEAN-14 rows in `TODO_STEPS.md`.

**Owner directive (2026-07-01): web-framework code is parked, not dead.** The
web/DB-web layer (everything in `reference/old_db` plus the web-facing
option/command surface still in `lib/`) is intentionally retained so the §9
webapp port can **rework the existing code, not rewrite it from scratch**. No
CLEAN ticket may hard-delete web-layer code: park it via path-preserving
`git mv` into `reference/old_db` (the #45 pattern) so it stays available for
the rework. Client-side dead scraps (an unread variable, a dead option thread)
may still be trimmed. Applies to the #64/#94/#98 notes below.

### Ordering / coordination for the CLEAN tickets

DO-FIRST (independent, behavior-preserving, no pending-chunk blocker — safe to land anytime and reduce rebase noise for the pending functional chunks): the pure dead-code / stale-doc / duplication tickets #64, #68, #69, #71, #72, #73, #74, #75, #76, #77, #78, #79, #80, #81, #82, #83, #85, #86, #87, #88, #89, #90, #91, #92, #93, #95, #96, #97, #99, #100, #101, #102, #103, #104, #105. Doc-only #103/#104 and the trivial import/newline sweeps (#92, #101, #105) are the cheapest and can go immediately.

SEQUENCE BEFORE PENDING CHUNKS (do these before the named functional chunk starts, so the chunk edits settled code once): #67 and #68 before chunk 16 (concurrent-run scheduler) — timeout-policy and TASK_LIST/dispatch edits happen once, not twice; #69 before chunks 11/16/22/23 (all churn Runner.pm); #70 (Handlers split) before chunks 16/27/28 so their new run-lifecycle / plugin-transition / retry handlers get a clean Completion/TransitionHub home instead of growing the monolith; #82 before chunk 16 (touches service lifecycle); #78 coordinate/rebase with chunks 11/16; #85 is post-#58 (landed) pure refactor gated on #58's ported tests; #95 (Pfile removal) before #62 (REF-PORT list/ping reworks ping.pm + adds Discovery->list), or fold ping's call-site change into #62.

WAIT ON / COORDINATE WITH PENDING CHUNKS: #66 (RenderLoop fan-out) MUST land with or after DB-Jsonl (#55/#56 — both rework Renderer::Base dispatch_to_sinks/renderers-list; doing #66 first conflicts); #89 coordinate with DB-Jsonl (#55/#56 rewrite the renderers-list construction) and #61 (renderers TTY-append); #90 relates to #55/#56 (jsonl format → helper regex in one place); #84 (gen_uuid) depends on #48 (R9 boundary) and #57 (v7 timestamps) — sequence before/with DB-4 so the logger persists v7 UUIDs; #93 (DB layer dedup) after DB-5 (#53/#54) is stable and coordinated with the active 2.0d-db-rewrite worktree (which re-introduces some Schema/publish consumers); #94 and #98 depend on #45 (DB-1) and defer server-side/web option work to the §9 webapp port; #100's YathUI sub-item is best folded into #55; #102's Log.pm sub-item defers to #55/#56.

INTRA-CLEAN COUPLING (same-file overlap to coordinate, not hard blockers): #91 (resources.pm per-poll fix) and #95 (Pfile→Discovery migration of resources.pm) touch the same discovery code — land #95's migration preserving non-fatal find semantics and let #91 own the loop-shape fix (or do them together). #64 and #65 both touch the two Composer copies and Test2::Formatter::Test2 — land #64 (which deletes the orphan and consolidates to one canonical Composer) before #65's Driver/status-bar work so #65 edits one copy. #79 and #80 both touch the Resource/* family; land #79 (boilerplate/constructor hoist) first, then #80 (header fix + v5.38 sweep) over the reduced surface. #87 (cli_args→doc_args) and #92 (command import sweep) both edit command files but are independent; #87 must scope its command-file touches to surviving (non-DB-stubbed) commands.

CONTEXT-ONLY (Depends lines cite DONE tickets purely for traceability, no blocking): #67 (#11/#22), #68 (#1/#29/#33), #71 (#19/#27), #72 (#12/#27/#32), #73 (#29/#39), #88 (chunk 17/30/41), #97 (#26), #103 (#6/#8/#26/#45). Note #70 (Handlers split, effort M / risk med) and #66/#89 (renderer refactors, risk med) are the higher-risk items — gate each on both canonical runners run 3× for flake plus a `ps` zombie check for the Runner-adjacent ones.

---

### #64 — Renderer/formatter dead code: orphan Composer, broken render plumbing, Formatter vestiges

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** — (Related: #45 created the Composer orphan; #42/#44 DONE)

> **Web-parking note (owner directive above):** deleting the orphan `Default/Composer.pm` loses no web code — the canonical `Test2::Formatter::Test2::Composer` stays in `lib/`, step 1 ports the two divergent lines into it first, and the parked `reference/old_db` consumers re-point at the canonical copy during the §9 rework.

**Problem.** `lib/App/Yath2/Renderer/Default/Composer.pm` is a dead near-duplicate of `lib/Test2/Formatter/Test2/Composer.pm` — its only consumers (Schema::RunProcessor, Schema::Overlay::Event) moved to `reference/old_db` under #45, and it differs from the canonical copy only at `Composer.pm:195` (`|| $_->{peek}` in the render_brief info grep) and `Composer.pm:242` (`map { $_ // '' }` seen-key guard); the `Default/` dir holds one orphan and its sibling `App::Yath2::Renderer::Default` does not exist. The canonical `lib/Test2/Formatter/Test2/Composer.pm` carries unreachable/broken plumbing inherited verbatim from `reference/legacy`/`reference/pre_ai_2.0`: line 23's `halt()` branch (no `halt()` method; crashes when render_one_line is called as the class method its POD advertises), `times` in the line-25 dispatch list building a nonexistent `render_times` (`Test2.pm:569` also pops a phantom `times` component nothing emits), dead `Data::Dumper` `$msg` blocks in render_info (276-289) and render_errors (309-330) that compute `$msg` then push `$details`, and render_about (299-304) whose inner `my $type` shadows the outer so the tag is always `ABOUT`. render_super_verbose + render_launch/start/exit/end + render_control's `super_verbose` tail (Composer.pm:35-148, both copies) have zero callers. `lib/Test2/Formatter/Test2.pm` carries an unused `-last_depth` slot (27), a redundant nested `if ($use_color)` (181-194) already guaranteed by the outer `if ($use_color && USE_ANSI_COLOR)`, and a raw `$self->{last_rendered}` key (295-301) beside HashBase slots. `lib/App/Yath2/RenderLoop/LiveProducer.pm:175` `asserts_seen` has no callers and always returns 0 (the dispatch_cb redirect bypasses the engine's ASSERTS_SEEN increment). `lib/App/Yath2/RenderLoop/Producer.pm:6` imports `Carp qw/croak/` but the role never calls it.

**Steps.**
1. Port the two divergent lines into canonical `Test2::Formatter::Test2::Composer` after confirming each is wanted (195 `|| $_->{peek}` changes which info items render; 242 is a warning-only undef-guard), then `git rm lib/App/Yath2/Renderer/Default/Composer.pm` and delete the now-empty `Default/` dir. Note that `reference/old_db` RunProcessor/Overlay::Event still `use` the orphan and must be re-pointed at `Test2::Formatter::Test2::Composer` on any future re-port (acceptable: `reference/` is unshipped via `dist.ini exclude_match ^reference`).
2. Tier 1 (zero behavior change): delete the line-23 `halt` branch, drop `times` from the line-25 dispatch list, and remove the phantom `times` pop at `Test2.pm:569` — after verifying Test2-Collector never emits a top-level `times` facet.
3. Tier 2 (user-visible output change; these are inherited upstream bugs): use `$msg` as rendered details in render_info/render_errors (or delete the dumper blocks and share one ref-to-string helper), and remove the inner `my` in render_about. Check for renderer-output/snapshot tests first and treat as a deliberate change.
4. Delete render_super_verbose + render_launch/render_start/render_exit/render_end and drop the `super_verbose` parameter plumbing from render_control/render_verbose (Composer.pm:35-148); restorable from git.
5. In `Test2::Formatter::Test2` drop `-last_depth`, flatten the redundant inner `if ($use_color)` (through 194), and promote `last_rendered` to a declared `+last_rendered` slot.
6. Delete `sub asserts_seen` at `LiveProducer.pm:175` plus its POD `=item` (~163-175) and the rollup-accessor mention (~157); keep final_data/tests_seen. Remove `use Carp qw/croak/` at `Producer.pm:6`.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); `grep -rn 'Default::Composer\|render_super_verbose\|render_times\|->asserts_seen' lib` clean of the removed surfaces; renderer-output tests pass after the Tier-2 change.

### #65 — Renderer duplication: Driver sweep/finalize, Formatter ctor args, status-bar dance, show_runner_output

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** — (Related: #44 DONE pinned §4.5; coordinate with #56 which touches Display renderer args)

**Problem.** `lib/Test2/Harness2/Renderer/Driver.pm` step (144-182) and tail (184-220) are identical except the middle section, sharing render_run_start, step_runner_output, the new_collectors launch loop, new_failing/new_diagnosing drains, new_aborted_jobs and new_finalized/new_test_exits; finalize (222-257) and _finalize_live re-check the same terminal predicate verbatim at 249 and 546 (`next unless $c->{final_state} || $status eq 'complete' || $status eq 'finalized';`), and the job_for/job_id/file/try extraction is triplicated (430-433, 494-497, 550-553). `Driver::_render_aborted` (348-419) rebuilds the identical harness_job/start/launch event `_render_launch` builds (319-337) plus repeats the `TESTS_SEEN++/tries++` bookkeeping, and dispatches unconditionally at 384 even for jobs whose collector already launched — a launched-then-watchdog-aborted job gets a second synthetic launch line and double increment (the ABORTED_RENDERED guard is keyed by job_id, independent of `launched` in BY_UUID). `lib/Test2/Harness2/Renderer/Formatter.pm` stores ctor args verbose/color/show_times then re-reads them from `$settings->display` (57/58/141), stores `quiet` with no slot, and carries dead `$self->{output}` fallbacks (38/44); base `Renderer.pm:9` `-verbose -color` accessors have no reader. The status-bar clear/reprint sequence (`print $io "\r\e[K"` + render_status) is copy-pasted in `Test2::Formatter::Test2::write` (308-321), `::step` (348-357) and `Test2::Formatter::QVF::write` (68-78); `Test2.pm:416` computes an unused `$reset` and render_status ignores its `$f` arg at 319/77. `show_runner_output` derivation (`hide_runner_output ? 0 : 1`) is copy-pasted in test.pm (385), watch.pm (99) and stop.pm (93).

**Steps.**
1. In Driver: extract `_collector_terminal($c)` and a shared synth-end fallback (synth_job_end + note_verdict + dispatch + ended flag) used by both finalize paths (effort S, pure win); keep the mode-specific middle of step/tail inline behind small named helpers (`_sweep_prologue`/`_drain_terminal_lists`) rather than one heavy callback so the drain-vs-render intent stays legible; do not force `_finalize_live`'s bounded-wait/`_render_launch` behavior to converge with finalize's sweep.
2. Extract `_dispatch_launch($job_id,$file,$try)` (event construction + TESTS_SEEN/tries bookkeeping) used by both `_render_launch` and `_render_aborted`, and have `_render_launch`/the helper set a per-`job_id` flag (e.g. `LAUNCH_RENDERED`); make `_render_aborted` skip the launch + bookkeeping when set (the aborted exit/end event at 396-416 still dispatches). Note `_render_aborted` hardcodes try=0 vs `_render_launch`'s `$c->{try} // 0`, so pass try as a parameter. Add a test for the launched-then-aborted (watchdog-after-start) path.
3. In `Renderer/Formatter.pm`: pick one source of truth — have init consume the ctor args (`$self->{+VERBOSE} // $settings->display->verbose`, etc.) rather than reaching into settings; drop `quiet` from the `@args` built at `Options/Display.pm:402-420`; delete the unused base `-verbose -color` attrs + POD and the `$self->{output}` fallbacks. Keep the `handles => [$io,$io_err,$io]` arg (live seam for handles-consuming formatters). Before deleting `@args` keys, grep `t/AI/fixtures` for the run-header renderers arg list (snapshot shape).
4. Extract `_clear_status($io)` and `_render_status($io)` (write() clears up front then re-renders later, so two helpers, not one) used by the three sites; delete the unused `$reset` at `Test2.pm:416` and the ignored `$f` arg at the render_status calls.
5. Add one `show_runner_output()` helper on `App::Yath2::Command` reading `$self->settings->display` and call it from test/watch/stop (do not default in `Renderer::Base::init` — stop::prime_shutdown uses the value to decide whether to build a renderer at all).

Verify: both canonical runners green; add golden-output coverage for the launched-then-aborted path and for the status-bar clear across Test2/QVF; snapshot renderer args unchanged aside from the intended `quiet` drop.

### #66 — RenderLoop fan-out consolidation; stop.pm onto LiveProducer

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** DB-Jsonl (#55/#56) — land with/after (both rework `dispatch_to_sinks`/renderers list) · Related: #42 (RenderLoop dispatch_cb seam)

**Problem.** Since chunk 31 the loop owns fan-out, but the fan-out code (annotate → renderers → asserts count → handle, `Base.pm` dispatch/dispatch_to_sinks 527-579) stayed on `lib/Test2/Harness2/Renderer/Base.pm`. Consequently `lib/App/Yath2/RenderLoop.pm:281-291` builds a second private `Renderer::Base->new(...)` purely as a sink (its jobs/tasks/run rollup state unused; only its asserts tally at 183 is used), the real engine is built with a fake `renderers => []` (`test.pm:391`, watch.pm) only to satisfy Base's `renderers is required` croak (`Base.pm:121-124`), and `LiveProducer.pm:118-125` must `set_dispatch_cb` to redirect the engine's dispatch into a queue. Meanwhile `lib/App/Yath2/Command/stop.pm:98-116` still constructs a Base with the REAL renderers list and hand-steps it (drain_shutdown), duplicating the tail-runner-output job `watch.pm` now does via RenderLoop+LiveProducer — the run loop exists in two shapes.

**Steps.**
1. Core (high-value, low-risk): move `dispatch_to_sinks` (plugin annotate/handle fan-out + asserts_seen) out of `Renderer::Base` into `RenderLoop` (or a tiny Sink class both share), eliminating the double `Renderer::Base->new` sink, the dummy `renderers => []`, and the `renderers is required` croak; keep the vetted `Renderer::Base` `dispatch_cb` backend seam (#42) rather than ripping the callback out wholesale.
2. Separable higher-risk sub-step: port `stop.pm` prime_shutdown/drain_shutdown onto the same LiveProducer/loop shape `watch` uses; preserve its distinct done()/teardown semantics (real renderers list, hand-stepped drain). Land this as its own commit (own rollback point).
3. Sequence after DB-Jsonl (#55/#56) so the `logger` inline sink is already deleted from `dispatch_to_sinks` and the renderers-list construction is settled — doing this first would conflict.

Verify: both canonical runners green; watch/test/stop produce identical rendered output before and after; no engine is constructed with `renderers => []` and no second Base sink remains.

### #67 — Runner/Preload::Host process-management duplication + write-only bookkeeping

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** — (context: #11/#22 DONE; get owner sign-off on the #22-directive caveat) · Do BEFORE chunk 16

**Problem.** `lib/Test2/Harness2/Preload/Host.pm` and `lib/Test2/Harness2/Runner.pm` carry byte-identical process-management code: check_timeouts (Host 393-436 vs Runner 292-345, incl. grace TERM→KILL, TIMEOUT_SIGNALED purge, RUN_REACHED_TIMEOUT record), stop (Host 439-458 vs Runner 346-368), handle_sig (Host 460-470 vs Runner 369-379, differ only in die-message prefix). Both `use parent 'Test2::Harness2::IPC'`, which already defines the empty `check_timeouts` hook (`IPC.pm:116`) its loop calls (IPC.pm:212). Separately, `Runner.pm:842-878,1183-1199,1249-1253` has four copies of the preload-root failure wind-down (`_emit_preload_failure_output; $self->{+SIGNAL} //= 'TERM'`), with _handle_dead_preload_root's if/else differing only by one warn; and `stop_preload_root`/`stop_sampler` (Runner.pm 980-1096) copy the same service_send + service_io/waitpid/sleep reap loop three times. `Preload/Host.pm` RUN_REACHED_TIMEOUT (63,430-431,841-842) and JOB_PIDS (71,148,836-840) are write-only bookkeeping never read (RUN_REACHED_TIMEOUT is mirrored dead in Runner.pm 71,337-338,1424-1425; JOB_PIDS is never populated — the writer lives only in Handlers.pm:976, composed only into Runner).

**Steps.**
1. Hoist check_timeouts, stop, handle_sig (parameterize the die prefix via `ref($self)` or an overridable `sig_prefix`) plus their supporting HashBase fields (LAST_TIMEOUT_CHECK, POST_EXIT_TIMEOUT, TIMEOUT_SIGNALED, RUN_REACHED_TIMEOUT, SIGNAL) into `Test2::Harness2::IPC` where the empty check_timeouts hook lives; keep the SUPER::stop chain to IPC's generic stop (IPC.pm:79); preserve check_timeouts' `settings->runner->use_timeout` and `isa('Test2::Harness2::Runner::Job')` behavior identically in both consumers. EXCLUDE all_libs and orphaned from the hoist (wrong altitude — leave duplicated).
2. Collapse the four wind-down sites to one `_fail_preload($warn_msg=undef)` (optional warn + emit + `SIGNAL //= 'TERM'`); fold _handle_dead_preload_root's if/else into a single `_fail_preload` call returning plain 1/0. Keep per-site guards. DO NOT remove the stage_host_exited pre-checks at 1184-1188/1249-1253 — they fire on the socket announcement before the root is reapable; the mid-run site's `stage_host_exited && @stage_host_errors` condition is deliberately different. Preserve the "must run AFTER _bring_out_yer_dead" ordering note (1233-1238).
3. Extract `_reap_poll($pid,$tries)` (service_io + waitpid WNOHANG + `Time::HiRes::sleep(0.02)`) and call it at all three loop sites (the third, post-TERM copy has no service_send); optionally a thin `_graceful_stop` wrapping eval{service_send}+_reap_poll for the two graceful sites. Keep the distinct tails + their load-bearing comments (preload-root must NOT be killed; sampler TERM→KILL). Use the house `my $ok = eval {...; 1 };` form if touched.
4. Delete RUN_REACHED_TIMEOUT at all four sites (Host 63,430-431,841-842 and Runner 71,337-338,1424-1425) — keep the check_timeouts kill()+STDERR diagnostic. Delete JOB_PIDS (Host 71,148,836-840); reword the 836-838 comment to keep the RUN_REACHED_TIMEOUT delete (live) and cite #28 (pids reach the runner via the collector handshake). Update `HANDOFF.md:48` if it still references RUN_REACHED_TIMEOUT as runner-side state.

Verify: both canonical runners green (3× for flake, `ps` zombie-free on a no-preload AND a `--preload` run); `grep -rn 'RUN_REACHED_TIMEOUT\|job_pids' lib` shows only Runner/Handlers job_pids remain.

### #68 — Runner::State dead code & duplication: next_task, wrapper pairs, take_dispatch_tasks, _stage_startup_timeout

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (residue of #1/#29/#33 DONE) · Do BEFORE chunk 16

**Problem.** `lib/Test2/Harness2/Runner/State.pm:211-227` `next_task` is dead — its only apparent caller (`Preload/Host.pm:735`) resolves to `StageDelegate::next_task` because Host's `state()` returns the stage delegate (Host.pm:220); the in-runner run_job that used it was deleted by #29, and its `'If we are replaying a state'` comment references removed machinery. Eight public→private wrapper pairs (queue_run/start_run/stop_run/queue_task/start_task/stop_task/retry_task at 289-515 and reload at 766-805) are one-line forwarders `$self->_X(@args)`; the public names are the dynamic-dispatch surface (Handlers submit_action, defined at `Runner.pm:883`) but the privates add nothing — _queue_run/_start_run/_retry_task/_reload have exactly one caller. `take_dispatch_tasks` (229-255) is called only as `take_dispatch_tasks(undef)` (`Runner.pm:1117`), so its `$root_stage` param and keep-partition are dead (start_task always sets a stage), and its 232-234 comment references the deleted run_job. `_stage_startup_timeout` (662-668) is byte-identical to `Resource/Preload.pm:37-43`, kept in sync by hand though Resource::Preload holds a `state` backref.

**Steps.**
1. Delete `next_task` (State.pm:211-227) with its stale comment; fix the now-stale comment above take_dispatch_tasks (229-234). Do not touch StageDelegate's own live next_task or the Preload::Host caller path.
2. Merge each private body into its public method, keeping the public names; switch internal callers (State.pm:454,500,512,543,549 in _retry_task/requeue_task) to the public names; update the two `_start_task`/`_queue_task` calls in `t/AI/unit/State_requeue_task.t` (42/45, 66/67) and the stale comment refs in `t/AI/unit/State_run_retention.t:13` and `Runner.pm:1114`. Note `reload` (766) is NOT a pure forwarder — it defaults `$stage //= 'default'` and reshapes to `{%$data, stage => $stage}`; fold that normalization in and keep the two-arg signature (mirrored by `StageDelegate::reload`).
3. Simplify take_dispatch_tasks to drain all started tasks (`my @out = @$list; @$list = (); return @out`), drop the `undef` arg at `Runner.pm:1117`, update the mock in `t/AI/unit/Runner_dispatch_abort.t:39` (and comment 175); rewrite the comment to state the contract (drain all started tasks; spawns live in PENDING_SPAWNS, not TASK_LIST). Also rewrite the identical stale run_job comments in `Role/Scheduler.pm:119-125` (kept accurate first sentence).
4. Make State's `_stage_startup_timeout` the single copy (rename to a public `stage_startup_timeout`, still reading `$self->{+SETTINGS}` directly — not the lazy settings() accessor); have `Resource/Preload.pm` delegate via `$self->{+STATE}->stage_startup_timeout`; delete both mirror comments. Move `t/AI/unit/Resource_Preload.t:100-107`'s settings injection onto the FakeState constructor.

Verify: both canonical runners green; `grep -rn '->next_task\|_queue_run\|_stage_startup_timeout' lib` shows only the intended survivors; State_requeue_task.t / Resource_Preload.t updated and green.

### #69 — Runner.pm/Scheduler hygiene: dead imports/slots, stale comments, key & HashBase consistency

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (extends #17 pattern) · Do BEFORE chunks 11/16/22/23 (all edit Runner.pm)

**Problem.** `lib/Test2/Harness2/Runner.pm` carries dead loads/imports (file2mod/parse_exit/runner_events_file used once on line 13 only; `use Test2::Harness2::Util::Queue()` at 14; `use ...::Runner::Constants` at 18 with CATEGORIES/DURATIONS unused; `use ...::Runner::Spawn()` at 22 — Spawn is instantiated only in `Preload/Host.pm:322`) and four never-read accessor slots (`<job_count <slots_per_job` at 38, `<cover` at 46, `<nytprof` at 52; values still arrive via the settings splat). `lib/Test2/Harness2/Runner/Role/Scheduler.pm:76-79,119-125` has stale comments naming the deleted run_stage/end_test_loop/run_job. Shared runner hash keys are accessed three ways: Role::Scheduler declares constant-only slots for grep-safety (8-17), yet Runner.pm reads role keys as bare strings (`{'job_passed'}` 1457, `{'collector_reap'}` 1525, `{submit_buffer}` 888/901, `{service_select}` 541, `{service_peers}` 741/763/785/1321, `{service_subs}` 567), while Runner declares `+monitor`/`+job_pids` but Handlers uses bare `{'monitor'}` (1148) and `{'job_pids'}` (349/869/976) — MONITOR is declared-and-unused; a typo vivifies a new slot. Finally `Runner/StatusReport.pm:8` (and 10 other Runner/* modules) `use Object::HashBase` while Runner.pm/State.pm/Run.pm use the bundled `Test2::Harness2::Util::HashBase`, and `dist.ini` does not declare `Object::HashBase` (satisfied only transitively via Test2-Collector).

**Steps.**
1. Delete the dead use/import entries (lines 13 partial, 14, 18, 22) and the four dead slots (38,46,52) plus the `$runner->cover` POD item (~1582); verify no fully-qualified `Test2::Harness2::Runner::JOB_COUNT`-style reads before deleting the constants, and confirm `Preload/Host.pm` loads/requires `Runner::Spawn` itself (add a `require` there if only the Runner `use` provided it).
2. Rewrite the two Scheduler.pm comments: 'stop' request sets service_stopped → `SIGNAL='TERM'` so run_scheduler_only winds down; dispatch_pending takes ALL started tasks (preload → stage channel, no-preload → `_launch_local_job`), nothing stays in the task list. Keep terse (chunks 16/23 rework dispatch again).
3. Apply the #17 pattern uniformly: declare constant-only slots in the owning role (Role::Tiny compiles in the role's own package, so Handlers must declare its own for the keys it owns — job_passed/collector_reap/service_*; Runner keeps declaring the slots it constructs) and convert the bare-string accesses in Runner.pm and Handlers.pm (incl. 436, 447/1332, 1025) to `{+CONST}`. Note the service_* keys' true owner is `Role/Service.pm` (bare strings at ~20 more sites, also composed into Preload::Host/Sampler) — sweep it too. Consider an author-test grep forbidding new bare self-hash keys in Runner*/Role*.
4. Close the HashBase-dep hole: add `Object::HashBase (>= 0.019)` to `dist.ini [Prereqs]` (cheapest); do NOT repoint the direct users at the bundled 0.008 copy (Resource.pm/Resource/JobCount.pm/Resource/Preload.pm rely on 0.019 `&Role` syntax from #24). Reconcile the STYLE_GUIDE/ARCHITECTURE §2.1 "use Object::HashBase" wording vs #61's bundled-copy prescription (update whichever loses).

Verify: both canonical runners green; `grep -rn "{'job_passed'}\|{'monitor'}\|{'service_select'}" lib` returns nothing outside declarations; a clean-room install without Test2-Collector's transitive Object::HashBase still resolves the prereq.

### #70 — Split oversized Handlers.pm (flag for human review)

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** — · Land BEFORE chunks 16/27/28 so their new handlers get a clean home

**Problem.** `lib/Test2/Harness2/Runner/Role/Service/Handlers.pm` is 1255 non-POD lines (`perl -ne 'print unless (/^=\w+/../^=cut/)||($seen||=/^__END__/)' | wc -l`), past the STYLE_GUIDE 1000-line module limit which says to flag for human review. It carries three separable concerns interleaved: the request_handler_* RPC surface, the collector-EOF completion/terminate/abort machinery (collector_conn_eof, decide_collector_outcome, terminate_run_collectors, _enforce_terminate_grace, _enforce_collector_connect_timeout, ~340-762), and the transition-hub/announce forwarding (service_transition, announce_job/announce_run/announce_run_health/announce_system_load, ~1146-1375).

**Steps.**
1. Per the style guide, flag for human review rather than silently splitting; get sign-off on the seams.
2. Keep the request_handler_* RPC surface in this role; relocate the completion-decision + terminate/abort machinery to `Runner::Role::Service::Completion` and the announce_*/service_transition hub to `Runner::Role::Service::TransitionHub`, composing both back into the same consumer (Runner) so dispatch-by-name still works. The concerns are interleaved, not contiguous line-ranges — relocate self-contained methods, do not abstract.
3. Honor #18's constraint (explicit handlers kept, no generic factory) and the TODO_TASKS 'do NOT cut' list (Role::Service/Connection framing, Monitor mirror) — split around load-bearing pieces.

Verify: both canonical runners green; each new role file under the 1000-line limit; `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` covers the RPC + completion + announce paths unchanged.

### #71 — Runner::Client/Subscriber connect layer + announce_* fold

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #19/#27 DONE; future beneficiaries #62, DB-4 #50) · Coordinate after chunk 24/#27 Client churn

**Problem.** `lib/Test2/Harness2/Runner/Client.pm:207-247` connection() and `lib/Test2/Harness2/Runner/Subscriber.pm:200-226` _connect() are the same ~30-line retry/backoff connect loop, and both duplicate `socket_path` (Client 129-131 / Subscriber 98-100), the lazy `identity` `"<kind>-$$"` default, and `sub CONNECT_TIMEOUT { 30 }` (198 each); the only real difference is Client's liveness_check/runner_gone escape. Separately, `lib/Test2/Harness2/Runner/Role/Service/Handlers.pm` announce_job (1263-1268), announce_run_health (1292-1298), announce_run (1336-1341) and announce_system_load (1367-1372) each end with the same fold+encode+forward: `{facet_data=>{…}}; $self->monitor->feed($payload); $frame=compress_blob(encode_json($payload)); $self->forward_frame($frame,$run_id)`.

**Steps.**
1. Add `Test2::Harness2::Runner::Role::SocketClient` (Role::Tiny, alongside Role::Scheduler) providing socket_path, identity(kind), CONNECT_TIMEOUT, and `_connect` with an optional liveness-check hook; compose into both Client and Subscriber. Leave the reply-wait loops (Client::_request vs Subscriber::subscribe) separate — they diverge materially (Subscriber parks transition deltas / replays into the Monitor mirror).
2. Extract `_announce($self,$facets,$run_id)` (`{facet_data=>$facets}; monitor->feed; forward_frame(compress_blob(encode_json($payload)),$run_id)`); have the four announce_* methods call it (announce_system_load passes undef for a global broadcast). Keep the per-method doc comments. Leave service_transition (feed 1161/forward 1193) outside the helper — it forwards the already-received frame verbatim without re-encoding. This is intentionally NOT the #18-rejected handler factory.

Verify: both canonical runners green; connect retry/timeout behavior and Monitor-mirror snapshot/transition ordering unchanged; announce output byte-identical.

### #72 — Watchdog/Monitor/Handlers dead code & stale comments

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (context: #12/#27/#28/#32 DONE)

**Problem.** `lib/Test2/Harness2/Runner/Watchdog.pm` abort_remaining's `terminate => 0` override (95-97 POD, 133-138 code) has no caller — the guard at 138 is always true and the POD misdescribes the resource-timeout path (which flows through the no-args wind-down at `Runner.pm:1286` with terminate ON); and its `->can('abort_run_collectors')`/`->can('mark_job_decided')` guards (139, 185-186) are always true in production (Runner unconditionally composes Handlers) and exist only to serve FakeRunner in `t/AI/unit/Runner_Watchdog.t`. `lib/Test2/Harness2/Runner/Monitor.pm` feed_frame (270-286) and final_state (312-315) have no production callers (feed_frame is feed's dead frame-decode path, sole user of the Zstd/JSON imports at 8-9; final_state readers poke `$c->{final_state}` directly). `Handlers.pm:884-885` comment claims request_handler_truncate returns a terminated count but line 908 returns `{ok=>1, running=>$running}`; `abort_run_collectors` (747-762) computes a count its only production caller (Watchdog.pm:147) discards. `Handlers.pm:1253-1257` announce_job comment references the deleted stop_task/retry_task handlers (the file itself says so at 818-821).

**Steps.**
1. Delete the `terminate` parameter check in abort_remaining (run the terminate block unconditionally — provably behavior-neutral), remove the `terminate => 0` POD (94-97) and inline comment (126-137).
2. Add recording stubs for abort_run_collectors/mark_job_decided to FakeRunner in `t/AI/unit/Runner_Watchdog.t` (push calls onto an array; must be repeatably callable for the idempotency check) and make the two `->can()` calls unconditional so a wiring regression fails loudly; add assertions on the recorded calls.
3. Delete Monitor feed_frame (270-286) + its SYNOPSIS/POD entries + the now-unused decompress_blob/decode_json imports, and its tests-only coverage in `t/AI/unit/Runner_Monitor.t`; delete final_state (312-315). Keep `feed` as the public entry (POD documents _process separately).
4. Fix the request_handler_truncate comment to `{ok=>1, running=>...}`; for abort_run_collectors either drop the count loop and update `t/AI/unit/Runner_abort_terminate.t:125` to assert the terminate side effects, or keep the count and comment it diagnostic/test-only (POD 127-132, inline 746). Rewrite the announce_job comment (1254-1257) to name the real remaining undef-run_id source (an EOF-decided collector whose identity payload omitted run_id) after tracing decide_collector_outcome (420/451/459/464/545); if no reachable caller ever omits run_id, delete the backfill + comment instead.

Verify: both canonical runners green; Runner_Watchdog.t / Runner_Monitor.t / Runner_abort_terminate.t updated and green; `grep -rn 'feed_frame\|terminate =>' lib` clean.

### #73 — Job/JobLauncher dead exec machinery: launch_via_fork, update_io fallback, prof_file

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (post #29/#39 residue; context #4/#28/#40) · Keep `Util::IPC` swap_io (kept core per #6/§5.4)

**Problem.** `lib/Test2/Harness2/Runner/JobLauncher.pm:241-260` launch_via_fork has no callers (the live launchers are launch_via_double_fork and launch_spawn; the comment at 256-257 and POD at 665/676 misdescribe it), so `_run_collected_child`'s non-collected branch is unreachable (line 323 `$collected` is always true; the `unless ($collected){...longjump...}` at 340-346 is dead). `update_io`'s job-file fallback (517-554) is unreachable — its only caller `cleanup_process:399` runs `unless $collected` and both live paths (collected test jobs; Spawn via `_install_spawn_fds` early-return 522-523) skip it — so lines 525-553 (open_file out_file/err_file, swap_io, `$FIX_STDIN=1`) never run, and the BEGIN `seek(STDIN,0,0) if $FIX_STDIN` (line 32) never fires; that strands `Job.pm` out_file/err_file (423-424) and their JSON_SKIP entries (385/391). `lib/Test2/Harness2/Runner/Job.pm:646-655` prof_file has no caller anywhere (NYTProf is handled via `-d:NYTProf` at 204 + `NYTPROF` env at 678). Stale comment at `Runner/Preloader.pm:208` references launch_via_fork.

**Steps.**
1. Delete launch_via_fork (241-260) and its POD; delete the non-collected branch + `$collected` variable in `_run_collected_child` (set `$0` to 'yath-collector' unconditionally, was 327); rewrite the comments at JobLauncher.pm 89/147/256-257/313 and POD 665/676 to describe only the two live entries (double-fork collector parent for preload test jobs; launch_spawn for spawn); fix the stale `Preloader.pm:208` reference. Leave a short pointer comment where launch_via_fork was (#7e precedent). If a non-collected fallback is wanted for safety, replace with a `die` (a test job reaching it means it escaped its collector).
2. Reduce update_io to the `_install_spawn_fds` call; delete the file-open/swap_io block (525-553), the `$FIX_STDIN` variable + its seek hook (line 32), and the now-unused clone_io/open_file/swap_io imports from JobLauncher (keep swap_io exported from Util::IPC — kept core). Drop `Job::out_file`/`err_file` (423-424) + their JSON_SKIP entries (385/391) + Spawn's undef overrides; keep `Job::in_file` and Spawn's in_file override (still live at Job.pm:226/299). Remove the out_file/err_file mock overrides in `t/unit/Test2/Harness2/Runner/Job.t:93-94`. Update the stale comments at JobLauncher.pm 139/200.
3. Delete `Job::prof_file` (646-654); note the removal in Changes (documented shipped method).

Verify: both canonical runners green (both no-preload and `--preload`); `grep -rn 'launch_via_fork\|->out_file\|->err_file\|prof_file\|FIX_STDIN' lib t` clean of the removed surfaces; Job.t green after the mock removal.

### #74 — Job/Event/reader dead attributes & stale comments

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (context: chunk 24 #27/#32) · Land before ArchiveProducer reuse (§4.5 reader generalization)

**Problem.** `lib/Test2/Harness2/Event.pm` declares `stream_id` (28) and `processed` (35) HashBase slots never set by any of the three Event->new sites (Renderer/Base.pm:612, RunnerReader.pm:158, JobReader.pm:92), and TO_JSON deletes phantom facet keys harness_job_watcher/harness.closed_by (78-79) that no 2.0 producer (or t2clib) emits — all 1.0 leftovers (line 80's JSON-cache strip and 81's PROCESSED delete must stay). `use_stream` is plumbed end-to-end but never read: `Run.pm:19` `<use_stream` and `Runner/Spawn.pm:39` `sub use_stream {0}` (which overrides a method neither Runner::Job nor IPC::Process defines) and `TestFile.pm:23` passthrough are all write-only (the consumer was 1.0's stream-formatter selection, now gone — Job.pm:676). `Job.pm:727-735` set_exit is a pure pass-through override of `IPC/Process.pm` set_exit that unpacks four unused vars just to host a chunk-24 comment. `Job.pm:78-79` has `# Avoid a ref cycle` above a commented-out `#weaken(...)` and line 11 imports `weaken` (never called). `lib/Test2/Harness2/JobReader.pm:15,80` declares/writes `+final_state` never read (poll uses local `$fs`).

**Steps.**
1. Drop Event.pm `stream_id`/`processed` slots + their POD (159-162, 172-177); drop the two phantom facet-key deletes at 78-79 (keep 80/81). HashBase stores unknown keys without accessors, so decoding old jsonl stays safe.
2. Delete the internal use_stream plumbing: `Run.pm:19` slot + POD, `Runner/Spawn.pm:39` override, `TestFile.pm:23` @FIELDS entry + POD, and the payload writes at `App/Yath2/TestFile.pm:547,614`; update `t/unit/Test2/Harness2/TestFile.t:28,66` and `t/AI/unit/runner_no_file_read.t:36`. KEEP the user-facing `--TAP/--no-stream/--stream` CLI options in `Options/Run.pm` for now (mark the description/comment inert); file a small follow-up on whether to forward the choice to Test2-Collector or retire the flags.
3. Delete `Job::set_exit` (727-735); relocate its chunk-24 invariant note (exit is health-only; verdict from collector transitions) into Job.pm POD or a comment near spawn_params. Verify the only set_exit definitions are IPC/Process.pm + this one.
4. Delete `Job.pm:78-79` (comment + commented-out weaken) and change line 11 to `use Scalar::Util qw/blessed/;` — do NOT re-enable weaken (jobs derive attrs from `$self->{+RUNNER}` well after construction at 426/431/459/569/629, are short-lived, and no leak exists).
5. Delete the `+final_state` slot (JobReader.pm:15) and the write at line 80 (use the in-scope `$fs`).

Verify: both canonical runners green; TestFile.t / runner_no_file_read.t / Job.t updated and green; `grep -rn 'stream_id\|->use_stream\|{use_stream}\|FINAL_STATE' lib` clean except the kept CLI option.

### #75 — Job.pm internal duplication: switches dedup, run_dir

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (coordinate lightly with chunk 22 #12 which reworks Runner::Run construction)

**Problem.** `lib/Test2/Harness2/Runner/Job.pm:615-644` switches() runs three consecutive near-identical dedup loops over task/runner/env switches, each repeating `$self->{+USE_W_SWITCH}=1 if $s =~ m/\s*-w\s*/;` and `push @switches => $s;` and differing only in which %seen hashes they consult; the same `-w` regex appears a fourth time (negated) in use_fork at line 566. `Job.pm:426` re-derives the run directory by hand (`clean_path(File::Spec->catdir($_[0]->{+RUNNER}->dir, $_[0]->{+RUN}->run_id))`) although its `{+RUN}` is a `Test2::Harness2::Runner::Run` (built at StageDelegate.pm:109 / State.pm:305 with the workdir) that already exposes a memoized `run_dir` (`Runner/Run.pm:27`) wrapping the base rule (`Run.pm:41-45`) — three run_dir surfaces, one re-implemented layout invariant.

**Steps.**
1. Collapse switches() to one helper loop over the three source lists that preserves the current intra-source-duplicates-kept / cross-source-dedup asymmetry EXACTLY (check only prior sources' seen-set); hoist `m/\s*-w\s*/` into a single predicate (e.g. `_is_w_switch`) shared with use_fork. Do NOT tighten the regex in this pass (it matches '-w' as a substring; `\s*` is zero-width) — make any dup-policy or regex change a separate ticket with a test.
2. Change `Job.pm:426` to `$_[0]->{+RUN_DIR} //= clean_path($_[0]->{+RUN}->run_dir)` (Runner::Run::run_dir ignores args and is already workdir-bound); verify `Runner::Run->workdir == Runner->dir` on both construction paths. `Runner/Spawn.pm:37` overrides run_dir to '' so the spawn path is unaffected.

Verify: both canonical runners green; switches() emits byte-identical switch lists (add a test if none covers intra-source dups); run_dir path unchanged for both normal and spawn jobs.

### #76 — TestFile family cleanup: POD hygiene, no-instantiation, queue_item dup, dead setters

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #58 REF-PORT — keeps Test2::Harness2::TestFile state-only; coordinate #58's E1 tests as queue_item regression coverage)

**Problem.** `lib/App/Yath2/TestFile.pm:248` uses the STYLE_GUIDE-forbidden term 'backstop'; line 500 carries a stale `# NOTE: Test this` above a regex shipped for years (the caller at 285-291 tests `if ($shbang)` on a helper that always returns a hashref); the check_feature POD (802-807) says undef is returned for documented features but the code (105-111) returns %DEFAULTS values, and the POD still describes only the legacy HARNESS-NO/USE/YES directive forms (stale after #58). `Test2::Harness2::TestFile` is never instantiated by production code (only tests call from_task); the no-op `use Test2::Harness2::TestFile();` at `App/Yath2/TestFile.pm:16` and its POD (689, 837) plus `Finder.pm:758` claim an integration that does not exist. `App/Yath2/TestFile.pm:530-561` (directive_error branch) hand-writes the same ~20 base task fields as the normal return (595-625) — a new field must be remembered in both or error-queued tasks ship an incomplete shape (read as undef by the runner). `Test2::Harness2::TestFile.pm:45-46,53-64` has four setters set_min_slots/set_max_slots/set_retry/set_retry_isolated with zero callers in 2.0 and 1.0, undocumented in POD (though check_min_slots/check_max_slots at 143-155 read the fields they populate — a real plugin-override seam parallel to set_stage).

**Steps.**
1. Zero-risk doc fixes: replace 'backstop' with 'safeguard' (248); delete the stale NOTE (500); rewrite check_feature POD (802-807) to document the default-value behavior + the optional `$default` arg (fix the 'ture' typo) and cover both HARNESS-... and the new HARNESS2 grammar (cite #58). Optionally drop the always-true `if ($shbang)` guard's dead-conditional appearance without changing `_parse_shbang`'s return contract.
2. Remove the no-op `use Test2::Harness2::TestFile();` at `App/Yath2/TestFile.pm:16`; rewrite the POD at 689/837 (and check `Finder.pm:758`) to state the runner consumes the raw task hash and Test2::Harness2::TestFile is the state-only counterpart, not currently instantiated. Do NOT delete `lib/Test2/Harness2/TestFile.pm` (referenced by #58; exercised by its unit tests).
3. Build one `_task_base()` returning the ~20 always-present base fields (binary, non_perl, category, duration, conflicts, switches, file, rel_file, job_id, job_name, run_id, stamp, rank, use_*, io_events, smoke, no_preload, require_preload, preload_list, stage) + QUEUE_ARGS/%inject tail; have both branches spread it and override specifics (error branch: category=>'general', no_preload=>1, directive_error=>...). Do NOT fold `_optional_task_fields` (628-643) into the base.
4. Either document the four TestFile setters in the POD as plugin-facing API (matching set_smoke — the lower-risk resolution given check_min_slots/check_max_slots read their fields) or delete them if the maintainer confirms the seam is unwanted.

Verify: both canonical runners green; `grep -rn 'backstop' lib` empty; error-queued and normal task payloads have identical shape (add/keep a test finalizing with a directive_error).

### #77 — Preload dead code & stale stubs

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (residue of #22/#29; feeds #8's deferred Host run_stage/run_job collapse) · Coordinate with chunk 23 (edits Preload.pm)

**Problem.** `lib/Test2/Harness2/Runner/Reloader.pm:153-158` never stores STAT_LAST_CHECKED (the final assignment writes a lexical, not `$self->{+STAT_LAST_CHECKED}`), so the stat-poll throttle guard at 157 is always false and `stat_min_gap` (Preloader.pm:75, Reloader attrs 36/58/74) is inert — the comment claims disk-hammering avoidance that does not happen (and Preloader::check's own 1s LAST_UPDATE gate is the real throttle; the stat path only runs on non-inotify platforms). `Preload/Host.pm:664-672,699-708` run_stage's non-stage-service else-branches are unreachable (`$stage` is set two lines before `is_stage_service`, always a non-empty name), and `$self->state->stage_restarting` at 707 would die (StageDelegate has no such method); `StageDelegate.pm:136-137` stage_ready/stage_down no-op stubs serve only those dead branches. `Runner/Preloader.pm:25` `<persist` is passed by both constructors (Host.pm:200, Runner.pm:240) but never read. `Preloader.pm:656` declares an unused `@fails`; `Preload.pm:150` has an unreachable second `$caller //= [caller()]` (already defaulted at 142).

**Steps.**
1. Delete Reloader's broken throttle block (153-158), the STAT_LAST_CHECKED/STAT_MIN_GAP attrs (36/58/74) and the `stat_min_gap` constructor arg (Preloader.pm:75) — the caller-side 1s gate is sufficient and this avoids the behavior change fixing-the-store would cause (stat cadence dropping to 2s off-Linux).
2. Drop run_stage's if/else on `$stage_service` (keep the service path unconditionally; add a one-line croak/assert if `is_stage_service` is ever false, documenting the STAGE-always-set invariant and protecting #8's future Host collapse); also make the two other `if ($stage_service)` gates (678, 699) unconditional. Delete `StageDelegate::stage_ready`/`stage_down` (136-137) + their POD (76-80); KEEP the live `done` stub (142, called from Host.pm:823) and `is_stage_service` (tested in runner_rootpid.t). Re-verify Handlers/Runner call stage_ready/stage_down only on State, not the delegate.
3. Delete `<persist` from Preloader's HashBase list and the `persist =>` arg at both construction sites; leave the callers' own PERSIST slots (Host orphaned/pfile at 799; Runner shutdown at 502/514/1286/1402) untouched.
4. Drop `@fails` from `Preloader.pm:656` and delete the redundant `Preload.pm:150` line.

Verify: both canonical runners green; `grep -rn 'STAT_LAST_CHECKED\|stage_restarting\|->persist\b\|@fails' lib` clean; runner_rootpid.t green.

### #78 — Preload DEFAULT_STAGE type fix + closure/resolve duplication

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: landed #10/#23, ARCHITECTURE §4.7a) · Coordinate/rebase with pending chunks 11/16

**Problem.** `lib/Test2/Harness2/Runner/Preload.pm:180-184` default_stage returns `$self->{+STAGE_LIST}->[0]` (a StageConfig OBJECT) when no `default()` was declared, but set_default_stage stores a NAME string and consumers require a name: `Preload/Host.pm:257` `$name eq $default` never matches an object (so no stage is flagged default — masked to silent wrong-default by State::_default_stage_from_map picking alphabetically-first) and `Preloader.pm:108` returns it as the task's stage name; the merge cache at `Preload.pm:177` (`$self->{+DEFAULT_STAGE} //= $merge->default_stage`) can permanently cache the object. `Preload.pm:31-78` import repeats the same `croak "No current stage" unless @{$instance->stack}; my $stage = $instance->stack->[-1];` preamble in the default/pre_fork/post_fork/pre_launch/preload/reload_remove_check/reload_inplace_check closures (watch uses a variant). `Preloader.pm:181` launch_stage re-resolves the stage name that its sole caller `_preload_stages` (152) resolved on line 150.

**Steps.**
1. Make default_stage always return a name: `return $self->{+STAGE_LIST}[0] ? $self->{+STAGE_LIST}[0]->name : undef;`; fix the merge cache at 177 to copy only an explicitly-set DEFAULT_STAGE name (or normalize with `blessed($v) ? $v->name : $v`). Add a test: a multi-stage preload without `default()` yields a Host stage map with exactly one `default=>1` (first-declared stage) and `Preloader::task_stage` returns a plain name. Note this intentionally changes observed behavior for no-default() preloads (the flag is now set).
2. Hoist one lexical helper inside import: `my $current_stage = sub { croak "No current stage" unless @{$instance->stack}; return $instance->stack->[-1] };` and call it from the six closures; leave the `watch` variant (it falls through to the DepTracer path, does not croak). `default` uses `$stage->name` — the helper-returns-stage shape accommodates it.
3. Delete the line-181 re-resolution in launch_stage and document that it takes an already-resolved StageConfig ref or 'NOPRELOAD'; keep the resolution at `_preload_stages:150` (it also serves the Host.pm:855 respawn path that passes a plain name, and _preload_stages needs the resolved ref after launch_stage returns). Optionally add a `confess` guard in launch_stage asserting `ref $stage || $stage eq 'NOPRELOAD'`.

Verify: both canonical runners green; the new default-stage test passes; a `--preload` run with a named default and an implicit-default preload both dispatch correctly.

### #79 — Resource boilerplate consolidation + constructor removal

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (schedule AFTER #59 settled — 0e93506b0 — since UnixLimits/Disk/CPU/Memory are #43/#59 deliverables; #24 Resource Role DONE is the enabler)

**Problem.** `Resource/CPU.pm:114-142,197-204` and `Resource/Memory.pm:139-167,266-273` are byte-identical available/assign/record/release + `_utilize_from_settings`; `Resource/UnixLimits.pm:241-269,478-485` repeats the four with an added `is_supported` line; `Resource/Disk.pm:214-230` repeats assign and overrides record/release with no-ops the composed `Runner::Resource` role already supplies (Resource.pm:36-38); `resource_name` is identical in all four (CPU:114/Memory:139/Disk:184/UnixLimits:212) although HashBase already generates a `name` reader (no lib caller); the duplicated croak says 'job' while the checked param is a task hashref. Separately, all six resource classes (CPU:10/65-70, Memory:12/75-80, Disk:12/81-86, UnixLimits:12/93-98, JobCount:8/16-21, Preload:8/20-25) carry a `# Predeclare new()` comment + `sub new;` + a hand-written `sub new { bless {@_}, $class; init; }` that Object::HashBase's generated new already provides (contradicting Resource.pm POD 138-140/386).

**Steps.**
1. Hoist the shared throttle contract into `Role::Resource::Utilizer` (composed by CPU/Memory/UnixLimits): default available() (task-defined croak + optional overridable `is_supported` gate + should_defer_for_utilization), assign() stamping `$state->{record}`, record()/track_started, release()/track_released, `_utilize_from_settings`; preserve UnixLimits' `return 1 unless is_supported` as an overridable hook. Disk is NOT a Utilizer-composing resource, so de-dup its redundant resource_name + no-op record/release against the base `Runner::Resource` role, and its assign copy stays or moves to base (not Utilizer). Drop the four `resource_name` copies in favor of the generated `->name` (update the two t/AI tests). Fix or drop the stale `'job' is required` wording.
2. Delete the `sub new;` predeclaration + comment + custom `sub new` from all six classes together (removing the predeclare in isolation would warn; removing all three lets HashBase generate new with identical behavior — init still fires). Drop any resource-authoring template guidance implying a custom new() is needed.

Verify: both canonical runners green; `t/AI/unit/Resource_Throttle.t` and `Resource_OSLimits.t` green; a resource composes and constructs with the generated new (init fires, defaults applied); `grep -rn 'sub new;\|sub resource_name' lib` clean of the removed copies.

### #80 — Resource JobCount header fix + v5.38/signature normalization

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (prerequisites #24/#10/#59 DONE; standalone) · Sequence with #79 if both land in one pass

**Problem.** `Resource/JobCount.pm:119` emits `headers => [qw/Runtime Slots Name/]` but the renderer `Resource::status_lines` (`Resource.pm:82`) passes `header => $table->{header}` to Term::Table — nothing reads `headers`, so the slot table in `yath resources` (rendered at `Role/Service/Handlers.pm:926`, surfaced via `Command::resources`) shows data rows with no header row; every other resource (CPU:157/Memory:189/Disk:255/UnixLimits:291,318) uses `header`. Separately the Resource family mixes three code styles vs the STYLE_GUIDE `use v5.38` + signatures mandate: Resource.pm/JobCount.pm/Preload.pm still open with `use strict; use warnings;`, while CPU/Memory/Disk/UnixLimits declare `use v5.38;` but write substantive method bodies in `my $self = shift` style; siblings Role::Resource::Utilizer/SystemLoad/Sampler use signatures.

**Steps.**
1. Rename `headers` → `header` in JobCount::status_data (line 119) — a correctness fix restoring the dropped header row.
2. Add `use v5.38;` to Resource.pm/JobCount.pm/Preload.pm and convert the shift-style method bodies (available/assign/record/release/status_data etc.) in CPU/Memory/Disk/UnixLimits to signatures; leave `sub new;` forward decls and argless accessors as appropriate. Covered by `t/AI/unit/Resource_Throttle.t` and `Resource_OSLimits.t`.

Verify: both canonical runners green; `yath resources` shows the Runtime/Slots/Name header row for the slot table; `grep -L 'use v5.38' lib/Test2/Harness2/Runner/Resource*.pm` lists none of the target files.

### #81 — Util::IPC/FdPass/Connection low-level dead & duplication

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (context: #25 extracted _swap_in_io; #8 kept Util::IPC as primitive)

**Problem.** `lib/Test2/Harness2/Util/IPC.pm` builds near-identical error-formatter die closures at swap_io's default (55-59), _run_cmd_fork's `$die` (133-140) and _run_cmd_spwn's `$die` (177-184), and the fork/spwn variants deref `$params{caller1}`/`$params{caller2}` with no defined-check even though the only caller passing them is `IPC.pm:285-292` (spawn) — the four direct run_cmd callers (Client.pm:321, Tester.pm:186, Plugin/Git.pm:33, test.pm:271) pass neither, yielding garbled uninitialized-warning error lines; a fourth near-identical die closure lives at `JobLauncher.pm:538-545`. `IPC.pm:60-77` start() computes `my @caller = caller(1)` (line 63) never used. `lib/Test2/Harness2/Util/FdPass.pm:243,318-328` `_set_cloexec` re-implements the exported `Util::IPC::set_cloexec` (IPC.pm:41-50, already used by Role/Service.pm and Runner/Job.pm), against AGENTS.md's reuse mandate. `lib/Test2/Harness2/Role/Service/Connection.pm:256-261` close() is byte-identical to `Util/FdPass/Control.pm:139-144`, and the nonblocking-sysread errno ladder (sysread 65536; EAGAIN/EWOULDBLOCK/EINTR return; close on error/EOF) is duplicated between Connection::drain (268-282) and Control::_fill (231-243) — protocol-independent byte-pump.

**Steps.**
1. Default `$params{caller1} //= [caller...]` / `caller2` inside run_cmd so the `$die` path never derefs undef for the four direct callers; collapse the two backend `$die` closures + swap_io's default (and absorb the `JobLauncher.pm:538-545` copy) into one shared formatter, preserving the deliberate `__FILE__ line __LINE__` suffix that swap_io/_run_cmd_spwn append but _run_cmd_fork omits. Only `IPC::spawn` forwards caller1/caller2, so dropping the forwarding is safe.
2. Delete `IPC.pm:63` `my @caller = caller(1)`.
3. In FdPass.pm `use Test2::Harness2::Util::IPC qw/set_cloexec/`, call `set_cloexec($listen)` at line 243, delete `_set_cloexec` + its POD, and remove the now-entirely-unused `use Fcntl qw/FD_CLOEXEC F_GETFD F_SETFD/;` (line 8). Note the semantic delta (overwrite vs read-modify-write; silently skips fileno-less handles) is safe at the single live call site (fresh listen socket).
4. Extract the shared byte-pump core — a `read_available($fh)` returning (bytes, 'eof'/'fatal'/'again') — plus a shared idempotent-close (CLOSED-guarded CORE::close) role; keep the two wire protocols (Connection FrameBuffer vs Control BUFFER string + blocking toggle) separate on top. The idempotent-close shape also recurs inline at Role/Service.pm:431 and JobLauncher.pm:152.

Verify: both canonical runners green; `t/AI/unit/Util_FdPass*` and Role_Service tests green; run_cmd/swap_io error messages no longer emit uninitialized-value warnings from the direct callers.

### #82 — Role::Service teardown/dispatch + IPC::spawn dead form

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #18; #8 kept IPC base) · Land before chunk 16 (touches service lifecycle)

**Problem.** `lib/Test2/Harness2/Role/Service.pm:425-483` has three teardown methods (close_service/reset_service/close_all_connections) sharing the 3-line conns/peers/subs clear plus a duplicated select-close loop, with inconsistent close semantics (close_service calls `$_->close for values %$conns` at 464-466 AND re-closes the same fhs via the select loop 468-471 — a harmless double close; reset_service closes raw fhs only, never marking Connection objects closed); the three cases are DOCUMENTED as different (POD 114-133: close_service unlinks the socket path, close_all_connections is a post-fork no-exec sweep that must NOT unlink, reset_service sets `service_stopped=0`). `Role/Service.pm:255-265` handle_request special-cases `'stop'` at 259 although the generic dispatch two lines later (`request_handler_$command`) resolves 'stop' to the same method with the same args (this role defines request_handler_stop at 267; no consumer overrides handle_request). `lib/Test2/Harness2/IPC.pm:270-282,425-448` spawn's else branch (`$params={@_}; process_class // 'IPC::Process'`) is reachable only with >1 arg, but the two callers (Runner.pm:1373, Preload/Host.pm:778) both call `$self->spawn($job)` (one-arg); `process_class` appears only in IPC.pm.

**Steps.**
1. Extract one private `_teardown_service(%opts)` (flags unlink_path / reset_stopped / conn_objects_vs_raw_close) and make the three public methods thin documented calls into it; collapse close_service's double-close. Preserve the deliberate per-method semantics — do NOT switch reset_service to Connection->close without confirming `t/AI/unit/Role_Service_fd_hygiene.t` and Preload/Host's reset→reuse flow still hold.
2. Delete `Role/Service.pm:259` (the generic dispatch covers 'stop' identically, honoring subclass overrides both ways).
3. Delete IPC::spawn's else branch (277-281) so spawn takes exactly one proc object providing spawn_params() (croak otherwise); collapse the `if (@_==1)` scaffold; remove the `spawn(%params)`/`process_class` POD (425-448), keeping `spawn($proc)` (423). Record the narrowed signature under #8/chunk-21 residual.

Verify: both canonical runners green; Role_Service.t / Role_Service_fd_hygiene.t green; teardown/reset behavior and fd hygiene unchanged.

### #83 — Util::* dead modules & members + File::JSON dup

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Queue confirmed dead by finding evidence; the pending queue.jsonl retirement does NOT resurrect the flat-file queue)

**Problem.** `lib/Test2/Harness2/Util/Queue.pm` is dead: `grep -rn 'Queue->new|::Queue\b'` finds zero constructions/method calls; it exports nothing, so the four bare `use` lines (Runner.pm:14, Command/run.pm:10, Command/stop.pm:12, `t/unit/App/Yath2/RunPlan.t:7`) are no-ops (1.0 flat-file run-queue, retired by socket IPC). `lib/Test2/Harness2/Util/File/Value.pm` is dead — its only consumer is its own test `t/unit/Test2/Harness2/Util/File/Value.t` (code is lines 1-29; a 1.0 pid/value-file vestige). `lib/Test2/Harness2/Util/JSON.pm:17-49` defines four never-imported JSON_IS_* constants + @EXPORT_OK line, a default-exported encode_canon_json (59) whose only caller is its own test, and a stray `1;` at line 14 before the backend-probe if/elsif chain. `lib/Test2/Harness2/Util/File.pm:48-51` rewrite has zero callers; `Util/File/Stream.pm` has a dead `-tail` attribute + init tail-seek (14-30), dead seek (90-99), a use_write_lock branch (12,72-74,83) whose only setter is dead Queue::_enqueue, and a transposed `seek($fh,2,0)` at line 80 (absolute byte 2, not EOF — masked by '>>' mode); `Util.pm:311-313` open_file's `ext` option has no caller. `Util/File/JSON.pm:19-29` maybe_read copies the parent's `-e`/read/decode logic (File.pm:34-46) adding only an empty-file guard.

**Steps.**
1. Delete `lib/Test2/Harness2/Util/Queue.pm` and the four bare `use` lines; delete `lib/Test2/Harness2/Util/File/Value.pm` and its test.
2. Delete the four JSON_IS_* constants + their @EXPORT_OK/POD entries (~199-213); collapse the BEGIN block to `require JSON::MaybeXS; JSON::MaybeXS->import('JSON'); 1` with the JSON::PP fallback (the stray `1;` becomes natural); demote encode_canon_json to @EXPORT_OK (plausible DB-rewrite fixture; costs one line) and update its POD (~227) — trim its unit-test coverage accordingly.
3. Delete File::rewrite (48-51), Stream's tail attr + init tail-seek block + seek + the transposed `seek($fh,2,0)` at line 80 (append mode already positions at EOF; if kept use `seek($fh,0,SEEK_END)`), and open_file's `ext` branch (Util.pm:311-313); with Queue gone (step 1) also remove Stream's use_write_lock branch (12,72-77,83) + POD (141-150); trim the seek block in `t/unit/Test2/Harness2/Util/File/Stream.t:105-114`. Do NOT touch the DIFFERENT live `tail` attribute on RunnerReader/Renderer::Base; write() itself (66-88) is live.
4. Reduce File::JSON::maybe_read to `return undef unless -e $self->{+NAME} && -s _; return $self->SUPER::maybe_read();`.

Verify: both canonical runners green; `grep -rn 'Util::Queue\|File::Value\|JSON_IS_\|->rewrite\|use_write_lock' lib t` clean of the removed surfaces; Stream.t green.

### #84 — Unify gen_uuid onto Test2::Util::UUID (v7), drop Data::UUID

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** #48 (R9 boundary lowercasing), #57 (v7 timestamp assumption) — sequence before/with DB-4 (before the logger persists run/job UUIDs)

**Problem.** Two competing gen_uuid implementations export the same name with different version/case semantics: `lib/Test2/Harness2/Util/UUID.pm:7-21` uses `Data::UUID` → v1-style UPPERCASE (`UG()->create_str()`), imported by 11 real call-site files (Plugin.pm, Renderer/Base.pm, JobReader.pm, RunnerReader.pm, Command/watch.pm, TestFile.pm, Role/Service/Connection.pm, Command/spawn.pm, Command/stop.pm, Options/Run.pm, Options/Runner.pm; Plugin/Cover.pm is a dead import); `lib/App/Yath2/Util/UUID.pm:8-23` uses `Test2::Util::UUID` → v7 lowercase. STYLE_GUIDE mandates Test2::Util::UUID v7; R9 (#48, ARCHITECTURE.md:886-890) deliberately keeps the backend minting uppercase and centralizes lowercasing only at the DB boundary. Data::UUID is not even a declared prereq (only Test2::Plugin::UUID is).

**Steps.**
1. In `Test2::Harness2::Util::UUID` replace `Data::UUID` with `Test2::Util::UUID` — keep the output UPPERCASE so the 11 importers see only a v1→v7 version change, no case change (do NOT lowercase at generation; R9 owns that at the App::Yath2::Util::UUID boundary). Leave `App::Yath2::Util::UUID` as the lowercase boundary wrapper (derive_uuid stays).
2. Add `Test2::Util::UUID` to cpanfile/Makefile.PL/dist.ini and drop the `Data::UUID` prereq. Remove the dead `gen_uuid` import from `Plugin/Cover.pm`.
3. Note the known Test2::Util::UUID load-order gotcha (project_quickorm_uuid_case) in the ticket; ensure load order is correct.

Verify: both canonical runners green; `grep -rn 'Data::UUID' lib` empty; gen_uuid still returns an uppercase (now v7) string for the 11 backend importers and the App-side boundary still lowercases.

### #85 — Directives parser duplication + oversized _record

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #58 landed the Directives modules — reuse its ported unit tests as the regression gate)

**Problem.** `lib/Test2/Harness2/Util/Directives.pm` and `lib/Test2/Harness2/Util/Directives/Legacy.pm` duplicate ~40 lines of driver code: parse_fh (114-121 vs 90-97) and parse_string (123-129 vs 99-105) are byte-identical, _prune (395-408 vs 309-322) is byte-identical, and parse_line's line_no++/embedded-newline croak/undef guard (131-137 vs 112-118) is identical (parse_file differs only in Legacy passing `file => $path`); `App::Yath2::TestFile::_scan` feeds both parsers per line via the shared parse_line preamble. `Directives/Legacy.pm:157-267` `_record` is a ~98-executable-line if/elsif dispatcher over 11 directive names, past the STYLE_GUIDE 75-line sub limit (the branch bodies are multi-line, so the one-liner-dispatch exception does not apply).

**Steps.**
1. Extract the shared drivers (parse_file, parse_fh, parse_string, the parse_line preamble guard, _prune) into a small common base class or Role::Tiny role both parsers consume; Legacy overrides parse_file to add `file => $path`.
2. Convert `_record` to a dispatch table of small per-directive handler methods keyed on `$dir`, with `_record` reduced to the ~15-line tokenizer + lookup. Preserve the exact order/edge subtleties as pre/post steps: the top-of-sub `meta` arg pre-split (162-166), the `no retry`→retry.count=0 case, the bare-`HARNESS-RETRY`→count 1 fallback checking `_leaf('retry.count')`, and the `job ... slots` branch (regex-guarded on `$rest`, MUST stay last in the fallthrough) — a naive `%HANDLER` keyed purely on `$dir` would drop the `$rest`-regex and meta pre-tokenization. Frame as readability/STYLE_GUIDE compliance (the legacy HARNESS grammar is frozen, so add-a-directive friction is low → LOW priority).

Verify: both canonical runners green; #58's ported Directives unit tests pass unchanged (pure behavior preservation); a HARNESS2 file and a legacy HARNESS file both parse to the same internal representation as before.

### #86 — CoverageAggregator duplication, bugs & POD

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk med) · **Step:** CLEAN · **Depends:** — (no related open ticket; orthogonal to DB chunks)

**Problem.** `Log/CoverageAggregator/ByRun.pm:82-170` and `ByTest.pm:96-168` get_coverage_tests duplicate ~70 lines across three blocks (finder-exclusion fetch 89-94 vs 104-109; the changes/parts iteration 97-133 vs 112-142; the manager-application eval 150-167 vs 151-167 including the identical warn string) — both dispatched from `Plugin/Cover.pm:421`. `ByTest.pm:91` finalize pushes wrapper-shaped records `{$_ => delete $ip->{$_}}` that no consumer reads (stop_test at 33 pushes the bare value; `Cover.pm:216`/`239-245` read `$list->[0]->{files/test/manager}`) — an edge-case shape divergence for tests IN_PROGRESS at harness_final (bail/crash). Both files capture `my $err = $@` then warn with the raw `$@` (ByRun.pm:165 / ByTest.pm:166), violating the eval-error rule and leaving `$err` unread. `ByRun.pm:149` has a dead `// []` fallback with the wrong type ($tests{$test} is always a defined hashref; `[]` would hand managers a malformed arg). `CoverageAggregator.pm:252` SYNOPSIS calls a nonexistent `metrics()` and 348-357 references `coverage()` which exists only on ByRun (dies on base/ByTest). `ByRun.pm:36-60` touch and `ByTest.pm:45-71` touch duplicate the mdata merge (ByTest adds an empty-$set fast path), and `ByRun::record_coverage:23` has a dead `my $files = ... //= {}`.

**Steps.**
1. Hoist shared helpers into the base `Test2::Harness2::Log::CoverageAggregator`: `_finder_exclusions($settings)`, `_collect_changed_parts($changes,$filemap,%flags)` with a per-hit callback (or returning subs/loads/opens), and `_apply_manager($test,$froms,$changes,$coverage_data,$settings)` wrapping the eval/test_parameters/fallback-warn (return the raw `harness_job_end` facet from any job-end helper — do NOT centralize the file/time extraction, which differs: times uses `rel_file`+whole `times`, speedtag... i.e. ByTest uses `\%froms` hashref vs ByRun `\%tests`). Each subclass keeps only its accumulation shape. Confirm no other subclass overrides these before promoting.
2. Change `ByTest.pm:91` to push the bare value (`push @$cm => delete $ip->{$_} for keys %$ip;`); add a regression test that finalizes with a test still IN_PROGRESS (job-start without job-end) and asserts `finalize->[0]{files}`/`{test}` populated in the bare shape.
3. Use the captured `$err` in the warns (ByRun.pm:165 / ByTest.pm:166).
4. Drop the `// []` at `ByRun.pm:149` (`my $froms = $tests{$test};`).
5. Fix the SYNOPSIS to call `build_metrics()` (verify the returned shape) and reword the build_metrics section to say it returns the metrics hashref directly, mentioning `coverage()` only as ByRun-specific.
6. Extract `_merge_manager_data($self,$set,$mdata)` standardizing on the grep-dedup form (equivalent to ByTest's empty-set fast path); delete the dead `my $files` at `ByRun.pm:23`.

Verify: both canonical runners green; `t/integration/coverage.t`/`coverage2.t`/`coverage3.t`/`coverage4.t` green (they exercise both ByRun and ByTest); the new bail-out finalize test passes.

### #87 — Wire cli_args into help/POD (doc_args bridge)

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #45 DB-1 / #54 stub-move DB commands — scope the sweep to surviving commands)

**Problem.** `App::Yath2::Command.pm` cli_help (60) and generate_pod (109) both use `$class->doc_args`, whose base default is `()` (line 20), and no command overrides doc_args — while ~28 command files define `sub cli_args` (e.g. failed.pm:31, import.pm:45, test.pm:67, times.pm:24, speedtag.pm:56, projects.pm:11, replay.pm:26) with ZERO callers (`grep -rn -- '->cli_args' lib t` is empty; the pre_ai reference consumed cli_args at App/Yath.pm:141-144, dropped in the rewrite). Consequence: `yath help import` / generated POD show no [COMMAND ARGUMENTS] section even for commands that require positional args (the ~11 with non-empty cli_args; the ~13 that return `""` render nothing anyway).

**Steps.**
1. Fix at the base class: add a base default `sub cli_args { '' }` and make the doc generators consume cli_args — either rename the two `doc_args` call sites (Command.pm:60/109) to `cli_args` or add a base `sub doc_args { my $a = $_[0]->cli_args; length($a) ? ($a) : () }`. The cli_args string renders fine as a single unstructured usage line; no per-command reformatting needed (the truthiness/length guard is required since ~13 commands return `""`).
2. Keep the ~28 cli_args subs as-is; regenerate POD via `release-scripts/generate_command_pod.pl`. Scope any command-file touches to SURVIVING commands — do NOT edit server.pm/recent.pm/db.pm/db/*/import.pm (stubbed/moved by DB-1 #45 / DB-5 #54). Add a test that a command with cli_args produces a [COMMAND ARGUMENTS] section in both cli_help and generate_pod.

Verify: both canonical runners green; `yath help failed` shows the log-file argument; regenerated POD includes COMMAND ARGUMENTS for the ~11 commands with non-empty cli_args; the new test passes.

### #88 — Command base + test.pm dead code

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (chunk 17/30/41 residue; keep finalize_plugins + run.pm's live overrides)

**Problem.** `App::Yath2::Command.pm:175-184` setup_plugins/teardown_plugins have no callers (plugin setup/teardown moved into the runner — test.pm:204-205,466; Runner.pm:461/489 call its own), and `run.pm:83,85` `sub setup_plugins {}`/`sub teardown_plugins {}` no-op overrides of them are equally dead. `test.pm:62` and `start.pm:85` both define `sub MAX_ATTACH() { 1_048_576 }` with zero other references (dead + duplicated); `Command/runner.pm:35,42` declares/sets `our $RUNNER_PID` while the sub uses a separate lexical `$runner_pid` (no reader of the package var); `spawn.pm:348` `pre_exit_hook` is empty with no override. `test.pm:351-354,517-521` submitter() and job_count() have zero callers (consumers use `$self->client->submitter` directly; job counts come from `$plan->populate`), and `run.pm:90` `sub job_count {1}` overrides an inert method. `test.pm:44,118,179-188` cleanup_subs (slot + init + DESTROY) has no producer — nothing ever pushes a cleanup sub, so DESTROY always iterates an empty array.

**Steps.**
1. Delete Command.pm setup_plugins/teardown_plugins (no POD to remove) and run.pm's two no-op overrides (83/85); keep run.pm's live write_settings_to/setup_resources/finalize_plugins. Update the comment at `Plugin.pm:11` to point at Runner's methods.
2. Delete both MAX_ATTACH constants (test.pm:62, start.pm:85). Delete `our $RUNNER_PID;` + its assignment in `Command/runner.pm` (lines 35, 42 only — do NOT touch the live `Runner.pm` RUNNER_PID at 163/175 or the +RUNNER_PID HashBase slots in Preload.pm/Preloader.pm/Client). Delete spawn.pm's pre_exit_hook (348) + its call site (251) — no subclass/mock exists.
3. Delete test.pm submitter (351-354) + its stale 3-line intent comment (348-350), test.pm job_count (517-521), and run.pm's `sub job_count {1}` (90); confirm run.pm's neighboring stubs (monitor_preloads etc.) still have callers before touching anything else.
4. Delete the cleanup_subs `<cleanup_subs` slot (test.pm:44), its init (118) and the DESTROY method (179-188); note in the commit that #41 orphaned it (the accessor is read-only, so no external producer path exists).

Verify: both canonical runners green; `grep -rn 'setup_plugins\|MAX_ATTACH\|cleanup_subs\|->submitter\b' lib` shows only the intended survivors; DESTROY removal leaves no leak.

### #89 — test.pm/replay render sharing + final-data duplication

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (Related: #41/#42 DONE) · Coordinate with DB-Jsonl #55/#56 (rewrite the renderers-list construction) and #61 (renderers TTY-append)

**Problem.** `App/Yath2/Command/replay.pm` isa `App::Yath2::Command` (not test) but calls test.pm methods on itself fully-qualified: `$self->App::Yath2::Command::test::renderers` (53), `...::render_final_data($final_data)` (87), `...::render_summary($final_data->{pass})` (88), plus `require App::Yath2::Command::test` (8) — working only because replay declares HashBase slots RENDERERS/FINAL_DATA/TESTS_SEEN/ASSERTS_SEEN (14) that collide with test.pm's slots (SETTINGS is legitimately inherited from the shared base); renaming a slot in either file silently breaks the other. Separately `test.pm:639-769` render_final_data and _render_final_data_plainly duplicate the same four sections (retried/failed/halted/unseen) with the same headers (~90 lines), differing only in table() vs hand-printed lines (the plain variant re-checks `quiet>1` at 690 already checked at 643 and reorders columns), and _subtest_paths (733) and stringify_subtest_map (752) are the same @todo/@state traversal (`stringify_subtest_map($map)` == `join("\n", _subtest_paths($map))."\n"`). render_final_data is also borrowed cross-package from `replay.pm:87`.

**Steps.**
1. Hoist renderers(), render_summary(), render_final_data()/_render_final_data_plainly() plus the RENDERERS/FINAL_DATA/TESTS_SEEN/ASSERTS_SEEN slots into the `App::Yath2::Command` base class (covers test/run/watch/replay with no new module); keep renderers()'s `command_class => ref($self)` arg and render_summary's optional $time_data/$cpu_usage args (replay passes only $pass — safe); delete replay.pm's `require` and the three fully-qualified calls.
2. Fold stringify_subtest_map into `join("\n", _subtest_paths($map))."\n"`, guarding on `@paths` (an empty map differs: `"\n"` vs `""`). Drive both render variants from one section table `[key => header => columns]` with per-format column ordering/omission metadata (plain reorders filename-first and skips falsy reason); drop the redundant `quiet>1` re-check at 690. Preserve render_final_data's name/signature (still borrowed).
3. Add a golden-output test for both table and plain final-data modes before refactoring.

Verify: both canonical runners green; test/run/watch/replay render identical summary output; renaming a render slot no longer needs cross-file coordination.

### #90 — Command duplication: log-file arg, JSONL scan, reload-issue render, speedtag split

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (Related: #55/#56 jsonl format — helper regex/format changes land in one place) · Skip publish.pm (retired by #45/#54)

**Problem.** The log-file arg parse/validate triplet (`shift @$args or die "You must specify a log file"` + `-f` check + `m/\.jsonl(\.(gz|bz2))?$/` guard, preceded by the `'--'` strip) is copy-pasted in five commands (failed.pm:51-55, times.pm:48-52, replay.pm:55-59, speedtag.pm:89-95, client/publish.pm:40-44). The JSONL event-scan loop skeleton (`Util::File::JSONL->new(name=>...)` + `while(1){ poll(max=>1000) or last; ...}` + the stamp/job_id/facet_data guard triplet) is duplicated in failed.pm:57-77, times.pm:65-88, speedtag.pm:103-125 (also recurs at Finder.pm:315 and JSONLFileProducer.pm:117). The reload-issue rendering walk (%seen dedupe + `"==== SOURCE FILE: $file ===="` banner + error/warnings emission) is duplicated between run.pm check_reload_state (112-128) and status.pm (97-105). `speedtag.pm:83-188` run() is 80 executable lines doing four jobs (arg/threshold validation, JSONL scan, test-file rewrite, durations.json output), past the 75-line limit.

**Steps.**
1. Add `shift_log_file_arg($self)` to the `App::Yath2::Command` base ('--' strip + shift + `-f` + regex + die messages, returning the validated path); call it from the FOUR surviving commands (replay/failed/times/speedtag) — skip client/publish.pm (retired path per #45/#54).
2. Add an `each_log_event($cb)` / `each_job_end($cb)` iterator (base class or a small `Command::Role::LogRead`) owning the JSONL stream + poll loop + stamp/job_id/facet_data guards; each command supplies its per-event callback and does its own key extraction (times uses `harness_job_end->{rel_file}`+whole `times`; speedtag uses `clean_path(...->{file})`+`->{times}{total}`) — return the raw `harness_job_end` facet, don't centralize extraction. Combine naturally with step 1.
3. Extract a shared `reload_issue_report($reload_status)` on run.pm returning `(\@lines, $errors, $warnings)`; status.pm prints @lines (ignoring the counts — it uses its own earlier tally), check_reload_state keeps only the abort/confirm policy and consumes all three.
4. Extract `classify_duration($seconds)` and `tag_file($path,$dur)` (the read/inject/write block) from speedtag::run so it drops under 75 lines; add/confirm coverage of the HARNESS-DURATION header injection + durations.json output.

Verify: both canonical runners green; failed/times/speedtag/replay parse+scan behavior byte-identical; run.pm/status.pm reload-issue output unchanged; speedtag::run under the sub-length limit.

### #91 — Persist-family command cleanups

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #62 REF-PORT list/ping adds persist commands; #51 DB-4 workdir cleanup) · Coordinate resources.pm with #95 (Pfile→Discovery)

**Problem.** `stop.pm:72-79` and `kill.pm:46-49` duplicate the runner-teardown tail (`sleep(0.02) while kill(0,$pid)` + pfile unlink + `remove_tree(workdir,{safe=>1,keep_root=>0})` + "Runner stopped" banner); kill.pm:46 also re-reads `$self->pfile_data->{pid}` when `$data->{pid}` is in scope. `ps.pm:13` declares an unused `queue` HashBase slot (1.0 leftover) and ps.pm run() (30-34) omits the `attach_runner($data->{pid})` step every persist sibling performs (a consistency gap — ps never consults liveness, so no functional impact today). `resources.pm:34-79` runner_resources hand-rolls `App::Yath2::Pfile->find + $pfile->data + kill(0) + attach_runner` inside a `while(1){...sleep 0.2}` loop, repeating the full discovery+attach 5×/second, with an unreachable `return 0` at 78. Dead imports abound: stop.pm (9/11/12/20), abort.pm (7/8/10/12/14), kill.pm:10, status.pm (8/10), ps.pm (8/10/13), resources.pm (7/8) — verified count=1 per symbol (the ps.pm queue slot is also line 13).

**Steps.**
1. Add `wait_and_cleanup_runner($pid,$pfile_path)` to `App::Yath2::Command::run` (the only shared ancestor — stop extends run; kill→abort→status→run) used by stop and kill; reuse `$data->{pid}` in kill.pm. Do NOT drop kill.pm:37's early attach_runner (it must precede kill's own end_queue via the liveness closure); leave abort's SUPER-chain attach as canonical. Note #51 will later defer runner-side workdir cleanup, interacting with the command-side remove_tree in this tail — the shared helper localizes that.
2. Drop `qw/queue/` from ps.pm's HashBase line (plain `use ...::HashBase;`) and add `$self->client->attach_runner($data->{pid});` after `my $data = $self->pfile_data();`, mirroring status.pm:36.
3. In resources.pm do discovery+attach once before the loop (keeping non-fatal find semantics + the custom "No persistent runner..." message — do NOT blindly swap to $self->pfile_data which dies and prints a banner the screen-clear wipes); reduce the loop body to `eval { $self->client->resources }` with a runner-gone exit like ping.pm:71-75 + its SIGINT/SIGTERM flag; drop/reach the `return 0`.
4. Delete the listed dead `use` lines across stop/abort/kill/status/ps/resources (change ps.pm line 13 to plain HashBase).

Verify: both canonical runners green; `yath stop`/`kill`/`ps`/`resources` behave identically (attach + teardown + poll); `grep -n 'queue' lib/App/Yath2/Command/ps.pm` empty.

### #92 — Command unused-import sweep

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** —

**Problem.** Unused imports across command files (verified count=1 per symbol): test.pm — `Test2::Harness2::Run` (9), `Test2::Harness2::Event` (10), `croak` (27), the `sleep` symbol from `use Time::HiRes qw/sleep time/` (25; only `Time::HiRes::sleep(0.05)` is used, fully-qualified — keep `time`), plus a redundant `require App::Yath2::Util::File::JSON` at 587 already `use`d at line 11. run.pm — `Test2::Harness2::Run` (9), `Util::Queue` (10), `mod2file`+`open_file` (15), `table` (16), `File::Spec` (18), `croak` (20). start.pm — `Test2::Harness2::Run` (12), `table` (18), `croak` (24). spawn.pm — `croak` (9). reload.pm — `open_file` (10; keep `File::Spec` line 7, used at 35). do.pm — `Test2::Harness2::Util::File::JSON` (7) and `open_file` (9) in a die-stub command. help.pm — `pkg_to_file` (5) and `open_file` from line 12 (keep `find_libraries`, used at 32/35).

**Steps.**
1. Remove the listed unused `use` lines / import symbols and the redundant `require` at test.pm:587; for test.pm:25 drop only `sleep`, keep `time`; reload.pm:10, do.pm:7, do.pm:9 are whole-line removals; help.pm:5 whole line, help.pm:12 trim to `qw/find_libraries/`.
2. Run the canonical suites after — dropping a `use Module;` bareword also drops its side-effect load for any consumer that forgot its own import.

Verify: both canonical runners green; `perl -Ilib -c` each edited file; a spot-check confirms no removed import was transitively depended on via an inherited-then-called method.

### #93 — DB layer dead code & duplication

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** #53/#54 (own db/sync/import) — land after DB-5 stable · Coordinate with the active 2.0d-db-rewrite worktree

**Problem.** `lib/App/Yath2/Schema.pm:13-24` registers a `yath` ORM singleton (autofill autotype JSON/UUID/DateTime + autorow) that is never fetched — every live connection is built by `DB/Connect.pm:265-272` build_connection (its own comment: QuickORM's `db` is write-once, so the singleton is never attached), which duplicates the autofill block in `DB/ORM.pm:60-65`, kept in sync by hand; the five `require App::Yath2::Schema` sites (Logger.pm:134, db/sync.pm:83, import.pm:79, db_sync.t:44, db_duckdb_sync.t:36) are no-ops (require never runs import; qorm() installs into Schema's namespace). `Command/db/sync.pm:82-95` and `Command/import.pm:78-93` duplicate the DB bootstrap (three requires + read-only-source/writable-dest build_connection pair) and the R11 lazy-require comment. `DB/Logger.pm:636-645` `_find_or_create` and `DB/Sync.pm:448-456` are functionally identical (only the connection source differs). Dead members: Sync.pm gen_uuid import (8), `+source_flavor/+dest_flavor` slots (17-18), dest_run_uuids (169), %NATURAL test_files/machine_users entries (121-131); Logger.pm's `encode_json` import (10; keep decode_json) and `gen_uuid` (12; keep derive_uuid); Flavor.pm `<is_default` (16); Connect.pm's Importer/@EXPORT_OK (11-18, no importer); Carp `croak` in db/sync.pm:7 and import.pm:7 (both use die).

**Steps.**
1. Delete `lib/App/Yath2/Schema.pm` and the five/seven `require App::Yath2::Schema` no-op sites (leaving DB/ORM.pm the single autofill definition), OR reduce Schema.pm to a one-line delegator to `App::Yath2::DB::ORM` if a stable public module name is wanted.
2. Extract a `connect_pair($from,$to)` helper (`App::Yath2::DB::Sync->connect_pair` or a DB::Connect function) doing the three requires + read-only-source/writable-dest build_connection pair; consolidate the R11 lazy-require + DuckDB read-only comments. Leave the `to` env-var/description differences per-command (YATH_DB_SYNC_TO vs YATH_DB_IMPORT_TO); only `as_user` (YATH_DB_AS_USER) is a clean common factor.
3. Move `_find_or_create($con,$table,$natural,$pk_col)` to one shared home (`DB::Connect::find_or_create`, taking the connection explicitly) used by both Logger and Sync.
4. Remove the dead imports/slots/registry data: Sync.pm gen_uuid (whole line 8), source_flavor/dest_flavor (17-18), dest_run_uuids + POD, %NATURAL test_files/machine_users (121-131); Logger.pm drop only `encode_json` from line 10 (keep decode_json) and only `gen_uuid` from line 12 (keep derive_uuid); Flavor.pm is_default (or start using it for default-flavor lookup); Connect.pm Importer/@EXPORT_OK (11-18); Carp import in db/sync.pm:7 and import.pm:7.

Verify: both canonical runners green; the DB matrix (`Schema_quickorm.t`/`db_sync.t`/`db_logger.t`) green; a live connection still autofills without Schema.pm loaded; sync and import share one bootstrap + one _find_or_create.

### #94 — DB/web command-surface cleanup: recent, publish HTTP stack, die messages, stub dup

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk med) · **Step:** CLEAN · **Depends:** #45 (DB-1) — sequence with/after; Related: deferred §9 webapp port · Do the client-side halves now; defer server-side count plumbing to the webapp rewrite

> **Web-parking note (owner directive above):** scope removals to client-side dead scraps (the unread `$count` thread, the LWP→HTTP::Tiny port, die-message text). Do NOT delete any server/web-layer code — that surface is parked in `reference/old_db` for the §9 rework and comes back reworked, not rewritten.

**Problem.** `Command/client/recent.pm:56-59` computes `my $count = $recent->max || 10;` and threads it through get_data→get_from_http, but get_from_http (109-126) never reads $count (the request is `/recent/$project/$user`, no count param) and already dies with detail — so run()'s `or die` (59) and get_data's `// die` (106) are redundant stacked error layers; `App::Yath2::Options::Recent` is include_options'd only here (recent.pm:22), so its `max` option is a silent no-op (the #45 inlining dropped the old DB branch that used $count). `Command/client/publish.pm:12-13` is the distribution's only LWP::UserAgent user (loaded at compile time, plus a redundant `use LWP;`), while every other HTTP consumer (client/recent.pm:115, Finder.pm:150, Plugin/Notify.pm:300, Plugin/YathUI.pm:211, Util/JSON.pm:121) lazily requires HTTP::Tiny — and YathUI.pm:212 already does the same multipart upload; dist.ini carries both stacks. Seven stub commands (db.pm:50, db/importer.pm:27, db/publish.pm:28, db/recent.pm:33, db/sweeper.pm:27, recent.pm:33, server.pm:27) die with a user-facing message pointing at `AI_DOCS/2026-06-21-db-layer-rewrite-quickorm-spec.md` (shipped in the tarball but not installed to any user-accessible path). `Command/db/recent.pm:15-36` and `Command/recent.pm:15-36` are duplicate die-stubs describing the same feature.

**Steps.**
1. Client-side recent cleanup: drop the dead `$count` (recent.pm:56) and its threading through get_data/get_from_http, and drop the `Options::Recent` include (Options/Recent.pm:10) since `--max` cannot be honored over the current endpoint; optionally collapse get_data's pass-through `// die` into run(). Do NOT add `?count=` server plumbing (the endpoint's web server is stubbed by #45; defer to the webapp rewrite).
2. Port client/publish.pm's single POST onto lazily-required HTTP::Tiny + HTTP::Tiny::Multipart (mirror YathUI.pm:217); drop the redundant `use LWP;` (12) and `use LWP::UserAgent;` (13); remove the LWP::UserAgent prereq from dist.ini. Verify multipart file-field encoding parity with a test.
3. Delete the `See AI_DOCS/...` line from each of the seven die() strings, keeping "The DB/web layer is being rewritten; this command is temporarily unavailable." (no ticket URLs/Changes refs).
4. Fold db-recent and recent onto the shared stub base (whatever #45 leaves); defer the distinct-vs-alias decision to the read-side/webapp effort.

Verify: both canonical runners green; `grep -rln 'LWP' lib` empty; `grep -rn 'AI_DOCS' lib` empty; `--max` no longer advertised by client-recent.

### #95 — Pfile shim removal + retired no_fatal args

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — · Land before #62 (REF-PORT list/ping reworks ping.pm + adds Discovery->list) or fold ping's call-site change into #62 · Coordinate resources.pm with #91

**Problem.** `lib/App/Yath2/Pfile.pm:99-125` is a pure delegation shim over `App::Yath2::Discovery`: workdir/dir/pid/path/describe forward to Discovery's workdir/pid/link/describe (path→link, dir→workdir renames), data() repackages the same three accessors, and find() is `Discovery->find` plus `delete @params{qw/no_fatal no_warn no_checks/}` for params Discovery ignores anyway. Its five callers (reload.pm, which.pm, resources.pm, run.pm:209-213/220/224, ping.pm) mostly unpack `->data` into pid/dir immediately, and Discovery already exposes workdir/pid/link/describe. Separately `reload.pm:30` and `which.pm:26` (and ps/status/watch/abort/stop/resources via their `pfile_params` sub, plus ping.pm:35 inline and kill.pm:26 `no_checks`) still pass the retired `no_fatal => 1` (and `no_checks => 1`) argument that Pfile::find silently deletes (Pfile.pm:105, POD 64-67).

**Steps.**
1. Migrate the five commands to `App::Yath2::Discovery->find` directly: run.pm:220 `->data->{pid}`→`->pid`, `->{pfile_path}` (224)→`->link`, ping.pm:46/50 `->workdir`/`->pid` (same names); resources.pm/reload.pm `->data` unpackers map 1:1 to `->pid`/`->workdir`/`->link`. Drop the dead no_fatal/no_warn/no_checks args at the call sites. resources.pm:27's `pfile_params` hook (only content `no_fatal => 1`) can likely be removed. Keep non-fatal find semantics for resources.pm (coordinate with #91's per-poll fix) — do not change its error path.
2. Delete `lib/App/Yath2/Pfile.pm` and port the useful describe()/find() assertions from `t/unit/App/Yath2/Pfile.t` into `t/unit/App/Yath2/Discovery.t` rather than pure deletion.
3. Drop the retired `no_fatal`/`no_checks` args at the remaining pass-through sites (reload/which inline, ps/status/watch/abort/stop pfile_params, ping.pm:35, kill.pm:26).

Verify: both canonical runners green; `grep -rn 'Pfile\|no_fatal\|no_checks' lib` clean of the removed shim/args; Discovery.t covers the ported assertions.

### #96 — App::Yath2::Util + Discovery dead exports & duplication

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (independent of DB chunks)

**Problem.** `lib/App/Yath2/Util.pm` exports three subs with no callers: fit_to_width (35-43; the App::Yath2 help path uses the differently-signatured `Getopt::Yath::Term::fit_to_width`), find_in_updir (125-139), share_file (358-380; Flavor.pm:256 uses share_dir, not share_file) — greps find only the module + its own unit test. `lib/App/Yath2/Discovery.pm:275-285` resolves() reimplements the live-probe half of probe() (314-347) — both do readlink → clean_path → `-S` → connect_unix, probe adding only errno classification; a liveness-rule change must be made twice. `App/Yath2/Util.pm` also implements three cwd-to-root directory walks: find_in_updir (125-139), _find_link_in_updir (156-172) and _glob_runner_links_updir (343-356) — the latter two are byte-for-byte the same realpath/%seen/parent/root skeleton (differing only in per-level body), find_in_updir a third accumulating-relative-path variant.

**Steps.**
1. Delete fit_to_width, find_in_updir, share_file, their @EXPORT_OK entries (Util.pm:21/23/27 and the second block 403/405/409), their POD `=item`s (455/463/494), and the three subtests + import lines (15/18) in `t/unit/App/Yath2/Util.t`. Leave share_dir untouched (Flavor.pm:256). (If the active DB-rewrite worktree wants find_in_updir/share_file for Renderer/DB.pm / Server.pm, coordinate before deleting — but they are dead on 2.0d today.)
2. Implement Discovery::resolves() as `return $self->probe->{state} eq 'live' ? 1 : 0;` (probe never throws), leaving one copy of the readlink/-S/connect logic. Note this makes find()'s liveness check eagerly compute workdir/pid (harmless — pid caches).
3. Extract a private `_walk_updirs($per_dir_cb)` owning the realpath/%seen/parent/root loop; make _find_link_in_updir and _glob_runner_links_updir one-body callers (the callback must receive the raw `$dir`, not a realpath'd final path — _find_link_in_updir exists precisely because realpath follows the symlink, comment 152-155). find_in_updir is a weaker merge candidate (keys %seen on the resolved full path, seeds by prepending '..'); fold it only if its keying/termination is preserved.

Verify: both canonical runners green; Util.t / Discovery.t green after the deletions; a dangling/live runner symlink resolves identically through resolves().

### #97 — Tester/Finder/Script misc: sleep bug, oversized yath, missing require, V2 POD

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** — (Related: #26 DONE reworked Script::V2; #55/#56 touch the jsonl surface Finder reads)

**Problem.** `lib/App/Yath2/Tester.pm:216` calls core `sleep 0.02` inside the `while(1)` waitpid/capture poll loop (yath(), 202-221); the file does not import Time::HiRes (import list 7-22), so the integer argument truncates 0.02→0 and the loop busy-spins at full CPU for every yath child the suite spawns (STYLE_GUIDE mandates Time::HiRes for sub-second sleeps). `Tester::yath` (91-283) is ~153 executable lines doing six jobs (param aliasing 98-119, stdin temp-file 124-136, inc/capture/log plumbing 138-171, env mutation 175-185, spawn+capture/timeout poll 186-243, result/subtest reporting 247-278), double the 75-line limit. `lib/App/Yath2/Finder.pm:311` instantiates `Test2::Harness2::Util::File::JSONL->new(...)` in add_rerun_to_search, but the file never loads that class (use list 7-16, lazy requires at 136/141/150 in add_data_stream) — it works only via an incidental transitive load through `Command::test`, and the POD documents standalone Finder subclassing. `lib/App/Yath/Script/V2.pm:307-317` NAME/DESCRIPTION describe it as the 'V1 (Legacy)' handler selected by V1 markers, though the external dispatcher loads `App::Yath::Script::V${version}` and there is no V1.pm in this repo — this is the V2 (2.0) handler with POD copied from the 1.0 module.

**Steps.**
1. Change `Tester.pm:216` to an explicit `Time::HiRes::sleep(0.02)` (avoid overriding CORE::sleep file-wide).
2. Extract named helpers along the six seams (`_parse_params`, `_setup_stdin`, `_setup_capture_and_log`, `_run_and_capture`, `_report_result`) leaving yath() a short orchestration under the sub-length limit; the ~40 caller test files are the regression net (test-infra only, no public API).
3. Add `require Test2::Harness2::Util::File::JSONL;` immediately before `Finder.pm:311` (matching the lazy pattern at 136/141/150) so `--rerun` does not depend on an incidental transitive load.
4. Rewrite Script::V2 NAME/DESCRIPTION (307-317) to say this is the V2 handler for the 2.0 harness, selected via a v2 rc marker or when V2 is the highest installed version; sanity-check the wording against the actual installed dispatcher selection semantics.

Verify: both canonical runners green; the integration suite runs without the Tester busy-spin; a standalone `Test2::Harness2::Util::File::JSONL`-less load of Finder + `--rerun` works; Script::V2 POD no longer says V1.

### #98 — Retire web/DB option modules + dead options

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** #45 (DB-1 landed) · Related: deferred §9 webapp port, DB-4 #48-52

> **Web-parking note (owner directive above):** step 1's path-preserving `git mv` into `reference/old_db` is the required pattern — Options::Server/WebServer are parked for the §9 rework, never hard-deleted. Step 3 trims only bare option *declarations* (flush_interval/buffer_size/retry/force/user, grace/request_retry) whose implementations already live parked in `reference/old_db`; the §9 port re-adds the declarations alongside the reworked consumers.

**Problem.** `lib/App/Yath2/Options/Server.pm` and `Options/WebServer.pm` have zero lib consumers after #45 (their only user Command/server.pm is a stub including only Options::Yath; WebServer.pm:9 itself notes its DB include is now in reference/old_db); the sole references are `t/AI/unit/Options_UI.t:25-26,54-75`. Four Options modules ship a hand-written `- FIXME` NAME abstract to CPAN (Publish.pm:65, WebServer.pm:9, Server.pm:64, WebClient.pm:48 — verified hand-written, not release-generated). `Options/Collector.pm:45-70` declares max_open_jobs/max_poll_events (with a 2*j default post_process) that nothing reads — still include_options'd by test.pm:59 and start.pm:36, so every run parses/defaults a settings group the external Test2-Collector pipeline no longer consumes. `Options/Publish.pm:22-52` — 5 of 6 options (flush_interval/buffer_size/retry/force/user) are registered by no command (only `mode` via client/publish.pm:19); `Options/WebClient.pm:24-35` grace/request_retry are read nowhere (only url/api_key consumed).

**Steps.**
1. `git mv lib/App/Yath2/Options/{Server,WebServer}.pm reference/old_db/lib/App/Yath2/Options/` (path-preserving, matching 647b55466); trim the Server/WebServer blocks from `t/AI/unit/Options_UI.t` (25-26, 54-75). Write real one-line NAME abstracts for the live Options/Publish.pm and Options/WebClient.pm.
2. Delete `Options/Collector.pm` and its two include_options entries (test.pm, start.pm) — the throttle now lives in external Test2-Collector, so re-wiring is not an option; remove the now-empty `collector` settings group plumbing. (These are unreleased 2.0 dev options — straight delete; if parse-tolerance matters, degrade to a deprecated no-op stub.)
3. Trim Options::Publish to the `mode` option (delete flush_interval/buffer_size/retry/force/user + their Options_UI.t default asserts 113-115) — coordinate with the active DB-rewrite worktree which re-wires some of these into the new RunProcessor. Drop WebClient's grace/request_retry (and Options_UI.t:102-103) as declared-but-unimplemented, to be re-added by the §9 webapp port intentionally.

Verify: both canonical runners green; Options_UI.t green; `grep -rn 'Options::Server\|Options::WebServer\|max_poll_events\|flush_interval' lib` clean; no run parses the collector group.

### #99 — Options/Plugin duplication: Notify, ordered-map insert, changes_applicable

**Status:** Proposed (cleanup audit 2026-07-01, effort M, risk low) · **Step:** CLEAN · **Depends:** —

**Problem.** `Plugin/Notify.pm:258-351,390-512` has three pairs of near-identical slack/email subs: send_job_notification_slack (258-276) vs _email (315-333), gen_slack_job_text (278-294) vs gen_email_job_text (335-351, differing only in the links line), and send_run_notification_slack (390-423) vs _email (443-485) copying the same 12-line failed-files loop (400-410 vs 453-463) — ~90 lines where a fix to one side misses the other (email variants additionally build a subject and call _send_email vs _send_slack). The insertion-ordered `'@'`-key map maintenance (`push @{$ref->{'@'}} => $key unless exists $ref->{$key}`) is hand-rolled at ≥7 sites cross-referencing each other by comment: Display.pm:328-343 and 423-426, Run.pm:386-401 and 487-493, Runner.pm:677-684, Cover.pm:152-159, Logging.pm:197-211. `changes_applicable` is byte-identical (modulo `$cmd`/`$c`) between Options/Finder.pm:745-750 and Plugin/Cover.pm:118-123 (same 'changed-files options do not apply to projects command' policy).

**Steps.**
1. Parameterize the Notify slack/email paths by a per-service spec (owner meta key, list/fail-list option names, no_batch flag, link formatter, optional email-only subject) feeding one shared _send_job_notification/_send_run_notification/_gen_job_text; keep the `gen_${service}_${scope}_text` names as thin delegators (gen_text dispatches on them; text_module overrides rely on the names).
2. Extract the ordered-map maintenance into ~2-3 small helpers in `App::Yath2::Util` — the shapes differ (trigger sites walk a flat pair list and must NOT store the class-keyed value; settings-post sites vivify via create_option and store it; Logging uses grep-based `//=`), so provide `ordered_map_insert($href,$key,$val)` for the store cases plus a value-less variant for the trigger case; replace the ≥7 bodies (incl. Display.pm:423-426) and consolidate the comments to the helper.
3. Export `changes_applicable` from `App::Yath2::Util` (@EXPORT_OK) and import it in both Options/Finder.pm and Plugin/Cover.pm instead of re-declaring.

Verify: both canonical runners green; Notify job/run notifications (slack + email, including subject) unchanged; renderer/import/dbi-profiling `'@'` lists build identically; changes_applicable policy identical for the projects command.

### #100 — Plugin dead code + stale markers: Cover cover-from-type, PreCommand TODO, YathUI block

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #55 rewires YathUI force-enable — fold the YathUI item into #55 if in the file)

**Problem.** `Plugin/Cover.pm` --cover-from-type/--cover-maybe-from-type are dead: `_deduce_content_type` is written as a function `sub _deduce_content_type { my ($path,$type)=@_; ...}` (315) but its only call site (365) invokes it as a method `$self->_deduce_content_type($maybe, $cover->maybe_from_type)`, so `$path` gets the invocant and the eq 'json'/'jsonl'/regex checks run on wrong values → effectively always returns {}; the `from` branch (374) passes no type data, so `option from_type` (91) is consumed by nothing; line 8 imports gen_uuid never used. All inherited verbatim from reference/legacy (STYLE_GUIDE forbids functions in object modules for exactly this failure). `Options/PreCommand.pm:165` carries `# TODO(Task 9): drop this guard once all plugins are on Getopt::Yath` above `next unless ... isa('Getopt::Yath::Instance')` — chunk 2 (Getopt::Yath migration) is ✅ and every in-repo plugin with options() uses Getopt::Yath, so the condition is met but the guard must stay (protects third-party plugins). `Plugin/YathUI.pm:77-82` is a commented-out median_durations option block with a bare `# TODO` (a 1.0 relic; the only real multi-line commented-out code block in lib/).

**Steps.**
1. Delete --cover-from-type / --cover-maybe-from-type, their POD, the broken `_deduce_content_type` sub, and the unused gen_uuid import (Cover.pm:8) — do NOT resurrect the feature by fixing the signature (that would make content-type forcing take effect for the first time, a behavior/feature change; file a separate feature ticket if wanted).
2. Replace the `Options/PreCommand.pm:165` TODO with a statement of the guard's real purpose (defensive: third-party plugins may return a non-Getopt::Yath options object) — or simply delete the TODO line since lines 150-151 already document the intent; do NOT drop the guard.
3. Delete `Plugin/YathUI.pm:77-82` (the commented median_durations block + bare TODO); prefer folding this into #55 (which already edits YathUI's force-enable) as a ride-along.

Verify: both canonical runners green; `grep -rn 'from_type\|_deduce_content_type\|median_durations' lib` clean; coverage plugin still runs (the deleted options were non-functional).

### #101 — Options/Plugin v5.38 style normalization

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: DB-1 #45 context; excluded web/DB option groups owned by DB-4 #48-52 / #98 / §9)

**Problem.** STYLE_GUIDE mandates `use v5.38` + subroutine signatures for shipped modules, but 9 of the audited files still open with `use strict; use warnings;` (verified via `grep -L 'use v5.38'`): Options/Publish.pm, Options/Recent.pm, Options/Server.pm, Options/WebServer.pm, Options/WebClient.pm, Options/Yath.pm, Plugin.pm, Plugin/SysInfo.pm, Plugin/Git.pm (the other 14 target files comply); the stragglers also keep shift-style bodies signatures can express (e.g. Git.pm:24-26 `sub git_output { my $class=shift; my (@args)=@_; ...}`, SysInfo.pm:13-15).

**Steps.**
1. Scope the sweep to the 4 stable-core files: Options/Yath.pm, Plugin.pm, Plugin/SysInfo.pm, Plugin/Git.pm — replace the strict/warnings pair with `use v5.38;` and convert the shift-style method bodies to signatures.
2. EXCLUDE Options/Server.pm + Options/WebServer.pm (dead — handed to #98's move) and Options/Publish.pm/WebClient.pm/Recent.pm (web/DB command surface being rewritten by DB-4 / §9 — converting now is throwaway churn).

Verify: both canonical runners green; `grep -L 'use v5.38'` on the four stable-core files lists none; no public CPAN API change (internal modules).

### #102 — Standalone dead modules: Command::collector, Converting.pm, Test2::Harness2::Log

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Log.pm sub-item Related: DB-Jsonl #55/#56)

**Problem.** `lib/App/Yath2/Command/collector.pm` is an unreachable 1.0-era internal command (`sub internal_only {1}` at 21): nothing spawns it (2.0 collectors are forked in-process by JobLauncher's `_run_collected_child`, renaming `$0` to 'yath-collector' at line 327 and delegating to the external Test2-Collector dist via `run_under_collector`; the runner is collector-wrapped via Client.pm:302), and its run() (27) expects a 1.0 `Test2::Harness::Collector` class that does not exist in lib/. Removing it strands `App::Yath2::Util::isolate_stdout` (35), whose only lib consumer is collector.pm:9/33. `lib/App/Yath2/Converting.pm` and `lib/Test2/Harness2/Log.pm` are `1;`-only POD modules linked from no shipped POD (no `L<App::Yath2::Converting>` or `L<Test2::Harness2::Log>` anywhere) — Converting's directive names (--no-stream/--no-preload/--no-fork) are still live in 2.0 and its content partly duplicates App::Yath2.pm:855-864; Log.pm documents the jsonl format DB-Jsonl reworks.

**Steps.**
1. Delete `lib/App/Yath2/Command/collector.pm` (zero spawners, no matching collector class); in the same commit delete `App::Yath2::Util::isolate_stdout` (Util.pm:35) and its `t/unit/App/Yath2/Util.t` coverage (now test-only dead weight). Run the full suite (collector.pm is auto-loaded by `t/0-load_all.t`).
2. Converting.pm — actionable now: LINK it from a SEE ALSO in App::Yath2.pm / Test2::Harness2.pm rather than delete (its directives are live), after verifying the exact option spellings against the current Getopt::Yath definitions.
3. Log.pm — defer to DB-Jsonl (#55/#56), which keeps the events.jsonl.zst format; it likely still needs a link (not deletion) afterward.

Verify: both canonical runners green; `t/0-load_all.t` and Util.t green after removing collector.pm + isolate_stdout; Converting.pm reachable from a shipped POD link.

### #103 — Stale docs sweep: IPC/Service/Connection, test.pm Renderer::DB, collector_exit_code, dangling POD

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #6/#8/#26 residue; #45 moved the old UI layer)

**Problem.** Doc-only defects across the tree. `IPC.pm` twice links `L<Test2::Harness2::IPC::Proc>` (331, 427 — no such module; the class is IPC::Process, linked correctly at 438); `IPC.pm:410` says 'If a blocking paremeter is provided' though wait() has no blocking param (#6 removed it, leaving the POD) and has a typo. `Util/IPC.pm:263` swap_io example says STDOUT keeps fd '2' (STDOUT is fd 1). `Role/Service.pm:149` documents `add_subscriber($conn,$run_id)` but the sub (272) takes a third `$drain_gate` (passed by Handlers.pm:1220, consumed by Runner.pm:571); service_io is listed under both PUBLIC (105-108) and PRIVATE (307-309). `Connection.pm:169` drain POD shows the identity event without the `payload` key service_identified relies on (Service.pm:376-377); Connection.pm:246 has a leaked HTML entity `runner-&gt;collector`. `Util/File/Stream.pm:116,135,155` say 'Subclass of L<Test2::Harness2::File>' (no such module; the parent is `Test2::Harness2::Util::File`, line 11). `Plugin.pm:245` links `L<App::Yath2::UI>` (no such module). `Renderer/Base.pm:98` calls the per-job ordering 'the interim per-job 3-phase ordering'. `Command/test.pm:228-231` and `Renderer/Base.pm:61-64` reference `App::Yath2::Renderer::DB`, retired to reference/old_db by #45. `Util.pm:242-246` collector_exit_code comment names two consumers that no longer exist (Runner::Job delegation / a Command::test wrapper) — the real callers are Runner.pm:149, Preloader.pm:267, Plugin.pm:88 (chunks 24/26 stranded it; keep the still-accurate 234-241 numeric-core lines).

**Steps.**
1. Fix IPC::Proc → IPC::Process (331, 427); reword the wait() POD (410) to reference `all` (drop 'blocking paremeter'); correct fd '2'→'1' at Util/IPC.pm:263; document add_subscriber's `$drain_gate` arg (Service.pm:149) and remove the duplicate service_io entry from the PRIVATE list (307-309); add `payload` to the drain identity-event POD (Connection.pm:169); fix `-&gt;`→`->` (Connection.pm:246).
2. Fix `Test2::Harness2::File` → `Test2::Harness2::Util::File` in Stream.pm (116, 135, 155); DROP the `L<App::Yath2::UI>` link at Plugin.pm:245 (do not retarget — the future UI namespace is undecided).
3. Reword the collector_exit_code comment (Util.pm:242-246) to name the three real consumers (runner wrap Runner.pm:149, stage wrap Preloader.pm:267, plugin-aux wrap Plugin.pm:88) and drop the bail-file/Job delegation sentence; keep 234-241.
4. Reword the two Renderer::DB references (test.pm:228-231, Renderer/Base.pm:61-64) to describe the mechanism / point at the live `App::Yath2::DB::Logger` (DB-4 logger process), not the retired renderer. LEAVE the Renderer/Base.pm:98 'interim' wording — TODO_STEPS line 305 still calls the 3-phase mechanism interim pending cross-job work, so rewording to 'pinned' would contradict the live plan doc (reconcile that separately if desired).

Verify: both canonical runners green; `podchecker`/link scan finds no dangling `L<...IPC::Proc>` / `L<Test2::Harness2::File>` / `L<App::Yath2::UI>`; no `Renderer::DB` reference remains in lib POD/comments.

### #104 — Sync TODO_STEPS / TODO_TASKS statuses (DB chunks + REF-PORT landed)

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (reconcile with any dbthoughts-redesign worktree staging TODO edits)

**Problem.** `TODO_STEPS.md:50-56` rows DB-1..DB-5, DB-Jsonl, REF-PORT are all `⬜` and `TODO_TASKS.md` #45-#56, #58-#62 are all 'Status: Decided', but every one is implemented and merged on 2.0d (DB-1 647b55466 — reference/old_db exists, db/server/recent are stubs; DB-2 966eb6516; DB-3 e6ec83c61; DB-Jsonl 597a86e9b/03ac4243c; DB-4 bf75f888c..a8b5dab7c; DB-5 df7b8863a/c05e9b8d9; REF-PORT b756025da/0e93506b0/fdec15e72/d5baf0e0b/409f4fc8c). AGENTS.md:114 mandates updating a chunk's status after landing it, and #63 (TODO_TASKS.md:1371) IS marked DONE, proving the neighbors were simply missed. (#57 is OPTIONAL/Deferred and stays.)

**Steps.**
1. Flip `TODO_STEPS.md` rows DB-1, DB-2, DB-3, DB-Jsonl, DB-4, DB-5, REF-PORT to ✅ (citing the landing commits) and `TODO_TASKS.md` #45-#56, #58-#62 to DONE, leaving #57 Deferred.
2. First check whether a dbthoughts-redesign worktree has already staged these TODO edits; reconcile there rather than double-editing if so.

Verify: both canonical runners green (doc-only); the status table matches the merged code (spot-check reference/old_db, lib/App/Yath2/DB/Logger.pm, lib/Test2/Harness2/Util/Directives.pm exist).

### #105 — die()/eval-return consistency: Notify/Finder newlines, stop.pm eval-return

**Status:** Proposed (cleanup audit 2026-07-01, effort S, risk low) · **Step:** CLEAN · **Depends:** — (Related: #25 quick-fix batch precedent)

**Problem.** `Plugin/Notify.pm:125,130` two config-validation dies omit the trailing `\n` (leaking ` at .../Notify.pm line 125.` into user-facing CLI output) while adjacent sibling dies at 117/128 deliberately end with `\n`. `Finder.pm:160,537` user-facing validation dies omit `\n` while most sibling dies in the file (154, 305, 309, 376, 379, 432, 587) terminate cleanly (line 447 `die "Invalid diff type '$type'";` is an internal should-never-happen guard where the missing `\n` is defensible — leave it). `Command/stop.pm:53-54` does `my $render = eval { $self->prime_shutdown };` then `warn "... $@" unless defined $render || !$@;` — violating the STYLE_GUIDE mandate to check the eval return (not `$@`) and omitting the `; 1` success sentinel (a legit `return undef` from prime_shutdown at line 96 is indistinguishable from failure by `$render` alone); the same sub uses the correct `my $ok = eval {...; 1 }` at 60/65/69.

**Steps.**
1. Append `\n` to the messages at Notify.pm:125 and 130.
2. Append `\n` to Finder.pm:160 and 537 (user-facing validation); leave 447 (internal guard) unchanged.
3. Restructure stop.pm:53-54 to the mandated capture form: `my $render; my $ok = eval { $render = $self->prime_shutdown; 1 }; my $err = $@; warn "Could not prime runner shutdown renderer: $err" unless $ok;` so the success decision rides the eval return.

Verify: both canonical runners green; the three die messages print without a ` at FILE line N.` suffix; stop.pm's prime-shutdown warn fires only on a real failure (not on a legit undef return).

---

## TIER 9 — Bug audit (2026-07-01, adversarially verified)

A full-`lib/` BUG audit: multi-agent finders over all shipped modules, every finding attacked by accuracy + severity skeptics, then a gap round. All 126 confirmed finding bodies (109 base, ids 0–108, plus 17 gap-round G0–G16) live in `AI_DOCS/2026-07-02-bug-audit-findings.json` under `confirmedFindings`, with reviewer verdicts and refinements applied. 7 findings were refuted — see that file's `rejected` list ('Refuted — do not re-file'). Severities below are the FINAL post-review ratings (reviewer refinements supersede stored notes). Duplicates were merged (6+G2, 12+G5, 7+G4).

**Status `Proposed` = found + verified, not yet decided.** Parent chunks are the BUG-1..BUG-14 rows in `TODO_STEPS.md`.

**Owner directive (2026-07-01) applies:** web-framework code is parked, not dead — no ticket here hard-deletes web-layer code; web-facing fixes (#153) rework in place.

---

### #106 — Role::Service: write-failure-closed connections never leave the IO::Select set — poisoned select wedges the whole service

**Status:** Proposed (bug audit 2026-07-01, severity P0, effort S) · **Step:** BUG-1 · **Depends:** — (coordinate with #108, which touches the same write paths; audit finding 105)

**Problem.** When a peer (preload stage, test collector being sent a terminate, sampler) dies and the runner writes to its socket before draining the EOF, the EPIPE croak is caught and `$conn->close` runs (`lib/Test2/Harness2/Role/Service/Connection.pm:329-334`), but the fh is never removed from `service_select` (`lib/Test2/Harness2/Role/Service.pm:348-361, 403-423, 250-253`). Every subsequent `can_read(0)` fails EBADF and returns nothing: collector transitions and EOFs are never read, no job completes its §5.4 EOF decision, `yath test`/`yath run` hangs indefinitely, and a persistent runner is permanently deaf until killed. Re-verify notes: inbound conns are `blocking(0)` (Service.pm:335), so an EAGAIN croak on a full buffer to a slow-but-alive peer also closes+poisons — not just dead peers; fd reuse can accidentally self-heal, but in the end-of-run scenario nothing allocates new fds, so the hang is indefinite. Not covered by any existing ticket (tier-7/8 teardown-dedup items don't touch the `_write`/`send_control` bypass of `_drop_conn`).

**Steps.**
1. Route every close path through `Role::Service::_drop_conn` (or add `$sel->remove($fh)` inside `Connection::close` via an owner callback), OR sweep `grep { $_->closed } values %{$self->{service_conns}}` through `_drop_conn` before each `can_read(0)`.
2. Audit `_write`/`send_control`/`forward_frame` failure paths so none leaves a closed conn registered.
3. Regression test: a service with two connected peers; force a write failure on one (close the peer end, write until EPIPE/EAGAIN); assert the select set no longer contains the dead fh and the surviving peer's frames still drain (no EBADF, no wedge).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); new regression test green; a run where one collector is SIGKILL'd mid-flight still completes with that job failed (no hang).

### #107 — Git plugin: infinite git-forking loop in _changed_diff on invalid/unrelated change base

**Status:** Proposed (bug audit 2026-07-01, severity P0, effort S) · **Step:** BUG-1 · **Depends:** — (audit finding 75)

**Problem.** `lib/App/Yath2/Plugin/Git.pm:128-131` loops appending `^` and forking `git merge-base` per iteration, but never checks `$?`: with a typo'd/nonexistent `--git-change-base`, an orphan/unrelated branch, or a **shallow clone** (common in CI — `HEAD^..^` past the shallow boundary is a bad revision, exit 128), git exits non-1 forever, spamming 'fatal: bad revision' while yath forks git in an infinite loop (line 130) and never starts a test. Re-verify: not a pure CPU spin (fork+waitpid per iteration) but an unbounded hang; severity raised to P0 per the review rubric (unbounded hang, trivially reachable config).

**Steps.**
1. Check `$?` after the `system()` call: exit 1 (not-an-ancestor) keeps looping; any other nonzero exit dies with a clear message naming the base and git's error.
2. Validate `$base` up front with `git rev-parse --verify` before entering the loop; optionally bound iterations by `git rev-list --count HEAD`.
3. Regression test: fixture repo + `--git-change-base no-such-ref` (and a shallow-clone case if cheap) → clean die naming the ref, bounded runtime; valid ancestor base still resolves.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; `yath test --changed-only --git-change-base <bogus>` exits nonzero within seconds.

### #108 — Role::Service write_frame treats EAGAIN as fatal — slow subscriber/logger/stage dropped, command sees false EOF and finalizes mid-run

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-2 · **Depends:** — (coordinate with #106/#109 — same byte-pump; Related: cleanup #81 touches Connection.pm's read ladder; audit finding 0)

**Problem.** All peer fhs are `blocking(0)` (`lib/Test2/Harness2/Role/Service.pm:226-227`); any `write_frame` failure — including EAGAIN — croaks, and `forward_frame` (Service.pm:294-297) / `Connection::_write` (`Connection.pm:329-334`) drop the connection. Realistic triggers are a fully stalled reader: Ctrl-S on the terminal, a SIGSTOP'd/suspended client, a blocked downstream pipe, or a `-L` DB logger stalled on slow DB writes — ~208KB of transition frames fills the socket and the next write EAGAIN-drops the subscription. The command's Subscriber sees EOF, `subscription_complete()` returns true (`lib/App/Yath2/Command/test.pm:453-457`), and the user gets a premature, wrong summary built from a partial mirror while the runner keeps running tests whose results are discarded; the same mechanism silently truncates a `-L` DB import and can close a stage's only dispatch channel.

**Steps.**
1. In `write_frame`, distinguish errno: EPIPE/ECONNRESET → drop (peer vanished); EAGAIN/EWOULDBLOCK → retry with a bounded select-for-writable (1-5s deadline), resuming at the same buffer offset (partial frame must not be resent from the start).
2. Better (if cheap enough now): per-connection outbound buffer in `Role::Service::Connection`, flushed from `service_io` on writability; drop a peer only after a generous stall timeout. Optionally raise SO_SNDBUF on subscriber sockets as a stopgap.
3. Regression test: subscriber that stops reading for 2s under sustained frame traffic → no drop, no lost frames; a genuinely closed peer still drops promptly.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; manual check: Ctrl-S for ~3s during a chatty `yath test` no longer truncates the run summary.

### #109 — Runner::Client silently drops one-way submissions on write failure and transparently reconnects — tests silently never run

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-2 · **Depends:** — (coordinate with #108; audit finding 30)

**Problem.** `lib/Test2/Harness2/Runner/Client.pm:207-253`: `_send` ignores `send_request`'s result. When a large submission burst fills the non-blocking unix socket (runner busy forking/preloading), syswrite gets EAGAIN, the connection closes, the in-flight frame is discarded, and the client silently reconnects and keeps going. Lost `queue_task` frames mean those test files are **never run and the run reports green**; a lost `queue_run`/`stop_run`/`end_queue` instead hangs the client waiting for run_done. write_frame can also tear a large frame mid-send; the reconnect EOF makes the runner discard the truncated frame cleanly (data loss, not corruption).

**Steps.**
1. Check `send_request`'s return in `Client::_send`: on undef/closed-during-send, croak (submission integrity broken) or reconnect-and-resend the exact frame.
2. Preferred: add a POLLOUT-waiting blocking-write variant of write_frame for client submissions (fd must stay non-blocking for `_request`'s drain loop), so a slow runner produces backpressure instead of loss.
3. Regression test: submit a burst larger than the socket buffer against a deliberately stalled reader; assert every queued task arrives (count on the runner side) or the client dies loudly — never a silent green run with missing tasks.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; large-suite submission (1000+ files) runs every file exactly once.

### #110 — Unguarded request-handler dispatch: one malformed or duplicate request frame kills the runner daemon

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-2 · **Depends:** — (cleanup #68 touches the same State.pm lines for unrelated reasons; audit finding 97)

**Problem.** `lib/Test2/Harness2/Role/Service.pm:382` dispatches request handlers with NO eval. A `queue_run` missing its `run` key, a duplicate `queue_task` (e.g. a client retry after a timed-out ack — plausible in normal operation), or a misdirected `run_task` (the Runner copy at `Handlers.pm:811`; the stage copy in `Preload/Host.pm:274` works) makes State die; nothing catches it until `Runner::process`'s outer eval, so a persistent `yath start` daemon tears down every stage and exits — **every in-flight run from every terminal is aborted by one bad frame**. Re-verify: when the preload root isn't ready the die instead fires later in `flush_submit_buffer` (Runner.pm:897-908) — same outcome. Transient runs die mid-flight with an internal stack trace instead of an error reply.

**Steps.**
1. Wrap the `handle_request` dispatch in `_handle_events` in the house `my $ok = eval { ...; 1 }; my $err = $@;` pattern; on failure reply `{ok => 0, error => $err}` (and/or apply the bad-frame policy to the offending connection) instead of unwinding the service loop.
2. Validate payload shape (`run`/`task` hashref present) in `request_handler_queue_run`/`request_handler_queue_task` before touching State; make a duplicate `queue_task` a per-request error, not a die.
3. Regression test: connect a raw client, send a run-less `queue_run` and a duplicate `queue_task`; assert the runner survives, replies with an error, and other in-flight work continues.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; persistent runner stays up across a deliberately bad frame.

### #111 — Named preload stages inherit the 'preload-root' jump frame — duplicate preload-root trees on reload/HUP, base hangs

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (land with #112/#113; audit finding 34, review-adjusted P0→P1)

**Problem.** `lib/Test2/Harness2/Preload/Host.pm:160-172, 715, 725-727`: on reload/HUP the base stage `killall(HUP)`s its children (requires USE_P_GROUPS — all non-Windows); every named stage takes the inherited 'preload-root' longjump and **execs its own duplicate preload-root tree**, which re-registers as 'preload-root' (clobbering the peer registry), re-preloads everything, forks its own copy of every named stage, and re-binds `preload-<stage>.socket` over the legitimate tree's sockets. The real base sits in an untimed `wait(all=>1)` (line 717) for pids that never exit — process count multiplies on every reload and the base hangs. The monitored-file-change path (Host.pm:816-818 → SIGNAL='HUP') triggers the same duplication, not just `yath reload`.

**Steps.**
1. Guard the respawn longjump at Host.pm:725 with the process-identity check that already exists one line below (line 729's `$stage eq 'base' || $stage eq 'default'`), or record launch()'s pid and require `$$` to match; named stages must exit 0 on HUP so the respawned tree relaunches them. Keep the run_test longjump path fork-reachable — the guard belongs on the respawn branch only.
2. Regression test: persistent runner + preload with named stages + `yath reload` → exactly one preload-root process after reload (assert via process table / peer registry), stages come back `up`, no hang.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; `ps` shows no duplicated preload-root/stage processes after two consecutive reloads.

### #112 — Monitor-detected change in the base stage never sets PENDING_RELOAD — persistent runner wedges or terminates itself

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (land with #111; ticket #4 lifecycle work is adjacent; audit finding 35)

**Problem.** `lib/Test2/Harness2/Preload/Host.pm:805-826`: when the preloader monitor detects a change in the base/default stage, it sets SIGNAL=HUP but never PENDING_RELOAD, so `run_stage` (725-729) skips the 'preload-root' respawn longjump; the stage host winds down and returns, `run_driver` (Preload.pm:201-223) announces stage_host_exited and idles. The preload-root stays alive, so `_handle_dead_preload_root` never fires: editing any base-preloaded file **kills all stages and marks them 'restarting' forever** — new runs hang at the dispatch gate — or, if stray warnings were captured, the runner TERMs itself. The user expected a stage reload, got a dead/wedged daemon.

**Steps.**
1. Where `preloader->check()` returns true in `end_test_loop` (Host.pm:816-818), also set PENDING_RELOAD — **only for the base/default stage** (named stages don't own the jump frame and already relaunch via exit-0), matching `request_handler_reload_root` (Host.pm:381-391).
2. Regression test: persistent runner + monitor on + reload off; touch a preloaded module → expect stage_restarting then a fresh stage_ready (respawn), not runner TERM or permanently-restarting stages; a queued run after the reload still dispatches.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #113 — HUP reload always silently dropped: _preload_root_stage_identity compares the stage peer_pid to the wrong pid

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (blocks #114; audit finding 24)

**Problem.** `lib/Test2/Harness2/Runner.pm:759-775, 190-212, 951-961`: the SIGHUP handler looks up the base-stage peer by PRELOAD_ROOT_PID (the collector parent's pid), but the 'preload-root' handshake connection dials from the **exec'd child**, so the comparison never matches; the handler returns without sending 'reload_root'. `yath reload` / `kill -HUP` reloads nothing, emits nothing — the user keeps running stale code with no indication why. The comment at Runner.pm:753-754 ('announced peer_pid equals PRELOAD_ROOT_PID') is the false premise; the other PRELOAD_ROOT_PID uses (reaper, stop_preload_root) are correct. `t/AI/unit/Runner_reload_routing.t` fabricates pid==PRELOAD_ROOT_PID and masks the bug.

**Steps.**
1. Match the base stage against `service_peers->{'preload-root'}->peer_pid` (or record the exec'd child's pid at handshake) instead of PRELOAD_ROOT_PID; correct the comment at Runner.pm:753.
2. Fix `t/AI/unit/Runner_reload_routing.t`'s FakeConn peers to model the real two-process pid split (collector parent vs exec'd child) so the test exercises the true comparison.
3. Regression test: integration — persistent preloaded runner, touch nothing, send HUP → 'reload_root' actually reaches the base stage (stage respawn observed).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); updated unit test fails against the old code and passes with the fix.

### #114 — yath reload is fire-and-forget: prints success and exits 0 with no acknowledgment, including on no-preload runners where HUP is a no-op

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-3 · **Depends:** #113 (identity fix first) (gap finding G8)

**Problem.** `lib/App/Yath2/Command/reload.pm:27-44` deletes the blacklist file, prints "Sending SIGHUP to $pid", kills, and returns 0 — no socket request, no readback. On a no-preload runner the HUP handler is an explicit `return;` no-op (`lib/Test2/Harness2/Runner.pm:190-212`, comment at 209-211), yet the user is told success and keeps running stale code. The silent-success surface is universal: even with preloads, an identity-lookup failure (see #113) or any runner-side reload failure is invisible because `service_send` has no reply. The command's own POD ("forcing it to reload") contradicts the no-preload no-op.

**Steps.**
1. Cheap mitigation first: in reload.pm, check the pfile/runner metadata for a no-preload runner and print an explicit 'this runner has no preload stages; restart it to pick up code changes' warning with a nonzero exit.
2. Thorough fix: route reload through the runner socket as a request/response (Client/service channel already exists) so the command reports which stages reloaded; nonzero exit when the runner reports nothing to reload or a failure.
3. Fix the POD to describe the no-preload behavior.
4. Regression test: `yath reload` against a no-preload persistent runner → warning + nonzero; against a preloaded runner → reports the reloaded stage(s).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; exit codes distinguish reloaded / nothing-to-reload / failure.

### #115 — task_stage re-resolution divergence between queue-time bucket and start-time lookup crashes the runner

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (audit finding 25)

**Problem.** `lib/Test2/Harness2/Runner/State.pm:397-415, 839-896, 1141-1232`: a task whose `preload_list` is [A, B] buckets under B while A is still 'starting'; when A registers stage_ready before dispatch, `_start_task` re-resolves task_stage to A, the PENDING_TASKS lookup in bucket A fails, and the runner dies mid-run with 'Task <job_id> was not pending' (or an undef-array-deref at line 411) — every running job is killed and yath aborts. Same crash on a persistent runner whenever a restarting stage comes back up while tasks listing it first sit bucketed under a later-preference stage. Re-verify: `_start_task` already receives the bucket stage as `$spec->{stage}` (advance_tasks:1068 passes `_next`'s run_by_stage, guaranteed equal to the bucket key), so the minimal fix is in hand.

**Steps.**
1. Use `$spec->{stage}` for the PENDING_TASKS lookup at State.pm:408-410 and the prune_hash path at 415 instead of re-resolving via task_fields (cat/dur/run_id/smoke are stable; only the stage dimension is volatile).
2. Optionally add a symmetric `_rebucket_stage_tasks` call on the starting/restarting→'up' transition (mirroring the existing down-demotion rebucket) so tasks migrate to their preferred stage.
3. Regression test: two-stage preload where the preferred stage readies late → run completes, no 'was not pending' die; task runs on the correct stage.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #116 — Submissions buffered after readiness regresses mid-run are never flushed — client hangs forever

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (re-check when ticket #3 reworks stage-peer liveness; audit finding 26)

**Problem.** `lib/Test2/Harness2/Runner.pm:806-908, 1168-1203`: `flush_submit_buffer` is called exactly once. With `--monitor-preloads`, the common sequence "save a source file (tree reload) then immediately `yath test`" lands the submission inside the stage-downtime window: queue_run/queue_task frames are buffered by `submit_action`, the stages come back up, and the buffer is never flushed — the run is never queued, the runner idles, and the client hangs forever with no error. Even a buffered `end_queue` alone hangs the runner (`State::done` requires QUEUE_ENDED, State.pm:175-187). Partial-buffer hazard: if the window closes mid-stream, later frames can apply ahead of buffered earlier ones, so any fix must flush before applying a newly-arriving action.

**Steps.**
1. Flush the buffer whenever `_ready_to_schedule` is true and the buffer is non-empty: at the top of `submit_action`'s ready branch (smallest change) and/or at the top of the main run loop after `service_io`; always drain the buffer in order before applying the triggering action.
2. Regression test: persistent runner; force a readiness regression (drop stage peers), submit a run, restore readiness → run executes; also cover the buffered-end_queue-only case.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; manual: save-a-preloaded-file-then-immediately-`yath test` no longer hangs.

### #117 — Retry declined by a halted run is still announced 'retry' — the job is never re-queued and the summary reports it as "never ran"

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-3 · **Depends:** — (audit finding 93, review-raised P3→P1)

**Problem.** `lib/Test2/Harness2/Runner/Role/Service/Handlers.pm:484-510` + `lib/Test2/Harness2/Runner/State.pm:494-506`: `_retry_task` silently declines on a halted run, but `_collector_retry_if_tries` cannot see the decline — the runner announces 'retry', the job is never re-queued and never announced done/aborted, its state entry dangles RUNNING, and the summary lists a test that ran and failed under 'The following jobs never ran'. Re-verify: with default `--abort-on-bail`, `collector_bail` terminates siblings synchronously so they take the aborted guard; the live paths are (a) `--no-abort-on-bail` (halt without sibling termination — sibling finishes failing after the halt) and (b) `request_handler_halt_run` (command-caught-signal halt, Handlers.pm:799-804) racing a failing EOF.

**Steps.**
1. Make `State::retry_task`/`_retry_task` return a truthy 'actually queued' indicator (or die) on decline; have `_collector_retry_if_tries` treat falsy as decline and fall through to the existing `_collector_stop` + `announce_job('done')` path.
2. Skip setting `collector_current_try` (Handlers.pm:506) when the retry was declined.
3. Regression test: `--retry=1 --no-abort-on-bail`, one job bails while a sibling fails → sibling is reported as a failed job (not "never ran"), no dangling RUNNING entry after the run.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #118 — Unvalidated HARNESS category/duration values (and durations-file values) hit an unguarded die in Runner::State — one bad directive aborts the entire run

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-3 · **Depends:** — (Related: #58's E1 directive-error path is the designated failure route; #110 hardens the dispatch side; gap finding G14)

**Problem.** The producer maps ANY non-long/medium/short directive token to category (`lib/App/Yath2/TestFile.pm:387-394`, via `Directives/Legacy.pm:231-239` — e.g. `# HARNESS-CATEGORY-NETWORK`) and stores any lowercased token as duration (:381); `lib/App/Yath2/Finder.pm:696` feeds durations-JSON values (e.g. numeric seconds) into set_duration unvalidated. These flow verbatim to the runner, where `State::task_fields` (`State.pm:924-925`) dies 'Invalid category: ...' inside the un-eval'd request dispatch. Re-verify: the runner does not die uncaught — `Runner.pm:474-477` catches, warns bare to runner stderr, and performs orderly teardown with exit 1 — but the net effect stands: **one file's plausible-looking directive (or one numeric durations entry) aborts the whole run mid-submit**, and on a persistent runner can take down other queued runs, with the diagnostic unattributed. The E1 machinery (TestFile.pm:523-561) exists precisely to turn bad directives into one failed job but only covers grammar parse errors, not value-domain errors.

**Steps.**
1. Validate category/duration against CATEGORIES/DURATIONS at the producer (`TestFile::check_category/check_duration` or `_apply_directives`), routing invalid values through the existing `directive_error` E1 path so only that job fails as a synthetic failure.
2. In Finder, coerce/validate durations-file values: accept numeric seconds by thresholding into short/medium/long, or reject with a message naming the file and key.
3. Defense in depth: wrap the State.pm:922-925 dies (or rely on #110's dispatch eval) so a bad task becomes a failed request, never a run abort.
4. Regression test: a suite with one `# HARNESS-CATEGORY-NETWORK` file → that job fails with a clear directive diagnostic, all other tests run; a numeric durations JSON is either coerced or rejected loudly.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #119 — Spawn supervisor stays in the intermediate's process group — stage stop/reload kills the 'detached' yath spawn session

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-4 · **Depends:** — (Related: #139 owns the companion spawn exit-status/escalation fixes; audit finding 95)

**Problem.** `lib/Test2/Harness2/Preload/Host.pm:297-324` (request_handler_spawn, watch_pid at 339) + `lib/Test2/Harness2/Runner/JobLauncher.pm:116-196`: the spawn supervisor never leaves the intermediate's process group. When the runner shuts down or `yath reload` fires, the stage's wind-down `killall()` TERMs (then KILLs) the intermediate's pgroup (`Host.pm:710-716`, `IPC.pm:108-114`), killing the supervisor that per ARCHITECTURE §4.8 must survive teardown: exit_status is never sent, the kill-on-command-EOF duty is lost, and the script child (own session, holding the user's terminal fds) is orphaned. The stuck WAITING entry can also make stage stop() wait its 5s timeout (re-verify: only when the supervisor survives the TERM). 

**Steps.**
1. Have the supervisor call `POSIX::setpgrp(0,0)` (or setsid) immediately after the fork in `launch_spawn`'s supervisor branch (mirroring `JobLauncher.pm:307`'s script-child setsid), so the intermediate's group empties as soon as it exits.
2. And/or reap the spawn intermediate with a plain waitpid instead of the pgroup-liveness `watch_pid` gate (`_check_if_dead_yet`).
3. Regression test: open a `yath spawn` session against a persistent preloaded runner, trigger `yath reload` and then `yath stop` → supervisor survives, script keeps running bound to the command, exit_status still delivered when the script exits.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; `ps` shows no orphaned spawn supervisor/script after reload+stop with an open session.

### #120 — yath watch exits immediately: done_check uses -f on the pfile symlink, which points at a unix SOCKET

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-5 · **Depends:** — (audit finding 9)

**Problem.** `lib/App/Yath2/Command/watch.pm:70` tests `-f $self->pfile->path`, but the pfile path is a symlink to `runner.socket`, so `-f` is always false (verified empirically): `yath watch` prints the backlog and exits on the first idle tick — behaving like the documented `watch STOP` mode — making it impossible to monitor a runner between runs. The same dead `-f` exists harmlessly in `stop.pm:75` and `kill.pm:47` (hygiene).

**Steps.**
1. In watch.pm's done_check, key the exit on `-l` (the link itself vanishing) plus `Discovery::resolves` (or at minimum `-e`), alongside the existing `$sub->closed` socket-EOF check; note `-e` alone stays true for a dangling link until discovery cleans it, so `-l` + resolves is the precise condition.
2. Fix the same test in stop.pm:75 and kill.pm:47 for hygiene.
3. Regression test: `yath watch` against an idle persistent runner stays attached across several idle ticks and exits promptly when the runner stops.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #121 — yath stop / yath kill: unbounded kill(0) busy-wait with no signal escalation — hangs forever on a wedged runner; kill never actually kills

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-5 · **Depends:** — (Related: #145 fixes the Discovery-side loss of the PID-file fallback; audit finding 1)

**Problem.** `lib/App/Yath2/Command/kill.pm:46` and `stop.pm:72` loop `sleep(0.02) while kill(0, $pid)` with no timeout and no escalation. Against a wedged runner — the exact case `yath kill` exists for — the truncate/end_queue croak (`Runner/Client.pm:266-268`, un-eval'd path at 227) can abort the command after a 30s stall with the runner still running; if the runner replies but refuses to exit, the loop spins forever. A crashed runner whose pid was recycled to a long-lived same-user process also spins forever (`attach_runner`'s kill(0) liveness always reports it alive). The documented PID-file signal escalation (Pfile.pm/Discovery.pm) is never implemented command-side.

**Steps.**
1. Eval-guard the truncate/end_queue socket steps in the kill path (house `my $ok = eval { ...; 1 }` pattern) so a wedged socket cannot abort the kill.
2. Bound the final wait (reuse stop.pm drain_shutdown's 30s deadline + 5s grace pattern with `Time::HiRes::sleep`); on deadline, implement the documented fallback: read the workdir PID file, TERM, wait, KILL, then clean workdir/pfile. `yath kill` sends the signals unconditionally after the graceful attempt.
3. Regression test: a fake/wedged runner (SIGSTOP'd or TERM-ignoring child with a live socket) → `yath kill` terminates it within the bounded window and exits nonzero-cleanly; recycled-pid case exits with a diagnostic instead of spinning.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; normal `yath stop` timing unchanged.

### #122 — Ctrl-C on yath run (attach mode) is unhandled: dirty terminal, unterminated -F log, loggers killed mid-import

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-5 · **Depends:** — (Related: cleanup #89 render-sharing touches the same flow; audit finding 65)

**Problem.** `lib/App/Yath2/Command/run.pm:64` + `lib/App/Yath2/Client.pm:209-215`: attach mode installs no INT/HUP/TERM handlers, so Ctrl-C kills the command instantly. Re-verify correction: the run IS aborted runner-side via the owner-disconnect sweep (abort_on_disconnect default true) — the defect is client-side ungraceful death: (a) ResetTerm's reset never runs, leaving the status bar's terminal state dirty; (b) a `-F log.jsonl` is left without its `null` terminator and 'Wrote log file' never prints; (c) client-spawned `-L` DB loggers in the foreground pgroup die mid-import; (d) all of test.pm's signal machinery (`signal_shutdown`, 'Waiting for child processes...') is dead code in attach mode.

**Steps.**
1. Make `Client::install_signal_handlers` mode-aware (drop the MODE_TRANSIENT early-return): in attach mode, INT/HUP/TERM set the signal flag and stop the render loop so `stop()` flushes renderers/logs via the existing `signal_shutdown` path.
2. Optionally send `halt_run` for this run_id over runner.socket for promptness (disconnect already aborts the run); keep the second-Ctrl-C hard-exit convention.
3. Regression test: attach-mode run interrupted by SIGINT → `-F` log ends with the `null` terminator, terminal reset emitted, exit code reflects the interruption.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #123 — yath start --daemon prints 'Persistent runner started!' and exits 0 with no liveness check — deterministic false success on a broken preload

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-5 · **Depends:** — (audit finding 66)

**Problem.** `lib/App/Yath2/Command/start.pm:152-175`: after `wait_for_runner_pid` the daemon branch prints the success banner and returns 0 with no liveness check. A broken `-P` module is not a race: the runner takes the explicit fail-fast path (`Runner.pm` ~1184-1192, stage_host_exited/_handle_dead_preload_root) and reliably exits after writing PID — so `yath start -d -PBroken && yath run` always proceeds on a false success and then fails with 'No persistent harness was found' and no hint why. If the runner dies before writing PID, the user first sits through a silent 30s `wait_for_runner_pid` stall. The foreground branch (start.pm:183-196) correctly propagates the runner exit code — the daemon branch is an inconsistency, not a design choice.

**Steps.**
1. After wait_for_runner_pid, do a bounded liveness check before the banner: `kill(0, $runner_pid)` and/or `waitpid($pid, WNOHANG)` on the collector child; better, treat a successful connect to `$dir/runner.socket` (Discovery->resolves) as the readiness signal.
2. On failure, print an actionable failure (pointing at the runner's error output) and exit nonzero.
3. Regression test: `yath start -d` with a broken preload module → nonzero exit + failure message; healthy start still exits 0 promptly.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #124 — yath failed crashes on logs where a failing job has no harness_job_end (exactly the aborted-run postmortem case)

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-5 · **Depends:** — (audit finding 69, review-raised P2→P1)

**Problem.** `lib/App/Yath2/Command/failed.pm:69-90`: a log from an interrupted run (Ctrl-C, CI cancellation, OOM-killed worker) where a failing job never got its harness_job_end makes the command die with "Modification of non-creatable array value attempted, subscript -1" instead of listing failures — the one command users reach for after killing a hung run crashes on exactly those logs. In the `--brief` branch the die occurs while evaluating the `if` condition on line 87 itself, so even jobs that would print nothing crash the command.

**Steps.**
1. Guard the deref: `my $end = @$ends ? $ends->[-1] : undef;` then gate both the brief-mode print and the table-row push on `defined $end`, rendering 'N/A'/unknown file (Times Run 0) for endless jobs.
2. Regression test: fixture log with a failing job missing harness_job_end → `yath failed` (both modes) lists the failure with N/A fields, exit code unchanged semantics.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #125 — Interactive mode Ctrl-C: pre-fork parent exits instantly and File::Temp CLEANUP deletes the workdir under the still-running child and runner

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-5 · **Depends:** — (Related: #140 owns the sibling $?>>8 signal-masking fix; audit finding 11)

**Problem.** `lib/App/Yath2/Options/Debug.pm:298-313` (fork/parent split) + 357-364: on Ctrl-C the accept-loop parent's INT/TERM handler calls `$finish` → `exit()` directly, firing File::Temp's END cleanup for the workdir tempdir (`Options/Workspace.pm:139-146`) while the yath child is mid-graceful-shutdown and the runner/collectors are still writing into it — events files vanish mid-write and the shell prompt returns over children still printing. The parent's END cleanup is the ONLY workdir cleanup in interactive mode (child can't clean due to File::Temp $$ keying), so it must be deferred, not removed.

**Steps.**
1. Make the INT/TERM handlers in `_interactive_accept_loop` set a flag (optionally forwarding the signal to the child) instead of exiting; keep the waitpid loop until the child is reaped so the END cleanup fires only after all workdir users are gone.
2. While there, propagate signal deaths as 128+sig (coordinates with #140's fix for the same line).
3. Regression test: interactive run interrupted with SIGINT → child completes its shutdown, workdir removed only after reap, no ENOENT/corruption warnings from runner/loggers.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #126 — --notify-email-fail alone never registers the Notify plugin — failure emails silently never sent

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-6 · **Depends:** — (Related: #150 owns the sibling owner-flag override bug; audit finding 76, review-raised P2→P1)

**Problem.** `lib/App/Yath2/Plugin/Notify.pm:111-121`: the email-enable condition omits `email_fail`, so `yath test --notify-email-fail dev@example.com` without --notify-email/--notify-email-owner never pushes the plugin — no email is ever sent for failing tests, silently (Email::Stuffer availability is not even checked). The slack branch three lines below already does this correctly (`$use_slack ||= grep { @{$settings->notify->$_} } qw/slack slack_fail/`).

**Steps.**
1. Include `@{$settings->notify->email_fail}` in the enable condition, mirroring the slack pattern — but WITHOUT tripping line 113's auto-enable of email_owner (1.0 did not auto-enable owner there): register the plugin and check Email::Stuffer when email_fail is set, leaving email_owner alone.
2. Regression test: settings with only email_fail set → plugin registered, Email::Stuffer checked; email_owner remains off.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #127 — -f/--fields name:details regex truncates details at the second colon — URLs silently destroyed

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-6 · **Depends:** — (audit finding 80, review-raised P3→P1)

**Problem.** `lib/App/Yath2/Options/Run.pm:283-291`: the name:details pattern is unanchored and non-greedy on details, so `yath test -f build_url:https://ci.example.com/42` stores `{name => 'build_url', details => 'https'}` — the URL is silently destroyed in run metadata/log/DB, discovered only when the field is needed.

**Steps.**
1. Anchor and make details greedy: `m/^([^:]+):(.+)$/s`.
2. Regression test: `-f` values containing colons (URL, `host:port`) round-trip intact into the run fields.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #128 — DB logger _project_name attributes every run to project 'tmp' — --project ignored

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-7 · **Depends:** — (fold into the DB-layer projects natural-key work when it lands; audit finding 19)

**Problem.** `lib/App/Yath2/DB/Logger.pm:616-622/670-676`: `_project_name` takes the workdir's PARENT directory — 'tmp' for the default tempdir workdir — so every `yath test -L db.sqlite` from any project collapses into a single 'tmp' projects row, and the user's `--project` setting (documented as necessary for persistent runners, PreCommand.pm:85) is ignored entirely. Note the code's own intended fix ([1]→[2], workdir basename) would be WORSE: the basename is the random `yath-<pid>-XXXXXX`, minting a new project row per run.

**Steps.**
1. Thread `settings->yath->project` through the logger config file written by `Command/test.pm` start_loggers (test.pm:228-267) and use it in `_ensure_run_row`.
2. Fall back to the ORIGINAL launch cwd's basename (not any workdir-derived path) when --project is unset.
3. Regression test: `-L` run with `--project foo` → projects row 'foo'; without --project → row named after the launch dir; never 'tmp'/'yath-*'.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #129 — DB sync is not transactional: an interrupted sync leaves a permanently incomplete run that all future syncs skip

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-7 · **Depends:** — (#53 designed the sync engine but not transactionality; audit finding 85)

**Problem.** `lib/App/Yath2/DB/Sync.pm:255-289`: `yath db sync` dying mid-run (Ctrl-C, network drop, constraint error on one artifact) after the runs row was inserted but before jobs/artifacts finished leaves the destination permanently incomplete — re-running prints 'skipped 1 already-present run(s)' (run-level short-circuit at 266-269) and succeeds, with the run's jobs/tries/blobs missing forever, repairable only by hand-deleting the dest runs row. Children copied before the crash persist (per-row guards would skip them on a repaired descent); the loss is exactly the not-yet-copied rows.

**Steps.**
1. Preferred (lower-risk across sqlite/Pg/DuckDB — DuckDB has single-writer/txn quirks per project memory): drop the run-level short-circuit and always descend into `_sync_jobs`/`_sync_collectors`/`_sync_artifacts` (all four child syncs already have per-UUID exists-checks); count skipped_runs from the runs-row insert outcome only.
2. Alternatively/additionally wrap each per-run copy (lines 279-286) in a destination transaction with rollback-on-die where the flavor supports it.
3. Regression test: kill a sync after the runs-row insert (fault injection), re-run sync → destination ends complete; idempotency preserved (third run copies nothing).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green across the DBMatrix flavors (#63 harness).

### #130 — DB logger stalls the full 30s DRAIN_TIMEOUT on every persistent-runner run: global service collectors never finalize

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-7 · **Depends:** — (audit finding 86)

**Problem.** `lib/App/Yath2/DB/Logger.pm:96-97, 209-219, 228-236`: `_all_finalized_imported` requires every collector to be finalized+imported, but the sampler's collector (unconditional) and the preload-root's (when preloads are configured) belong to the daemon, not the run, and never finalize — so `yath run -L results.sqlite` against a persistent runner polls (0.02s sleep) for the full 30s DRAIN_TIMEOUT after every run while the command's `wait_for_loggers` blocks on the logger pid: every persistent `-L` run appears to hang ~30s after completion. A bounded stall, but paid on every single run.

**Steps.**
1. In `_all_finalized_imported`, skip collectors whose monitor-tracked run_uuid is undef or ne RUN_ID; apply the same filter in `_upsert_collectors` (the latter also fixes the run_uuid misattribution of shared service collectors).
2. Regression test: persistent runner + `-L` run → logger exits within a couple of poll intervals of run_done; sampler/preload-root collector rows are not attributed to the run.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green; timed check: persistent `-L` run completes without the 30s tail.

### #131 — Watchdog-aborted jobs are never folded into DB rows — run logged 'complete' with NULL verdicts hiding the failure

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-7 · **Depends:** — (renderer-side double-launch for the same path is cleanup #65 step 2 — different defect, same area; audit finding 87, review-raised P2→P1)

**Problem.** `lib/App/Yath2/DB/Logger.pm:337-373, 578-629`: aborted jobs with no collector finalize are silently dropped. Re-verify scoping: a hung test tripped by its own event/exit timeout IS finalized by the collector (recorded correctly); the broken cases are (1) `abort_job` on a failed dispatch to a dead stage — no collector ever exists, no job_tries row, skipped by Logger.pm:591 `next unless @tries`, leaving jobs.passed/failed NULL; (2) wind-down/run-timeout/owner-drop aborts of jobs whose stage or collector died without finalizing; (3) the pid hard-kill grace fallback. These are designed operational events (yath abort, owner disconnect, mid-run stage death), and the resulting DB corruption — status='complete' hiding an aborted job, run counts excluding it — is silent and permanent.

**Steps.**
1. Fold Monitor job state 'aborted' (or drain `new_aborted_jobs`) into try/job rows via `_collector_status`/`_try_columns`: status='broken', result=0.
2. Count aborted jobs as resolved/failed in `_finalize_run_row` instead of skipping; handle the no-try-row case at line 591, not just the NULL-result case at 607.
3. Regression test: `-L` run where one job is watchdog-aborted (dispatch-to-dead-stage or owner-drop) → DB shows the job failed/broken and the run's failure counts include it.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression test green.

### #132 — DB logger finalizes runs as 'complete' (exit 0) even when the runner died mid-run or the drain timed out with unimported blobs

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort M) · **Step:** BUG-7 · **Depends:** — (Related: #152's finding 98 covers the die-path finalize; audit finding 88, review-raised P2→P1)

**Problem.** `lib/App/Yath2/DB/Logger.pm:166-224, 619, 690`: kill -9 the runner mid-run and the logger sees the socket close, does one final sync, and writes runs.status='complete' with partial counts; a failed collector-blob import warns to detached stderr, still marks 'complete', and exits 0. Re-verify: the die-mid-loop case DOES exit 1 (TERMINAL_ERROR); the exit-0 complaint applies to the `_record_error`-only paths (EOF-before-run_done, drain timeout, import failures). Both triggers are ordinary operational events, and the persisted status silently lies to CI gating/dashboards keyed on runs.status.

**Steps.**
1. Track whether run_done was actually observed and whether all imports succeeded; on EOF-before-run_done, drain-timeout, or import errors write status='broken' (or 'canceled') instead of 'complete'.
2. Call `_finalize_run_row` from run()'s failure path too, and return a nonzero exit whenever errors were recorded.
3. Regression test: (a) kill -9 the runner mid `-L` run → runs.status='broken', logger exits nonzero; (b) corrupt one events blob → status='broken' + nonzero, warning names the collector.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #133 — -L DB loggers silently SIGTERM'd at the teardown timeout and their exit status never checked — truncated imports unreported

**Status:** Proposed (bug audit 2026-07-01, severity P1, effort S) · **Step:** BUG-7 · **Depends:** — (#50 covers logger lifecycle but not exit-status reporting; #132 owns the logger-side 'broken' marking; audit finding 68, review-raised P3→P1)

**Problem.** `lib/App/Yath2/Command/test.pm:286-310`: a DB import legitimately needing more than the 120s teardown window (slow remote DB) is SIGTERM'd mid-import by `wait_for_loggers` with no message; yath exits 0 and the DB silently holds a truncated run left at status='running' (no 'broken' marker — `_finalize_run_row` never runs after SIGTERM). Re-verify: startup failures (bad DSN, exec-127) DO print to the inherited stderr (Logger.pm:678-688, IPC.pm:131-140) — what's missing there is harness-level reporting and any exit-status effect; the TERM'd pids are also never reaped (trivial zombies at command tail).

**Steps.**
1. On timeout, print a warning naming the still-running logger pids ('DB logger <pid> did not finish within 120s; import may be incomplete') before TERM; after TERM do a blocking waitpid to reap.
2. For loggers that exited within the window, check `$?` and warn on non-zero exit (naming the -L target).
3. Consider propagating a nonzero command exit (or at least a prominent warning) when any logger failed — decide with the owner.
4. Regression test: logger stub that sleeps past a shortened timeout → warning printed, process reaped; logger stub exiting 1 → non-zero-exit warning printed.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #134 — Service/IPC hardening bundle: corrupt-frame crash, SIGPIPE, fork-child die-into-parent-cleanup, PENDING leak, wall-clock timeouts, handshake/subscriber liveness

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-8 · **Depends:** — (Related: cleanup #81/#82 touch the same byte-pump/teardown code; audit findings 13, 43, 14, 106, 104, 94, 108)

**Problem.** Seven verified P2/P3 defects in the service/IPC core. **(13, P2)** `Connection.pm:284-299`: a zstd framing croak from `FrameBuffer->drain` is uncaught — any garbage bytes on runner.socket (`printf garbage | nc -U ...`) kill the whole service, aborting every connected client's run; a desynced stream can never resync, so the right policy is close-that-connection-immediately. **(43, P2)** `Util/FdPass/Control.pm:202-224` + `FdPass.pm:144-158`: no SIGPIPE protection — a peer dying mid-handoff kills the yath command (spawn.pm:280 send_fds 2nd/3rd fd) or the supervisor at send_hello (JobLauncher.pm:161), orphaning the spawned pgroup; interactive is already covered by Debug.pm:365's dynamic scope. **(14, P2)** `Util/IPC.pm:104-153`: fork-child failure paths die instead of `_exit`, unwinding into the runner's process() eval — the child kills the real sampler, unlinks runner.socket, and writes the 'complete' marker (not pid-guarded, `Command/runner.pm:70-79`) after a transient EMFILE/ENOSPC. **(106, P2)** `Connection.pm:224-236, 377-385`: PENDING request-id entries for one-way requests (system_load per tick, run_task per test) are never removed on daemon-lifetime connections — unbounded sender-side memory growth on persistent runners. **(104, P2)** wall-clock `Time::HiRes::time` drives every daemon deadline (`Handlers.pm:709-714, 607, 1245`, `Connection.pm:196, 211-215`, `State.pm:204-208, 630`, `IPC.pm:240`): suspend/resume or an NTP step mass-aborts dispatched jobs as 'collector did not connect' or freezes timeouts. **(94, P3)** `Preload.pm:334-358` (corrected lines): the preload-root handshake wait ignores `$conn->closed`, stalling the full preload_map_timeout on a dropped runner connection (0.01s-sleep poll, then idles until reaped). **(108, P3)** `Runner/Subscriber.pm:198-226`: connect retries have no liveness escape — a runner that dies after binding the socket costs a flat 30s stall in `_connect` (207-215; the reply-wait loop already EOF-croaks fast).

**Steps.**
1. (13) Eval-wrap the `FB->drain` call in `Connection::drain`; on croak close the connection on first occurrence (no 3-strike) and return events gathered so far — covers inbound and outbound sides.
2. (43) `local $SIG{PIPE} = 'IGNORE'` around the syswrite loop in `Control::_send` and the IO::FDPass::send loop in `send_fds`, matching write_frame.
3. (14) Hoist the `$die`/POSIX::_exit(127) helper above the vulnerable block and wrap the entire post-fork child body (including the command-coderef invocation at IPC.pm:121) in `my $ok = eval { ...; 1 }; POSIX::_exit(127) unless $ok;`; pid-guard the 'complete' write and the Runner::process wind-down (`$$ != rootpid` → _exit).
4. (106) Add `want_reply => 0` for the one-way command set (queue_run/queue_task/stop_run/end_queue/run_task, Sampler system_load) so send_request skips the PENDING insert.
5. (104) Add a small Util monotonic-clock shim (`clock_gettime(CLOCK_MONOTONIC)`) and switch the identified interval-math sites; keep wall clock for event stamps only.
6. (94) Inside the `_request_sync` wait loop, `croak ... if $conn->closed` (the held $conn is marked closed by drain on EOF).
7. (108) Give Subscriber the optional liveness_check attribute Runner::Client has (Client already owns runner_gone), checked each `_connect` retry.
8. Regression tests: garbage-bytes-to-socket survives; fd-pass peer-death returns an error instead of dying; fork-fault child never runs parent cleanup (socket still present); PENDING size stable across N one-way sends; subscriber against a dead-socket runner fails fast.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); new regression tests green; persistent-runner RSS stable across repeated runs (spot check).

### #135 — Runner state/scheduler bundle: Monitor/ledger leaks, sampler reap race, stranded 'down' buckets, one-tick run announce, shared-ref mutation, decided-key mismatch, per-job terminate grace

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-8 · **Depends:** — (finding 2 rides #49's 1-based is_try audit; audit findings 3, 16, 27, 28, 29, 2, 15)

**Problem.** **(3, P2)** `Runner/Monitor.pm:444-533` + `Handlers.pm:382-387, 1315`: the runner-side Monitor never prunes collectors/jobs/runs; all seven PENDING_* lists and RUN_HEALTH grow forever, decided_jobs/announced_runs ledgers too — a long-lived `yath start` daemon's RSS climbs and every subscriber snapshot serializes lifetime history. **(16, P2)** `Runner.pm:1063-1096, 1478-1511`: a sampler reaped by the subreaper sweep is invisible to stop_sampler (PRELOAD_ROOT has a guard, SAMPLER does not) → deterministic 5s+2s shutdown stall after a sampler crash, and TERM/KILL to a possibly-recycled pid; stop_aux shares the pid-reuse hazard. **(27, P2)** `State.pm:640-645, 740-764`: demoting a stage to 'down' (set_stage_map on reload with a stage removed; latent stage_down endpoint) strands its PENDING_TASKS bucket — `_next` never walks it, the run hangs forever. **(28, P2)** `Role/Scheduler.pm:105-117`: a run activated and retired within one advance loop is never announced — harness_run_end lost (hung subscriber) and, on the owner-drop leg, the run leaks permanently in RETAINED/STOPPED/HALTED_RUNS. **(29, P2)** `State.pm:417-421, 494-515`: `_start_task` mutates env_vars/test_args refs shared with TASK_LOOKUP (and the finder's TestFile), duplicating per-attempt resource args across retries (third-party Resource API pattern). **(2, P3)** `Watchdog.pm:185` + `Handlers.pm:721`: fire-once ledger key mismatch (is_try undef → 'id+0' vs collector EOF 'id+1') — aborted first-try jobs are re-decided; absorbed today, armed for any future subscriber without dedupe. **(15, P3)** `Handlers.pm:652-678, 274-280`: collectors terminated via the per-job connect-timeout intent are never hard-killed — `_enforce_terminate_grace` only enforces run-level intents, though `_terminate_collector`'s own comment (623-628) promises the fallback.

**Steps.**
1. (3) On announce_run/purge_run, delete the run's Monitor RUNS entry and its run-scoped collectors/jobs (including undef-run-linkage strays), clear that run's decided_jobs/job_passed/announced_runs keys, and stop populating PENDING_* on the hub-side monitor.
2. (16) In `_bring_out_yer_dead`, mirror the PRELOAD_ROOT_PID guard for SAMPLER_PID (delete + skip); apply the same pattern to AUX_PIDS in stop_aux; add an ECHILD check before the KILL fallback.
3. (27) Call `_rebucket_stage_tasks($stage)` on both demotion paths (set_stage_map removed-stage loop at 760 and stage_down at 643), mirroring `_expire_stale_stages`:697.
4. (28) Have clear_finished_run/advance report retired run_ids and announce every retired run instead of diffing the ACTIVE_RUN slot.
5. (29) Deep-copy env_vars/test_args in `_start_task` (both branches, incl. the `unless stage ne` branch at 418); correct the requeue_task comment (517-536).
6. (2) Normalize with `// 1` at Watchdog.pm:185 and Handlers.pm:721 (or default `_decided_key` to `// 1`); update the 0-based-try unit tests (Runner_abort_terminate.t) to 1-based.
7. (15) Stamp `deadline => time + $self->_terminate_grace` on the entry in `_terminate_collector` and have `_enforce_terminate_grace` fall back to entry-level deadlines (drop the `return unless keys %$aborting` early-out).
8. Regression tests: run-purge leaves Monitor size flat across runs; stage-removed reload completes queued tasks; one-tick run emits harness_run_end; retried task carries exactly one copy of per-attempt args.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); new/updated unit tests green; 3× repeat + `ps` zombie check on a persistent-runner session (Runner-adjacent risk gate).

### #136 — Preload subsystem bundle: dead stop_stages, default_stage object bug, dead transitive blacklist, stat-throttle no-op

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-8 · **Depends:** — (finding 37 = execute via cleanup #78; audit findings 36, 37, 38, 21)

**Problem.** **(37, P2)** `Runner/Preload.pm:167-184`: `default_stage` returns a truthy StageConfig object when no default() was declared, so no stage is ever flagged default and tests fall to the alphabetically-first stage (wrong preload env); the `//=` merge cache also lets a first-merged no-default lib permanently mask a later lib's EXPLICIT default(), violating the documented first-wins contract. Already ticketed as cleanup **#78** — execute there, don't duplicate. **(38, P2)** `Runner/Preloader.pm:680-707`: transitive blacklist propagation is dead — check() looks up dep_map with absolute watched paths but DepTracer keys by relative require paths ($rel computed at 691/695 but unused): dependents are never blacklisted, so blacklist churn-prevention never works (every edit to a dependency re-triggers a full stage restart, and the dependent re-loads it into the preheated image). **(36, P3)** `Preload/Host.pm:526-540`: `stop_stages` is a silent no-op (child stages register as peers of the real runner, never of the parent host) — dead code plus a wrong comment that forces all host-initiated teardown onto the raw-signal paths (#111/#112's enablers). **(21, P3)** `Runner/Reloader.pm:152-158`: STAT_LAST_CHECKED assigned to a dead lexical copy — the stat_min_gap throttle silently never engages (2x stat amplification on non-inotify systems).

**Steps.**
1. (37) Execute cleanup #78's fix (`return $self->{+STAGE_LIST}[0] ? $self->{+STAGE_LIST}[0]->name : undef;` + normalize the merge cache via `blessed($v) ? $v->name : $v`); add a regression test for the no-default() and later-explicit-default() cases.
2. (38) Use `$dep_map->{$rel}` at Preloader.pm:705; normalize ARRAY items' caller files through the already-built %CNI to relative keys before recursing; dedupe %seen on $rel; guard `$mod ne ''` before `->can('TEST2_HARNESS_PRELOAD')`.
3. (36) Delete `stop_stages` and its call at Host.pm:713 (runner's stop_preload_stages + killall($SIGNAL) already cover every path — same rationale as #11's recorded decision); fix the misleading comment.
4. (21) Write the throttle back: `$self->{+STAT_LAST_CHECKED} = $check_time;`; optionally guard the `[undef, undef]` stat comparison warn at 168.
5. Regression tests: no-default preload flags first-declared stage; editing a dependency of a preloaded module blacklists the dependent transitively (no restart churn on the second edit).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; `grep -rn 'stop_stages' lib` shows only the runner-side survivor.

### #137 — Runner::Job env/switch handling bundle: empty-string switch from HARNESS_PERL_SWITCHES, '-w' substring match, spawn TMPDIR inside the workdir

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-8 · **Depends:** — (finding 32's predicate hoist = cleanup #75; audit findings 31, 32, 33)

**Problem.** **(31, P2)** `Runner/Job.pm:368-376`: `HARNESS_PERL_SWITCHES=" -w"` (leading space — common when composing from an unset var) splits to an empty-string switch; the exec'd perl treats `''` as its program and every test silently does not run (no -M injections, no test body). **(32, P2)** `Job.pm:567, 624, 632, 639` + `JobLauncher.pm:445`: '-w' is matched as a substring anywhere, so `-I/home/bob/my-website/lib` is treated as the -w switch — silently dropped on the preload path (wrong libs) with $^W force-enabled. **(33, P2)** `Job.pm:523-532, 687-688` + `Runner/Spawn.pm:12-46`: spawned harness-outliving scripts inherit TMPDIR/TEMPDIR pointing inside the workdir, which `yath stop`/`yath kill` deletes while the script still runs — later tempfile creation fails ENOENT with no connection to yath; spawns also carry test markers (HARNESS_ACTIVE etc.) they shouldn't.

**Steps.**
1. (31) In `switches_from_env`, use awk-style `split ' ', ...` or `grep { length } split /\s+/, ...`; consider `Text::ParseWords::shellwords` for quoted-switch support.
2. (32) Anchor the predicate to `m/^\s*-w\s*$/` at all four sites (or land after cleanup #75 hoists the single `_is_w_switch` predicate and anchor once); clustered `-wT` then correctly forces the exec path.
3. (33) In `Runner::Spawn`, override `tmp_dir` to `settings->harness->orig_tmp` (SYSTEM_TMPDIR already computes it) and wrap env_vars to drop HARNESS_ACTIVE/TEST2_HARNESS_ACTIVE/TEST2_JOB_DIR for non-test spawns.
4. Regression tests: leading-space HARNESS_PERL_SWITCHES still runs the test body with the switch applied; a '-w'-containing -I path takes the exec path with the -I honored; spawn env has TMPDIR outside the workdir.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #138 — Resources/sampler bundle: mem-report starvation in the danger zone, impossible nproc gate, resources-table header

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-8 · **Depends:** — (finding 40 = execute via cleanup #80; 41 can ride cleanup #79's Utilizer rework; audit findings 39, 41, 40)

**Problem.** **(39, P2)** `Service/Sampler.pm:199-233, 301-332` + `Resource/Memory.pm:169-177`: the 5%-bucket change gating stops sending updates once mem_pct pins at 100, so `-R Memory=512mb` sees a frozen mem_available (~5% of total) while free memory collapses — the resource never defers and the OOM killer fires, exactly what the option was configured to prevent (any threshold finer than the 5% bucket, and --utilize > 95, are starved; raw bytes only refresh if the CPU bucket happens to move). **(41, P2)** `Resource/UnixLimits.pm:425-477`: the nproc gate compares the runner's own /proc/self/status Threads (constant 1) against RLIMIT_NPROC (a per-user process count) — the pct-threshold gate can never fire (fork EAGAIN storms proceed), and an absolute threshold ≥ cap-1 silently throttles every run to min_concurrent=1. **(40, P3)** `Resource/JobCount.pm:119`: status_data uses key 'headers' but the base reads 'header' — the `yath resources` slot table renders with no header row (already ticketed as cleanup **#80** step 1).

**Steps.**
1. (39) Add a max-staleness heartbeat in service_tick (send unconditionally if the last send is older than N seconds) and/or bypass gating whenever the rounded mem bucket is 100; alternatively give Resource::Memory a snapshot timestamp and treat a stale top-bucket snapshot as unavailable.
2. (41) Either measure the user's real task count (sum Threads across /proc/*/status entries with matching real Uid, matching kernel accounting) or drop/deactivate the nproc dimension until a correct source exists — do not ship a gate that cannot fire; document the choice in the module POD (which currently describes the broken sampling as intended).
3. (40) Execute cleanup #80's rename `headers` → `header`.
4. Regression tests: sampler emits a report within the heartbeat window despite a pinned bucket; UnixLimits nproc either gates on a synthetic /proc fixture or is absent; resources table renders its header row.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; t/AI/unit/Resource_OSLimits.t updated to cover real semantics, not just mocks.

### #139 — yath spawn robustness bundle: false exit-0 on supervisor death, TERM-only escalation, fd leak, recv_fds EINTR spin, numeric %SIG reset

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-9 · **Depends:** — (#119 owns the pgroup/setsid fix these interact with; audit findings 6+G2 merged, 12+G5 merged, 23, 67, G3)

**Problem.** **(6+G2, P2)** `Command/spawn.pm:291-305`: bridge_io initializes `$status = 0` and treats control-channel EOF without an exit_status frame as a clean exit — a supervisor OOM-killed/crashed between hello and exit_status (or a failed `_send` in send_exit_status, JobLauncher.pm:192) leaves the setsid'd script running detached while `yath spawn` exits 0 (the pre-hello fork-failure case is already caught by the hello guard at 285-287). **(12+G5, P2)** `JobLauncher.pm:175-181`: the supervisor's command-death path sends one `kill('-TERM', $child)` then blocks in waitpid forever — a TERM-trapping/wedged daemon leaves a permanently stuck supervisor plus a runaway script on the freed terminal; escalation must be `kill('-KILL', ...)` to the group (descendants may ignore TERM too); the setsid-race half is practically unreachable — treat setpgid-after-fork as hardening only. **(G3, P2)** `Util/FdPass.pm:187-200`: IO::FDPass::recv returns -1 on peer EOF WITHOUT touching errno; with stale EINTR in errno (common across fork from the stage host's signal-handling IPC) the `next if $! == EINTR` retry spins forever at 100% CPU in a detached supervisor (empirically reproduced); `Interactive.pm:114` shares the defect with milder blast radius; $! is also never cleared before the FIRST call. **(23, P3)** `JobLauncher.pm:116-196` (gap after the fork, ~159): the detached supervisor never closes inherited stage-host fds (stage listen socket, runner channel, collector stdout/stderr pipes), contradicting the Host.pm:356-358 comment — the runner keeps a dead stage connection registered and writes into an unread buffer during reload windows (soft impact per re-verify; no wedge). **(67, P2)** `Command/spawn.pm:253-257`: %SIG reset uses the NUMERIC signal from parse_exit — a reliable spurious 'No such signal: SIG15' warning on every signal-terminated spawn plus a numeric user-facing message (the effective reset already happened by name in `_clear_sig_forwarding`).

**Steps.**
1. (6+G2) In bridge_io, track whether an exit_status frame was received; on `$ctl->closed` without one, print 'spawn supervisor vanished before reporting an exit status' and exit non-zero (e.g. 255). Companion hardening: restore blocking mode before the supervisor's final status write.
2. (12+G5) Replace the blocking waitpid with a WNOHANG poll (~5s grace, Time::HiRes::sleep), then `kill('-KILL', $child)` and a final blocking waitpid — mirroring `Preload::Host::stop` (Host.pm:444-455); check kill's return and signal the child pid as well as the pgroup; optionally setpgid the child right after fork.
3. (G3) Set `$! = 0` immediately before each IO::FDPass::recv/send call in the retry loops of recv_fds AND send_fds (both FdPass.pm and the Interactive.pm consumer path) so EOF is never mistaken for EINTR; follow-up: consider `delete @SIG{qw/INT HUP TERM CHLD/}` after setsid in launch_spawn to remove the EINTR source.
4. (23) At the top of launch_spawn (before target_connect), run the `_run_spawn_child` sweep — `$runner->stop(); $runner->close_all_connections;` — and reopen fds 0/1/2 onto /dev/null, making the Host.pm comment true.
5. (67) Resolve the signal number to a name via `$Config{sig_name}` for both the message and any %SIG write — or simply drop the now-redundant reset (already restored by name in `_clear_sig_forwarding`).
6. Regression tests: SIGKILL the supervisor mid-session → spawn exits nonzero with the vanish message; TERM-ignoring spawned script is KILLed within the grace window; recv_fds against a closed peer with errno=EINTR croaks instead of spinning (existing repro); /proc/<supervisor>/fd holds no stage socket/pipe fds post-handshake; signal-terminated spawn prints a named signal and no 'No such signal' warning.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; no stray 100%-CPU or orphaned spawn processes in `ps` after the spawn test matrix.

### #140 — Interactive-mode bundle: signal-masked exit 0 / ECHILD hang, unauthenticated STDIN fd-pass socket, quiet/verbose override ordering

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-9 · **Depends:** — (#125 owns the tempdir-cleanup half of the same accept loop; audit findings 7+G4 merged, G6, 77)

**Problem.** **(7+G4, P2)** `Options/Debug.pm:370-381` (vulnerable expression at 373): the accept-loop parent — the process the shell waits on — reaps the yath child with `$finish->($? >> 8)`, so a signal death (OOM SIGKILL, segfault) computes 9>>8==0 and **CI sees a green run that was killed mid-flight**; secondarily, a SIG_IGN-inherited CHLD makes waitpid return -1 forever (hang-until-Ctrl-C, 0.2s poll). **(G6, P3)** `Options/Debug.pm:336-341, 375-391` + `Interactive.pm:104-128`: the accept loop passes the real terminal STDIN fd to any connector with no identity check, and YATH_INTERACTIVE (the socket path) is broadcast into every test's env for the whole run — a harness-aware descendant (nested yath, forked code loading Interactive) dialing late steals keystrokes from the genuine interactive test (narrowed trigger per re-verify: the descendant must actually invoke connect_stdin). **(77, P2)** `Options/Debug.pm:184, 320-324` + `Options/Display.pm:383-404`: interactive's quiet/verbose/live/qvf overrides run at weight 99998, after Display resolved renderers at weight 90/100 — `yath test -q -i` shows nothing at all (prompt invisible, looks hung on STDIN); plain `-i` gets verbose formatter output but loses show_job_launch/show_job_info (frozen pre-override into the args array).

**Steps.**
1. (7+G4) Signal-aware forwarding via `Test2::Harness2::Util::parse_exit`: `$finish->(($? & 127) ? 128 + ($? & 127) : ($? >> 8)) if $got == $pid;` plus `$finish->(1) if $got < 0;` to break the ECHILD loop (coordinate with #125's handler rework — same lines).
2. (G6) Since interactive is -j1 and the accept loop knows the currently-dispatched job, tag the job's env with a per-job nonce and require the dialer to echo it before send_fds; log and drop non-matching connections.
3. (77) Move the interactive display overrides (quiet/verbose/live/qvf) into their own post-process below weight 90 (leaving the fork/stdin-handoff at 99998), or have the weight-90/100 posts consult `debug->interactive` directly.
4. Regression tests: SIGKILL'd interactive child → wrapper exits 128+9; `-q -i` renders the formatter (prompt visible); a wrong-nonce dialer is rejected while the real test still receives STDIN.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #141 — Renderer Driver/live-pipeline bundle: aborted-job double count, --hide-runner-output 5s stall, settled-job finalize waits, per-job fd leak, RETRY mislabel, RunnerReader stamps

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-10 · **Depends:** — (findings 4 and 17 partially land via cleanup #65 — coordinate; audit findings 4, 17, 52, 96, 99, 107)

**Problem.** **(4, P2)** `Renderer/Driver.pm:348-384`: `_render_aborted` dispatches a second synthetic launch for jobs whose collector already launched (abort_remaining paths: wind-down, `yath abort`, owner-drop) — file shown 'started' twice, File Count inflated, phantom 'Times Run: 2 / Succeeded Eventually? NO' row; cleanup **#65 step 2** already plans this dedup — execute there with the regression test. **(17, P2)** `RenderLoop/LiveProducer.pm:289-314` + `Renderer/Base.pm:337, 399-405`: every `yath test --hide-runner-output` run pays a fixed 5s dead wait at finalize because `runner_output_done` can never become true when the reader is gated off — fix is one line in Base (`return 1 unless $self->{+SHOW_RUNNER_OUTPUT};`). **(52, P3, re-verified)** `Driver.pm:522-559`: `_finalize_live` waits the full 5s TAIL_TERMINAL_TIMEOUT serially per collector for watchdog-aborted jobs whose collector died without finalizing, under `--live`/interactive — bounded end-of-run delay with correct verdicts. **(96, P2)** `Driver.pm:499, 109` + `JobReader.pm:26-30, 79-83`: in live-tail mode TAIL_READERS accumulates one open zstd fd per job (per try) for the whole run — `yath test --live` with more files than the fd rlimit hits EMFILE mid-run and rendering breaks. **(99, P2)** `Renderer/Formatter.pm:116` + `Driver.pm:336, 382`: the 1-based try ordinal is used directly as the boolean retry flag — every first launch is tagged RETRY under -v, making real retries indistinguishable; the aborted path hardcodes try=0 (inverse defect: retries of aborted jobs never tagged). **(107, P2)** `RunnerReader.pm:157-166, 111-118`: record stamps are ignored and after a harness_process_restart every subsequent event is frozen at the restart's stamp — hours of stage output collapse onto the restart instant in renderers/DB.

**Steps.**
1. (4) Execute cleanup #65 step 2 (skip the synthetic launch + TESTS_SEEN++/tries++ when already launched, keyed on `$job->{tries}` or BY_UUID{launched}; still emit the aborted exit/end); add the launched-then-aborted regression test.
2. (17) `return 1 unless $self->{+SHOW_RUNNER_OUTPUT};` at the top of `Renderer::Base::runner_output_done`.
3. (52) In the `_finalize_live` sweep, `next if $self->{+ABORTED_RENDERED}{$job_id};` (or `next if $job && $job->{verdict};`) before the until-loop, and/or hoist the line-546 status gate above the wait, mirroring the non-live sweep at Driver.pm:244-249.
4. (96) When `$entry->{ended}` is set, `delete $self->{+TAIL_READERS}{$uuid}`; and/or have JobReader close and clear +READER when it sets +DONE.
5. (99) Emit a boolean: `retry => ($try // 1) > 1 ? 1 : 0` in `_render_launch`; give `_render_aborted` the real try ordinal (from $job/task) instead of the constant.
6. (107) Mirror `JobReader::_stamp_for`: harvest each record's own facet/trace stamp (refreshing LAST_STAMP), with LAST_STAMP//time only as fallback.
7. Regression tests: abort-one-job run asserts TESTS_SEEN==1 and no retry row; timed assertion that --hide-runner-output finalize completes < 1s; -v first launch tagged LAUNCH and a real retry tagged RETRY.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; golden-output checks for the launch/retry tags.

### #142 — Formatter/Composer output bundle: QVF ECOUNT double-count, HASH(0x...) details, ABOUT tag shadowing, dead halt branch, retry status-bar counters, DESTROY ANSI reset

**Status:** Proposed (bug audit 2026-07-01, severity P3, effort S) · **Step:** BUG-10 · **Depends:** — (findings 54/55/56 are already scheduled inside cleanup #64 steps 2-3 — execute there, in the CANONICAL `Test2::Formatter::Test2::Composer`; audit findings 51, 54, 55, 56, 101, 102)

**Problem.** All P3 display defects, several inherited verbatim from released 1.x. **(51)** `Formatter/QVF.pm:32-65`: buffered events are ECOUNT-counted again on failed-job replay and !$job_id events double-counted — the status bar's 'Events: N' inflates toward 2x. **(54)** Composer render_info/render_errors compute a dumped `$msg` for ref details but emit the raw ref — terminal shows `HASH(0x...)` instead of the error content. **(55)** render_about's inner `my $type` shadows the outer — tag always 'ABOUT'. **(56)** render_one_line's halt branch tests `$class->{control}` (never true) and 'times' dispatches to a nonexistent render_times (latent crash on synthetic facets). **(101)** `Formatter/Test2.pm:378-399`: a to-be-retried failure is counted in F permanently and todo goes negative — [P:1|F:1|T:-1] on a run that will PASS; note the end-facet {retry} flag is injected by `Renderer::Base::note_verdict`, not the collector. **(102)** `Test2.pm:763-775`: DESTROY writes `\e[0m` to non-TTY/--no-color output — stray escape byte in CI logs.

**Steps.**
1. (54/55/56) Execute via cleanup #64 steps 2-3 in the canonical Composer (per #64, the orphan `Default/Composer.pm` is deleted; do NOT fork fixes into it).
2. (51) In QVF::write, count only buffered-not-forwarded events (or save/restore ECOUNT around the replay and SUPER::write calls; `local` won't work — ECOUNT must persist).
3. (101) In update_active_disp, treat an end with {retry} as neither passed nor failed (re-increment todo / track a retry bucket), or skip todo-- when harness_job_launch->{retry} is true.
4. (102) Gate the DESTROY reset on `$self->{+COLOR} && USE_ANSI_COLOR` (mirroring line 182 / the reset() helper at 610).
5. Regression tests: QVF event count matches processed events on a failing run; retry run's status counters end at [F:0, T:0]; captured --no-color output contains no `\e[` bytes.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; Tester.pm output assertions no longer need the trailing-escape workaround (check before removing it).

### #143 — Jsonl renderer / lastlog bundle: dangling-symlink sweep, unchecked print/close with false 'Wrote log file', silent --logger-lastlog failure

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-10 · **Depends:** — (rides #55/#56, which own this renderer and its options; audit findings 20, 57, 84)

**Problem.** **(57, P2)** `Renderer/Jsonl.pm:105-127`: unchecked print at 107 (render_event), unchecked print/close at 118-119 (finish), unconditional success message at 125-127 — disk-full mid-run silently drops events, close() fails to flush the compressed tail, yet yath prints 'Wrote log file: run.jsonl.gz' with exit 0; the falsely-blessed corrupt archive is the run's only record. On the plain path stdio buffering means per-event failures surface at close, so the close() check is the primary fix for BOTH paths. **(20, P2)** `Jsonl.pm:75-91, 127`: the lastlog stale-link sweep uses `-f` (follows the link, false for dangling), symlink() then fails EEXIST but the `eval{...;1}` ignores the return value — the run reports '(Symlinked to: ./lastlog.jsonl)' while lastlog still points at a deleted (or wrong) old log; the warn also prints `$@` (empty) instead of `$!`. **(84, P3)** `Options/Logger.pm:236-243`: the lastlog.sqlite unlink+symlink at 240-241 swallows failure — the pointer is silently lost even though the user explicitly passed --logger-lastlog (the dated log itself survives).

**Steps.**
1. (57) In finish(), `close($fh) or do { warn "Failed writing log '$self->{+FILE}': $!"; return }` before the success block (IO::Compress surfaces flush/trailer errors via close); per-event print checks optional hardening.
2. (20) Sweep with `next unless -l $name || -e $name;` and check the symlink return while keeping the eval for symlink-less platforms: `if (eval { symlink($file, $name) }) {...} else { warn "...: " . ($@ || $!) }` — mirror Options/Logger.pm:240; consider one shared helper for both sites.
3. (84) Check unlink and symlink returns in `_maybe_lastlog`, warning with `$!` on failure; consider symlink-to-temp + rename for atomic replacement.
4. Regression tests: finish() against a closed/failed handle suppresses the success message and warns; a dangling lastlog link is replaced and points at the new log.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #144 — Finder/test-selection bundle: unchecked chdir, symlinked dirs skipped, exclude-list raw-string mismatch, durations-vs-exclusion ordering, dedup aliasing

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-11 · **Depends:** — (audit findings 58, G12, G13, G15, G16)

**Problem.** Five test-selection defects, all silent (wrong test set with exit 0). **(58, P2)** `Finder.pm:531-571`: `find_multi_project_files`' unchecked `chdir($pdir)` silently scans the CURRENT directory's subdirs as projects on a typo'd/deleted path — a test run of the wrong code. **(G12, P2)** `Finder.pm:615, 655-684`: File::Find runs without follow, so symlinked test SUBDIRS are silently skipped (their tests never run, run exits 0 when siblings pass); a symlink as the only search path exits 1 with zero explanation; inherited from 1.x, and symlinked FILES are unaffected. **(G13, P2)** `Finder.pm:103-120, 723-727`: exclude entries are compared as raw strings against exactly two spellings — './'-prefixed, whitespace-padded, '..'-containing, or symlink-differing entries exclude NOTHING (a destructive test runs anyway); same raw compare in changes_exclude_files (248, 256); CRLF is already handled. **(G15, P2)** `Finder.pm:637, 678, 686-698`: --no-long/--only-long are evaluated at collection time, BEFORE --durations data applies — durations-file LONG markings are ignored for selection (--only-long even inverts); also the durations source is silently skipped whenever test_count < durations_threshold (defaults to job_count+1), ignoring an explicit --durations. **(G16, P3)** `Finder.pm:629-630, 663-665`: listed-vs-scanned dedup keys on rel2abs without realpath — `yath test t/../t/db.t t/` (or a symlink alias) queues the same file twice, racing HARNESS-CONFLICTS-style exclusive resources.

**Steps.**
1. (58) `chdir($pdir) or die "Could not chdir to '$pdir': $!\n"` (block form) plus an up-front `-d` check; also check the two restore chdirs (548, 562).
2. (G12) Add `follow_fast => 1, follow_skip => 2` to the File::Find call (plain `follow` dies on symlink loops) and/or realpath-resolve top-level @dirs at line 615; emit 'no tests found under <dir>' per zero-yield search dir and a diagnostic before test.pm:202's `return unless $pop`.
3. (G13) Trim whitespace (incl. \r) on every exclude entry and canonicalize both sides (store clean_path($entry) + abs2rel forms; also fix the changes_exclude_files path); add a 'N exclude entries never matched any discovered test file' warning; document symlink-realpath as a known limitation if not closed.
4. (G15) Resolve/apply duration data before (or inside) the exclude_file pass — split collection from filtering so set_duration happens between them; honor an explicit --durations regardless of durations_threshold (or warn when the threshold skips it).
5. (G16) Key %seen on realpath-canonical clean_path in both branches while keeping the non-realpath path as the TestFile's file; print a dedup notice when a listed path is skipped.
6. Regression tests: symlinked t/ subdir's tests run; padded/'./'-prefixed exclude entries exclude; durations-file LONG + --no-long skips the test; aliased listing queues once.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #145 — Discovery/start lifecycle bundle: publish-before-bind race, find() destroys the PID-file fallback, start deletes a live/pinned workdir

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-11 · **Depends:** — (fold into cleanup #95 (Pfile removal) / REF-PORT #62 (Discovery list/ping), which churn the same files; #121 consumes the restored PID-file fallback; audit findings 22, 62, 64)

**Problem.** **(22, P2)** `Command/start.pm:141-160` + `Discovery.pm:149-163, 275-285, 378-408`: the discovery symlink is published before runner.socket exists and cleaned by path without identity check — a concurrent discovery command (second terminal, cron, CI) landing in the runner's boot window sees 'not a socket yet', declares it dead, and unlinks the fresh link: a preloading runner survives as a permanently undiscoverable leaked daemon; a no-preload runner orphan-detects and TERMs itself right after 'Persistent runner started!'. **(62, P2)** `Discovery.pm:149-163`: find() unlinks the symlink on ANY connect failure, destroying the documented PID-file fallback for a wedged runner — after one failed `yath stop`, the only pointer to the workdir/PID is gone and the wedged runner must be hunted by hand (re-verify: a hung runner with a live listen fd passes via the accept backlog; the destructive clean fires on a truly-gone listener, full backlog EAGAIN, or client-side EMFILE/EACCES — and stop/kill's current teardown is socket-driven, so the immediate loss is discoverability). **(64, P2)** `start.pm:139-144`: the unguarded `remove_tree($dir)` on the already-running abort path deletes ANY user-pinned workdir — including the LIVE runner's own (runner.socket/PID/settings.json unlinked, daemon orphaned, unstoppable) when YATH_WORKDIR is reused.

**Steps.**
1. (22) Publish the link from the runner itself after start_service binds runner.socket (or have start wait for `-S $dir/runner.socket`/resolves before publishing); make write_link atomic (symlink-to-temp + rename); in clean paths, re-readlink and only unlink if the target still matches the probed target.
2. (62) Make find() classify via probe() and clean only on state 'dead' (dangling link / missing target / ECONNREFUSED), via clean_if_owned; return a not-live discovery object so stop can still reach the workdir PID file (feeds #121's escalation).
3. (64) Only remove_tree when the workdir was freshly created for this invocation (created-this-run flag from Workspace.pm), and never when the dir contains runner.socket/PID or matches the found discovery's workdir.
4. Regression tests: concurrent `yath status` polling during `yath start` boot never unlinks the fresh link; find() against a wedged-but-alive runner leaves the link and reports not-live; repeated pinned-workdir `yath start` leaves the live runner intact.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #146 — Persist-command UX bundle: Ctrl-C messaging, resources blank-screen loop, N/A sort warnings, ps attach, ping exit code, reload/stop undef-pid guard

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-11 · **Depends:** — (finding 18 = execute via cleanup #91 step 3; finding 5 folds into cleanup #89's flow; audit findings 5, 18, 71, 73, 103, G11)

**Problem.** **(5, P2)** `Command/test.pm:145-177, 428-445`: Ctrl-C during `yath test` prints a false 'No tests were seen!' plus an internal-looking 'Final data never received from collector!' die and exit 255 instead of an honest 'interrupted by SIGINT' with partial results (legacy-parity flow; plugin finish() hooks also skipped on signal). **(18, P2)** `Command/resources.pm:58-78`: after the runner goes away the loop clears the screen every 0.2s forever (the runner-gone `return 0` is unreachable) — already planned as cleanup **#91 step 3**. **(71, P3)** `status.pm:76-116` / `ps.pm:44-57`: numeric sorts over pid columns containing 'N/A' spray "isn't numeric" warnings whenever a stage is restarting (2+ rows required; ps's realistic source is the running-tests loop at 49). **(73, P3)** `ps.pm:31-34`: missing `attach_runner` gives the client zero connect-retry tolerance — a transient connect failure silently prints an empty process list, exit 0. **(103, P2)** `ping.pm:68-77`: 'no response' break exits 0 — `yath ping && ...` health checks proceed on a dead runner; the fall-through also prints 'Stopped.', reading as a clean user stop. **(G11, P3)** `reload.pm:41-42` + `stop.pm:46, 58, 72`: a live socket with a missing/garbled workdir PID file (external deletion/corruption only — PID is written before the socket binds) crashes with "Can't kill a non-numeric process ID" after printing 'Sending SIGHUP to <blank>'.

**Steps.**
1. (5) Branch on `$self->signal` after stop(): print 'Run interrupted by SIG<x>', harvest partial tests_seen/final_data (move the harvest above the signal return), skip the final-data die, re-raise the signal after restoring DEFAULT (128+sig convention); run plugin finish hooks; check `yath run`/watch for the same pattern.
2. (18) Execute cleanup #91 step 3 (`last unless defined $resources;` + 'Runner has gone away' + return 0, modeled on ping.pm).
3. (71) Numeric-fallback comparator (`/^\d+$/ ? $_ : -1`) or `no warnings 'numeric'` around the sorts in both files.
4. (73) Add `$self->client->attach_runner($data->{pid});` before the status call, matching status.pm/abort.pm.
5. (103) `return 1` on the no-response path (structure as `if (!$reply) { ...; return 1 }`), keeping 0 for the SIGINT/TERM `$stop` paths; don't print 'Stopped.' on failure.
6. (G11) Guard: `my $pid = $data->{pid} // die "Runner found at $data->{dir} but its PID file is missing/unreadable; restart the runner.\n";` in reload.pm and the stop.pm consumers (58, 72).
7. Regression tests: SIGINT'd test run prints the interrupted banner and no collector die; ping against a stopped-responding runner exits 1; reload with a removed PID file dies with the named-workdir message.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #147 — Replay bundle: filtered-batch idle sleeps, truncated-compressed-log crash, no-match filter silence, corrupt-line confess

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-11 · **Depends:** — (JSONLFileProducer is a documented transition shim — fixes G9 belong in replay.pm; audit findings 53, G7, G9, G10)

**Problem.** **(53, P2)** `RenderLoop.pm:199-206, 221`: job-filtered replay counts filtered-out batches as idle — ~5000 empty batches on a 5M-event log add ~100s of pure 20ms sleeps; even unfiltered replays pay one stray sleep on a harness_final-only batch. **(G7, P2)** `Util/File.pm:91-93` + `JSONLFileProducer.pm:114-121`: replaying a truncated .jsonl.gz/.bz2 (killed writer) crashes with the internal 'IO::Uncompress::Gunzip::seek: cannot seek backwards' (exit 255, renderers never finalized) instead of the plain-log 'Log did not contain final data!' diagnostic — the trailing partial decoded line trips read_line's tell-mismatch re-seek on a forward-only handle. **(G9, P2)** `replay.pm:61-90`: a job filter matching nothing ('./t/x.t' vs 't/x.t' spelling, lowercase uuid) is silently ignored — zero events stream but the whole-run final table and exit code render as if unfiltered (the whole-run summary itself is documented legacy behavior; the missing piece is the per-arg 'matched nothing' diagnostic, and note even matching filters render the unfiltered final table, contradicting the command docs — flag for the same pass). **(G10, P2)** `Util/File.pm:106-113` + `JSONLFileProducer.pm:169-171`: one corrupt line aborts the whole replay with a JSON-decode confess — `skip_bad_decode` exists but the producer never enables it; the die also discards the valid events earlier in the same 1000-line batch.

**Steps.**
1. (53) Give JSONLFileProducer an `idle` method (true only when the raw stream batch was empty) and have RenderLoop prefer `$producer->can('idle') ? $producer->idle : !@events`.
2. (G7) In read_line, treat a seek failure on a non-seekable (IO::Uncompress) handle as stream-done (capability check or eval around the seek) so replay reaches the existing 'Log did not contain final data!' diagnostic.
3. (G9) After the loop, warn per filter arg that never matched (the producer mutates $jobs on match, so unmatched keys are detectable); document/decide on scoping the final table to selected jobs.
4. (G10) Construct the replay stream with `skip_bad_decode => 2` (warn and continue) or add a --strict/--lenient option; at minimum catch the decode error and die with a one-line 'log line N is corrupt'.
5. Regression tests: filtered big-log replay completes without idle-sleep inflation (timed); truncated-gzip replay reports the incomplete-log message and exits like the plain case; unmatched filter warns; single-corrupt-line log replays to completion with a warning.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #148 — CLI script/rc parsing bundle: section-header whitespace/comments, unquoted glob() shell-out, greedy APP_PATH regex

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-11 · **Depends:** — (V2.pm stale-POD fix in cleanup #97 can share a commit; audit findings 60, 63, 59)

**Problem.** **(60, P2)** `App/Yath/Script/V2.pm:99-105`: a `.yath.rc` section header with trailing whitespace or a trailing `;comment` is not recognized — '[test]' flows through as a command/argument ('yath command '[test]' not found' / "'[test]' is not a valid file or directory"), and every option under the malformed header silently rebinds to the previous/global section (which can change run behavior even when the token is consumed without a fatal). **(63, P3)** `V2.pm:138-153`: glob()/relglob() shell out with unquoted interpolation — a path with a quote/space makes the subshell die (stderr-only or fully silent) and the config value is silently dropped (wrong test set, no indication). **(59, P3)** `App/Yath2.pm:32-35`: APP_PATH's greedy `s{App\S+Yath2\.pm$}{}g` strips too much when the absolute path contains an earlier 'App' (~/Apps/...), so Tester.pm's `-D/-I` point nested yaths at the wrong tree (loud failure, or silent wrong-code testing when an installed copy exists).

**Steps.**
1. (60) Replace V2.pm:101 with `if ($line =~ m/^\[(.*?)\]\s*(?:;.*)?$/) { $cmd = $1; next; }` (per the re-verify refinement — fixes both the fatal and the silent rebinding).
2. (63) Replace the backtick with the list-form pipe-open (`open my $p, '-|', $^X, '-e', 'print join "\n", glob($ARGV[0])', "${path}${val}"`), check close/$? and warn instead of silently dropping; note Perl's csh-glob splits on whitespace — wrap the pattern (`glob(qq{"$pat"})`) or use in-process File::Glob::bsd_glob if the avoid-loading-File::Glob constraint is no longer real.
3. (59) Anchor the component match: `$APP_PATH =~ s{App[/\\]+Yath2\.pm$}{};` (or use `dirname(dirname(__FILE__))`).
4. Regression tests: rc fixture with `[test] ;comment` binds options to the test section; spaced-path relglob yields the globbed values or a warning; APP_PATH correct for a path containing '/Apps/'.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #149 — speedtag/times maintenance-command bundle: dead file sort, wrong die message, non-atomic in-place rewrite, ignored DUR alias

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-11 · **Depends:** — (cleanup #90 already plans the speedtag read/inject/write split + the times log-arg dedup — natural landing spot; audit findings 70, 72, 74, 100)

**Problem.** **(70, P2)** `Command/times.pm:122-144`: sorting by the 'file' field looks 'file' up in the times hash — the requested primary sort key silently does nothing (output actually sorted by 'total'). **(74, P2)** `speedtag.pm:164-170`: test source files are rewritten in place with unchecked print/close and no temp file — Ctrl-C or disk-full mid-write truncates the user's (possibly uncommitted) test file to zero/partial, and line 178 still reports 'Tagged'. **(100, P2)** `speedtag.pm:147`: the regex misses the supported `HARNESS-DUR-*` alias, so a new `HARNESS-DURATION-SHORT` line is inserted while the stale `HARNESS-DUR-LONG` wins at parse time — a deterministic wrong scheduling decision (exactly one stale/new pair persists; no unbounded stacking per re-verify). **(72, P3)** `speedtag.pm:101`: an invalid max_medium argument dies blaming "max short duration".

**Steps.**
1. (70) Special-case the file field: `my $fa = $field eq 'file' ? $ja->{file} : $ta->{$field};` (same for $fb).
2. (74) Write to `"$file.tmp$$"` checking print AND close returns (stdio buffering surfaces ENOSPC at close), then rename() over the original; warn and skip the file on any failure — only then print the 'Tagged' line.
3. (100) Change the match to `DUR(ATION)?` so speedtag recognizes what Legacy.pm's parser accepts; add a regression test alongside cleanup #90's planned extraction.
4. (72) Fix the line-101 die to say 'max medium duration'.
5. Regression tests: times sorts by file; speedtag under injected write failure leaves the original file intact; DUR-tagged file gets its tag updated in place (no duplicate pair).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #150 — Plugin/options bundle: git_output stderr deadlock, owner-flag override, dead --cover-from-type, unreachable HEAD^ fallback, env-var job_count reshaping

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-12 · **Depends:** — (#126 owns the sibling email-fail registration bug; audit findings 78, 79, 81, 82, 83)

**Problem.** **(78, P2)** `Plugin/Git.pm:36-60`: git_output drains stderr only after stdout EOF — the parent blocks in the readline at Git.pm:43 while git blocks writing >pipe-capacity stderr; exposure is every run with the Git plugin (inject_run_data calls git_output for rev-parse/status on each run), hanging before any test starts when git is stderr-noisy. **(79, P2)** `Plugin/Notify.pm:104-134`: explicit `--no-notify-email-owner`/`--no-notify-slack-owner` are force-flipped back ON whenever any email/slack/slack_url/slack_fail source is set — owners get spammed after an explicit opt-out. **(81, P2)** `Plugin/Cover.pm:91-100, 362-377`: `--cover-from-type` is never read — the type hint is dropped for --cover-from (and maybe_from_type doesn't default to it); a complete fix must also honor the hint in the stream layer (stream_json_l_file picks its parser by file extension and croaks otherwise). **(82, P2)** `Plugin/Git.pm:133-146`: the HEAD^ clean-tree fallback is unreachable (_diff_from always returns a truthy 2-element list) — a clean-tree `--changed-only` run dies 'Could not find any changed files.' (Finder.pm:376) instead of testing the last commit; inherited from 1.x. **(83, P2)** `Options/Runner.pm:368-380, 613-658`: `YATH_JOB_COUNT=8:2` bypasses the ':' reshaping (trigger fires only on action 'set', not 'initialize') — numeric-compare warnings and 1 slot per test instead of 2 (die at line 658 for the crash variant); the colon syntax is documented in the option's own examples.

**Steps.**
1. (78) Drain both pipes with select() (or non-blocking stderr reads inside the line loop), or switch to Capture::Tiny as reference/pre_ai_2.0's Git plugin does.
2. (79) Track set-ness: make owner flags default subs keyed off the email/slack lists (1.0 semantics) instead of force-setting in post_process (or use Getopt::Yath's set-by-cli source if exposed).
3. (81) Compute `_deduce_content_type($from, $cover->from_type)` on the non-maybe branch (line 374) and pass type_data through; default maybe_from_type to from_type per its docs; honor the parser hint in stream_json_l_file/url for extensionless sources.
4. (82) Probe diff emptiness eagerly (peek the first line via a push-back wrapper, or `git diff --quiet HEAD`) before choosing HEAD vs ${from}^.
5. (83) Accept action 'initialize' in the job_count trigger (matching utilize) or factor the ':' split into a shared normalize sub used by both paths.
6. Regression tests: git_output with >64KB stderr completes; --no-notify-email-owner suppresses owner mail; YATH_JOB_COUNT=8:2 yields job_count 8 / 2 slots; clean-tree --changed-only selects the last commit's tests.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #151 — Coverage aggregator bundle: ByRun swapped exclude guards, ByTest wrongly-shaped in-progress records

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-12 · **Depends:** — (amend cleanup #86 so its planned base-class hoist deliberately keeps ByTest's correct guards; audit findings 49, 50)

**Problem.** **(49, P2)** `Log/CoverageAggregator/ByRun.pm:118-132`: the `changes_exclude_loads` / `changes_exclude_opens` guards are swapped (inherited from pre_ai_2.0) — with run-level (JSON) coverage data each flag has the mirror-image wrong effect, so the two coverage formats give contradictory test selections for identical data; only manifests when a user passes either flag. **(50, P3)** `Log/CoverageAggregator/ByTest.pm:85-94`: finalize pushes `{testname => rec}` instead of `rec` for tests still in progress — reachable only for genuinely truncated collection (timeouts/bails DO get synthesized job_ends per re-verify); a later --cover-from silently drops the record, and the same run emits a bogus run_coverage facet with undef files/testmeta.

**Steps.**
1. (49) Swap the two guards in ByRun::get_coverage_tests to match ByTest.pm and the option docs; annotate cleanup #86 so the hoist preserves the corrected conditions.
2. (50) `push @{$cm} => delete $ip->{$_} for keys %$ip;` (the record already carries test/aggregator), optionally with `$rec->{incomplete} = 1`; guard Cover.pm's run_coverage emission on `$final->[0]{files}` being defined.
3. Regression tests in t/integration/coverage*.t: both aggregator formats select identical tests for identical data under each exclude flag; a truncated-collection record round-trips through --cover-from.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #152 — DB layer P2/P3 bundle: logger config tempfile leak, non-atomic sqlite bootstrap, swallowed module-load errors, die-path finalize

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-13 · **Depends:** — (#132 owns the EOF/timeout finalize half; audit findings 8, 89, 90, 98)

**Problem.** **(8, P2)** `Command/test.pm:253, 228-231` + `DB/Logger.pm:57-71`: `-L` config tempfiles are written UNLINK=>0 and never unlinked despite the comment claiming the logger 'reads and unlinks' — one ~200-byte file per -L target per run accumulates in TMPDIR forever (File::Temp is 0600, so clutter, not credential exposure). **(89, P2)** `DB/Connect.pm:193-211`: ensure_sqlite_db bootstrap is non-atomic — two first-opens of a shared results DB race to duplicate-table errors, and an interrupt after the first committed DDL statement leaves a permanently broken file ('no such table: runs' forever; a zero-byte file self-heals). **(98, P2)** `DB/Logger.pm:166-226, 578-629`: a die inside _run skips `_finalize_run_row`, leaving the runs row status='running' forever — indistinguishable from a live run, and (per re-verify) permanently excluded from `db sync` propagation, which only syncs complete/broken/canceled. **(90, P3)** `DB/Connect.pm:115-124`: require_db_modules swallows the real load error — a broken installed DBIx::QuickORM is misreported as 'not installed' with a cpanm hint, hiding the actual compile failure.

**Steps.**
1. (8) `unlink($path)` in run_from_config_file after decode_json (matching the comment), plus parent-side removal in wait_for_loggers/exec-failure paths.
2. (89) Verify a schema marker (schema_meta row) rather than just non-zero size, and bootstrap into a tempfile + atomic rename (or flock around the DDL) — closes both the interrupted and concurrent-first-open cases.
3. (98) In run()'s `unless ($ok)` branch, after _terminal_error, `eval { $self->_finalize_run_row; 1 }` (the RUN_ROW_SEEDED guard already makes it safe pre-seed) so the row is stamped 'broken'.
4. (90) Append the captured $@ to the croak message unless it is `Can't locate <that module>.pm` specifically (dependency Can't-locates are compile failures the user must see).
5. Regression tests: -L run leaves no yath-logger-*.json in TMPDIR; two concurrent first-opens both succeed (DBMatrix sqlite cell); injected mid-sync die leaves runs.status='broken'; broken-module fixture surfaces the compile error.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green.

### #153 — Web-client command bundle (web-parked surface — rework in place): client-recent --max ignored, client-publish non-JSON crash

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-13 · **Depends:** — (audit findings 91, 92)

> **Web-parking note (owner directive):** these commands are part of the web-facing surface retained for the §9 webapp port. Both fixes below **rework the code in place** — no deletions, no `git mv`; if the §9 port later reshapes the client API, these fixes carry forward with it.

**Problem.** **(91, P2)** `Command/client/recent.pm:56, 109-124`: `--max` is parsed but never sent — the server's default count (typically 10) is returned with no warning, silently misleading the user about how many runs they're seeing; the server already routes `/recent/:project/:user/:count` (Controller::Recent defaults count to 10), so the client just never appends the segment (inherited from the legacy get_from_http). **(92, P3)** `Command/client/publish.pm:67-77`: a 200 response with a non-JSON body (proxy/maintenance page) dies via an uncaught decode_json longmess (the body IS embedded between ======= markers, but it's a stack trace, not a clean error); with allow_nonref a bare-scalar JSON body instead dies on the line-73 hash deref; a missing run_uuid prints a broken 'View run at: .../view/' with an uninit warning.

**Steps.**
1. (91) Append `"/$count"` to the request URL at recent.pm:119 (the route already supports it).
2. (92) Wrap the decode in the house `my $ok = eval { ...; 1 }; my $err = $@;` pattern; on failure print status_line + raw body as a clean error (exit 1); verify the decoded value is a hashref; only print the view URL when run_uuid is defined, else warn that the upload may have succeeded without a returned run_uuid.
3. Regression tests: recent builds the count-suffixed URL; publish against a text/HTML 200 exits 1 with the body shown, no stack trace.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; no web-layer files deleted or moved.

### #154 — Util/directives bundle: unterminated-final-line drop, bare-directive corruption, wrong warning line numbers, maybe_open TOCTOU, Value SUPER::init, FreeBSD/DragonFly SubReaper syscalls

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort M) · **Step:** BUG-14 · **Depends:** — (45/46 fold into cleanup #85's _record dispatch-table rework; 42 verifies via #28's ported subreaper test; audit findings 44, 45, 46, 47, 48, 42)

**Problem.** **(44, P3)** `Util/File.pm:100-101`: a final line without a trailing newline is silently dropped by all Stream/JSONL readers (done never set) — `--rerun`/`yath failed` on hand-edited/externally-produced files silently lose the last record. **(45, P3)** `Directives/Legacy.pm:157-266`: a bare legacy directive ('# HARNESS-META' with no args) corrupts the result tree and dies 'Not a HASH reference' (location stripped by TestFile's _clean_err) instead of a clear 'directive requires arguments'. **(46, P3)** `Legacy.pm:112-129`: warnings count only directive lines, so diagnostics point at the wrong file line. **(47, P3)** `Util.pm:275-279, 334-338`: maybe_open_file/maybe_read_file TOCTOU — deletion between -f and open confesses instead of returning undef, killing a polling reader at teardown. **(48, P3)** `Util/File/Value.pm:10-13`: init skips SUPER::init — required-name check and fh arg bypassed (hardening; keep the deliberate DONE=1). **(42, P2)** `Util/SubReaper.pm:21, 80-90`: FreeBSD SYS_procctl is 544 not 548, so subreaper acquisition always fails on FreeBSD (warning per start; detached collectors reparent to init); DragonFly is doubly wrong (SYS_procctl 536 — 548 is wait6 — and different REAP cmd constants).

**Steps.**
1. (44) Have bounded consumers (stream_json_l_file, Finder rerun, failed/times/speedtag) `set_done(1)` before polling static files (or treat EOF on a non-tailing read as done); warn when a poll ends holding a partial line.
2. (45/46) In `_record`, validate args per directive before building dotted paths (warn `_at` and skip on missing key/value/feature); make _set/_append croak clearly on empty path segments; feed every scanned header line to the Legacy parser (as TestFile already does for HARNESS2) so line_no matches file lines. Fold into cleanup #85's dispatch-table rework.
3. (47) Attempt the open directly, returning undef only on ENOENT/ESTALE (keep confess otherwise); keep the -f check plus ENOENT-undef for the IO::Uncompress branch.
4. (48) `$self->SUPER::init(); $self->{+DONE} = 1;`; audit sibling subclasses (JSON.pm, JSONL.pm) for the same pattern.
5. (42) Set SYS_procctl_FREEBSD = 544; drop 'dragonfly' from the OS match (or table its own syscall number AND cmd constants) so it reports unsupported instead of false-positive.
6. Regression tests: newline-less JSONL final record read by rerun/failed; bare-META fixture produces the clear per-file diagnostic at the right line; maybe_open of a racing-deleted file returns undef.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); regression tests green; #28's 40-subreaper-behavior.t (or a CPAN-testers FreeBSD box) confirms subreaper acquisition post-fix.

### #155 — Tester.pm wait loop: integer sleep(0) busy-spin + TERM-only timeout recovery with no KILL escalation

**Status:** Proposed (bug audit 2026-07-01, severity P2, effort S) · **Step:** BUG-14 · **Depends:** — (audit findings 10, 61)

**Problem.** Test-infrastructure only (Tester.pm drives the t/ self-tests), but it burns the suite. **(10, P2)** `App/Yath2/Tester.pm:199-221`: the capture wait loop's `sleep 0.02` is core integer sleep(0) — every yath() call spins at 100% CPU for the child's lifetime; under `-j16` that is up to 16 cores of pure polling competing with the children being waited on (bounded by the 120s YATH_TESTER_TIMEOUT). Violates the recorded sub-second-sleep convention. **(61, P2)** `Tester.pm:208-215`: timeout recovery sends TERM then blocks in `waitpid($pid, 0)` — a wedged yath child that forwards/absorbs TERM converts the timeout into an infinite hang of the calling test file.

**Steps.**
1. (10) `use Time::HiRes ();` and `Time::HiRes::sleep(0.02)` in the wait loop (line 216).
2. (61) After kill('TERM', $pid) at line 210, poll `waitpid($pid, WNOHANG)` with Time::HiRes::sleep for a ~5s grace, then kill('KILL', $pid) and a blocking waitpid. Because run_cmd uses `no_set_pgrp => 1`, KILL-to-pid may orphan grandchildren — consider dropping no_set_pgrp or recording the child pgid so `kill(-$pgid)` can sweep the tree (a second TERM would also trip Client's second-signal exit, but KILL is the robust choice for an unkillable-by-TERM runner).
3. Regression: a Tester self-test with a deliberately TERM-ignoring child reaps within the grace window; spot-check suite CPU (the -j16 run should show the parent poller off the top of `top`).

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); suite wall time not regressed (expected improvement under -j16).

### #156 — Dead-seam cross-refs: Util::Queue dead code + Stream.pm transposed seek (execute via cleanup #83)

**Status:** Proposed (bug audit 2026-07-01, severity P3, effort S) · **Step:** BUG-14 · **Depends:** cleanup #83 (Util::* dead modules — already prescribes both fixes) (gap findings G0, G1)

**Problem.** Both gap findings are latent and ALREADY tracked inside cleanup **#83**; this ticket exists so the audit trail lands somewhere and #83's execution covers them deliberately. **(G0)** `Util/Queue.pm` is dead code on 2.0d: `Runner.pm:14`, `run.pm:10`, `stop.pm:12` only `use` it (never instantiate — the live queue seam is socket-based; `Runner.pm:452` confirms no queue.jsonl), and `t/unit/App/Yath2/RunPlan.t:7` merely loads it — yet the module ships with POD advertising a multi-process contract whose latent races would be re-armed by any future consumer following its SYNOPSIS. Scope caveat: Queue IS still instantiated in stale worktrees (worktrees/collectors-everywhere, .claude/worktrees/*) — delete on 2.0d only, leave worktrees alone. **(G1)** `Util/File/Stream.pm:80`: `seek($fh,2,0)` transposes POSITION/WHENCE — absolute offset 2, not SEEK_END — masked today only by '>>' open modes; a misleading landmine for any future edit (note line 9 imports only SEEK_SET, so a keep-the-seek fix must add SEEK_END to the import; deletion is preferred per #83).

**Steps.**
1. Execute cleanup #83: delete `lib/Test2/Harness2/Util/Queue.pm` plus the four dead `use` sites (Runner.pm:14, run.pm:10, stop.pm:12, RunPlan.t:7), and delete Stream.pm:80 (comment that '>>' guarantees appends) as part of #83's Stream.pm cleanup.
2. Confirm no non-worktree consumer remains: `grep -rn 'Queue->new\|Util::Queue' lib t` clean after the delete.

Verify: both canonical runners green (`AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` **and** `AUTHOR_TESTING=1 yath test -D -j16`); grep shows no Util::Queue references outside reference/ and worktrees; Stream.pm has no transposed seek.

---

## Explicitly justified — do NOT cut

Load-bearing, all auditors agree: the unified `Role::Service`/`Connection` framing
layer; `Runner::Subscriber` parking deltas until after the snapshot;
`Runner::Monitor`'s render mirror; `stop_preload_root` not killing the collector
parent (the ChildMonitor fallback); the `no_reply`/`drain_input` fix (#9 — dedup, not
delete). Known migration gaps (not bloat): pfile discovery (ch12), `yath spawn`
(ch13), system-load (ch7), run-scoped stages.
