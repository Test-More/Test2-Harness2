# IPC / Service Loop / Shared-State Bloat Audit — Consolidated

This document merges four independent audits (Gemini, GPT, Opus, Sonnet) of the
IPC layer, service loops, and shared scheduling state in `Test2-Harness2`. Each
finding below notes **which auditors flagged it** (consensus is a rough
confidence signal), explains the bloat, and proposes a simpler shape.

The overarching pattern all four agree on: the migration from file-based IPC
(`dispatch.jsonl` / locks / polling) to socket RPC succeeded, but the **chunk-19
preload-root work** added several overlapping defenses against one underlying
condition ("reports/channels from a dead-or-replaced preload-root incarnation"),
and a number of dispatch-file-era fossils were left in place as no-ops rather
than removed.

After each finding there is a **> Response:** block for you to fill in with what
to do (if anything).

---

## TIER 1 — Strong consensus, behavior-preserving dead weight

### 1. `poll()` no-op + `_enqueue`/`%ACTIONS` indirection (dispatch-file fossil)
**Flagged by: Gemini, GPT, Opus, Sonnet (all four)**
**Files:** `Runner/State.pm`, `Runner/Role/Scheduler.pm`

`sub poll { return }` is a no-op still called from `run`, `done`, `next_task`,
`advance`, `truncate`, and `scheduler_tick` (~6 sites). It was meaningful when
State read `dispatch.jsonl`; that path is gone.

Layered on top: every public action routes `public method → _enqueue($action,
$item) → %ACTIONS{$action}->($self, ...) → _do_$action`. All callers are
in-process now; there is no serialization or deferred execution. Two hops carry
zero information and defeat grep (you can't find `_do_queue_run` by searching
`queue_run`). Opus also notes `$$` is threaded as a bogus "pid" through every
action — only `_stage_ready` reads it, and it stores the *runner's own* pid as
the stage's "readiness pid", making `StatusReport`'s advertised stage-pid field
false.

**Simpler:** Delete `poll` + its call sites, delete `_enqueue`/`%ACTIONS`, call
the `_do_*` methods directly. Make stage readiness a plain boolean and drop the
`$$` arg. (~40 lines + ~6 call sites; the single biggest safe win.)

> Response:

**Fix.** Confirmed against the code — three pieces, all verified:

1. **Delete `poll`** (State.pm:238) and its 6 no-op call sites (`run` 106, `done`
   113, `next_task` 152, `advance` 204, `truncate` 256, `Scheduler.pm:103`).
2. **Delete `_enqueue` + `%ACTIONS`** (214-250). Each public mutator calls its
   `_*` impl directly (`stage_ready` → `_stage_ready`, etc.) — restores grep-ability.
3. **Delete the bogus `$$` thread.** `_enqueue` passes `$$` to every handler; only
   `_stage_ready` read it, storing the *runner's own* pid as the stage "readiness
   pid" (and `_set_stage_lifecycle` got the same `$$` — so the lifecycle pid was
   bogus too). After this, **State stores no pid at all**; `_stage_ready` keeps
   only `{stage, generation}`.
4. Fold-in (Opus SS-10): `truncate` (252) — the real work is the `halt_run` loop;
   the `_enqueue(truncate)` → empty `_truncate` (259) + its `poll` are vestigial.
   Delete `_truncate` and the enqueue, keep the halt loop.

**The stage pid is recovered properly — as a connection property, not message
data (decided in discussion).** Enforce that every end of a socket connection
announces its pid in the handshake:

- `Connection::send_identity` (Connection.pm:192-195) sends
  `{identity => {name => ..., pid => $$}}`; the receive path (299-313) stores
  `IDENTITY_PID`; add a `peer_pid` accessor. The Role's `service_peers` map then
  carries every peer's pid for free (`$conn->peer_pid`) — `preload-<stage>`,
  `preload-root`, collectors, command clients.
- `no_reply` collector reporters announce identity via the recorder *preamble*
  (Runner.pm:1043, Plugin.pm, Preloader.pm, Job.pm), so add `pid => $$` there too
  — same call sites IP-3 (#9) folds into a `collector_reporter_args($identity)`
  helper; do it as part of that.
- `yath status` shows each **connected (up)** stage's real pid, read from its
  `preload-<stage>` peer connection. A down/restarting stage has no connection
  (peer removed on EOF, Role/Service.pm:419-421) and therefore no pid — correct:
  a down stage has no pid. `StatusReport` (currently takes only `state`) also
  takes the peer-pid view from the runner.

**Boundary:** item 1 is the mechanical removal + the handshake-pid mechanism. The
stage-state *representation* (readiness vs lifecycle convergence, and where the
pid is surfaced in status) is item #2's call; #2 consumes the `peer_pid` from the
connection rather than storing a pid in State.

---

### 2. `STAGE_LIFECYCLE` parallel to `STAGE_READINESS` (duplicate state)
**Flagged by: GPT, Opus, Sonnet**
**Files:** `Runner/State.pm`, `Runner/StatusReport.pm`, `App/Yath2/Command/status.pm`, `Handlers.pm`

Two structures describe the same facts. `STAGE_READINESS` is `{stage => pid}`
(pid = up); `STAGE_LIFECYCLE` is `{stage => {state, generation, pid, stamp}}`.
Every lifecycle transition must update both. Opus verified by grep that
`STAGE_LIFECYCLE`'s **only** readers are `StatusReport.pm` + `status.pm` —
nothing in scheduler/dispatch/recovery reads it. The `restarting`-vs-`down`
distinction is never acted on by any logic; both just clear the readiness gate.
The whole `stage_restarting` action verb + handler + 3rd State method + wire
report exist only to print "restarting" instead of "down" in a status column.

**Simpler:** Make one structure canonical and derive the other. Either keep
lifecycle and derive readiness (`up` = ready), or keep readiness and derive the
status label. Preserve the `yath status` output either way.

> Response:

Converge on only one state, prefer the one with more information. `yath status`
can be updated to reflect any additional states, exact behavior does not need
to be preserved, `yath status` is intended for humans to see the current state
of things, more information is an improvement, not a bug. Store state only
once, and we probably do not need to derive the lossy state, just use the
richer state in the status.

**Refined plan (discussion):**

Converge on the single richer structure (`STAGE_LIFECYCLE`); delete
`STAGE_READINESS` entirely. It was a redundant truthy-`up` view — the comment at
State.pm:546-552 admits it ("the gate behavior is unchanged, only the label is
richer"). Both are written on every transition (587-588, 604-605, 625-626).

- **Scheduler gate** reads lifecycle: `_stage_order` (891) and `spawn_stage_ready`
  (369) dispatch iff `state eq 'up'`.
- **No pid in State** (per #1): `_set_stage_lifecycle` drops its pid param;
  lifecycle = `{state, stamp, generation}`. `yath status` merges the real pid from
  the peer connection (`$conn->peer_pid`), not from State.
- **`StatusReport`** drops the `stage_readiness` key, returns `stage_lifecycle` +
  peer pids; `status.pm` (61-62) and `ps.pm` (41) read lifecycle. Back-compat of
  the status shape is not preserved (intended — richer is better).
- **Free fold-in:** once #1 removes `_enqueue`, the stage methods take plain
  `($stage, $generation)` args, so `_stage_action_parts` (570-574) and its dead
  "bare-string caller" branch (Opus SL-3) get deleted outright.

**The states are functional, not cosmetic** — they are the substrate for a future
**preload Resource** (NOT implemented yet — only `JobCount` + `SharedJobSlots`
exist; neither consumes stage state). That resource will map stage state onto the
existing tri-state `Resource::available()` contract (Resource.pm:386-397):

| State | Meaning | future `available()` |
|-------|---------|----------------------|
| `starting` | known/committed (in reported stage map), not yet reported ready | false/0 — wait |
| `up` | reported ready, dispatchable | positive — available |
| `restarting` | temporarily down, coming back (reload/respawn) | false/0 — wait |
| `down` | permanently gone, not coming back | negative — skip |

**Implement all four states now**, including `down` — but `down` has **no setter
yet** (left unreachable on purpose; its triggers are future error conditions we
have not defined, certain to be needed).

- **Add `starting`**: set when the runner learns a stage will exist
  (`set_stage_data` / reported stage map) but before `stage_ready` arrives.
  Currently that is the implicit "absent from readiness" case; make it explicit so
  the future resource can say "hold the task" vs "skip it."
- The current non-reload stage exit (`stage_down` at Runner.pm:1458-1463) maps to
  **`restarting`**, not `down` — at wind-down the run is ending (state is reset via
  `reset_stage_lifecycle` anyway) and in a persistent runner the stage respawns for
  the next run. This keeps `down` reserved/unreachable as intended.
- The reload exit already maps to `restarting` (Runner.pm:1457) — unchanged.

The preload Resource itself is a follow-up, not part of this cleanup; item #2 is:
converge to one structure + add `starting` + define `down` (no setter) + map the
current non-reload exit to `restarting` + surface real pid from the connection.

---

### 3. Stale-incarnation defense is built three times over (chunk-19 core)
**Flagged by: GPT, Opus, Sonnet** (Opus/GPT call this the headline finding)
**Files:** `Runner.pm`, `Handlers.pm`, `Preload.pm`, `Runner/Stage.pm`

When the preload-root dies mid-run, the runner eagerly drops channels of stages
that are *themselves still alive and still have work to report*. Three
overlapping mechanisms were added to cope:

1. **Generation stamping** (`e74e8402f`) — monotonic counter threaded through
   handshake → `Preload.pm` → every `stage_ready/down/restarting` report →
   `_stale_stage_generation` on receipt. **But it does not guard job-outcome
   reports** (`stop_task`, `retry_task`, `job_pid`, `reload`, `halt`).
2. **Busy-channel retention** (`1f4ad24ad`) — `_drop_preload_peers` computes a
   `%busy` set from running tasks and refuses to drop a `preload-<stage>` peer
   with an in-flight job — needed *only because* defense #1 skipped job reports.
   (Opus: the `m/^preload-(.+)$/` regex also runs twice per peer.)
3. **`STAGE_LIFECYCLE`** (see #2 above) — the parallel record.

Root-cause framing (all three agree): the orphaned stages are independently
alive — their collectors watch the real runner, not the dead root. So the
correct small fix is **on preload-root death, drop only the `preload-root` peer;
let orphaned stages report their in-flight results and be reaped naturally.**

**Simpler:** Pick *one* mechanism. Best: make job-outcome messages
self-validating (carry `stage` + `preload_generation`, validate against the
task's recorded assignment), then drop **all** stale peers on root restart. That
removes the `%busy` special-case and most of the generation plumbing. GPT and
Opus both note an alternative: just don't drop live stages' channels, so the
race never arises.

> Response:

Simplify this as much as possible. I like avoiding the race altogether, do not
drop live channels. Also I think we need to add multi-pid watching to
Test2-Collector so that stage collectors can be told to watch both the runner
pid, and all parent pids they have, then they can self-terminate when the
preload root or a parent stage goes away, including sending the 'going down' or
'restarting' etc states before they do. The runner should not need to manage
them beyond initially starting the preload root, it should just need to receive
and track state updates. The preload process tree should manage itself once
started, it already largely does this by spawning the stages, respawning them
when the drop, etc. We just need to add the "terminate if my parent or the root
goes away", and the collector already has that logic, it is just limited to a
single pid.

Edit Test2-Collector so that it supports watching multiple-pids and can
self-terminate (send graceful term/int, then kill if it takes too long) when a
parent goes away. The stages should be written to catch that signal and
immediately finish what they can (update state so they get no more requests,
drain pipes and finish spawning things that were already requested, then exit)

**Refined plan (discussion) — all three defenses collapse into one Role-level
check + collector self-termination. The infrastructure for the clean version
already exists.**

**1. Multi-pid `ChildMonitor` (Test2-Collector).** Today `watch_parent_pid` is a
scalar (ChildMonitor.pm:17); `check_parent` (203-218) polls that one pid and on
death TERMs the child; `escalate_kill` (244-253) already does TERM→KILL after a
grace period; `install_signal_handlers` (65-71) already forwards TERM/INT/QUIT to
the child. Extend `watch_parent_pid` to a **list**: if *any* watched pid is gone,
self-terminate. All the graceful-shutdown machinery is already present — only the
single-pid limit changes.

**2. Stage graceful shutdown.** The stage process catches the forwarded TERM →
stops accepting new requests, drains pipes, finishes already-requested spawns,
reports its state, then exits → socket EOF. **Stage collectors** watch their full
ancestor set (runner + parent stage(s) + preload-root).

**3. Runner stops managing stage lifecycle.** Delete `_drop_preload_peers` + the
`%busy` retention (Runner.pm:884-905). The runner never drops live channels —
stages drop themselves on ancestor death and EOF removes the peer
(Role/Service.pm:419-421, already done). The runner only: starts the
preload-root, receives state updates, tracks them.

**4. Generation stamping → connection-currency (A: agreed — delete the whole
app-level mechanism).** `handle_request($payload, $conn)` (Role/Service.pm:273)
**already passes the source connection** to handlers; the stage handlers just
ignore it and call `_stale_stage_generation($payload)` instead. Replace that with
a connection-currency check: honor a stage report only if `$conn` is the
connection *currently registered* as the `preload-<stage>` peer. A superseded
incarnation's late `stage_down` arrives on its *old* connection (no longer current
in `service_peers`) and is dropped. **The connection is the generation.** Delete
`PRELOAD_ROOT_GENERATION` threading (handshake → `Preload.pm` → reports), the
per-report `generation` field, and `_stale_stage_generation`. Uses `$conn`
(already passed) + the peer map (already maintained) + `peer_pid` (from #1).

**Decisions:**

- **(B) Preload-root death = test failure; the runner does NOT respawn it.** On
  preload-root **crash / unexpected exit**, the runner sees the `preload-root`
  peer EOF and **fails the run** (keep `_emit_preload_failure_output` for the
  diagnostic). Delete the runner-side crash-respawn apparatus (PR-1): the respawn
  budget (`preload_root_respawn_limit`), `_handle_dead_preload_root`'s respawn
  branch, `_reset_preload_root_state`, the `$st eq 'respawn'` path in
  `run_scheduler_only` (Runner.pm:1296-1300) — and `PRELOAD_ROOT_GENERATION` goes
  with it (already removed by A). **HUP reload is the only restart**, and the
  preload-root does it to *itself* via `exec()` (its existing `setjump 'preload-root'`
  + `'respawn'` exec, Preload.pm:137/148-151), triggered by the forwarded HUP
  (item #4). The runner never restarts the preload-root.
  - Mechanical note: `exec()` keeps the **same pid**, so a HUP self-restart does
    *not* trip the stages' parent-watch (root pid unchanged). The preload-root
    therefore TERMs its own stages before exec → they report `restarting` → exit →
    the post-exec root respawns them fresh. **Multi-pid watch is the crash
    backstop; HUP reload is orchestrated by the root**, not by the watchers.

- **(C) Test-job collectors watch the runner only** (Preloader.pm:257) — a forked
  test job does not care about its stage once forked, and is not killed when the
  stage exits. Only **stage** collectors get multi-pid ancestor watching.

- **(D) On ancestor-death / orchestrated teardown a stage reports `restarting`**
  (item #2: temporarily unavailable, coming back). The permanent `down` state
  stays unreachable for now (item #2). The crash path (B) aborts the whole run, so
  whatever a dying stage reports there is moot — the runner tears down on root EOF.

**Scope:** this spans Test2-Collector (multi-pid watch — user authorized) and the
runner/service layer (connection-currency, delete `%busy`/generation/PR-1). It
subsumes #3's "pick one mechanism" by removing all three. Sequence after #1
(peer_pid) and #2 (lifecycle states) land, since it consumes both.

**Prerequisite — a `requeue_task` primitive (immediate, blocks this work).** Once
stages self-terminate (multi-pid watch), a stage going `restarting` mid-run is
**normal**. But today, if a stage is gone at dispatch, `dispatch_pending`
(Runner.pm:1211-1217) calls `watchdog->abort_job` and the job is announced
`aborted` (**failed**) — there is no requeue-without-retry path (`retry_task`
consumes an attempt; the task is already pulled to RUNNING with its slot
consumed). So self-restart would wrongly **fail** any job that was `assign`ed to a
stage but not yet launched when the stage restarts.

Add a `requeue_task` primitive: **RUNNING → PENDING, release slot/resources, no
retry consumed** — the job re-resolves and re-dispatches on a later tick once the
stage is `up` again. Call it at the dispatch-stage-gone path instead of
`abort_job`. This is distinct from `retry_task` (test-level failure, counts
attempts) and `abort_job` (real give-up): it means "the stage wasn't ready, try
again later, cost-free." Required before stages self-terminate, and reused by the
long-term preload resource below.

**Dispatch-success + requeue safety (GPT review — must fix first).** `requeue_task`
is only safe **before** a stage has accepted the job; after the stage forks it, the
collector result owns completion and requeueing would **duplicate-run** the test.
Two preconditions:
- **`service_send` must reliably report failure.** Today it returns the request id
  from `send_request` even if the underlying `_write` closed the connection, so a
  failed dispatch can look truthy and get announced `dispatched`. Fix the contract:
  `service_send` returns **false** on no-peer or write failure.
- **"Accepted" is an explicit stage ack, not a successful write** (decided). The
  stage sends an **ack** before the runner announces `dispatched`; requeue is
  permitted only until that ack arrives. After ack/fork → never requeue, the
  collector owns the outcome.

**`requeue_task` state contract (specify + test):** reuse the **same `job_id` and
try number** (it is not a retry); **clear the assigned `stage`** before returning to
PENDING (so it re-resolves against the current map); **delete any recorded
`job_pids` entry**; call the resource **`release`** (and a fresh `assign`/`record` on
re-dispatch); emit **no** `done`/`aborted` subscriber transition (emit a `requeued`
mutation or nothing, not a terminal one); and **clear the task's `SORTED` bucket
memo** so the reinserted task re-sorts (ties to #13's clear-on-add).

**Long-term — preload becomes a scheduler Resource (§4.7a / MIGRATION chunk 11).**
This whole stage-availability + file→stage area stops being a direct scheduler
component and becomes the **preload resource**: `available($task)` is tri-state
over the stage lifecycle (`1` = `up`; `0` = `starting`/`restarting`; `-1` = `down`
permanent → skip/fail); `assign` records the resolved stage on the job (none for
no-preload); `release` is ~a no-op (preload is unbounded); and the assign→launch
race uses the **same `requeue_task`** primitive. The file→stage **resolver** (#10)
folds into this resource's best-fit selection. So the connection-currency +
self-termination work here is the runtime substrate; the resource is the scheduler-
facing API that consumes the `starting`/`up`/`restarting`/`down` states (#2) on top
of it. (See ARCHITECTURE.md §4.7/§4.7a, MIGRATION chunks 10/11.)

---

### 4. Dual preload architecture + lying "DORMANT" comments
**Flagged by: Opus, Sonnet** (Gemini/GPT touch related pieces)
**Files:** `Runner.pm`, `Runner/State.pm`, `Handlers.pm`, `Preloader.pm`

`spawn_preload_root` sets `PRELOAD_ROOT_HOSTS = 1` unconditionally and runs
whenever any preloads exist. So the **new scheduler-only path**
(`run_scheduler_only`, dispatch over sockets) is live for every preload run, and
the **old in-runner stage-forking path** (`Preloader::_preload_stages`,
`launch_stage`, the `setjump "Stage-Runner"` loop, the stage-relaunch in
`set_proc_exit`, the `else` branches in `dispatch_pending`) is unreachable
whenever stages exist.

Yet ~5 comment blocks still say "DORMANT until 19.3" / "NOT YET TRIGGERED" even
though the flip already happened (code at `Runner.pm:1062` is literally labeled
"the atomic flip"). Sonnet frames the same thing from the other side:
`_preload_root_hosts_stages` is described as always-false scaffolding — both
auditors agree the gate state is confusing; they disagree only on *which* branch
is dead. **Resolve which is true first**, then either delete the dead path
(several hundred lines) or honestly document the live fallback. A comment that
tells a maintainer live code is dead is worse than no comment.

This second kept-warm architecture is the structural reason the crash-recovery
scaffolding in #3 is so heavy.

> Response:

**Resolved (code verified): the flip already happened — Opus is right, Sonnet was
wrong, and Sonnet was wrong *because it believed the stale comment*.** That is
the clearest possible proof the lying comments cause real harm, so they go first.

Verification chain: `_preload_root_wanted` (Runner.pm:646) is true whenever
preloads are configured (above threshold); line 499 calls `spawn_preload_root`,
which runs *in the runner-root* and sets `PRELOAD_ROOT_HOSTS = 1` at
Runner.pm:1071; `_preload_root_hosts_stages` (667) then returns 1. Named stages
only exist when preloads exist, so for every staged run the gate is **true** and
`run_tests` returns into `run_scheduler_only` (1233). The DORMANT comments
(661-665, 1176-1178, 1230-1232, 1266-1273, 182-191) were written in 19.2b before
the 19.3 flip wired line 1071 and never updated.

**It is NOT "one whole architecture is dead."** Both `run_tests` legs are
reachable, for different run types:
- **Preload runs** → scheduler-only main runner; preload-root hosts every stage.
- **No-preload / below-threshold runs** → the in-runner `run_stage` path (the
  base/no-preload job-running path).

What is genuinely dead is the in-runner **named-stage hosting** machinery
(`launch_stage` forking named stages, `_stage_transition_reporter`, the
stage-relaunch in `set_proc_exit`) — named stages now always route through the
preload-root.

**Actions, in order:**

1. **Fix the comments first** (cheap, high-value — they are actively producing
   wrong audits *right now*). Rewrite 661-665 etc. to state the gate is live for
   preload runs; delete the "DORMANT/NOT YET TRIGGERED" claims.

2. **Split job launch by preload-ness, and remove restart from the runner
   entirely.** Root insight (decided in discussion): *the only reason the runner
   was ever restartable is preloads, and post-flip no preloads live in the
   runner.* Therefore:
   - **No-preload job launch becomes plain fork+exec under a collector** — the
     collector forks and exec's the test file. No `goto::file`, no `Long::Jump`,
     no BEGIN. (The runner is already a normal command sub, not a BEGIN process —
     only the preload-root bootstraps in BEGIN via `-MPreload=launch`.)
   - **`goto::file` + `Long::Jump` leave the main runner completely.** They are
     needed only to run a test *in-process inside a preloaded interpreter*, which
     now happens solely in the preload tree (`Preload.pm`, `JobLauncher.pm`).
   - **Delete the runner's self-restart:** the `setjump "Test-Runner"` frame
     (runner.pm:74) and its `$action` dispatch (119-137), `respawn_runner_callback`
     (runner.pm:102), the `'respawn'` exec branch (121-127), the
     `RESPAWN_RUNNER_CALLBACK` plumbing (Runner.pm:62, 1608), and the respawn
     trigger in `end_test_loop` (1607-1610). Verified the main runner's respawn is
     either unreachable (preload runs are scheduler-only — `run_scheduler_only`'s
     loop never calls `end_test_loop`) or vestigial (no-preload HUP has nothing
     preloaded to reload).

3. **HUP becomes a pure forward.** On SIGHUP the runner does **nothing on its own**
   except `service_send('preload-root', 'reload')` and continue. No `SIGNAL=HUP`,
   no winddown, no exec. The preload-root already owns reload (its own
   `setjump 'preload-root'` + `'respawn'` exec at Preload.pm:137/148-151, driven by
   `respawn_runner_callback` at Preload.pm:268); the forward just triggers that
   existing path (e.g. a `request_handler_reload` that sets the stage-host's
   `SIGNAL=HUP`) instead of `preloader->check`. On a no-preload run there is no
   preload-root, so HUP is a harmless no-op — nothing is preloaded, nothing to
   reload.

Net result: restart/reload is wholly a **preload-tree** property. The main runner
holds no preloaded state, runs no test in-process, and cannot restart itself — it
only schedules, dispatches, and relays HUP. `goto::file`/`Long::Jump`/BEGIN
become exclusively preload-tree concerns. Then do the §#3 work (preload tree
self-manages via multi-pid collector watching) on top of this cleaner base.

(Minor: confirm `yath start`/persistent-daemon docs don't advertise HUP-reload as
a user feature for *no-preload* daemons before dropping no-preload self-restart —
defensible behavior change, worth a one-line note if so.)

---

### 5. SharedJobSlots: dead internals + a real loader bug
**Flagged by: GPT, Opus, Sonnet**
**Files:** `Runner/Resource/SharedJobSlots/State.pm`, `.../Config.pm`, `SharedJobSlots.pm`

Cluster of grep-verified dead weight plus one genuine bug:
- **`transaction` carries a never-read reentrancy `stack`** — no callback ever
  re-enters `transaction`, so the nested branch is dead and `stack` is written
  but never read. Collapse to lock → read → cb → (write?) → unlock.
- **`_clear_old_registrations` runs twice per write txn** (before *and* after the
  callback). The pre-sweep `kill(0)`-probes every runner pointlessly. Drop the
  pre-callback call.
- **Dead declarations:** `state_fh`, `ready_assignments` (never read), `SEEK_END`
  (imported, unused), `carp` (imported, never called).
- **`default_slots_per_run`/`default_slots_per_job`** plumbed three layers deep
  (`Config.pm` → `SharedJobSlots.pm` → `State.pm`), never read inside State.
- **Real bug:** the custom-algorithm path calls `mod2file($mod)` but the module
  imports only `find_in_updir` from `Test2::Harness2::Util` — `mod2file` is not
  imported. Custom shared-slot algorithms would die on load. Import it.
- Tests assert internal `stack`/transaction implementation details; switch them
  to assert behavior (nested read/write effects, rollback, final persisted state).

> Response:

**Delete SharedJobSlots completely.** It will be replaced later by a system-usage
resource; none of the dead-internals / loader-bug cleanup above is worth doing on
code that is being removed. (For the record, all the audit claims verified: dead
`state_fh`/`ready_assignments`/`SEEK_END`/`carp`/never-read `stack`,
unread-in-State `default_slots_per_*`, and the real `mod2file` bug at Config.pm:123
— moot now.)

**Remove (grep-verified integration points):**

- The modules: `Runner/Resource/SharedJobSlots.pm`, `.../SharedJobSlots/State.pm`,
  `.../SharedJobSlots/Config.pm` (the whole `SharedJobSlots/` dir).
- Its unit test(s): `t/.../Runner/Resource/SharedJobSlots/State.t`.
- Option wiring: `App/Yath2/Options/Runner.pm:581-607` (the shared-config probe
  that auto-`unshift`es the resource) plus the shared-slots option definitions it
  reads.
- The `resources` command branch: `App/Yath2/Command/resources.pm:55-56+`.
- Reference cleanup: `Runner.pm:219` (comment), and the mentions in
  `Command/test.pm`, `Command/projects.pm`, `Command/start.pm`,
  `Schema/RunProcessor.pm` (confirm each is only option/config plumbing, not a hard
  dependency, as part of removal).

**Feature note:** SharedJobSlots is the cross-runner shared-slot coordinator
(multiple yath runners on one host sharing a slot budget via a locked state file).
Deleting it removes multi-runner slot coordination until the system-usage resource
lands. Single-runner job limiting is unaffected — that is `JobCount`, which stays.

---

### 6. Dead `wait()` parameters in the IPC hot loop
**Flagged by: Opus, Sonnet**
**Files:** `IPC.pm`

`wait()` accepts `all`, `cat`, `all_cat`, `block`, `timeout`. Every caller passes
only `all`, `timeout`, or nothing. The unused `cat`/`all_cat`/`block` branches
drive a meaningful chunk of `wait`'s dispatch complexity in the hottest loop in
the system, making it look like a general scheduler when it is only "reap
non-blocking" or "block until all."

**Simpler:** Drop the unused params (+ matching POD), or split into
`wait_one(block, timeout)` / `wait_all(cat)`. Add a test if any path is kept as
public API.

> Response:

**Delete `cat` / `all_cat` / `block` (+ their POD).** Verified all four call sites
pass only `all`, `timeout`, or nothing (IPC.pm:77, Runner.pm:406/1446/1486); the
three params are dead.

**Why they exist (1.0 archaeology):** they were scheduling primitives from when the
runner drove dispatch by waiting on category-scoped child exits. Three categories
existed — `default` (IPC::Process), `job` (Runner::Job), `stage`
(Runner::Preloader::Stage). `wait(cat=>'job')` *was* the run-loop throttle ("block
until a job slot frees, then dispatch the next"); `wait(all_cat=>'stage')` was the
stage-teardown barrier; `block` was block-until-any-progress.

2.0 removed every consumer: scheduling is now an in-process **tick** loop fed by
**socket** state reports (`stop_task`/`retry_task`), not block-by-category waits;
tests run under **collectors** that reap the test and report completion over the
socket; and the `stage` category only applied to the in-runner stage path that #4
deletes. **Reaping went from a scheduling signal to mere zombie cleanup** — so the
only two `wait()` modes still needed are non-blocking reap each tick (drain
zombies) and `wait(all=>1)` at teardown (barrier before exit). Neither needs
categories or block-until-progress.

**Result:** drop the `$cat_total` bookkeeping + the `if (my $cat = …)` block in
`wait()`, and the `all_cat`/`block`/`cat` branches in `_wait_done`, leaving:

```perl
sub _wait_done {
    my ($self, $found, $start, $params) = @_;
    my $all = keys %{$self->{+PROCS}};
    return 1 unless $all;                                          # nothing left
    return 1 if $params->{timeout} && time - $start >= $params->{timeout};
    return 0 if $params->{all};                                   # 'all' mode, procs remain
    return 1;                                                      # default single-pass
}
```

`wait()` collapses from "looks like a general scheduler" to its two real modes.
(`PROCS_BY_CAT` itself stays only if something else still reads it — check during
removal; if `cat` was its sole consumer, drop it too.)

---

### 7. Misc verified dead lines / fossils
**Flagged by: Opus (verified), Gemini, Sonnet**
**Files:** various

Small, individually-safe removals:
- **Duplicate `IN_MOVE_SELF` mask line** — identical line twice in
  `Reloader.pm:20-21`; second is a copy-paste no-op. *(Opus, verified)*
- **Broken FIFO retry loop** — `JobLauncher.pm:32-39`: `die` on iteration 1 makes
  the `sleep 1` and the rest of `for (1..10)` unreachable, then a redundant `die`
  after. Either a botched backoff-retry or a pointless loop. *(Opus, verified)*
- **`_redistribute_first`'s `$c` counter** incremented but never read.
  *(Opus SS-9)*
- **Unused `use Atomic::Pipe`** in `App/Yath2/Renderer/DB.pm:14` — leftover; the
  module uses `Consumer::NonBlock`. *(Gemini)*
- **Dead `DepTracer` callbacks** — `add_callback`/`add_callbacks` stash
  `{+CALLBACKS}` that the `my_inc`/`MY_REQUIRE` hook never reads or fires.
  Registration is dead code. *(Gemini)*
- **Dead `reap_children`** in `Role/Service.pm` — `Runner` overrides it to a
  no-op (reaps via IPC), and `Preload.pm` drives its own `service_io` and never
  calls the role's `run()`. Never executed on any live path. *(Gemini)*

> Response:

Mixed bag — two trivial deletes, one moot, one reframed as a rewrite, one false
positive, and one bigger-than-flagged delete. Verified each:

**7a — delete.** Reloader.pm:21 duplicate `$MASK |= IN_MOVE_SELF()` (identical to
line 20, no-op). Trivial.

**7d — delete.** Renderer/DB.pm:14 `use Atomic::Pipe` unused (module uses
`Consumer::NonBlock`, lines 11/111). Trivial.

**7c — moot.** The unread `$c` counter lives in `SharedJobSlots/State.pm`, which
#5 deletes wholesale. Gone with #5.

**7b — do NOT patch the retry; replace the whole feature.** The broken FIFO open-
retry is part of **interactive mode** (`--interactive`: connect the `yath test`/
`yath run` *client* IO to each test). The current impl is a FIFO IO-proxy
(`POSIX::mkfifo` + pump STDIN through the pipe + re-open the test's STDIN from the
fifo in a `goto::file` filter patch). This is slated for rewrite to **socket-shared
IO**, reusing the `yath spawn` mechanism (the launcher `dup2`s an accepted socket
fd onto the test's STDIN/STDOUT/STDERR; the client streams its terminal IO over the
socket — a real shared FD/TTY, correct for debuggers, not a byte proxy). Interactive
forces `-j1`, so one test owns the client IO at a time. **Tracked now so it is not
dropped: MIGRATION.md chunk 20 + ARCHITECTURE.md §4.10.** The broken retry is moot —
the code goes away.

**7e — REJECT (false positive). Keep, no change.** The `watch $file => sub{}` /
`add_callback` preload-DSL hook is **live**: it registers a custom reload handler,
and `Preloader::_reload_cb_reload` (Preloader.pm:580-595) reads `$dtrace->callbacks`
and **fires the matching callback** (runs it *instead of* the normal symbol reload)
when the watched file changes; wired via `reload_cb` (Preloader.pm:80) → `Reloader`
(Reloader.pm:248). The auditors (and a first-pass grep) only checked the
`@INC`/`require` hook — which records deps and never touches `CALLBACKS` — and
missed the *reload* consumer. The constant-grep also missed it because the read
goes through the lowercase `callbacks` accessor, not the `CALLBACKS` constant.
Nothing to delete. (Worth a one-line comment near `add_callback` pointing at
`_reload_cb_reload` so the next auditor doesn't repeat the mistake.)

**7f — delete (bigger than flagged): the whole Role::Service `run()` is dead, not
just `reap_children`.** Verified `run()` (Role/Service.pm:201-215) has **zero
callers** in-tree; `reap_children` (226-233) is reachable only from `run()`. It is
a **chunk-9 / harness-service-MVP artifact** (added in `ba9bde35a`; reflects the
old `Service`-object-owns-the-loop model from `cce8e2a90`/`cb10c76af`) that the
chunk-19 architecture stranded — the Runner is now the canonical state owner with
its own process loop, and the preload-root drives its own `service_io` loop, so
nothing adopted the role's default loop. Confirming evidence it is not merely
unused but *wrong* for the real consumer: the Runner **overrides `reap_children` to
a no-op** (Runner.pm:207) because the role's `waitpid(-1)` would race the IPC
reaper; and **no consumer implements `service_on_start`/`service_on_stop`/
`service_on_reap`** (grep empty), so those hooks have zero implementors. Delete:
`run()`, `reap_children`, the `service_on_start`/`stop`/`reap` hook plumbing + POD,
the Runner no-op override (Runner.pm:207), and the POD telling consumers to
override it. **Keep `service_tick`** — that one is live, called directly from the
Runner's own loop (the scheduler), not via `run()`.

---

## TIER 2 — Defensible but over-built (consolidate or simplify)

### 8. `_ex_parrots` vanished-process sweep + "die on unmonitored waitpid"
**Flagged by: Gemini, Opus, Sonnet**
**Files:** `IPC.pm`

`_ex_parrots` iterates all monitored PIDs each cycle calling `kill(0)` to detect
processes that vanished without being reaped. In a normal Unix environment
`waitpid(-1, WNOHANG)` already catches terminated children as zombies — the sweep
is a rarely-hit 1.0-era backstop adding syscalls every reap cycle.

Related: `_bring_out_yer_dead` **dies** if `waitpid(-1)` catches an untracked
PID. Gemini notes this forces other subsystems (preload-root pid, plugin
`AUX_PIDS`) to be tracked *outside* `{+PROCS}` with their own bespoke reaping
loops (250-iteration, 50-iteration). If it `next`/`warn`ed instead, those could
live in `{+PROCS}` and use standard cleanup. Sonnet additionally flags the whole
three-pass death detection (`_bring_out_yer_dead` / `_check_if_dead_yet` /
`_ex_parrots`, ~130 lines) as foldable into two passes.

**Simpler:** Demote the "vanished!"/"escaped the wait cycle" warns behind a debug
flag; make unmonitored-waitpid non-fatal; consider deleting the sweep if reaping
is reliable (verify on non-Linux first).

> Response:

**This is bigger than two sweeps — collapse and remove the `Test2::Harness2::IPC`
controller entirely. Tracked as MIGRATION chunk 21 + ARCHITECTURE.md §5.4.**

The audit framed item 8 as "trim the defensive death-detection." The real finding
(from the discussion): the whole IPC *controller* is vestigial in the new
architecture. Collectors + sockets already do what it existed for; what should
remain is **spawn + zombie-reap**, nothing more.

Verified consumer map — the controller (`spawn`/`wait`/`watch`/`killall`/reaping)
has exactly **2** real consumers:
- **Runner** (`use parent IPC`, Runner.pm:38) — manages N children; mostly the
  no-preload in-runner job path.
- **`test.pm` command** (an IPC instance) — manages exactly **one** child, the
  runner process (`spawn`/`wait`×4/`killall`/`procs` alive-check/`stop`). Trivial.

Everything else imports `IPC::Process` (proc value object — `Job`,
`Preloader::Stage` subclass it) or `Util::IPC` (`run_cmd`/`swap_io`/`USE_P_GROUPS`,
the genuine reusable fork-exec primitive), not the controller.

Why it collapses:
- **Results already come over the socket, not the reap.** `Job::set_exit` says so
  outright ("runner bookkeeping only — the job's exit status is recorded by the
  collector"). The preload path gets `stop_task`/`retry_task` over the stage
  socket. Only the no-preload path still schedules off the reap, via
  `Runner::set_proc_exit` (Runner.pm:1624) — and that migrates onto the collector
  socket report to match.
- Once it does, `set_proc_exit` is deleted (its job branch → socket; its stage
  branch is the dead in-runner named-stage path from #4), and with it the whole
  reap-as-scheduling apparatus: `cat`/`all_cat`/`PROCS_BY_CAT` (#6), the
  `_check_if_dead_yet` process-group wait (the runner then reaps only single
  collector pids — the collector owns the test's process group), `_ex_parrots`, and
  the `die`-on-unmonitored (which only existed to be tripped, forcing the
  out-of-`PROCS` preload-root/aux reaping sprawl).

End state:
- **Keep** `Util::IPC` (`run_cmd`/`swap_io`) — real reusable primitive.
- **Keep** `IPC::Process` as a thin value object (drop its exit-tracking once
  collectors own results).
- Runner keeps a minimal `waitpid` zombie-reaper on `Util::IPC`.
- The command inlines its one-child spawn+`waitpid`+signal — no base class.
- Delete the `IPC` controller (`PROCS`/`WAITING`/`PROCS_BY_CAT`, the three-pass
  death detection, `wait`'s cat machinery, `set_proc_exit`, `watch`/`watch_pid`,
  the `die`/`warn` guards).

So the original "demote the warns / make `die` non-fatal" is subsumed: those lines
are deleted, not demoted. The narrow cleanup is unnecessary once the controller is
gone. Sequence after #6 (cat-waits) and the #4 / no-preload-socket-unification land.

---

### 9. `no_reply` / `drain_input` reporter boilerplate (keep the fix, dedup it)
**Flagged by: Gemini, GPT, Opus** (all say: correct fix, do NOT remove)
**Files:** `Connection.pm`, `Plugin.pm`, `Preloader.pm`, `Job.pm`, `Role/Service.pm`

The "reporter identifies first, `no_reply`, `drain_input`, read-before-expire"
machinery is a **correct** fix for a real TCP-RST race (an unread identity-reply
on a one-way reporter's close discards in-flight transitions). Not bloat to
remove — but:
- The boilerplate + its 4-line rationale comment is **copy-pasted across 3 call
  sites** (`Plugin.pm:61`, `Preloader.pm:305`, `Job.pm:331`). Factor into one
  helper (`collector_reporter_args($identity)`), move the rationale to one doc.
- The symmetric handshake means **one-way command submits** (`Runner::Client`)
  still open a two-way handshake and ignore the inbound half, while collector
  reporters use the `no_reply` escape hatch. GPT: either have `Client` drain the
  identity frame once, or let write-only submits use `no_reply`. Add a regression
  test: close a write-only client right after queuing several requests, prove the
  runner receives all of them.
- The `identity_timeout`/`DEADLINE`/`expired` second per-iteration loop is now
  (per the author's own commit) only a backstop for a truly silent peer holding
  an fd — EOF/ECONNRESET largely covers it. Keep, but mark it a backstop and
  don't grow more around it.

Gemini frames the deeper cause: fire-and-forget streams were merged into the same
`Connection` class as interactive RPC peers, which is why `drain_input`/`no_reply`
exist at all.

> Response:

**Agreed — keep the fix, dedup it (pre-decided by #1).** Verified **4** identical
sites (audit said 3), each building the same
`Recorder::Socket->new(paths, preamble=>{identity=>{name, no_reply=>1}}, drain_input=>1)`
with the same ~4-line rationale comment:

- `Runner.pm:1039` (`collector:preload-root`)
- `Runner/Job.pm:319` (`collector:job:$id`, in `_transition_reporter`)
- `Runner/Preloader.pm:293` (`collector:stage:$name`, in `_stage_transition_reporter`)
- `Plugin.pm:59` (`collector:aux:$name`) — **the non-runner site**

**Factor into one standalone function** — `Test2::Harness2::Util::socket_reporter($identity, $socket)`
— that builds the `Recorder::Socket` with `no_reply => 1`, `drain_input => 1`, and
`pid => $$` (the #1 handshake-pid), with the rationale comment in that one place.

Placement detail (important): it must be a **standalone `Util` function, not a
Runner method.** `Test2::Harness2::Plugin` is decoupled from the Runner object — it
has no runner handle and derives `runner.socket` from `$ENV{T2_HARNESS_WORKDIR}`
(Plugin.pm:45-49) — so a Runner method is unreachable there. A plain
`($identity, $socket)` function is callable from all 4 sites, runner or not.

Net:
- Keep `no_reply`/`drain_input`/read-before-expire (load-bearing TCP-RST race fix).
- Dedup 4 sites + the repeated comment into `Util::socket_reporter`.
- Single place `pid => $$` is added to the reporter preamble (#1).
- `identity_timeout` backstop stays but stays marked a backstop (IP-4/#4) — not grown.

---

### 10. `_drop_preload_peers` busy-retention + resolver retry-by-respawn-limit
**Flagged by: GPT, Opus** (overlaps #3)
**Files:** `Runner.pm`, `Handlers.pm`, `Preload.pm`

Two coupling smells in the resolver path:
- `resolve_file_stage()` retries `preload_root_respawn_limit + 1` times — but the
  thing being retried is a stage *resolver peer*, not the preload-root process.
  Wrong dimension: too many stale resolver peers and a live later one is never
  tried; too few and the loop does redundant work.
- `request_preload_sync()` blocks up to 30s pumping the service loop, so
  scheduler + service IO + peer-failure detection + stage assignment all collapse
  into one blocking re-entrant call.

**Simpler:** Build an explicit resolver-candidate list from current `preload-*`
peers; try each once per lookup, excluding failed ones; keep 30s only as a final
per-peer/per-lookup bound; keep the existing result cache.

> Response:

Two parts, both downstream of #3 and the preload-resource plan.

**Part 1 — `_drop_preload_peers` busy-retention: resolved by #3.** Deleted
wholesale there (runner never drops live channels; connection-currency +
multi-pid self-termination replace it). Nothing to do here — see #3.

**Part 2 — resolver retry-by-respawn-limit: immediate fix, forced by #3.** The
resolver lets the scheduler-only runner (no loaded preloader) ask a live preload
**stage** to run the preload's `file_stage` callbacks (`resolve_file_stage` →
`resolve_file_stages` RPC). It is sound; the only bug is the retry bound:
`$attempts = preload_root_respawn_limit + 1` — wrong dimension, and **#3 deletes
`preload_root_respawn_limit`** (runner no longer respawns the root), so the line
loses its basis. Rewrite:
- `_resolver_identity` → return the **list** of live `preload-*` resolver peers.
- `resolve_file_stage` tries **each candidate once**, skipping closed channels;
  bound = candidate count, not a respawn count.
- Keep the **30s per-request** timeout (`request_preload_sync` already bails early
  on channel close) and **cache success only**.
- No resolver up right now → return `undef` and let the **scheduler tick retry**
  next pass (cleaner than an inline retry loop).

**Long-term — the resolver folds into the preload Resource (§4.7a / chunk 11).**
This file→stage logic should not stay a direct scheduler component. It becomes the
preload resource's best-fit stage selection, with `available($task)` tri-state over
the stage lifecycle (`1`=`up`, `0`=`starting`/`restarting`, `-1`=`down` permanent),
`assign` recording the stage, `release` ~a no-op, and the assign→launch race
handled by the **`requeue_task`** primitive (see #3). So the immediate retry-bound
fix is interim — keep the resolver working until chunk 11 moves it into the
resource — and should not be over-invested in. (ARCHITECTURE.md §4.7a, MIGRATION
chunk 11.)

**UPDATE (decided in side discussion) — the resolver is ELIMINATED, not patched.**
Stage choice moves **entirely client-side, at queue time** (test directives +
plugin hooks → three job fields `no_preload`/`require_preload`/`preload_list`).
Preloads make **no** routing decisions and the runner resolves from the **local
map** — so `resolve_file_stage`, the `resolve_file_stages` RPC, `request_preload_sync`
(resolver use), `_resolver_identity`, the `file_stage` callbacks, and **`eager`**
stages all **go away**. The retry-bound fix above is therefore moot — don't bother;
delete the resolver. (ARCHITECTURE §4.7/§4.7a, MIGRATION chunk 23.)

---

### 11. Multiple overlapping terminate/reap/timeout layers
**Flagged by: Gemini, Sonnet**
**Files:** `Runner.pm`, `Runner/Watchdog.pm`, collector ChildMonitor

Four systems ensure children die: (1) collector `ChildMonitor`
(`watch_parent_pid`), (2) IPC reaping of `{+PROCS}` in `stop`, (3)
`Runner::check_timeouts` grace-period SIGTERM→SIGKILL escalation, (4)
`Runner::Watchdog` aborting jobs whose stages vanished. They handle different
failures but duplicate a lot of process-monitoring, signal-dispatch, and
timer-check code. Sonnet separately flags `stop_stages` (in-process `{+PROCS}`
children) vs `stop_preload_stages` (socket peers) as two teardown paths sharing
no logic despite doing the same conceptual thing.

**Simpler:** Unify stage teardown behind one `stop_all_stages` iterating both
collections with the same signal/wait logic; document why each timeout layer is
distinct (or merge the ones that aren't).

> Response:

**Mostly subsumed by #3/#4/#8 — the overlap is an artifact of the old
runner-managed-stages + in-runner-reaping model those items dismantle.** After
they land, the four "layers" reduce to distinct, non-overlapping roles:

- **ChildMonitor (`watch_parent_pid`)** → the **multi-pid self-termination**
  mechanism (#3): the canonical process-tree teardown.
- **IPC reaping** → a **minimal zombie-reaper** (#8).
- **`Runner::Watchdog`** → narrows to **wind-down abort** (`abort_remaining`) only;
  its stage-gone `abort_job` (from `dispatch_pending`) becomes **`requeue_task`**
  (#3 — stage gone is now normal/temporary).
- **`Runner::check_timeouts`** → already narrowed (per-test timeouts live on the
  collector); kept as a **thin, explicitly-marked backstop** that TERM→KILLs a
  reaped collector whose process group lingers. It guards a real "wedged collector"
  failure the collector itself can't cover; keep it cheap and debug-logged, not a
  primary mechanism.

**Two teardown paths → one.** `stop_stages` (iterates `PROCS` for
`Preloader::Stage`) is the in-runner named-stage path **#4 deletes** — post-#4 no
such procs exist in `PROCS`, so it goes away. `stop_preload_stages` (iterates
`service_peers` for `preload-*`) survives as the single teardown path. Sonnet's
"two parallel teardown paths" dissolves.

So nothing new to build here beyond what #3/#4/#8 already do; the only standing
decision was the `check_timeouts` backstop — **keep, but thin** (marked backstop,
cheap, debug-logged).

---

### 12. `RUN_ITEMS` / dual run storage never pruned
**Flagged by: Gemini, GPT, Opus, Sonnet** (various angles)
**Files:** `Runner/State.pm`

State keeps both raw run-settings hashes (`RUN_ITEMS`) and `Runner::Run` objects
(`RUN`, `PENDING_RUNS`). `run_item` only ever returns the *active* run's copy,
but `RUN_ITEMS` retains a full copy of every queued run for process lifetime —
unbounded growth in a persistent runner, and two representations that can
diverge. GPT (#8) and Opus (SS-6) flag the growth; Sonnet (5c) and Gemini (3.1)
flag the duplication.

**Simpler:** Keep only the object form (serialize from it at write time), or store
a single `current_run_item` and delete on run stop/clear.

> Response:

**Fold the raw item onto the `Run` object (option C), and gate run-state retention
on the queuing client connection.**

The leak is real: `RUN_ITEMS` (`run_items`) keeps `{%$run}` for **every** queued
run (`_queue_run`, State.pm:297), `run_item` only ever returns the **active** run's
copy (310-313), and `_stop_run` never deletes it (799) — unbounded growth on a
persistent runner, plus a second representation alongside the `Run` object. The raw
hash itself is deliberate: the stage rebuilds its `Runner::Run` from the raw item,
not from a serialized live object.

**Fix (C):** store the raw hash as a field **on the `Run` object**
(`$run->raw_item = {%$run}` at queue); `run_item` returns `$RUN->raw_item`. One
canonical structure (the `Run` objects in `PENDING_RUNS`/`RUN`), the raw item lives
and dies with its run — no separate hash, no manual pruning of `RUN_ITEMS`.

**Retention lifecycle (refinement):** do **not** purge a run on completion — keep
it until the queuing command no longer needs it. Each `Run` records the
**connection that queued it** (`request_handler_queue_run` already receives `$conn`,
Handlers.pm:100; + its `peer_pid` from #1) and an **`abort_on_disconnect` flag
(default true)**. On owner-connection drop (`_drop_conn`, the existing close hook):

- **finished + owner connected** → retain (command may still query).
- **finished + owner gone** → purge (Run + job states + raw item).
- **running + owner drops, flag true (default)** → **abort the run**: halt pending,
  kill running jobs (signal their collectors → kill test groups), mark aborted,
  advance to the next run. A vanished `run`/`test` command = crash or user-kill,
  which intends to kill the run. Reuses watchdog `abort_remaining` scoped to the run.
- **running + owner drops, flag false** → **detach**: keep running (results persist
  to events/DB), purge on completion. Enables a future queue-and-detach command
  (`yath queue`).

This bounds the persistent runner's in-memory run state by **live client
connections**, not by total runs queued. Recorded in ARCHITECTURE.md §4.2 +
MIGRATION chunk 22. (Immediate part — the C fold — kills the leak now; the
connection-gated retention + abort-on-disconnect is the fuller lifecycle, ties to
multi-run / chunk 16.)

---

### 13. Package-global `%SORTED` memoization leak + ref-reuse bug
**Flagged by: Opus, Sonnet**
**Files:** `Runner/State.pm`

`%SORTED` caches sorted task order, keyed by stringified arrayref, as a
**package global** — never cleared. A long-lived scheduler grows it unboundedly,
and a freed bucket's reused address can hash-collide and wrongly skip the
conflict-priority sort. It also persists across State instances in-process
(test contamination).

**Simpler:** Make it an instance field and prune in `prune_hash`, or just sort
unconditionally — buckets are small for typical runs.

> Response:

**Fix A — keep the memo, fix it correctly.** The package-global `%SORTED`
(State.pm:906/938) has three bugs: unbounded leak (never cleared, keyed by a
freed-then-reused arrayref address), a **correctness** bug (a reused bucket address
finds the stale "already sorted" flag and skips the conflict-priority sort of the
new bucket), and cross-instance contamination. But it is a real optimization —
`_next` runs ~once per dispatch and the bucket shrinks each time, so dropping the
memo is O(N² log N) on a large single-bucket run.

Fix:
- Make it an **instance field** (`$self->{+SORTED}`) — dies with the State / run,
  no cross-instance bleed.
- Key by the **stable path tuple** (`"$run_id\0$smoke\0$stage\0$cat\0$dur"`), **not**
  the arrayref address — address-reuse-safe.
- **Clear** a bucket's flag when a task is added to it (`_queue_task` /
  `task_pending_lookup`), and clear all on run purge.

This keeps sort-once-per-bucket while killing the leak, the ref-reuse correctness
bug, and the contamination. (Rejected B — unconditional sort — because large
same-stage/cat/dur runs are realistic in Test2-Harness and the per-dispatch re-sort
is quadratic.)

**Comment the clearing points for the concurrent-multi-run future.** `_next` and
the `SORTED` clear/scope logic currently assume **one active `RUN`**. The future
goal is concurrent runs with **earlier-run priority + backfill** (an earlier run
gets first claim on slots/resources; when it can't use a free resource, later runs'
jobs backfill — no idle capacity). The per-run structures already carry `run_id`,
but the scheduler loop and these clear points must be revisited then. **When
implementing fix A, add a comment at each clearing site** noting it assumes a
single active run and must be revisited for concurrent multi-run. Recorded in
ARCHITECTURE.md §6.1 (future goal; no MIGRATION chunk yet).

---

### 14. Deep 5-layer task partitioning + `prune_hash`
**Flagged by: Gemini**
**Files:** `Runner/State.pm`

Pending tasks live in
`PENDING_TASKS->{run_id}->{smoke}->{stage}->{cat}->{dur}`, a 5-level nested hash
that requires the recursive `prune_hash` helper to GC empty sub-keys and avoid
leaks. The partitioning helps scheduling loops run efficiently, but the hardcoded
nesting introduces significant bookkeeping.

**Simpler:** (Gemini only — lower confidence.) Consider a flatter keying scheme
or a small index object. Evaluate against scheduler hot-loop performance before
changing.

> Response:

**Reject — false positive. Keep as-is; add an explanatory comment.** The 5-level
nesting (`run_id`→`smoke`→`stage`→`cat`→`dur`, `task_fields`) **is the scheduler's
priority index**: it exactly mirrors `_next`'s nested priority traversal
(`for smoke { for stage_set { for lcat { for ldur {...}}}}`), so `_next` walks the
dimensions in priority order by iterating the index in place rather than filtering a
flat list against each dimension every dispatch. Flattening it would make the hot
loop re-derive that partitioning each call — slower, not simpler. Gemini itself
hedged ("evaluate against hot-loop performance first").

`prune_hash` is a 25-line generic recursive GC, called once per task removal
(O(depth=5) — cheap), keeping the index free of empty buckets. Justified.

Bonus: `run_id` is the **outer** key, so the structure already holds multiple runs'
tasks — forward-compatible with the concurrent-multi-run future (§6.1), which
changes `_next`'s traversal (span run_ids by priority), not the partitioning.

Only change: **add a comment** stating the nesting is the priority index (mirrors
`_next`'s loop order) so the next auditor doesn't try to flatten it (same
"stop re-flagging this" pattern as #7e). The hardcoded depth in
`task_pending_lookup` + the `prune_hash` call is minor coupling on stable dims —
not worth abstracting.

---

## TIER 3 — Lower confidence / single-auditor / note-only

### 15. Chunk-comment archaeology
**Flagged by: Sonnet** (Opus/GPT note stale comments separately)
**Files:** `Runner.pm`, `Runner/State.pm` (pervasive)

`# chunk N.M (§X.Y): rationale` development-journal comments crowd out structural
understanding; many describe history ("this replaced dispatch.jsonl") rather than
current invariants. **Recommendation:** sweep chunk-comments after each chunk
stabilizes; keep only current-constraint comments; history already lives in git +
plan docs. (Opus/GPT's stale-"DORMANT" comments in #4 are the worst instance.)

> Response:

**Real, but defer the bulk sweep to after #1–#13 land; not a blanket delete.**
127 chunk-comments in lib (Runner.pm 47, Handlers.pm 32, State.pm 7 — mostly
`# Chunk 19.x`). Two reasons to defer:

1. **The heavily-commented code is exactly what #1–#13 rewrite** (set_proc_exit,
   generation, `%busy`, the resolver, the IPC controller, …). Sweeping now is
   wasted — sweep the *final* code.
2. **Migration is ongoing**, so chunk numbers still correlate code to
   `MIGRATION.md`. Right cadence (Sonnet's): sweep a chunk's comments once that
   chunk's code stabilizes.

**Not a blanket `grep -v '# Chunk'`** — two kinds are mixed: purely historical
("replaced dispatch.jsonl") → delete; current-invariant explanation wearing a chunk
prefix ("Chunk 19.3: the atomic flip — the runner is now scheduler-only") → strip
the prefix, **keep the explanation**. Per-comment judgment.

**Exception:** the lying `DORMANT` comments (the worst — they misdescribe live
control flow and already fooled an auditor) are fixed/deleted **now** as step 1 of
#4, not deferred.

---

### 16. `run_ord` socket sub-dir scoping — unused capability
**Flagged by: Opus, Sonnet**
**Files:** `Role/Service.pm`

`service_socket_path` branches on `->can('run_ord')` to nest sockets under
`runs/<run_ord>/`, but no consumer defines `run_ord` (a comment says the runner
"deliberately does NOT"). A `->can` check on every socket bind for a capability
nothing provides.

**Simpler:** Remove until a consumer exists.

> Response:

**Reject "remove" — keep the seam, but rename `run_ord` → `run_id` and clarify.**
`run_ord` is not dead scaffolding; it is the collision-safe socket-naming seam for
**run-scoped preload stages** (`service_socket_path` nests under
`runs/<run_ord>/...` when a consumer provides it). It is dormant only because
execution is serialized and stages are global; it becomes necessary once
**run-scoped stages** combine with **concurrent multi-run** (§6.1), where two
concurrent runs' same-named stages would otherwise collide on
`preload-<stage>.socket`. Verified it appears **only** in Role/Service.pm +
Runner.pm (not in App/UX/DB) — so the rename is clean and scoped.

**Rename `run_ord` → `run_id` (decided):** the name is overloaded — `run_ord` means
something different in the UX/DB (a run ordinal), and it cost real
time to rule that out. The runner always refers to runs by **`run_id`** (a UUID).
The seam value will **always be the run's `run_id` UUID, never an integer counter**,
so:
- Rename the optional consumer hook `run_ord` → `run_id` in `Role::Service`
  (`->can('run_id')` check, the doc, `service_socket_path`).
- Fix the doc ("a per-run **numeric** subdir" → "the run's `run_id` (UUID) subdir")
  and the Runner.pm seam comment (it already wrote `runs/<run_id>/`, but the method
  was misnamed `run_ord`).
- **Global preloads leave `run_id` undefined** → flat `preload-<stage>.socket`
  (unchanged behavior).
- Cross-linked to §6.1 (the run_id-keyed hook is a dependency of the concurrent-runs
  future). ARCHITECTURE §6.1 updated to say `run_id` and why `run_ord` was rejected.

No removal; rename + clarify only.

---

### 17. `scheduler_tick` issues
**Flagged by: Opus, Sonnet**
**Files:** `Runner/Role/Scheduler.pm`

- **Retry-5-then-abort** wraps `poll`/`advance`/`dispatch_pending` in an `eval`
  that retries the same tick 5×; but a scheduler bug now throws in-process and
  deterministically, so it just fails 5× and prints 5 scary `Scheduler error
  (n/5)` lines before aborting. Drop to fail-fast, or scope the retry to
  resource-tick failures only. *(Opus SL-6)*
- **Bare hash keys** — `$self->{'rootpid'}`, `{'signal'}`, `{'active_run'}`,
  `{'resource_timeout'}`, `{'scheduler_errors'}` bypass HashBase constants
  (`{+ROOTPID}` etc.), so typos aren't caught and grep misses them. *(Sonnet 6a)*
- **Two-level `service_tick` → `scheduler_tick`** with no intermediate logic —
  inline or keep one name. *(Sonnet 6b)*

(Sonnet also flags `run_reached_timeout` accessed as a bare slot in
`check_timeouts` — same HashBase-bypass class.)

> Response:

Three sub-findings, mixed:

**17a — bare hash keys: fix (mechanical).** `scheduler_tick`/`service_tick` use
`$self->{'rootpid'}`/`{'signal'}`/`{'active_run'}`/`{'resource_timeout'}`/
`{'scheduler_errors'}` (and `check_timeouts` uses `{run_reached_timeout}`) as bare
strings instead of HashBase constants. Same slots (no correctness bug — the
constant is the lowercased string), but bypasses typo-checking/grep. Convert all to
`{+ROOTPID}` etc.

**17b — retry-5-then-abort: fail-fast.** `SCHEDULER_MAX_ERRORS = 5` wraps
`poll`/`advance`/`dispatch_pending` in an `eval` and retries the tick 5× before
TERM. The retry's rationale is the **dead separate-process model** (the comment
admits it: "a separate process could die and be detected via waitpid; now it is
in-runner code"). In-process a throw is deterministic — retrying 5× fails 5×
identically, hiding a real bug behind scary noise + abort. **Drop the retry;
fail-fast** — a `poll`/`advance`/`dispatch_pending` throw is a real bug, surface it.
Resources own their **own** transient-error resilience (retry/refresh inside their
`tick()`), rather than the scheduler re-running the whole tick. Ties to #8 (the
separate-process model is gone).

**17c — two-level `service_tick` → `scheduler_tick`: reject.** Not a pure
passthrough — `service_tick` sets `signal = TERM` on `service_stopped` before
calling `scheduler_tick`. The split is justified (service-loop concern vs
scheduling). Keep both.

---

### 18. Handler boilerplate + duplicated stale-generation guard
**Flagged by: Sonnet** (guard-dup overlaps #3)
**Files:** `Handlers.pm`

About half the handler file is "receive request → forward to state/`submit_action`"
3–6 line wrappers (`request_handler_queue_run/queue_task/stop_run/end_queue/
halt_run`). And `_stale_stage_generation` is checked identically in the
`stage_ready`/`stage_down`/`stage_restarting` handlers.

**Simpler:** A single guarded `_handle_stage_lifecycle` dispatcher for the three
stage events; optionally a generic `action_handler` for the forwarders. (Opus
SL-7: `announce_job` backfilling missing `run_id` via `monitor->job()` is the
same family — carry `run_id` from the task at the source instead.)

> Response:

**Part 2 (duplicated `_stale_stage_generation`) — dissolves via #3.** The guard is
copy-pasted across the `stage_ready`/`stage_down`/`stage_restarting` handlers
(366/374/385); #3 deletes `_stale_stage_generation` entirely (→ connection-currency,
applied once via a shared helper / single guarded dispatcher). Gone as part of #3.

**Part 1 (handler boilerplate / factory) — reject.** Sonnet's generic
`action_handler` factory is the wrong fix: it re-introduces the command-string→method
**dispatch-table indirection that #1 deletes** (`%ACTIONS`/`_enqueue`), same
grep-ability cost. The handlers aren't uniform anyway — they decode different
payload fields (`run`/`run_id`/`task`), some carry extra logic (`queue_run` prints
tolerated preload warnings), and `submit_action` isn't a passthrough (it **buffers**
actions until the base stage is ready — the scheduler-only startup gate). Thin
explicit decode-then-forward handlers **are** the right RPC surface: greppable,
clear, no meta-layer. Keep them.

No new work beyond #3.

---

### 19. `Runner::Client` still exposes stale stage-reporting API
**Flagged by: GPT**
**Files:** `Runner/Client.pm`, `Runner/Stage.pm`, `Runner.pm`

`Runner::Client` still has `stage_ready`/`stage_down`/`job_pid`/`stop_task`/
`retry_task`/`reload`, but the live stage path uses `Runner::Stage->_report()` /
direct `service_send()`. The command client is really only used for
queue/status/run-submit/spawn-submit/subscribe. Keeping the stale methods makes
it hard to see which callers are real.

**Simpler:** Keep `Client` as a command/query client; keep stage reports on
`Runner::Stage`; remove the unused stage-report methods once call sites are
confirmed absent.

> Response:

**Confirmed dead — delete the 6 stage-report methods.** `Stage->_report` uses
`$runner->service_send('runner', ...)` directly (Stage.pm), **not** `Runner::Client`,
so `Runner::Client`'s `stop_task`/`retry_task`/`reload`/`stage_ready`/`stage_down`/
`job_pid` (lines 170-175) have **0 callers** (verified; the earlier `reload` hit was
the unrelated `reload_state` query). Delete them. `Runner::Client` stays a
command/query/subscription client (`queue_*`, `stop_run`, `end_queue`, `stop`,
`halt_run`, `reload_state`, `status`, `truncate`, `resources`,
`connect_subscriber`/`submitter`/`subscriber`).

Also fix the **stale comment** at Runner.pm:333 ("a Runner::Client back to
runner.socket for outcome reports") — the stage delegate reports via `service_send`,
not a Client (fold into #15's sweep). YAGNI on a future command wanting
`stop_task`/`retry_task` — nothing uses them; re-add if one ever does.

---

### 20. Preload library `require` happens outside the preload guard
**Flagged by: GPT** (already noted in MIGRATION.md as deferred)
**Files:** `Preload.pm`, `Runner/Preloader.pm`

`Preload::_handshake` → `_load_preloads` `require`s preload libs during the
preload-root handshake, but `test2_start_preload()` guard starts later in
`Preloader::preload()`. Require-time Test2 side effects can fire outside the
guard. **A real correctness bug, not clutter** — and relevant here because more
warning-capture / fallback-scrape diagnostics will keep treating symptoms until
load ordering is fixed. Fix the ordering, then reassess how much diagnostic
plumbing is still needed.

> Response:

**Real correctness bug — fix by making the handshake lightweight (decided).**
Confirmed: `Preload::_load_preloads` does a full `require` of each preload module at
**handshake** (Preload.pm:385) to read `TEST2_HARNESS_PRELOAD` meta, **before**
`test2_start_preload()` (which runs later in the stage-host's `Preloader::preload`,
Preloader.pm:124). The modules are then already in `%INC`, so the **guarded** load
is a no-op — the guard never wraps the real `require`, and require-time Test2 side
effects fire outside it. Preloads are also loaded **twice** (handshake + stage-host).

**Fix (cleaner than gating the guard):** decouple handshake from load.
- Handshake = dial + identify + `get_preload_list` only. **No `_load_preloads`,
  no `set_stage_data`.**
- The stage-host preloads **once, under the existing `test2_start_preload` guard**,
  and builds the meta (`$preloader->staged` — already produced; `resolve_file_stages`
  reads it).
- Report `set_stage_data` + preload warnings **after** that guarded load.
- The runner already blocks scheduling until the map arrives
  (`run_scheduler_only`'s `until ($self->_ready_to_schedule)`), so **no runner-side
  change** — it just waits a little longer.

Deletes `Preload::_load_preloads` and the duplicate load; **no double-start /
guard-flag dance** (one `test2_start_preload`, in the existing spot). And it moves
warning capture to the single guarded load — **shrinking #21** rather than being its
prerequisite. Recorded in ARCHITECTURE §4.7 + MIGRATION (deferred note updated to
this approach).

**UPDATE:** the lightweight-handshake fix stands, and the **resolver part is also
eliminated** (#10 update / chunk 23) — the post-guard `set_stage_data` reports only
the map (stages/`default`/state), no `resolve_file_stages`. Stage choice is
client-side.

---

### 21. Preload failure diagnostics split across two paths
**Flagged by: GPT**
**Files:** `Runner.pm`, `Preload.pm`

`Preload::run_driver` captures warnings and reports failures via service
messages, but `Runner::_emit_preload_failure_output` *also* reads
`preload-root-events.jsonl.zst` / `stage-*-events.jsonl.zst` directly from disk
as a fallback — putting one-off zstd/jsonl knowledge into a control-plane class
that overlaps the reader/renderer layer.

**Simpler:** Pick one durable path — prefer a structured preload-failure
diagnostic over the service channel (text normalized by preload-root/stage host);
or, if event files are canonical, move the read into the existing reader/renderer
layer. Then delete the runner-local scrape.

> Response:

**Reframed into two separate concerns — detection (solved) vs diagnostics
(simplify).**

**Detection ("don't wait forever") — solved, not really #21.** The runner already
knows a stage/preload-root died without reporting: a dead process **EOFs its
socket** (and #3's connection-currency + multi-pid self-termination makes this
robust), and `_ready_to_schedule` has a deadline. Confirmed there is **no
per-named-stage startup timeout** — `done()` stays 0 while tasks are pending, so a
legitimately-slow (2+ min) named stage just waits, never timed out. Two fixes here:
- **Make the deadlines configurable** — the 60s map/base-stage deadline
  (Runner.pm:1282) and the 30s resolver deadline (Runner.pm:760, Preload.pm:410) are
  hardcoded; deployments with multi-minute preloads exist, so they must be settings.
- **Close the hung-stage gap** — a stage that is *alive but never reports ready*
  (hangs, no EOF) currently waits forever. Add an **optional, configurable,
  generous/off-by-default per-stage startup timeout**, enforced by the preload
  resource (§4.7a): a too-long `starting` → `available` = `-1` (skip/fail or abort).

**Diagnostics ("show why") — the actual #21, and it simplifies a lot.** The dead
process's error is **already recorded** by its collector
(`preload-root-events.jsonl.zst`) and the **renderer already displays that stream**
(tagged INTERNAL). So the runner does **not** need to read the stage's output or
relay the error — it only needs to **know there was a problem** (a simple flag) and
fail the run; the renderer surfaces the error eventually. **Delete
`_emit_preload_failure_output`'s inline zstd/jsonl scrape** (the control-plane
class carrying event-file decode knowledge — GPT's real point). #20 already moves
warning capture to the single guarded load, so the structured "a stage failed"
signal is reliable; the bespoke scrape is redundant with the renderer.

Recorded in ARCHITECTURE §4.7a (startup-wait + configurable timeouts). Net: keep a
minimal "stage failed" signal, drop the scrape, make timeouts configurable, add the
resource-enforced hung-stage backstop.

**UPDATE:** the **resolver 30s deadline goes away** with the resolver itself (#10
update / chunk 23 — stage choice is client-side, no round-trip). The
configurable-timeout point now applies to the **map/base-stage readiness** deadline
and the resource's per-stage **startup** timeout, not a resolver call.

---

### 22. `ROOTPID == $$` role branching scattered across Runner
**Flagged by: Sonnet** (rated High)
**Files:** `Runner.pm` (~15 sites)

Runner runs as root, stage child, and preload-root from one class, with
`$self->{+ROOTPID} == $$` guards re-derived in `process`, `run_stage`, `run_job`,
`set_proc_exit`, `setup_plugins`, `teardown_plugins`, `stop_preload_root`,
`dispatch_pending`, etc. Each new role-sensitive method needs its own check.

**Simpler:** Extract role objects or split into named entry points
(`run_as_root`/`run_as_stage`/`run_as_preload_root`). (Larger refactor — note,
not a quick win.)

> Response:

**Real, but defer to after #4/#8/#20/chunk 23, then split into separate classes.**
~16 `ROOTPID == $$` guards (+ `STAGE` checks) distinguish three roles on one
`Runner` class: scheduler-only **root** (`ROOTPID==$$`), forked **stage child**
(`STAGE` set), and the preload-root's **stage-host** (injected `rootpid`).

The role branching *persists* after #4 (the stage-host/child role isn't deleted —
it moves into the preload tree, `Preload.pm`'s driven Runner), but several guards
**disappear with other items first**: #8 removes the reaping branches, #20/chunk 23
remove the scheduler-only resolver branches. So the count shrinks on its own before
any dedicated refactor.

Doing the split now is premature (the roles are actively shifting under
#4/#8/#20/chunk 23 — same reasoning as #15). **After those land, reassess** — the
clean end-state roles (scheduler-only **root** vs preload-tree **stage-host/child**)
are different enough that the right move is likely **two separate classes**
(eliminating `ROOTPID` branching entirely), not named entry points on one class. The
preload-tree Runner is already constructed separately (`Preload::_run_stage_host`
with injected `rootpid`); formalizing that split is the clean version.

---

### 23. Three distinct concepts all named "Stage"
**Flagged by: Sonnet** (rated High)
**Files:** `Runner/Stage.pm`, `Runner/Preloader/Stage.pm`, `Runner/Preload/Stage.pm`

`Runner::Stage` (in-stage delegate mimicking State's API),
`Runner::Preloader::Stage` (parent-side `IPC::Process` tracker), and
`Runner::Preload::Stage` (user DSL config object) collide on the name —
`Preloader` vs `Preload` differs by one letter in the path. Every search for
"Stage" hits all three. Related: `Runner::Stage::done` always returns 0 (the
stage never self-terminates) — a leaking-abstraction stub kept for API parity.

**Simpler:** Rename — e.g. `StageChild` / `StageProcess` / `StageConfig`. Make
`done` die "impossible" or drop it if it can never be true.

> Response:

**Real collision; defer the rename to after #4/#8/chunk 23, coordinate with #22.**
Three classes named "Stage" (`Preloader::Stage` vs `Preload::Stage` differ by one
letter):
- `Runner::Stage` — in-stage delegate.
- `Runner::Preloader::Stage` — `IPC::Process` proc tracker (`name`, `eager`).
- `Runner::Preload::Stage` — user DSL config (`watches`, `file_stage`).

All three **thin** under the other items first: #4 removes `Preloader::Stage`'s
in-runner-root use (it survives only in the preload tree), #8 thins its
`IPC::Process` base, **chunk 23 removes `eager` (both) and `file_stage` (DSL)**
(keeps `watches`, #7e). So rename the **final** shapes, and **coordinate with #22's
root/stage-host class split** (which reorganizes the stage classes anyway).

Proposed renames: `Runner::Stage` → `StageDelegate` (or `StageChild`);
`Runner::Preloader::Stage` → `StageProcess`; `Runner::Preload::Stage` →
`StageConfig`. Plus **4b**: `Runner::Stage::done` always returns 0 → `die "impossible"`
(catch misuse) or drop it.

Defer (rename after the classes thin); not now.

---

### 24. Resource base class: 9 no-op methods, silent failures
**Flagged by: Sonnet**
**Files:** `Runner/Resource.pm`

`tick`/`refresh`/`discharge`/`available`/`record`/`assign`/`release`/`cleanup`/
`setup` are all base-class no-ops. A subclass that forgets `available` silently
returns false for every task instead of failing loudly. Also
`scope_global/scope_host/scope_run` appear unused (grep before removing).

**Simpler:** A Role with `requires` for the mandatory methods (`available`,
`assign`, `release`); default no-ops only for optional hooks (`tick`, `refresh`).

> Response:

**Fix now — it's the interface the new preload resource (§4.7a) targets, and it's
stable (not reshaped by #4/#8/chunk 23).**

- **Remove `scope_global`/`scope_host`/`scope_run`** (Resource.pm:11-13): the only
  override anywhere is `SharedJobSlots.pm:27`, which **#5 deletes**, and nothing
  reads scope to route. Fully dead after #5.
- **Make the base a Role with `requires 'available', 'assign'`** (user decision —
  both required). Today `available` defaults to `-1` (permanent-skip), so a subclass
  that forgets it silently all-skips its tests; making `available` + `assign`
  required turns omission into a **load-time error**. Keep no-op defaults for the
  genuine optional hooks: `tick`/`refresh`/`discharge`/`cleanup`/`setup`/`record`/
  `release`/`status_data`/`status_lines`.
- With **SharedJobSlots gone (#5)**, the implementers are **JobCount** + the **preload
  resource** — both define `available` + `assign`, so the new `requires` is satisfied
  and the contract is enforced for future resource authors.

---

### 25. Smaller single-auditor notes
**Flagged by: individual auditors** — low priority, listed for completeness

- **`_drain_transitions` fixed 50×0.01s spin** (`Runner.pm`) — drain-until-empty
  with a deadline is more correct than a fixed count. *(Sonnet 3d)*
- **`find_churn` 50×/0.02s sleep-retry** (`Preloader.pm:540`) waiting for a saved
  file to "un-vanish" — papers over atomic-rename-on-save that inotify
  `IN_MOVE_SELF` re-watch already handles. Confirm still needed. *(Opus PR-7)*
- **`Preloader::_monitor` stores a full `Carp::longmess`** on every monitor start
  to defend a presumably-fixed double-start bug — downgrade to plain `die`.
  *(Opus PR-9)*
- **`Job::bailed_out`** keeps a legacy "scan out_file for `Bail out!`" branch with
  no input since chunk 3; `Job::set_exit` is now a pure `SUPER` pass-through.
  *(Opus PR-8)*
- **`Reloader::_can_reload`/`_find_loaded` dead** — `Preloader` always passes
  `can_reload_cb`/`find_loaded_cb` closures duplicating that logic. *(Opus PR-6)*
- **DepTracer dual hook** — both an `@INC` hook (`my_inc`) and a
  `CORE::GLOBAL::require` override record the same dep-map; commit to one (the
  require override is more reliable). *(Sonnet 9c — note Gemini 5.2 says the
  callback half is entirely dead.)*
- **Two file-watch poll loops** — `Reloader` and `Preloader::check()` each own a
  1s-gated poll loop for the same concern; `Reloader` should own watching.
  *(Sonnet 9d)*
- **`Util/IPC.pm` IO-swap duplicated** across `_run_cmd_fork` / `_run_cmd_spwn` —
  extract shared pre-exec setup. *(Sonnet 1d)*
- **`_runner_todo` negative-count sentinel** (`SharedJobSlots/State.pm`) — `-1`
  means "remove"; use a boolean/explicit method. *(Sonnet 8d)*
- **`_redistribute_fair` "Yikes!" self-deprecating comment** — algorithm is
  correct at current scale (2–10 runners); just delete the comment. *(Sonnet 8c)*
- **`min(grep {$_} ...)` concurrency clamp** copy-pasted in 3 places
  (`SharedJobSlots.pm:111`, `JobCount.pm:51,65`) — small shared helper. *(Opus
  SS-11)*
- **Bad-frame tolerance of 3** (`Connection.pm`) — over Unix sockets corruption
  is virtually impossible; a bad frame means version mismatch or a buggy peer.
  Closing on the first is safer and simpler. *(Gemini 2.2)*
- **`check_timeouts` no-op stub in IPC base** — only `Runner` overrides it and
  calls it on self; move it to `Runner` only. *(Sonnet 1c)*
- **`set_sig_handler()` documented public API never called** — its sole consumer
  pokes `{+HANDLERS}` directly. Keep one, not both. *(Opus IP-2)*

> Response:

Triaged into moot / quick-fix / verify / keep.

**Moot (resolved by earlier items):**
- `_runner_todo` negative sentinel + `_redistribute_fair` "Yikes!" comment — in
  `SharedJobSlots`, **deleted by #5**.
- `check_timeouts` no-op base stub + `set_sig_handler` never called — on the IPC
  controller, **collapsed by #8**.
- `min(grep) clamp ×3` — one copy is `SharedJobSlots` (#5); the other two are
  `JobCount.pm:51,65`. After #5, 2 copies in one file — **not worth a helper, leave.**
- The "DepTracer callback half is dead" claim (Gemini 5.2) — **wrong, disproven in
  #7e** (callbacks fire via `_reload_cb_reload`).

**Quick fixes (do):**
- `_drain_transitions` 50×0.01s spin → **drain-until-empty with a deadline**
  (`Time::HiRes`), more correct than a fixed count.
- `Preloader::_monitor` per-start `Carp::longmess` → plain `die`.
- `Job::bailed_out` legacy out_file `Bail out!` scan — dead since the chunk-3
  collector swap; **delete the scan**, keep the structured bail signal.
- `Reloader::_can_reload`/`_find_loaded` — dead (Preloader always passes
  `can_reload_cb`/`find_loaded_cb` closures that duplicate them); **delete.**

**Verify-then-fix (low-risk, my judgement = proceed):**
- `find_churn` 50×/0.02s sleep-retry — confirm inotify `IN_MOVE_SELF` re-watch
  covers atomic-rename-on-save, then remove.
- Two file-watch loops (`Reloader` + `Preloader::check`) — `Reloader` owns watching;
  `Preloader` calls it. Confirm no ordering dependency, then merge.
- `Util/IPC` IO-swap dup (`_run_cmd_fork`/`_run_cmd_spwn`) — extract shared pre-exec
  setup. (`Util::IPC` survives #8, so still relevant.)

**Keep (user decisions):**
- **Bad-frame tolerance of 3** (`Connection.pm`) — kept as-is.
- **DepTracer dual hook** (`@INC` + `CORE::GLOBAL::require`) — the redundancy is
  useful belt-and-suspenders; **keep.**

---

## Explicitly justified — do NOT cut (consensus)

All auditors that touched these agree they are load-bearing:
- The unified `Role::Service`/`Connection` framing layer (identity,
  request/response correlation, transitions, subscriptions over one socket).
- `Runner::Subscriber` parking transition deltas until after the snapshot.
- `Runner::Monitor`'s render-facing mirror (it's the subscriber/render model, not
  a second scheduler).
- `stop_preload_root` intentionally **not** killing the collector parent
  (documented in IPC.md — the parent must observe runner death and self-clean).
- The `no_reply`/`drain_input` fix itself (#9) — dedup, don't delete.
- pfile-based discovery + runner-mediated spawn are known migration gaps to be
  closed by planned work, not opportunistic cleanup.

---

## Suggested order (merged from the four "what to do first" lists)

1. **Tier 1 dead-weight:** #1 (poll/_enqueue/$$), #7 (verified dead lines), #5
   (SJS internals + mod2file bug), #6 (wait params). Behavior-preserving.
2. **Consolidate the chunk-19 over-defense:** #3 (pick one stale-incarnation
   mechanism — ideally self-validating job reports), #2 (collapse STAGE_LIFECYCLE),
   then resolve #4 (which preload path is dead) and delete it.
3. **Long-running-process correctness:** #13 (`%SORTED` leak), #12 (`RUN_ITEMS`
   growth) — these specifically bite a persistent runner.
4. **Investigate before touching:** #22 (ROOTPID branching, big), #10 (resolver
   retry), #20 (preload require ordering — fix first, it's a real bug), #25
   sleep-retry/longmess items.

*No files were edited during any of the four audits or this consolidation.*

> Note: the "Suggested order" above is the **pre-discussion** audit-merged ordering.
> It is partially superseded by the per-item `> Response:` decisions and the
> dependency map in the Notes section below. Read the Notes first.

---

## Notes & Context for Reviewers

Context from the working session that produced the `> Response:` blocks, not fully
captured item-by-item. Read this before acting on individual items.

### How to read this doc
- The `> Response:` blocks are **decisions by the project owner**, not open audit
  suggestions. Treat them as the agreed direction. Where a response **rejects** a
  finding (#5 delete-don't-fix, #7e, #14, #16, #18), the audit was wrong or
  superseded — do not "re-fix" it.
- Several findings were **verified against the live tree** during the session
  (the chunk-19 flip in #4, the resolver mechanics in #10, dead `Runner::Client`
  stage methods in #19, the `set_proc_exit` job/stage split in #8, `_load_preloads`
  loading outside the guard in #20). Others are still audit-level claims flagged
  "verify" (the #25 "verify-then-fix" group). Don't assume every claim is verified.
- Branch is `2.0d`. Test run: `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` (portable;
  the installed `yath -D test` also works). The harness is **not** self-hosting yet
  — there is **no `scripts/yath`** in this checkout. `AUTHOR_TESTING=1` is required
  or author-gated tests **skip silently** and hide regressions.

### The unifying root cause
Most of this is **not "too many features."** It is two layers of residue:
1. **Chunk-19 residue** — the preload-root extraction landed (runner is now
   scheduler-only), but a stack of crash/race/de-flake machinery and stale comments
   around it never got cleaned up. The flip already happened; comments and
   defenses lag the architecture.
2. **1.0 carryover superseded by collectors + sockets** — the `IPC` controller,
   category waits, reap-driven scheduling, etc. The recurring theme: **state now
   flows over sockets (collector transition reports), and reaping is mere zombie
   cleanup, not a scheduling signal.** When in doubt, that is the lens.

### New artifacts created this session (review these too)
The discussion added forward-looking design to the canonical docs — reviewers
should check these as part of reviewing the plan:
- **ARCHITECTURE.md:** §4.2 (run-state lifecycle / retention), §4.7 + §4.7a
  (preloads report map only; preload-as-resource with the 3 directives/3 job
  fields; configurable timeouts + startup backstop), §4.10 (interactive IO),
  §5.4 (process spawn/reap target), §6.1 (concurrent-runs-with-priority + backfill;
  `run_id` rename).
- **MIGRATION.md chunks 20–23** (interactive IO; IPC collapse; run lifecycle;
  client-side stage assignment / resolver elimination), plus the updated
  preload-guard deferred note.

### Foundational mechanism touching many items
**Connection identity = the source of truth.** #1 adds **`pid` to the handshake**
(every peer's pid known via `$conn->peer_pid`); #3 replaces generation-stamping
with **connection-currency** (a report is honored only from the currently-registered
connection for an identity). This one idea resolves #1, #2 (real stage pid in
status), #3 (stale-incarnation race), #9 (reporter args), and underpins #12
(run owner connection). Review these as a set, not in isolation.

### Dependency / sequencing map (supersedes the stale "Suggested order")
- **Do early, independent, behavior-preserving:** #1, #6, #7 (a/d), #19, #24.
- **#1 → #2 → #3** in that order: peer_pid, then 4-state stage lifecycle
  (`starting`/`up`/`restarting`/`down`, `down` reachable-later), then the
  self-termination + connection-currency rework. #3 introduces the **`requeue_task`**
  primitive (RUNNING→PENDING, no retry consumed) — a **prerequisite** for stages
  self-restarting and for the preload resource's assign→launch race (§4.7a).
- **#5 first among SharedJobSlots-touching items** — it deletes the whole subsystem,
  mooting parts of #7c and #25.
- **#6 before #8** — `cat` waits go, then the IPC controller collapses.
- **#4 / #8 / #20 / chunk 23 reshape the Runner**, so **#15 (comment sweep), #22
  (root/stage-host class split), #23 (Stage rename) are deferred until after them** —
  sweeping/splitting moving code is wasted.
- **Resolver elimination (chunk 23) supersedes #10/#20/#21's resolver discussion** —
  the round-trip, `resolve_file_stages`, `file_stage` callbacks, and `eager` stages
  are deleted, not fixed. Stage choice is decided **client-side at queue time**.
- **#20's lightweight-handshake fix is a prerequisite** to cleanly shrinking #21.

### Real-world context that drove the bigger decisions
- **Preload routing (chunk 23):** the 1.0 preload-side `file_stage` auto-assignment
  and `eager` stages were added but **never effectively used** in practice. The
  pattern people actually use is the **harness directive** + a **custom plugin that
  assigns stages at queue time**. Chunk 23 codifies that and drops the unused parts.
  Stages are **advisory** (a speedup, not a hard requirement) unless
  `# HARNESS-STAGE-REQUIRE` is used.
- **Timeouts (#21):** at least one production deployment has **preload stages that
  take 2+ minutes to start** (root preload <1 min). Hence: no fixed named-stage
  startup timeout, the map/base-stage and resolver(now-removed) deadlines must be
  **configurable**, and the hung-stage backstop must be **generous/off-by-default**.
- **Run abort (#12):** a vanished `run`/`test` command means a crash or user-kill
  intending to kill the run → **abort + kill jobs by default**, with a flag to
  detach (future `yath queue`).

### Out of scope (not bloat — known migration gaps)
pfile-based discovery (chunk 12), `yath spawn` (chunk 13), the system-load service
(chunk 7), and run-scoped preload stages as a user feature are **planned future
work**, not cleanup targets. Don't conflate them with the items here.

---

## Review follow-ups (Gemini + GPT reviews of this doc)

Refinements from two plan reviews, with the owner's decisions. Most confirmed the
plan; these are the deltas worth implementing.

**Resolved into the docs already (this pass):**
- **Test command corrected** — `AUTHOR_TESTING=1 prove -Ilib -j16 -r t/` (or
  installed `yath -D test`); no `scripts/yath` in this checkout; the harness is not
  self-hosting yet. `AUTHOR_TESTING=1` required or author-gated tests skip silently.
- **Generation contradiction (#2 vs #3) reconciled** — connection-currency wins.
  Stage lifecycle is `{state, stamp}` (no wire `generation`); the per-report
  `generation`, `PRELOAD_ROOT_GENERATION`, and `_stale_stage_generation` are
  removed; status pid comes from `peer_pid`. ARCH §4.7 corrected.
- **`down`'s setter defined (#2 / #5 / §4.7a)** — "will never be available" =
  **absent from the stage map** (never configured, misspelled, or removed by a
  refresh). A `require_preload` test with no presentable stage gets `-1`
  deterministically; present-but-no-`up`-peer is `starting`/`restarting` (wait).
- **Persistent-runner preload-root crash (#3 / §4.2)** — the persistent runner
  **terminates** (no respawn). Separately, **broken-preload resilience in reload
  mode**: a stage with a failed preload **stays alive and reloads when the file is
  fixed**, rather than dying (§4.7).
- **Run control requests (#12)** — `queue_task`/`stop_run` accepted from **any**
  command connection; only retention/abort is owner-gated.
- **Startup/hung backstop covers `restarting`** too, not just `starting`, via the
  configurable timeout (§4.7a).
- **`%SORTED` clear-on-run-purge (#13)** — delete keys matching `^<run_id>\0` in
  `_stop_run`, clear-on-add in `_queue_task` (Gemini's concrete keying).
- **Stale ARCH refs fixed** — resolver-deadline (gone with the resolver),
  generation-counter target, `§5.x` placeholder.

**Dispatch/requeue safety (#3)** — added to #3's response: `service_send` returns
false on write failure; an **explicit stage ack** (not a successful write) marks
"accepted"; requeue only before ack; full `requeue_task` state contract specified.

**Interactive sequencing (#4 / #7b / ch.20) — decision.** #4 removes
`goto::file`/`Long::Jump` from the runner, where the interactive FIFO patch lives.
We **do not** keep interactive working short-term: temporarily **disable interactive
mode (or leave it broken behind a TODO/`xfail` test)** when #4 lands, and fix it
properly via the socket-shared IO rewrite (ch.20). The TODO must ensure it is
eventually fixed, not silently dropped.

**`HARNESS-STAGE` expansion (ch.23 / #23)** — same directive, just **expanded to
accept multiple args**; a single arg is the natural 1-element `preload_list`
(back-compat, no separate alias). Also a concrete chunk-23 site (Gemini): **delete
the `eager` fallback loop in `State::_stage_order`** (~L897-901) and query only
`up` stages — simplifies the hot scheduling path. Spell out in the chunk: existing
`file_stage`/`eager` tests are **rewritten to directives or deleted**, not kept.

**Resource role mechanics (#24)** — **not** a HashBase-vs-role conflict: Object::HashBase
has first-class `Role::Tiny` integration (the `&RoleName` attr-list prefix, added for
this project — see `~/projects/Test2/Object-HashBase`). `Runner::Resource` becomes a
`Role::Tiny` role that `use`s Object::HashBase with `requires 'available', 'assign'`;
consumers compose via `use Object::HashBase qw{ &Test2::Harness2::Runner::Resource … }`,
getting load-time `requires` enforcement + the HashBase attrs. No `use parent`
breakage. Keep no-op defaults for the optional hooks; update POD away from inheritance.

**Multi-pid collector watch — repo-side updates (#3 / GPT #7).** When the
`Test2-Collector` `watch_parent_pid`→list change lands, in the **same chunk**: bump
`dist.ini` / `cpanfile` / generated `Makefile.PL` dependency floors off
`Test2::Collector = 0.000001`; update `agent_scripts/audit-collector-watch-parent`
to check scalar-vs-list usage; keep the public name `watch_parent_pid` with
**scalar+arrayref back-compat** (Gemini's `ref($v) eq 'ARRAY' ? @$v : ($v)` shape),
rather than a new `watch_parent_pids`.

**Client-side assignment migration detail (ch.23)** — plugin hooks override/validate
the three job fields (re-run the `no_preload ⟹ others empty` validation after plugin
mutation); a literal stage named `REQUIRE` is reserved (the stage-directive keyword).
