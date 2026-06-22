# ARCHITECTURE.md

Authoritative architectural spec for yath 2.0 — **where we want to be**.

The three planning docs: **`ARCHITECTURE.md`** (this — the target state) ·
**`TODO_STEPS.md`** (the broad migration steps/chunks to get there) ·
**`TODO_TASKS.md`** (specific, decided, ready-to-implement tickets). Steps and
tickets cross-reference the §-sections here.

This document is **aspirational**: it describes where the code is going, not
where it is today. yath 2.0 is built by **evolving the 1.0 codebase in small
chunks** (see §1), so at any given moment most of the tree is still 1.0 and
most of the target architecture below is not yet in place. Each subsystem
section is tagged with a status (see "Status tags") so a reader can tell what
is inherited, what is mid-migration, and what is still a goal.

Style and formatting rules live in `STYLE_GUIDE.md`. Per-agent / contributor
workflow lives in `AGENTS.md`. This file owns the target process topology,
module boundaries, contracts between subsystems, on-wire formats, and any
other decisions that constrain how the code fits together as it is migrated.

## Status tags

Every subsystem section (and any other claim that may be ahead of the code)
carries one of:

- **`[1.0]`** — inherited from yath 1.0, expected to survive largely as-is (it
  may be renamed but not redesigned).
- **`[migrating]`** — actively being changed from its 1.0 shape toward the
  target described here; both forms may exist in-tree at once.
- **`[target]`** — aspirational. Not started, or only prototyped in an
  abandoned branch under `reference/`. Nothing in the live tree depends on it
  yet.

Chunks 1 and 2 of the migration have landed (mechanical renames + version
bump, §1.1; argument processing → `Getopt::Yath`, §2.3): the tree carries the
2.0 names/versions and option handling is `Getopt::Yath`. The remaining target
subsystems are otherwise still 1.0 logic. Update the tag on a section as its
migration starts and completes. Current per-chunk migration status lives in
`TODO_STEPS.md`, not here.

## Conventions for this document

- **This is a target-state spec, not a log of landed work.** Unlike the
  earlier (abandoned) ground-up rewrite, sections here may describe
  architecture that does not exist yet, as long as it is tagged `[target]`.
  Keep speculative detail proportionate: describe the shape and the contracts,
  not imagined implementation minutiae that the migration will settle.
- **Tag every subsystem.** A reader must always be able to tell `[1.0]` from
  `[migrating]` from `[target]`.
- **Deviations are recorded in-place.** If something ships that contradicts a
  section here, update that section (and, per `AGENTS.md`, append an addendum
  explaining the deviation). The authoritative target stays in one place.
- **User-facing strings never reference this file.** POD, command help, and
  diagnostic strings restate the relevant rule in plain prose instead of
  pointing at internal docs. `STYLE_GUIDE.md` ("POD style") and `AGENTS.md`
  ("Referencing AI docs from code") cover this in detail.
- **Regular code comments may cite this file**, with a specific section
  identifier (e.g. `# See ARCHITECTURE.md §4.3 "Transition channel"`). Bare
  tokens like `D6` or `step 4+5` are not acceptable.

## 1. Project scope and strategy

yath 2.0 is the next major version of the Test2 harness. It is produced by
**evolving the existing 1.0 codebase in small, reviewable chunks**, not by
rewriting from scratch. Several prior from-scratch attempts were abandoned;
their code survives read-only under `reference/` (§2.7) and is mined for
designs, but the live tree starts from 1.0 and is migrated forward.

- **Distribution.** The distribution is renamed to **`Test2-Harness2`**. The
  rename — of the distribution and of the namespaces below — is deliberate:
  it lets an installed yath 2.0 **co-exist with an installed yath 1.0**
  (`Test2-Harness`) rather than replacing it. This whole-distribution rename
  is the reason the namespace changes are mechanical.
- **Namespaces.** Two namespaces, split by concern. The migration renames the
  1.0 namespaces into them:
  - **`Test2::Harness2`** (from `Test2::Harness`) owns **producing results**:
    running tests, orchestrating collectors, scheduling, job dispatch, and
    preloads. Perl API only; no user interface lives here.
  - **`App::Yath2`** (from `App::Yath`) owns **the user interface**: parsing
    user input, feeding tests-to-run into `Test2::Harness2`, and formatting /
    displaying results (live render, archived render, querying past runs). The
    database + UI layer that used to be the separate `Test2-Harness-UI`
    distribution is rewritten **inline** here.
  - **Reading test files is a UI/input concern, not a producing-results one.**
    Discovering test files and reading each one (its header directives / metadata)
    to decide how it runs belongs in **`App::Yath2`**. `Test2::Harness2` holds only
    a **state-only** representation of that per-file decision data. The `test` /
    `run` commands gather the files, compute that state in `App::Yath2`, then
    **queue the run with jobs carrying the already-computed state** — the runner
    consumes pre-decided state and does no file reading/parsing to plan a run.
    (`Test2::Harness2::TestFile` currently mixes both roles and is split to match
    this: the file-reading/decision logic moves to `App::Yath2`, leaving a plain
    state object in `Test2::Harness2`.)
- **Versions.** Every module's version moves to **`2.000000`**.
- **The `yath` script** is provided by `App::Yath::Script` (an external module
  that discovers and loads our implementation). A `V2` entry point
  (`App::Yath::Script::V2`) selects the 2.0 `App::Yath2` implementation. This
  distribution does not ship its own `yath` binary.
- **Dependency direction.** `Test2::Harness2` must not load `App::Yath2*`
  except when explicitly driven by user-provided options. The collector comes
  from the external `Test2-Collector` distribution and never depends back on
  this one (§2.8).

### 1.1 Migration order `[migrating]`

The end state is reached in chunks, each small enough for a human to review
and each keeping the test suite green. Per-chunk status (done / in progress /
not started) + dependencies + the tickets that implement each chunk are tracked
in `TODO_STEPS.md` (commit history lives in git). The intended order, roughly:

1. **Mechanical renames** — `App::Yath` → `App::Yath2`,
   `Test2::Harness` → `Test2::Harness2`; versions → `2.000000`;
   `App::Yath::Script::V2` entry point.
2. **Argument processing** — migrate option handling to `Getopt::Yath` (§2.3).
3. **Collector swap** — adopt `Test2-Collector` for executing and auditing
   tests; simplify the yath-side collector to gather events from the
   `.jsonl.zst` files the collector writes, instead of receiving and
   parsing/auditing raw events itself (§4.1).
4. **Collectors everywhere** — wrap every yath-started process in a collector,
   not just tests: the runner and each preload stage (§4.1, §4.2, §4.7).
5. **Runner service + socket IPC** — make the runner a collected service with a
   unix socket; collapse the scheduler from a separate process into an
   in-runner object; make preload stages socketed services the runner
   dispatches to; carry run submission, job dispatch, and transitions over
   sockets with Monitor-style state sync; retire the
   `queue.jsonl` / `run_queue.jsonl` / `dispatch.jsonl` coordination files
   (§4.2, §4.3, §4.7, §5.2-5.3). This subsumes the old "transition pipelining"
   step.
6. **Renderer rewrite** — a base renderer / role that knows how to locate the
   `.jsonl.zst` files (§4.5). An interim step first moves renderers into the
   `test` / `run` command processes; see `TODO_STEPS.md`.
7. **System-load service** — a global harness service that samples CPU/memory
   load on a reliable tick (its own process; the runner loop can exceed the
   sample interval) and reports it to the runner so the scheduler can gate
   concurrency in addition to or instead of a static `-j` (§4.4).
8. **Database + UI inline** — rewrite the former `Test2-Harness-UI` DB+UI
   layer inline in `App::Yath2`, with `DBIx::QuickORM` schema and sqlite log
   files (§4.6). Landed as an interim `DBIx::Class` import (8a); the
   `DBIx::QuickORM` conversion is 8b.

The chunks above (1-8a) have landed; the items below are the **post-6
revised-target** work, settled after chunks 1-8a shipped (the `thoughts` /
`thoughts2` decisions, §4.4/§4.7/§4.8/§5.2/§5.3 and §1). They re-shape several
already-shipped mechanisms, so they are planned changes, not done. Numeric order
is **not** execution order here — dependencies are noted inline:

9. **Unified symmetric service channel** (§5.2) — replace the separate
   inbound/outbound pools and the two one-way runner↔stage channels with **one
   bidirectional, reused connection per process-pair**, in a single connection
   set, behind a shared Role/base class. **Prerequisite for 7, 10, 13, 16.**
10. **Preload stage self-registration + lifecycle** (§4.7) — a stage connects to
    the runner, registers, reports its own state, and owns its restarts; the
    runner dispatches over that registered channel. Depends on 9.
11. **Preload as a resource** (§4.7a) — model preload availability as a scheduler
    resource so jobs gate on it like any other resource. Depends on 10.
12. **Discovery via runner-socket symlink** (§5.3) — replace `yath-persist.json`
    with a well-known symlink to `runner.socket`; clients read the workdir `PID`
    file as a signal-fallback when the socket is unresponsive.
13. **`spawn` bypasses the runner** (§4.8) — connect directly to a stage socket,
    share IO over the socket (dup2 onto the child's std streams), double-fork the
    child with no collector. Depends on 9, 10, 12.
14. **Split `Test2::Harness2::TestFile`** (§1) — move file-reading/decision logic
    into `App::Yath2` (alongside `App::Yath2::RunPlan`); leave a state-only
    object in `Test2::Harness2`; queue jobs carrying the pre-computed state.
15. **Final renderer ordering** — the cross-job ordering guarantees on top of the
    §4.5 base renderer (the current `Renderer::Driver` per-job ordering is interim).
16. **Concurrent run execution + run-scoped preload stages** — multiple runs
    progressing at once on a persistent runner, and run-scoped preload stages as
    a user feature (naming `runs/<run_id>/preload-<stage>.socket` is reserved,
    §6.1). Depends on 9, 10.

Note **chunk 7 (system-load service) depends on chunk 9** — it is a full service
on the unified connection model.

The order is a guide, not a contract; chunks may be reordered or split as the
work demands.

## 2. Foundational rules

These are non-negotiable. New and migrated code must follow them; any future
exception must be recorded as an addendum to this document.

### 2.1 Object orientation

- Objects use `Object::HashBase`.
- Roles use `Role::Tiny` / `Role::Tiny::With`.
- Inheritance uses `parent`, not `base`.
- `Object::HashBase` and `Role::Tiny` compose freely — `Object::HashBase` may
  be used inside roles and by classes that consume roles.

Style rules tied to object orientation (slot ordering, "named subs in object
modules must be methods, not functions", and the rest) are in `STYLE_GUIDE.md`.

### 2.2 UUIDs

UUIDs are generated in Perl, using `Test2::Util::UUID`, never in the database.
They are v7; do not re-pack bits for index locality — v7 is already
time-ordered.

### 2.3 Argument parsing: `Getopt::Yath`

Command-line and option processing is handled by **`Getopt::Yath`**, and the
settings object is **`Getopt::Yath::Settings`**. The 1.0 `App::Yath::Options`
machinery has been removed.

### 2.4 Databases

- The schema is defined with **`DBIx::QuickORM`** (schema-as-Perl), not
  hand-written DDL files and **not `DBIx::Class`**.
- The default backend is **`DBD::SQLite`** used directly. Log files are sqlite
  databases (§4.6).
- UUIDs are generated in Perl as v7 (§2.2), never by the database.
- Non-default flavors (Postgres, MySQL, MariaDB, Percona) are driver-loaded on
  demand; their `DBD::*` modules are Suggests / Recommends in `dist.ini`,
  never hard requires.
- `DBIx::QuickDB` is used for ephemeral test databases and for spinning up
  non-default flavors on the fly; never for the default sqlite path.

### 2.5 No `IPC::Manager`

Earlier rewrite attempts routed cross-process coordination through
`IPC::Manager`. The 2.0 architecture **does not use `IPC::Manager`**. Transient
bytes between processes go through `Atomic::Pipe` (the test child → its
collector pipe). **Cross-process coordination and dispatch** — submitting a run,
dispatching a job to a preload stage, reporting a transition — flows over
**unix-domain sockets in the collector wire format** (§4.2, §4.3, §4.7, §5.2),
**not** through polled coordination files. The only files on the target IPC path
are the per-collector `.jsonl.zst` events files, read for display/archival
(§4.5), never for decisions; the 1.0 `queue.jsonl` / `run_queue.jsonl` /
`dispatch.jsonl` files are retired. If a reference doc or a snippet of
`reference/` code calls for `IPC::Manager`, treat that as outdated and follow
this document.

### 2.6 Minimum Perl version `[target]`

The harness targets **Perl 5.38.0** as its floor. New and migrated modules
start with `use v5.38;`, which enables `strict`, `warnings`, and stable
`signatures` in one line. Modules inherited from 1.0 still use
`strict`/`warnings` directly and adopt `use v5.38;` as their migration chunk
touches them. `STYLE_GUIDE.md` ("Minimum Perl and subroutine signatures")
owns the usage rule.

### 2.7 Reference trees are immutable

`reference/` holds prior iterations for reading: `legacy/` (1.0), `botched/`
(a failed refactor), `old2/` / `old3/` / `old4/` (earlier 2.0 attempts), plus
snapshots of abandoned 2.0 feature branches — `2.0b/` (collector swap to
`Test2-Collector` + Monitor + harness-service MVP), `harness_service/`
(`Role::Service`, scheduler, system-load service), `dbix_quickorm/` (a refined
`DBIx::QuickORM` layer), `painter/` (an event-painting renderer), and
`io_events/` (in-tree formatter IO-events before the `Test2-Collector`
extraction). `reference/notes/` holds working notes captured from that
abandoned-branch era. Nothing under `reference/` is edited in place — copy out and
modify the copy. When a reference's behavior conflicts with this document,
this document wins and the conflict gets flagged.

### 2.8 The collector comes from `Test2-Collector`

The collector pipeline — spawn one process, capture everything it produces,
feed it through `parser -> processors -> recorder + reporter` — is **not** part
of this distribution. It lives in the standalone **`Test2-Collector`**
distribution (`Test2::Collector` namespace; working checkout at
`~/projects/Test2/Test2-Collector`). That distribution's own `ARCHITECTURE.md`
is the authoritative spec for the collector contract; §4.1 here documents only
the boundary the harness consumes.

`Test2-Collector` is a hard dependency and must be installed (declared in
`dist.ini`). The dependency points one way: `Test2::Collector` never loads
`Test2::Harness2*` or `App::Yath2*`.

## 3. Repository layout `[migrating]`

Layout the architecture depends on. The renamed `lib/` paths are in place;
`lib/Test2/Harness2/Role/`, `t/AI/`, and `AI_DOCS/` appear as the first work
that needs them lands:

- `lib/Test2/Harness2/` — harness library code (from `lib/Test2/Harness/`).
- `lib/Test2/Harness2/Util/` — leaf utilities the harness alone needs.
  Wire-format and IPC utilities (JSON, zstd framing, unix sockets) come from
  `Test2::Collector::Util::*` (§2.8) — do not re-grow harness copies.
- `lib/Test2/Harness2/Role/` — `Role::Tiny` roles consumed by harness code.
- `lib/App/Yath2/` — user-interface code (from `lib/App/Yath/`), including the
  inline database + UI layer (§4.6).
- `t/` — human-authored tests; `t/AI/` — AI-generated tests mirroring `t/`'s
  layout.
- `reference/` — historical iterations; immutable, see §2.7.
- `AI_DOCS/<YYYY-MM-DD>-<slug>.md` — durable context for non-trivial decisions.

## 4. Subsystems

Each subsystem is described at the level of its responsibility, the contract
it exposes, and the invariants it relies on — not at implementation depth.
Detail re-accretes here as each chunk is migrated from 1.0. Subsections are
numbered stably; a retired subsystem's number is not reused.

### 4.1 Collectors `[target]`

**Responsibility.** A collector spawns one process, captures everything it
produces, and feeds it through `bytes -> parser -> processors -> recorder +
reporter`, where the **recorder** sink writes the full event stream to one
`jsonl.zst` events file and the **reporter** sink emits only transitions
(§4.3). That machinery is owned by `Test2-Collector` (§2.8).

**Target shape.** Two changes from 1.0:

- **`Test2-Collector` executes and audits tests.** The yath-side collector
  stops receiving and parsing/auditing raw events. Instead it consumes the
  `.jsonl.zst` files the collector writes — auditing happens inside the
  collector pipeline, and yath reads the recorded result. (Chunk 3 did this
  with a standing yath-side **gatherer** process that walks the workdir for
  those files; the end state removes that gatherer — see §4.2 — and reads a
  specific events file **by path on demand**.)
- **Every yath-started process is a collector** — with one exception. The
  runner, each preload stage, and auxiliary harness services (e.g. the
  system-load service, §4.4) all run as (non-test) collectors, so every process
  speaks one wire format and records one kind of events file (§4.2). The
  exception is a **`yath spawn`** child, which runs under **no collector** (§4.8):
  it is detached from the harness and not a harness-tracked result.

**Collectors watch the runner and self-terminate (invariant).** Every collector
spawned **under a runner** (test jobs, preload stages — directly or via a stage)
is given the **runner's pid — and only the runner's pid — to watch**
(`Test2::Collector`'s `watch_parent_pid`). If the runner process disappears while
the collector's child is still running, the collector **kills its child and
finalizes/exits itself**. A collector watches the runner, **never an intermediate
stage**: a stage may **intentionally restart** (a preload reload) with a new pid,
and that must **not** take its in-flight test down — only the runner going away
does. This makes collectors
reliably self-terminating even when the runner dies *without* getting to signal
them (a crash, `SIGKILL`, or any uncatchable death) — it is the fallback behind
the runner's normal process-group `killall`, not a replacement for it. Combined
with the rule that **no harness child (except `yath spawn`) may survive the
runner**, this guarantees a dead runner leaves no orphaned collectors or test
processes. The runner's *own* collector wrap is exempt (its child *is* the
runner). A `yath spawn` child is exempt (§4.8): it has no collector and is the one
process meant to outlive the harness.

**Liveness, completion, and reaping (see §5.4).** `watch_parent_pid` is the
collector's own defense against a dead runner. In the other direction, the runner
learns a test collector finished from the **EOF on that collector's transition
connection** to `runner.socket` (never a pid check), and decides the test's outcome
purely from the collector's transitions (`harness_final_state` / `halt`) — never
from the collector's exit code. The runner is a **child subreaper** so it owns
reaping for the whole tree; preload-spawned collectors **double-fork and detach** so
the preload tree reaps nothing. The full model — the decision algorithm, the
"no final state ⇒ fail" invariant, collector-exit-is-health-only, and the
subreaper/reparenting mechanism (`Test2::Harness2::Util::SubReaper`) — is in §5.4.

### 4.2 Main harness service `[target]`

**Responsibility.** One long-running **runner** service owns the canonical run
state and does scheduling and job dispatch. It is itself a collector (§4.1):
`Test2::Harness2::Runner->start` (or equivalent) launches the runner process
under a non-test collector, then runs a service loop. Each test, and each
non-test process it starts, runs under its own collector. There is **one runner
process** — the scheduler is an **object inside it**, not a separate process.

**The runner does not hold preloaded state (chunk 19).** When preloads are
configured (and not below `preload_threshold`), the runner **spawns a separate
preload-root process** (`Runner::spawn_preload_root`: a collector running
`perl -MTest2::Harness2::Preload=launch,<runner.socket> -e 1;`) that loads the
preloads, hosts the stages, and forks the tests (§4.7). The runner then goes
**scheduler-only** (`Runner::run_scheduler_only`): it loads no preloads, runs no
stage, never enters `BEGIN`/goto-file, and simply schedules and dispatches each
task out over the channel the hosting stage opened to it. The runner reaps the
preload-root (tracked outside its child-wait set so it never trips the
`waitpid(-1)` reaper). With **no** preloads — or below the threshold — there is
no preload-root and the runner forks each test-job collector itself directly
(unchanged). This keeps preloaded interpreter state out of the orchestrator.

**Contract.**

- The service holds the **canonical state** for a run in an in-process **state
  object**; other components learn state from it (§4.3) rather than
  reconstructing it from raw events.
- It exposes a **unix socket** (`runner.socket` in the workdir, §5.3) for
  requests. Commands are **thin clients** that connect and **submit runs as JSON
  over it** (replacing the 1.0 `queue.jsonl` / `run_queue.jsonl` files); they do
  not own run state. `yath test` is the per-run / transient client and uses this
  baseline directly. `yath run` / `yath start` are the **persistent** path and
  now run on the same socket model — **routed per run, execution serialized**
  (§6.1 resolved). Disentangling `test` / `start` / `run` into thin clients of
  this one service is an explicit goal of the migration.
- **Lifespan.** Two modes. *Transient* (`yath test`): the service shuts down
  and exits once all submitted runs finish and their transition queues drain.
  *Persistent* (`yath start`): it stays alive listening on `runner.socket`
  until a client sends an explicit shutdown request (e.g. a future `yath stop`).
- **Scope (per-run vs global) — resolved (§6.1).** A single `runner.socket` in
  *the workdir* serves both the transient `yath test` baseline and the persistent
  `yath start` + `yath run` path. The persistent runner runs **one active run at a
  time** but **routes each client only its own run's** transitions (canonical
  state keyed by run; stage/runner-lifecycle transitions broadcast as a global
  bucket). Concurrent run *execution* and run-scoped preload stages remain future
  work (chunk 16, §6.1).
- **The scheduler is an in-runner object, ticked each service-loop iteration.**
  The loop IO-polls the socket (an arriving transition or request forces a
  prompt wakeup) and also ticks on a timer; on each tick the scheduler advances
  pending → running as resources allow. There is no separate scheduler process
  and no `dispatch.jsonl` / flock coordination file.
- **On connect, a client receives a serialized snapshot of the run state**, and
  thereafter the runner **forwards every state-mutating transition** to clients
  that asked for them (Monitor-style sync, §4.3).
- **Two distinct runner outputs — do not conflate them.** (1) The runner's own
  *collector lifecycle* transitions go to its **events file**; it does not
  connect to `runner.socket` to report to itself. (2) State mutations the runner
  *originates* (e.g. a job it scheduled) are still **forwarded to subscribed
  clients** like any other state change, so the snapshot-plus-transitions
  contract above stays whole. Every *other* collector reports its transitions to
  `runner.socket` (§4.3).
- **Completion comes from transitions, not reaping.** Collectors are not
  necessarily direct children of the service, so it must not depend on
  `waitpid` to learn that one finished; the finalized transition on the
  channel is the completion signal. Reaping is a local detail for whichever
  process forked the collector.
- **This replaces the yath-side gatherer.** There is **no separate
  tree-walking gatherer process** — the 1.0 `Test2::Harness2::Collector` loop
  (distinct from `Test2-Collector`) that polled the queue/job files and walked
  the workdir for `events.jsonl.zst`, reconstructed run state, rolled up
  verdicts, and decided completion is gone. The runner service *is* the state
  authority; completion arrives as a transition; a consumer that wants full
  detail reads the relevant events file **by the path its transition carries**
  (§4.3).
- **The gatherer's non-walking duties move into the runner service/scheduler:**
  stalled-job detection, run-level timeout aborts, and verdict rollup become
  tick-loop work over the canonical state (per-test silence/lifetime timeouts
  already live in the `Test2-Collector` parent, §4.1). Final-state / summary
  handling (`harness_final`) moves to the command-side renderer (§4.5 migration
  note).
- **`JobReader` / `RunnerReader` survive only as by-path readers** of a single
  events file, not as a discovery/orchestration loop. Because the
  `Test2::Harness2::Collector` gatherer class is deleted, they move **out of the
  `Test2::Harness2::Collector::*` namespace** into a neutral `Test2::Harness2::*`
  namespace — reading recorded events is *producing-results* data access
  (`Test2::Harness2`), consumed by `App::Yath2` display code.
- **Run state is owned by the `Run` object and retained per the queuing client.**
  A run's data — its raw queue item, its job states, its lifecycle — lives **on the
  one canonical `Run` object** (no parallel `run_items` hash). Each run records the
  **connection that queued it** (the command's peer connection + its `peer_pid` from
  the §5.2 identity handshake, bloat #1) and an **`abort_on_disconnect` flag
  (default true)**. Retention and teardown are gated on that owner connection,
  **not** on completion:
  - **Finished + owner connected** → retained (the command may still query it).
  - **Finished + owner gone** → purged (Run object + job states + raw item).
  - **Running + owner drops, `abort_on_disconnect` true (default)** → the runner
    **aborts the run**: halt its pending tasks, kill its running jobs (signal their
    collectors → kill the test process groups), mark it aborted, and advance to the
    next run. A vanished `run`/`test` command means a crash or a user kill, which
    intends to kill the run.
  - **Running + owner drops, `abort_on_disconnect` false** → the run is **detached**:
    it keeps running (results persist to events/DB) and is purged on completion.
    This flag enables a future queue-and-detach command (e.g. `yath queue`) that
    exits without watching in real time.

  This bounds a persistent runner's in-memory run state by **live client
  connections**, not by total runs ever queued, and reuses the watchdog's
  `abort_remaining` (scoped to the run) for the abort path. A run's control
  requests (`queue_task`/`stop_run`) are accepted from **any** command connection,
  not only the owner — only *retention/abort* is tied to the owner.
- **Preload-root crash terminates a persistent runner.** If the preload-root exits
  unexpectedly (a crash, not a clean stop) the runner cannot host preloaded runs and
  does **not** respawn it (bloat #3) — the persistent runner **terminates**
  (active runs fail; this is not a per-run condition the runner papers over). This is
  deliberate: it prevents accidentally recreating respawn-like behavior. The narrower
  resilience that *is* wanted lives in the stages: when **reload is enabled**, a
  stage with a **broken preload** should catch the load failure, stay alive in an
  error state, and **reload the module once it is fixed** — rather than letting the
  whole stage/process die (§4.7).

### 4.3 Transition channel and state sync `[target]`

**Responsibility.** Carry the small, high-value set of per-collector
occurrences — start, each state transition, final state, finalized — from
every collector to the main harness, and from the main harness to other
consumers. This replaces 1.0's model of broadcasting the full per-event stream
everywhere.

**Contract.**

- **Collectors report transitions to the main harness.** A collector's
  reporter connects out to a socket and streams its transitions; the main
  harness folds them into canonical state (Monitor-style sync, prototyped on
  the abandoned 2.0b branch — see `reference/2.0b/`).
- **The main harness's own transitions go to its events file**, not over the
  channel — it is the hub, not a reporter to itself. Everything *else* (test
  jobs and preload-stage collectors) reports to `runner.socket`.
- **Other consumers get transitions from the main harness**, not directly from
  every collector. The harness is the hub.
- **Full detail is pulled on demand.** Transitions carry each collector's
  events-file path, so a renderer or other consumer that needs the full event
  stream reads that collector's `.jsonl.zst` file directly, when and if it
  cares. No component rebroadcasts the full stream, and **no standing gatherer
  reconstructs state by walking the tree** (§4.2) — reads are by path.
- **Wire form.** Unix-domain stream sockets; messages are transition events,
  JSON-encoded and zstd-compressed into self-contained frames, each carrying
  the collector `uuid`. See §5.2.

### 4.4 System-load service `[target]`

**Responsibility.** Report system load (CPU, memory) so the scheduler can gate
how many tests run concurrently — in addition to, or instead of, a static `-j`.
Prototyped on the abandoned `harness_service` branch
(`reference/harness_service/`, `t2h2_sysload`).

**Contract.**

- It runs as its **own (global) harness service process** — *not* folded into
  the runner. Load sampling needs a **reliable, fixed tick**, and the runner's
  service loop can have iterations that exceed that interval, so it cannot
  sample inline.
- It is a non-test collector and a **full service on the shared connection model
  (§5.2)**: it has **its own listen socket** and, on startup, **connects to the
  runner** so it can immediately push load updates there. Any other process may
  also connect to the system-load service's socket to receive updates; the
  service **broadcasts each load state-change (a threshold crossing) to all
  connected peers**. Because the connection model is symmetric (§5.2), the same
  channel a peer opened (or that the service opened to the runner) carries the
  updates regardless of which side connected.
- The scheduler in the runner (§4.2) consumes those updates to decide when a
  slot may open, combining the load signal with any static `-j` limit.

All such services are **global** — there are no per-run services (§4.7). The
older rule that an emit-only auxiliary service has *no socket of its own* is
superseded by the unified connection model (§5.2): every service has one listen
socket, and reaching out vs being reached are the same channel.

**§4.4 addendum — gating policy and realized implementation (chunk 7 / #43,
`[landed]`).** The previously-undefined gating policy is now pinned, and the
sampler half is landed:

- **The sampler is `Test2::Harness2::Service::Sampler`** (consuming
  `Test2::Harness2::Role::Service`) over the sampling primitive
  `Test2::Harness2::SystemLoad` (cpu_pct/mem_pct/mem_*/load_avg via Linux `/proc`,
  BSD `sysctl`; first sample reports `cpu_pct` undef as a baseline since CPU% is a
  two-reading delta). The runner spawns it **always-on** at startup
  (`Runner::spawn_sampler`) as a global helper under a collector — the same shape
  as the preload-root, with `watch_parent_pid` = runner so it self-terminates if
  the runner dies. It is spawned whenever the runner runs, **independent of whether
  a throttling resource was requested**, so its transitions are always logged.
- **Steady 0.2s tick; change-gated reporting.** It samples every tick but reports
  only on a change. CPU and memory are each rounded **up to the nearest 5%** and
  tracked independently with the same policy: an **increase reports immediately**, a
  **decrease only after the lower value holds `decrease_delay` (1.0s ≈ 5 ticks)**,
  an unchanged value reports nothing. A message carries the current rounded value of
  both metrics (plus the load average).
- **One-way `system_load` reports to `runner.socket`.** The sampler dials the runner
  as a service peer (identity handshake) and sends one-way `system_load` requests.
  The runner's `request_handler_system_load` stores the snapshot in its canonical
  `State` (`set_system_load`) **and** announces a `harness_system` transition
  (`announce_system_load`) that is **broadcast globally** (run-less) to every
  subscriber, with only the latest retained for a late subscriber (folded into
  `Runner::Monitor`'s `system_load` slot, carried in every snapshot).
- **Reap-at-stop gotcha (handled).** The sampler's collector inherits the runner's
  std-fd write ends, so the runner reaps it (`Runner::stop_sampler`) before exit —
  graceful `stop` over the socket, then a TERM→KILL+reap fallback — so the runner's
  own collector is not held open past shutdown by an orphaned sampler. (The 30s
  `_read_one_frame` EOF busy-spin the reference AI_DOC root-caused does **not** exist
  on 2.0d: the current `Role::Service::Connection::drain` already treats `sysread`
  == 0 / a fatal read error as connection-closed and drops the connection.)

**Gating policy = opt-in throttling resources (not a scheduler check).** Throttling
is modeled as scheduler **resources** composing the #24 Resource Role plus a new
`Test2::Harness2::Role::Resource::Utilizer`, reading the runner's shared
`system_load` snapshot (via a `State` backref) rather than sampling `/proc` inline —
so they are cross-platform (Linux + BSD):

- **`Resource::CPU`** — `available` returns **0 (defer, a transient wait)** when the
  rounded reported `cpu% >= utilize_percent` (default **80**); opt-in `-R CPU[=70]`.
- **`Resource::Memory`** — defers when reported free memory `< min_free` (default
  **5%** of total, or an absolute `512mb`); opt-in `-R Memory[=20%|512mb]`. When
  `--utilize PCT` is also set the more **conservative** free-memory floor wins
  (`(100-PCT)%`).
- **Utilizer starvation floor.** A resource defers **only when `in_flight >=
  min_concurrent`** (default **1**), so at least that many tests always run even
  under sustained saturation; the scheduler never stalls. A throttle is always a
  defer (`0`), never a permanent skip (`-1`).
- **`--utilize`/`-U`** sets the shared utilization-threshold percentage the
  utilization-aware resources read. All throttling is **off by default** (opt in
  with `-R`).

### 4.5 Renderers `[target]`

**Responsibility.** Format and display results — live during a run, and from
archived runs after the fact. A rewrite of 1.0's renderers.

**Contract.**

- A **base renderer (or renderer role)** knows how to locate a collector's
  `.jsonl.zst` events file from the transition state (§4.3), so concrete
  renderers consume recorded events rather than a live broadcast.
- Renderers are consumers of the transition channel for liveness and of the
  events files for detail.
- **The event source generalizes from a path to a byte source.** "Locate a
  collector's events file" is, for a live run, an on-disk `.jsonl.zst` **path**; for
  an archived run it is an **artifact blob** read from the log database (§4.6). The
  collector-events reader (`JobReader` / `RunnerReader`, path-only today) is
  generalized to read either, so the same decode + dispatch path serves live and
  archived rendering. The driving loop and the live/archive sources are the §4.12
  render-loop library. *(Forward-looking; the archive half lands with the DB-layer
  rewrite.)*

**Status — base renderer landed.** The base renderer is
`Test2::Harness2::Renderer::Base`: it holds a transition-state mirror
(`Runner::Monitor`, fed by `Runner::Subscriber`), locates each collector's
`.jsonl.zst` from that state, reads it by path (`JobReader` / `RunnerReader`),
computes the run rollup (`harness_final`), and fans recorded events out to
concrete `render_event` **sink** renderers (`Renderer::Formatter` →
`Test2::Formatter::*` for the terminal; `App::Yath2::Renderer::{DB,Server}`) plus
the logger. `test` / `run` render through it; `yath watch` is a global
(no-run-id) subscriber that renders runner/stage output through the same base.

**Interim ordering still in place (one follow-up).** The per-job 3-phase ordering
(a job's transitions live, then its whole events file at completion, then its
final status) lives in `Renderer::Base`'s thin subclass `Renderer::Driver`, not
in the base — so a future streaming / cross-job-chronological renderer can sit on
the same base. That interim per-job ordering is **not** the final renderer
contract; the final ordering guarantees are not pinned here — §4.5 stays
authoritative for the final shape.

### 4.6 Logs and database `[target]`

**Responsibility.** Persist runs for archival, querying, and the UI. Replaces
the former separate `Test2-Harness-UI` distribution, rewritten inline in
`App::Yath2`.

**Contract.**

- **Log files are sqlite databases.** A run's `events.jsonl.zst` files are
  stored in the database's artifacts tables, so a log file is a single,
  self-contained, queryable artifact.
- The schema is defined with **`DBIx::QuickORM`** (§2.4); the default backend
  is `DBD::SQLite` used directly.
- The database is for storing / archiving / querying logs and driving the UI;
  it is **not** the live cross-process coordination substrate (that is the
  transition channel, §4.3).
- **The render-loop library's `ArchiveProducer` (§4.12) is the read/render consumer
  of this store** — the DB renderer is the *write* side (it ingests a live run's
  events into the artifacts tables); the `ArchiveProducer` is the *read* side (it
  renders a stored run back out from the artifact blobs + state rows). The current
  DB layer is legacy lifted for backcompat; the concrete artifact-blob shape and the
  `ArchiveProducer` are settled by the (not-yet-specced) DB-layer rewrite, not here.

### 4.7 Preload stage services `[migrating]`

**Responsibility.** Each preload stage runs as its own (non-test) collector
(§4.1) **and** as a service with its own unix socket (`preload-<stage>.socket`
in the workdir, §5.3). A stage holds the preloaded interpreter state from which
matching tests are forked.

**A separate preload-root hosts the stages (chunk 19).** The stages are **not**
forked by the runner; the runner spawns one **preload-root** process (§4.2) and
the preload-root hosts them. Concretely (`Test2::Harness2::Preload`): the runner
execs `perl -MTest2::Harness2::Preload=launch,<runner.socket> -e 1;` under a
collector; that process establishes the `Long::Jump`/goto-file host in `BEGIN`,
dials `runner.socket` and identifies as **`preload-root`**, and fetches the preload
specs (`get_preload_list`). The handshake is **lightweight — it does not load the
preloads or build the stage map**. It then drives a **stage-host `Runner` whose
`rootpid` is the real runner's pid**, so that inner Runner hosts the
base/default/NOPRELOAD stage **in-process** and forks the named stages as its own
children. The preloads are loaded **once, inside the `test2_start_preload` guard**
(the stage-host's preload flow), which also builds the `TEST2_HARNESS_PRELOAD` meta;
the stage map (`set_stage_data`) and any preload warnings are reported **after** that
guarded load, not at the handshake. The **map is the only thing the preloads report
about routing** — which stages exist, which is `default`, and live state
(`starting`/`up`/`restarting`/`down`). Preloads make **no test-routing decisions**:
there is no `resolve_file_stages` round-trip, no `file_stage` callbacks, and no
`eager` stages (§4.7a — stage selection is decided client-side from test directives).
**The runner blocks scheduling until the map arrives** — it knows preloads are
configured, so it waits (the existing `_ready_to_schedule` gate) rather than
scheduling without a stage map. This ordering avoids loading preload modules (and
their require-time Test2 side effects) *outside* the guard, and removes the duplicate
handshake-time load. Each stage (in-process base or forked) dials `runner.socket` as
`preload-<name>` and reports up exactly as below. The **test-job goto-file launch**
runs in the preload-root/stage via `Test2::Harness2::Runner::JobLauncher` (extracted
from the `App::Yath2` runner command so `Test2::Harness2` loads no `App::Yath2`).
The `preload-root` is thus a new service-kind identity that **dials** `runner.socket`
and does **not** listen on a socket of its own.

**Stages do not reap test collectors (see §5.4).** A stage launches each test under
a collector that **double-forks and detaches**, so the collector re-parents away from
the stage — to the runner on a subreaper-supported OS, or to init otherwise. The
stage therefore has **no** test-collector reaping logic and makes **no** completion
or retry/bail decision; the test collector streams its transitions straight to
`runner.socket`, and the runner decides everything from those transitions + the
connection EOF. This is the same path the no-preload runner-launched collector takes,
which is why the two paths converge on one scheduler-only run loop (§5.4).

**Scope of services (decided).** All services are **global** harness services;
there are **no per-run services**. The service kinds are: the runner (§4.2),
preload stages (this section), and auxiliary harness services (e.g. the
system-load service §4.4). Every service has **one listen socket** and speaks
the **unified, symmetric connection model** (§5.2) — there are no separate
inbound/outbound channels and no service that lacks a socket. What is **dropped**
is the earlier run-vs-global service split and
run-specific *services* — an over-extrapolation from two concrete preload needs.
Those needs are met directly by **preload-stage scope** (a feature, not a
service class):

- **Global preload stages** — started with the runner, shared by every run
  (use case 1; already the inherited 1.0 behavior).
- **Run-scoped preload stages** — extra preload branches brought up when a run
  begins and torn down when it ends, applying only to that run's jobs (use
  case 2). A run-scoped stage is an ordinary preload-stage service whose
  lifecycle is bound to a run; it is **not** a per-run *service* class or any
  new service infrastructure.

**Contract.**

- **A stage registers itself with the runner (the stage initiates).** When a
  stage's preload is ready it **connects to the runner** and registers, opening
  the one shared bidirectional channel between them (§5.2). The runner may know
  it *tried* to start a stage, but **treats a stage as unavailable until it
  registers**. (This reverses the earlier "runner connects out to dispatch"
  direction.)
- **The stage owns its own lifecycle/state and reports it over that channel.**
  The stage itself decides when to restart (e.g. on a preload-file change) and
  reports readiness/teardown to the runner; the runner consumes that and does not
  drive the stage's restarts. (The explicit `starting` / `up` / `restarting` /
  `down` enum is in place — see `TODO_STEPS.md` chunk 10. **Stale-incarnation reports are
  rejected by connection-currency** — a report is honored only from the connection
  currently registered for that stage identity — **not** by a wire generation
  counter; the earlier per-report `generation` is removed, bloat #3.)
- **Restart is stage-initiated; respawned by the preload-root.** On its own
  restart trigger the stage reloads **in-place** (churn) when it can; otherwise it
  closes its channel and **exits**, and the **preload-root** (the stage's parent
  and reaper, chunk 19) spawns a **fresh** stage instance that reconnects and
  re-registers (reusing its `stage-<name>-events.jsonl.zst` for output continuity).
  Neither the runner nor the preload-root reaches in to restart a live stage — only
  one that has exited is respawned. (Previously the runner forked and respawned
  stages; that moved to the preload-root in chunk 19.)
- **A broken preload does not kill the stage (reload mode).** When reload is enabled,
  a stage whose preload **fails to load** (a syntax error / die in a watched module)
  should **catch the failure, stay alive in an error state, and reload the module
  once it is fixed** — not let the whole stage/process die. (This is the
  stage-local resilience that replaces, for the common "I broke a file, let me fix
  it" case, any urge to respawn the whole tree; preload-root *crash* is still fatal
  to a persistent runner, §4.2.)
- **Dispatch rides the same channel.** While a stage is `up`, the runner sends
  job-start / rerun requests over the **same** registered channel (not a second
  connection). Job results still arrive as transitions from each test job's own
  collector (§4.3).
- **The stage's listen socket is for `spawn`, not the runner.** A stage keeps
  its own `preload-<stage>.socket`, but it is used by `yath spawn` connecting
  **directly** to a stage (§4.8), bypassing the runner — not by the runner for
  dispatch.
- **Preload availability is a resource (§4.7a).** A stage's expected existence
  plus its current state (`up` etc.) is modeled as a **resource**, so jobs that
  need a given preload are gated on that resource the same way as any other
  resource, rather than through ad-hoc stage checks.
- **No-preload path.** When there are no preloads there are no stage services:
  the runner forks the test job's collector itself, directly.
- **Run-scoped stage lifecycle.** A run-scoped stage is brought up when its run
  begins and torn down when it ends (the stage still registers with the runner
  as above). Global stages outlive any single run. Run-scoped stage sockets must
  be run-qualified to avoid collisions (§5.3, §6.1).

**§4.7a Preload as a resource `[target]`.** When a run has a preload, preload
availability is modeled as a **scheduler resource** — the *preload resource* —
implementing the standard `available`/`assign`/`release` contract (§4.4,
`Test2::Harness2::Runner::Resource`). It **subsumes the ad-hoc stage-readiness
checks**, so preload-gated jobs flow through the same path as any other resource.

**Preloads make no test-routing decisions (decided).** The stage a test wants is
decided **entirely client-side, at queue time**, and carried on the test job — there
is **no file→stage resolver, no `resolve_file_stages` round-trip, no `file_stage`
callbacks, and no `eager` stages.** (The 1.0 preload-side auto-assignment + eager
were added but never effectively used; the real-world pattern is the harness
directive plus a plugin assigning stages at queue time. This codifies that.) The job
carries three preload fields, set by `App::Yath` test logic from the test's
directives and overridable by plugin hooks:

- **`no_preload`** (bool) — the test cannot run under a preload. Directive
  `# HARNESS-NO-PRELOAD` (the existing generic `NO-<feature>` parse → `features.preload=0`).
- **`require_preload`** (bool) — the listed stages are mandatory; no fallback.
  Directive `# HARNESS-STAGE-REQUIRE A B C` (parses as `$dir=stage`, leading
  `REQUIRE` keyword).
- **`preload_list`** (array, ordered preference) — preferred stages. Directive
  `# HARNESS-STAGE A B C` (the existing single-arg `HARNESS-STAGE` expanded to a
  list; one stage is a 1-element list). Empty with the others false ⟹ `default` stage.

**Directive syntax note:** the parser (`App::Yath2::TestFile`) takes the directive
name as the **first token only** (`split` on the first dash/space), so multi-word
names like `HARNESS-REQUIRE-PRELOAD` don't work — the required form is
`HARNESS-STAGE-REQUIRE …` (dir = `stage`). `REQUIRE` is therefore a reserved first
list element for the stage directive.

**Validation:** `no_preload` true ⟹ `require_preload` false and `preload_list`
empty. Enforced when the job is built and after plugin overrides.

The resource reads these three fields and resolves against the **local stage map**
(stages + which is `default` + live `starting`/`up`/`restarting`/`down` state) — no
communication with the preloads to make the decision:

- **Selection** = the **first stage in `preload_list` that is currently `up`**
  (first-to-become-available; it does **not** wait for a higher-preference stage).
  Empty list → the `default` stage. `no_preload` → the no-preload path (fork+exec,
  §4.1), not gated on this resource.
- **`available($task)` mapping** (stage lifecycle §4.7: `starting`/`up`/`restarting`/
  `down`):
  - **`1`** — a `preload_list` stage is `up` (assign the first such); **or** the
    list is exhausted/empty and the test is **advisory** (`require_preload` false) so
    it falls to the `default` stage.
  - **`0`** — no listed stage is `up` yet but ≥1 is `starting`/`restarting` (coming
    back) → the job **waits** (whichever becomes available first wins).
  - **`-1`** — none of the `preload_list` stages will ever be available **and** the
    test is **`require_preload`** → the job is skipped/failed. (An advisory test never
    returns `-1`: it falls to `default`.)
- **"Will never be available" = absent from the map (this is `down`'s setter).** A
  `preload_list` stage that is **not present in the current stage map** — a stage
  that was never configured, a misspelled name, or one removed by a map refresh — is
  **permanently unavailable for that map**: it contributes nothing to selection, and
  a `require_preload` test with no presentable stage gets `-1` (skip/fail)
  *deterministically* rather than sitting in `starting` forever. A stage **present in
  the map but with no current `up` peer** is `starting`/`restarting` (→ `0`, wait),
  **not** absent. A map refresh (reload) decides per stage whether a now-missing
  stage is dropped from the map (→ treated absent/permanent for new resolutions) or
  explicitly marked `down`. So `down`/absent is the concrete permanent-unavailable
  signal #2 reserved.
- **`assign($task, $state)` records the chosen stage on the job** (the first
  available listed stage, or `default` for an advisory miss), so dispatch sends it to
  the right `preload-<stage>` channel. A `no_preload` task gets no stage and is not
  gated on this resource.
- **`release()` is ~a no-op.** Preload is **not a bounded resource** — assigning a
  job to a stage consumes nothing, so there is nothing to free.
- **assign→launch is racy; the job is requeued, not failed.** A stage can go
  `down`/`restarting` between `available`/`assign` and the actual dispatch. When
  dispatch to the assigned stage finds it gone, the job is **put back in the queue**
  to be re-resolved and re-assigned on a later tick — *not* aborted, and *not*
  counted as a retry. This requeue primitive is required by the scheduler
  regardless (a stage that self-restarts mid-run, §4.7/#3, must not fail its
  in-flight-but-unlaunched jobs); the resource just makes it the normal path.
- **Startup-wait is the resource's job, with a configurable safeguard.** A stage may
  legitimately take minutes to preload, so there is **no fixed startup timeout** —
  tasks for a `starting`/`restarting` stage simply wait (`available` = `0`), and
  `done()` will not complete a run while tasks are pending. A *crashed* stage is
  detected by its socket EOF (§4.7/#3), so it never hangs the run. The remaining
  gap is a stage that is **alive but never reports ready** (hangs during preload **or
  during a `restarting`/reload**): to bound that, the resource enforces an
  **optional, configurable per-stage startup timeout** — generous and off-by-default
  so it never kills a legitimately-slow stage — after which a too-long `starting`
  **or `restarting`** flips to `available` = `-1` (skip/fail those tasks, or abort
  the stage). The stage-map / base-stage readiness deadline is likewise a
  **configurable setting**, not hardcoded (deployments with multi-minute preloads
  exist).

### 4.8 Spawn (`yath spawn`) `[target]`

**Responsibility.** `yath spawn` starts a single process **from a preloaded
interpreter** and attaches it to the caller's terminal — without coupling it to
the harness lifecycle. **Spawn requires a preload:** its entire purpose is to
start a process out of an existing preload stage, so with no preload available it
has nothing to do (it is meaningless / an error, not a fork-from-scratch
fallback).

**Contract.**

- **Spawn bypasses the runner.** It discovers the harness via the runner-socket
  symlink (§5.3), follows it to the workdir, inspects which
  `preload-<stage>.socket`s are available, and **connects directly to the chosen
  preload stage** (`Preload::Host`) to request the spawn. It does not go through the
  runner. "Available" means the stage's socket accepts a connection; a socket file
  whose stage is `starting` / `restarting` / `down` (or whose connect fails) is not
  a spawn target. When multiple stages match, stage selection follows the command
  options / run-plan match (the implementation pins the exact rule). The stage host
  carries a dedicated **`request_handler_spawn`** (it composes only `Role::Service`,
  so it must learn this command) that double-forks the supervisor **asynchronously**
  and acks `{ok=>1}` without blocking the host's service loop.
- **IO is shared by passing the command's real terminal descriptors (`SCM_RIGHTS`),
  not by proxying bytes.** This **supersedes the earlier dup2-socket-onto-stdio /
  "no fd-passing" stance** (an addendum-worthy deviation, see below): the command
  opens a **listen socket** and the spawned side **dials back** to it; the command
  then `send_fds` its actual `STDIN` / `STDOUT` / `STDERR` over the connection and
  the spawned side `recv_fds` + `dup2`s them onto `0` / `1` / `2`. The child then
  reads/writes the user's *real* terminal directly (single keystrokes, raw mode,
  `isatty`/termios) — the command leaves the byte path entirely (no pump). Because
  the command passes whatever its actual `0` / `1` / `2` are, terminal vs redirected
  streams (`yath spawn x 1>out 2>err`) are preserved with no merging and no PTY. The
  fd-pass primitive is `Test2::Harness2::Util::FdPass` over **`IO::FDPass`**, an
  **optional** dependency: with it absent, `yath spawn` errors early with an
  actionable message; it is never loaded on the normal `test` / `run` path. This
  replaces the 1.0 `/proc/<pid>/fd` IO-proxying.
  - **Limitation.** After a `setsid` detach the child has no *controlling*
    terminal, so `/dev/tty`, foreground-process-group checks, and
    terminal-generated `SIGINT` / `SIGTSTP` / `SIGWINCH` do not reach it natively —
    the command traps and **forwards** those over the control channel. Passing the
    tty fd gives `isatty`/termios/raw-mode reads, not controlling-terminal
    ownership. A child that leaves the terminal in raw mode on an abrupt death may
    require the user to run `reset` (the command is not proxying and cannot
    restore it).
- **One connection, two phases: fd-pass then a dedicated control protocol.** After
  the `SCM_RIGHTS` message (which carries a one-byte payload that the receiver
  consumes), the same socket becomes a **dedicated, tiny framed control channel**
  (not `Role::Service::Connection`, whose identity-first framing would collide with
  the raw fd-pass byte). It carries: the supervisor's pid, forwarded signals /
  window-size, and the child's **raw wait status** at exit (so a signal-death is
  reported and re-raised on the command exactly as the 1.0 `parse_exit` path does —
  not just a numeric exit code). The request payload to the stage carries
  `{file, args, env, cwd, abs_path, correlation_id, listen_socket_path}`.
- **The child is detached and runs with NO `exec` (preload-preserving): double-fork,
  no collector.** The supervisor is double-forked from the preloaded stage, so it
  *holds the preloaded image*. It forks a script child which **must not `exec`** (an
  `exec` would wipe the preload — the entire point of `spawn`); instead the script
  child `dup2`s the received fds onto `0`/`1`/`2`, runs post-fork sanitization
  (close inherited service/runner/collector sockets + the command listener — so the
  §5.4 EOF model is preserved — close the received fd duplicates after `dup2`, reset
  Test2, fire the stage `do_post_fork`/`do_pre_launch` hooks), and **unwinds into the
  preloaded interpreter via the existing `Long::Jump` + `goto::file` path** (the same
  mechanism the current `launch_spawn` uses). The supervisor `waitpid`s the script
  child, reports its raw wait status, and exits. A spawned process runs under **no
  collector** — it is not a harness-tracked result.
- **Detached from the harness, bound to its command.** The spawned process survives
  runner/stage teardown (it is reparented away), but it is **not** orphaned from the
  command: the supervisor watches its control connection and, on **EOF** (the
  `yath spawn` command/terminal died), kills the script's process group
  (`kill(-pgid)`; the detached child `setsid`s, so it leads its own group) and
  exits. It does not outlive the command.

### 4.9 Plugin lifecycle (`setup`/`teardown`, aux output) `[target]`

**Responsibility.** A plugin's `setup`/`teardown` are **runner-environment** hooks
— start/stop services the tests need, prepare/clean shared state — distinct from
the client/render-side `finalize`/`finish` hooks.

**Contract.**

- **`setup`/`teardown` run in the runner, not the command.** The runner invokes
  `setup` after its `runner.socket` is bound (before the run loop) and `teardown`
  after the run loop ends (transient end / persistent shutdown), root-process only.
  Running them in the command — before the runner (and its socket) exist — was the
  1.0-era mistake that forced flat `aux_logs` files; on the runner, aux output is a
  normal collector stream and any aux process is a runner child.
- **The runner reconstructs plugin instances from specs.** Plugins serialize to
  bare class names (`Plugin::TO_JSON`), so the command stashes the resolved specs
  (`Class` or `Class=arg1,arg2`) in `harness->plugin_specs`; the runner rebuilds the
  same instances (`require` + `->new(@args)`). Loading `App::Yath2::Plugin::*` in the
  runner is user-driven (the `-p` the user passed), which §2.8's dependency rule
  permits. (Consequence: the runner loads plugin modules, so test children forked
  from it inherit them in `%INC` — unlike 1.0, where the runner was a fresh `exec`.)
- **Aux output is collector events, not flat files.** `shellcall` (synchronous) and
  `run_collected` (non-blocking / daemon — replaces the old `fork` + `redirect_io`)
  run the command/coderef under a collector whose reporter streams to `runner.socket`
  and whose recorder writes an events file; the renderer tags its output with the
  plugin-chosen name (the historical `(NAME)` shape). Each aux collector watches the
  runner pid (§4.1), so it and its child die with the runner — there is **no detach**
  (unlike `yath spawn`, §4.8): nothing a plugin starts survives the runner.
- **Aux processes do not gate the runner.** A `run_collected` daemon's pid is tracked
  in a separate list (**not** the runner's child-wait set), so it never blocks the
  runner's `wait(all=>1)`; the runner `TERM`→`KILL`s and reaps it at `teardown`.

**Divergence from 1.0.** `reference/pre_ai_2.0/` split this into `client_*` (command)
and `instance_*` (runner) hooks purely to keep the 1.0 `Test2::Harness`/`App::Yath`
namespaces back-compatible. The `*2` namespaces have no such constraint, so a single
`setup`/`teardown` pair lives on the runner.

### 4.10 Interactive mode (`--interactive`) `[migrating]`

**Responsibility.** Interactive mode connects the **client** (`yath test` /
`yath run`) terminal IO to each test as it runs, so a test that prompts, drops into
a debugger (`perl -d`, `$DB::single`), or otherwise needs a live STDIN/TTY works
despite running deep in the runner's process tree.

**Contract.**

- **One test at a time.** Interactive forces `-j1` (tasks run in the `isolation`
  category), so exactly one test owns the client's IO at any moment — there is no
  contention for the shared terminal.
- **STDIN only — output stays with the collector.** Interactive shares **only the
  test's `STDIN`**; its `STDOUT`/`STDERR` continue to flow to the collector and
  render through the normal events-file path (§4.5). (This corrects the earlier
  "share `STDIN`/`STDOUT`/`STDERR`" wording: a test is a collected job, so its
  output must remain recorded; the user sees it via the rendered stream, as in 1.0.)
  Sharing only `STDIN` keeps the debugger UX of 1.0 (type into the real terminal,
  watch output via the renderer) — with its retained limitation that output round-
  trips through the renderer rather than appearing on a raw tty.
- **The STDIN fd is passed (`SCM_RIGHTS`), reusing the `spawn` primitive (§4.8).**
  The **command opens a listen socket only when `--interactive` is set**;
  `$ENV{YATH_INTERACTIVE}` carries that **socket path** (not a fifo path). The test
  **dials in, `recv_fds` the command's real `STDIN` fd, and `dup2`s it onto fd 0** —
  in the `goto::file` filter on the preload path, or via a pre-exec connect on the
  no-preload path. The test then reads the user's real terminal directly (single
  keystrokes, raw mode), not a proxied byte stream. The fd-pass util / `IO::FDPass`
  optionality and the controlling-terminal limitation are the same as §4.8.
- **One pass per test.** Because interactive is `-j1` there is no contention, but a
  run still has *N* sequential tests. The command keeps its listener open and passes
  the `STDIN` fd **once per test**, with a connect timeout + cleanup, and stops
  accepting once the run ends.
- **Replaces the FIFO IO-proxy.** The 1.0 implementation makes a FIFO
  (`POSIX::mkfifo`, sets `$ENV{YATH_INTERACTIVE}` to the fifo) and pumps the
  client's STDIN through the pipe, re-opening the test's STDIN from the fifo in a
  `goto::file` filter patch (`Runner::JobLauncher`). That proxy — and its broken
  open-retry loop — is removed in favor of the passed-fd path above.

### 4.11 Harness-client library `[target]`

**Responsibility.** One library — the bridge between `App::Yath2` and the
`Test2::Harness2` runner socket — that `test` / `start` / `run` construct and use,
so the command classes get thin. It owns submission, the finders, test-job-spec
building, the runner lifecycle, and the local runner-state mirror; it does **not**
own renderers (those are §4.12).

**Contract.**

- **Grow the existing `App::Yath2::Client` into the full bridge.** Today it wraps
  only the submit (`Runner::Client`) and subscribe (`Runner::Subscriber`)
  transports; it absorbs the rest:
  - **Runner lifecycle as a mode enum** — *transient* (spawn the collector-wrapped
    runner, own + reap + signal it, **trap+forward `INT`/`TERM`/`HUP` to the runner
    process group**), *attach* (discover the persistent runner via the §5.3 symlink,
    `kill(0)` liveness, never reap it), *start* (spawn the daemon, write the discovery
    state, return). This collapses the 1.0-era `run extends test` override pile and
    the inline runner spawn/reap/signal logic in the `test` command.
  - **Finders + job-spec building** — it owns `App::Yath2::RunPlan` (file discovery,
    plugin sort hooks, per-file task construction).
  - **State queries** — first-class accessors over the mirrored `Runner::Monitor`
    (`jobs_in_state`, `events_file_for($job)`, run/job rollup), so callers stop
    drilling `client->subscriber->monitor->…`.
- **The three commands collapse onto the client mode.** `test` = client *transient* +
  render loop; `run` = client *attach* + render loop; `start` = client *start*, no
  render loop. The transient-vs-persistent difference is a client mode, not a
  command-inheritance tree.
- **`spawn` uses the client only to discover stages.** It asks the client for the
  available preload stages, then connects directly to a `preload-<stage>.socket` and
  runs its own fd-pass + control-channel IO bridge (§4.8); it does not submit a run
  or use the render loop.

### 4.12 Render-loop library `[target]`

**Responsibility.** A generic render loop — separate from the harness-client (§4.11)
— that watches a source, gathers events, and feeds the sink renderers, so the loop
is not duplicated across `test` / `run` / `watch` / `replay`. It is reusable for
rendering a **live run or a stored log**.

**Contract.**

- **`RenderLoop` owns dispatch + the sink lifecycle + the run rollup.** It holds the
  sink renderers and an injected **Producer**, owns the `step` / `finish` / `signal`
  lifecycle and `compute_final`, and owns the dispatch fan-out (annotate → logger →
  sinks → handle plugins). It exposes `->iterate()` (one pass, for a command that
  owns its own loop and needs other per-tick work) and `->start()` /
  `->start(sub {…})` (the loop owns the iteration; the optional sub runs each tick).
  It lives in `App::Yath2` (display is a UI concern), wrapping the
  `Test2::Harness2::Renderer::Base` mechanics.
- **A `Producer` is a pure source** — `poll()` → *ordered events to render*,
  `done()` → bool (+ optional `finalize`). It does not dispatch or roll up. The
  variants:
  - **`LiveProducer`** — a `Runner::Subscriber`/`Monitor` mirror + the per-job
    ordering (the current `Renderer::Driver`'s ordering logic; its dispatch +
    `compute_final` + bounded `wait_terminal` move into the loop, preserving the
    false-FAIL fix), yielding events read from on-disk `.jsonl.zst` by path.
    `done()` = socket-closed (`test`) / `run_done` (`run`). The `watch` variant
    yields runner/service output only.
  - **`JSONLFileProducer`** — wraps the existing flat-`.jsonl` reader to keep
    `replay` working through the transition; thrown away once the DB-backed
    `ArchiveProducer` lands.
  - **`ArchiveProducer`** *(deferred to the DB-layer rewrite, §4.6)* — renders a log
    database (sqlite usually; importable into mysql/pg, possibly many runs per DB).
    It builds a `Monitor` snapshot from the DB's run/job/collector state rows
    (`apply_snapshot`) so the same ordering renders archived runs, and reads each
    collector's events from the **artifact blob** (the generalized by-path /
    by-blob reader, §4.5). Faithful re-render uses the blob, not a row-level event
    projection.
- **Designed for future child-process renderers.** Sinks are fed only self-contained
  `Event` objects (no shared in-memory command state), so a slow sink (DB writes)
  can later run its loop in a forked child fed events over a pipe — not built yet.

## 5. Cross-cutting concerns

### 5.1 Event compression: measured conclusions

The event encoding spans the test child (which serializes and sends events),
the collector pipeline (which receives, decodes, and records them), and the
on-disk events file. The implementation lives in `Test2-Collector` (§2.8), but
the conclusions bind anything in the harness that reads or writes these
formats. They were settled by measurement; recorded here so they are not
relitigated.

- **Compress each event in the test child before sending it over the pipe.**
  The zstd cost is small next to the cost of pushing a larger uncompressed
  payload through the pipe. The on-wire form is a zstd frame, not raw JSON.
- **Pass an already-compressed frame through verbatim whenever possible.**
  When an event still carries the compressed frame it arrived on and nothing
  downstream modified it, the recorder writes that frame to the events file
  as-is — no recompression. Only an event an auditor actually changed is
  re-encoded.
- **Do not buffer / batch writes to the events file.** Batching was prototyped
  and benchmarked: `syswrite` lands in the page cache, and the write time was
  a sub-1% slice of what the pipeline already spends decompressing and
  processing the same events. The only upside (a smaller events file from
  merged frames) is a disk-size win, not a speed win, and it would cost added
  recompression CPU, a flush timer, a new ordering invariant, and a change to
  the one-frame-per-record file format every reader depends on. The recorder
  writes one zstd frame per event, immediately, with no buffer.

### 5.2 Transition channel: unix sockets `[migrating]`

The wire is **unix-domain stream sockets** (`SOCK_STREAM`), not `Atomic::Pipe`,
everywhere. There are **two connection patterns**: short-lived **collector
reporters** (below) and long-lived **service channels** (next).

**Status.** Implemented in `Test2::Harness2::Role::Service` +
`Test2::Harness2::Role::Service::Connection` as a full bidirectional RPC: a
mandatory identity exchange on open, `{request=>{request_id,command,...}}` /
`{response=>{request_id,...}}` frames **correlated by id** (no ordering
assumption), and a bad-frame policy. It carries the **runner↔stage** channel
(stage dials, runner dispatches back over it) **and** every command connection
(commands are full peers, not a separate request/reply lane). Collector reporters
also identify first (via the `Test2-Collector` `Recorder::Socket` `preamble` hook,
which sends an identity frame carrying `no_reply` so the accepter does not reply) —
there is no identity exemption. The future system-load service (chunk 7) is the next
consumer.

**Collector reporters (effectively one-way, connect-out).** A per-process
collector's reporter streams its transitions and does not act on requests — but it
still **identifies first** like every other connection (there is no identity
exemption).

- **One connection per collector.** Frames from different collectors land on
  separate file descriptors and never interleave — atomicity by construction.
- **The reporter connects out and identifies.** The collector's reporter sink is
  given socket paths, connects to each, and **sends an identity frame first** (the
  `Test2-Collector` `Recorder::Socket` `preamble` hook, set by the harness to
  `{identity=>{name=>"collector:...", no_reply=>1}}`); it then streams transitions.
  The `no_reply` flag tells the accepter **not** to send its identity back: the
  reporter is one-way and never reads, so a reply would sit unread and, on close,
  turn into a TCP-RST that discards transitions the reader has not yet consumed.
  The reporter also drains+discards input defensively (the `drain_input` hook).
- **Message shape.** Each transition is JSON-encoded and zstd-compressed once into
  one self-contained frame, written with a blocking `syswrite` (retried on
  `EINTR`, `SIGPIPE` ignored so a vanished reader surfaces as a trappable error).
  The collector `uuid` rides on every message so any multiplexing reader can
  demultiplex. The start message additionally carries the collector name, the
  events-file path, the run association, and (for tests) the try number.

**Service channels (one symmetric, reused channel per pair).** Services — the
runner, preload stages, the system-load service — talk to each other over a
**single, bidirectional, reused** connection, not separate inbound/outbound
pools and not a channel per direction:

- **One listen socket per service; one connection set.** A service accepts new
  connections on its socket and adds them to its connection set. When it needs to
  reach another service it opens a connection and puts it in the **same** set.
- **Reuse, never duplicate.** If a connection between two processes already
  exists, it is reused. There is **never a second channel** between the same two
  processes — one channel carries traffic both ways regardless of which side
  established it.
- **Symmetric.** Once connected, **either end may send requests and responses**.
  (So, e.g., a preload stage connects to the runner to register, and the runner
  then sends job dispatch back over that same connection — §4.7.)
- **Identity exchange on connect.** A `SOCK_STREAM` accepted via `accept` carries
  no service identity, yet reuse and addressing require each side to know **which**
  peer is on the descriptor. So a connection **exchanges an identity frame**
  (`{identity=>{name=>...}}`) on open — the dialer announces itself, the accepter
  replies — **before** it carries requests. A non-identity first frame, or no
  identity within a timeout, drops the connection as bad. This applies to **every**
  connection, collector reporters included (they send their identity via the
  `Recorder::Socket` `preamble` hook, with `no_reply` so the accepter sends nothing
  back to a one-way reporter) — there is no exemption.
- **No ordering; correlation by id.** Either end may have requests in flight at any
  time, so a request carries a `request_id` (a v7 UUID, §2.2) and its response
  echoes it; responses are matched by id, never by arrival order. An endpoint may
  receive unrelated messages between sending a request and its response.
- **Bad-frame policy.** After identity, three consecutive corrupt/invalid frames
  (no valid frame between) close the connection; a fatal read error drops it at
  once.
- **One reusable implementation.** The per-connection transport (framing, identity,
  correlation, bad-frame policy) is `Test2::Harness2::Role::Service::Connection`;
  `Test2::Harness2::Role::Service` drives a set of them. Every service (runner,
  preload stages, the future system-load service §4.4) and every command client
  reuses it — not re-implemented per peer.

The detailed reader/monitor design from the abandoned 2.0b branch is preserved
under `reference/2.0b/` and will be adapted as §4.3 lands; it is not restated
here until it is committed architecture again. Its `run_uuid` proxy-fan-out was
built for the abandoned global-vs-run *service* split (§6.1); only the narrow
piece — routing each client only its own run's transitions on a multi-run
persistent runner — survives that simplification.

### 5.3 Socket naming and topology `[target]`

Service sockets live in the **workdir** and are named for their service:
`runner.socket` for the main runner (§4.2), and `preload-<stage>.socket` for
each **global** preload stage (§4.7). They use the same wire form as §5.2 —
zstd-compressed JSON object frames, the collector's wire format.

**Discovery is a symlink to the runner socket.** A persistent harness publishes a
well-known **symlink that points at its `runner.socket`** (rather than a
`yath-persist.json` metadata file). A client follows the symlink to reach the
runner, and follows it to the socket's directory to locate the **workdir** (and
from there the available `preload-<stage>.socket`s). This replaces the
`yath-persist.json` discovery file.

- **PID fallback for signals.** `yath-persist.json` also carried the runner PID,
  which clients (`status` / `stop` / `abort`) need to signal a **wedged** runner
  whose socket no longer accepts/responds. The runner already writes a flat `PID`
  file in its workdir (`Runner.pm`, the workdir `PID` file). The contract: a client
  queries liveness/PID **over the socket** in normal operation, and resolves the
  workdir via the symlink and **reads the `PID` file** as the fallback for
  signal-based termination when the socket is unresponsive.
- **Failure semantics.** A dangling symlink (or one whose `connect` fails) means
  no live runner: the client treats the harness as absent and cleans the stale
  symlink, rather than blocking. (Owner/permission, version, and
  multiple-harness-per-project handling are settled at implementation time and
  tracked in `TODO_STEPS.md`.)

`preload-<stage>.socket` is only the **global / per-run-baseline** form. A
**run-scoped** preload stage on a persistent multi-run runner needs a
**run-qualified** name so two runs using the same stage name — or a run-scoped
name colliding with a global one — do not share or clobber a socket. The scheme
is **decided** (§6.1): a per-run subdir `runs/<run_id>/preload-<stage>.socket`
(global stages stay `preload-<stage>.socket`, `runner.socket` stays a single
global socket). The collision-safe naming foundation is in place; run-scoped
stages *as a user feature* are deferred (chunk 16).

Direction of connection (the symmetric service model, §5.2):

- **Every service accepts on its one socket; any side may initiate.** Once a
  connection exists between two services it is reused for both directions — there
  is no fixed "X always connects to Y".
- **The preload-root dials the runner (chunk 19).** The runner spawns the
  preload-root, which connects to `runner.socket`, identifies as `preload-root`,
  and runs the preload handshake (`get_preload_list`, then `set_stage_data` /
  `preload_warnings` after the guarded load, §4.7). The preload-root has **no
  listen socket of its own** — its output rides its collector's reporter to
  `runner.socket` and its `preload-root-events.jsonl.zst`.
- **Preload stages initiate to the runner.** A stage (the preload-root's in-process
  base stage, or a forked named stage) connects to `runner.socket` to register and
  report state; the runner then dispatches jobs back over that same connection
  (§4.7). The runner does **not** open a separate connection to a stage to dispatch.
- **A stage's `preload-<stage>.socket` is for `spawn`.** `yath spawn` connects to
  it directly (§4.8); the runner does not use it for dispatch.
- **Commands connect to the runner**, and **collector reporters connect out** to
  the sockets they report to (the one-way pattern in §5.2).
- The only files on the IPC path are the per-collector `.jsonl.zst` events
  files, read for display/archival (§4.5); all decision and dispatch traffic is
  on sockets (§2.5).
- **Children locate sockets via the workdir, passed explicitly.** The workdir
  path is propagated to every child collector / subprocess (environment or
  spawn-time argument), so a child connects to `runner.socket` (or a
  `preload-<stage>.socket`) without hardcoded assumptions.
- **Transitions carry the *absolute* events-file path**, so a consumer opens the
  right `.jsonl.zst` with no discovery step.
- **Reuse the `Test2-Collector` wire utilities** (§2.8), do not re-implement:
  `Test2::Collector::Util::Socket` (`connect_unix`, `open_unix_listen`,
  `write_frame`) for sockets/frames, and `Test2::Collector::Util::Zstd::FrameBuffer`
  for frame-boundary buffering + decompression on reads.

### 5.4 Process spawning and reaping `[migrating]`

**Target.** Process management reduces to two primitives — **spawn a child** and
**reap a zombie**. A reap is *only* zombie cleanup; it is **never** a scheduling or
verdict input. Everything else the old `Test2::Harness2::IPC` controller did is
carried by collectors + sockets.

- **A test's outcome comes only from its collector's transitions.** Each test runs
  under a `Test2-Collector` collector that streams its transitions — including the
  audited `harness_final_state` (`pass`, and `halt` on a bail-out) — to
  `runner.socket` (§4.3, §5.2). The runner folds them into canonical state
  (`Runner::Monitor`) and makes **every** completion decision from them. The
  collector's OS exit code is **never** the test verdict (see *Collector exit
  semantics*).

- **The gone signal is socket EOF — not the reap, not a pid check.** A collector's
  transition connection to `runner.socket` closes when the collector process ends —
  on a clean exit *and* on a hard, uncatchable death (`SIGKILL`, segfault, OOM) — on
  every platform, with no pid-reuse race. So the runner learns a collector is gone
  from the **EOF on its connection**, independent of who (if anyone) reaps it. Every
  handshake still reports a pid (below) for status/diagnostics and to map a
  connection to its job, **not** for liveness.

- **FD ownership is a hard prerequisite (invariant).** Socket EOF is only a reliable
  "gone" signal if **no other process holds a duplicate** of that connection's fd. A
  UNIX socket EOFs to the reader only once *every* holder has closed it. The runner
  forks a collector parent **without exec** (it runs Perl), so the child inherits the
  runner's listen socket **and every other live collector's connection**; the test
  child (and any descendant it forks) can likewise inherit the collector's reporter
  socket — especially on the preload `goto::file` path where there is no exec. So:
  every socket is created `FD_CLOEXEC`, **and** every fork performs an explicit
  close-sweep in the child — the collector parent closes all inherited runner
  connections + the listen socket; the test child (no-exec preload launch included)
  closes the collector's reporter/recorder sockets and any inherited runner
  connections. Without this, EOF is unreliable under concurrency and the whole model
  breaks silently. A regression must prove a preload test that forks a long-lived
  descendant still EOFs promptly.

- **The reporter is mandatory.** Because EOF + transitions are the *only* completion
  signal, a test that runs without a connected reporter would never complete. The
  test-job reporter connection is therefore required: a connect failure
  **synchronously fails/aborts the job** through a runner-visible path (it never
  silently degrades to recorder-only). A configurable **`--collector-connect-timeout`**
  (on by default) bounds "dispatched but no `starting` transition arrived" — exceeding
  it fails/aborts that job.

- **Handshake identity.** Every connection to `runner.socket` (commands, stages,
  collectors) identifies itself with its **pid**; a test collector additionally
  carries its **`job_id` (uuid) + `job_try`** (+ `run_id`/`collector_uuid`). The
  connection stores the **full identity payload** (not just name+pid), and the runner
  registers a `conn → {pid, job_id, job_try, run_id}` map. Close handling is
  **idempotent** (EOF, any reap, and any explicit terminate converge to one decision),
  and a **stale-try guard** applies: an EOF/report whose `job_try` ≠ the job's current
  try is ignored for stop/retry (it is a dead prior attempt; the connection of a
  superseded try is explicitly retired so its late EOF is a no-op).

- **Completion decision (runner, identical for both run paths).** On a test
  collector's connection EOF, the runner drains any pending transition frames on it,
  then:
  - `harness_final_state` **seen** → act on the audited verdict: `pass` ⇒ complete
    (pass); `!pass` ⇒ **retry** if the task has tries left (re-queue the same
    `job_id` with an incremented `job_try`; the scheduler picks it up on a later
    tick) else complete (fail); a `halt` ⇒ **bail**: halt the run (no further
    dispatch) and terminate all active jobs (when `--abort-on-bail`).
  - `harness_final_state` **absent** at EOF → the test produced no verdict: **fail
    it**. If the runner did not deliberately terminate this job, flag it as a
    *possible harness/collector internal error that may not indicate a problem with
    the test* (a healthy collector always emits a final state, so its absence is
    itself a collector problem — this holds **even if the collector exited 0**). If
    the runner **did** terminate it (a `--abort-on-bail` bail of another test, a
    `yath abort`, or an owner-disconnect abort — see *Bail and abort*), it is recorded
    as **aborted**, *not* a harness-internal error.

- **No-verdict completions need a render representation.** When the runner decides a
  job's outcome with no collector `final_state` (EOF-no-verdict, abort, or a bail
  where the collector never reported), there may be no `completed`/`final_state`
  transition and no usable events-file terminal for the command-side renderer to key
  off. The runner therefore emits a **runner-originated terminal mutation**
  (a `harness_runner_job` failed/aborted carrying `job_id`/`run_id`/`file`/`job_try`
  and the diagnostic **reason**), consumed exactly once, so the subscriber renders the
  decided outcome instead of rolling the job up as "never ran." The reason is
  **harness output**, distinct from job output.

- **Bail and abort: a runner→collector terminate message (bidirectional connections).**
  Teardown of a running job is driven over the socket, not by the runner signaling
  pids. This requires the **test-collector connection to be bidirectional** — the
  collector reads inbound control messages from the runner between events (today's
  test reporters are one-way; that changes). The primitive:
  - **Bail (`--abort-on-bail`, default):** the bailing test's collector sends the
    `halt` transition (and kills its own child if it has not self-exited, recording a
    bail-out *from itself*). On seeing it, the runner stops dispatching new jobs for
    that run and sends a **"run bailed" message to every job collector of the run**;
    each kills its child (normal signal escalation to descendants), writes an
    events-file note that it **received a bail-out from another test**, records its
    findings, and exits → EOF. Any collector that **reports in after** the bail (a job
    dispatched but not yet connected) gets the message on connect — the runner tracks
    the run as bailed. `halt` **wins over retry** (a bailing job is never re-queued).
    With `--no-abort-on-bail` the collector still sends the transition and still kills
    its own child; the runner just does not propagate it to the run.
  - **Abort (`yath abort`) and owner-disconnect abort** use the **same** terminate
    message: the runner records an **abort intent** for the run/job and tells each
    collector to terminate (and terminates any that connect afterward). This replaces
    signaling pids from a possibly-stale snapshot, so it cannot miss a job whose pid
    had not yet been reported.
  - **Pid/process-group is the fallback only:** if a collector does not comply, the
    runner hard-kills via `kill(-pid)` (a detached collector `setsid`s, so its pid is
    its group leader). Pids come from the handshake (above), so no stage-side pid
    tracking is needed.

- **Invariant: a collector problem or a missing `harness_final_state` always fails
  the test.** The harness never reports a pass it did not see audited. The retry
  *policy* (how many tries) lives in the runner — the `--retry` setting plus the
  per-file `# HARNESS-retry N` / `# HARNESS-no-retry` directives — never in the
  collector.

- **Collector exit semantics.** A **test-job** collector's parent process exits with
  a **health code only**: `0` when the collector itself functioned (regardless of
  whether the wrapped test passed, failed, or died by signal — that is in the
  transitions), non-zero only when the *collector* malfunctioned. It no longer encodes
  the test's verdict. The single source of "collector health" is the
  `Test2-Collector` helper (`Test2::Collector::Runner->spawn_exit_code`); the harness
  uses it for the test-job parent and **deletes `Runner::Job::_collector_exit_code`**
  (the verdict-layering). `Test2::Harness2::Util::collector_exit_code` (which forwards
  the *wrapped child's* exit) **stays** for **non-test** wraps — the runner wrap (whose
  child *is* the runner, whose exit `yath test` must return), stage, and aux collectors
  — where the wrapped exit is genuinely meaningful.
- **Post-pass collector failure (best-effort, supported platforms).** A collector can
  fail *after* it has already emitted `harness_final_state.pass = 1` (a late
  recorder/reporter flush error). The audited part — the verdict — already succeeded,
  so the **test stays a pass** and is never reopened. On a **subreaper-supported**
  platform the runner reaps the collector and sees the non-zero health exit: it
  **reports the collector error to harness output** (not job output) and **marks the
  overall suite/run failed** at `test`/`run` exit, even if every test passed — so
  harness/collector bugs are surfaced for debugging. On an **unsupported** platform
  the runner never sees that exit, so a post-pass collector failure **may be lost**;
  this is accepted (the critical path, auditing, succeeded). The health exit is used
  *only* for this post-hoc suite-level escalation, never for a per-test verdict.

- **Process tree: the runner is a child subreaper; preload collectors detach.** So
  the runner is the single owner of the process tree (zombie reaping, kill-tree on
  shutdown, escalation) and the preload tree needs **no** reaping logic of its own:
  - The runner registers as a **child subreaper** at startup via a small pure-Perl
    helper, `Test2::Harness2::Util::SubReaper` (no XS, no external dependency): Linux
    `prctl(PR_SET_CHILD_SUBREAPER, 1)` and FreeBSD/DragonFly `procctl(...,
    PROC_REAP_ACQUIRE)`, issued through `syscall()` with a per-(OS,arch) number
    table. Any unknown platform or failed call is a graceful no-op (eval-guarded) —
    the platform is simply "unsupported."
  - **Collectors spawned by preload stages always double-fork and detach** from the
    stage. On a subreaper-supported OS they re-parent to the **runner**, which reaps
    them; on an unsupported OS they re-parent to **init**, which reaps them. The
    preload tree never reaps a collector either way.
  - **No-preload** collectors are the runner's direct children, reaped by the runner.
  - The runner learns every collector's pid from its **handshake** (above), so the
    stage tracks **no** collector pids — its detached collector self-reports to the
    runner. `job_pids` is cleared on **EOF** (the decision point), not on reap.
  - Because the completion **decision** rides on EOF + transitions, it is identical
    whether the runner reaps the collector, init reaps it, or it is never reaped —
    reparenting governs only *zombie ownership and teardown*, never the verdict.

- **Removed by this model.** `Runner::Job::_collector_exit_code` (verdict-layering)
  and the `bail` file it wrote; the reap-driven retry/stop/bail in
  `Runner::set_proc_exit` *and* `Preload::Host::set_proc_exit`; the
  `StageDelegate`/`Runner::Client` verdict reporting (`stop_task`/`retry_task`
  carrying a verdict the runner now reads straight off the transition). A stage's
  reap becomes zombie + local bookkeeping only (and on a subreaper-supported OS the
  stage's detached collectors re-parent away, so it has none to reap).

- **Net structural result (landed, #29).** No-preload and preload runs both reduce
  to "fork a collector → decide from its transitions/EOF → the runner owns reaping,"
  so `run_scheduler_only` is the runner's **only** run path; the in-runner
  `run_tests`/`run_stage`/`run_job`/`end_test_loop` stage machinery is removed (the
  #22 residual and #4 Part 4 / #8 Part 4 folded into this). `dispatch_pending` branches
  once on `_preload_root_hosts_stages` (kept; still the preload-vs-no-preload
  discriminator — NOT live-peer presence, so a transiently-disconnected preload stage
  still requeues): preload → `service_send` to the stage; no-preload → the runner forks
  the test collector itself (`_launch_local_job`). A no-preload collector stays a
  **watched** runner child (reaped via `set_proc_exit`, job_id known) -- completion
  still rides EOF; only preload collectors detach and re-parent (#28). Spawn requires a
  preload stage (rejected at queue time on a no-preload runner).
- **The `IPC` controller base class is slimmed, not dismantled.** The original plan
  (ticket #8) was to delete the base class outright, on the premise that only **2**
  consumers ever used it: the Runner and the `yath test` command. That premise no
  longer holds. The #22 split created a **third** co-equal consumer,
  `Test2::Harness2::Preload::Host` (`use parent 'Test2::Harness2::IPC'`): the
  in-preload-tree stage host runs its **own** `run_stage`/`run_job` loop and is still
  a genuine multi-child controller — it forks stages + jobs, calls `wait()`, and reaps
  them through `set_proc_exit` (its Job branch is zombie-only, but its `StageProcess`
  branch performs live monitor-relaunch of named stages via `longjump`). #29 scoped
  `Preload::Host` explicitly **out of scope** ("the Host, with its OWN
  run_tests/run_stage/run_job, is OUT OF SCOPE"). So the shared three-pass reaper
  (`_bring_out_yer_dead` / `_check_if_dead_yet` group-wait / `_ex_parrots`
  vanished-sweep) inside `wait()`, plus `killall`, `check_for_fork`, `watch`, `spawn`,
  and the `category` slot, **remain** — `Preload::Host` depends on all of them. What
  *was* removed is real but narrower than the original framing:
  - **`cat`/`all_cat`/`block` waits + `PROCS_BY_CAT`** — gone (ticket #6). `wait()`
    takes only `all`/`timeout`.
  - **Reap-driven verdicts** — gone (#27/#28/#29). Both `Runner::set_proc_exit` and
    `Preload::Host::set_proc_exit` Job branches are now pure zombie cleanup + local
    bookkeeping; completion rides EOF + transitions.
  - **die-on-unmonitored** — gone (#8 Part 1): an unmonitored pid reaped here is
    benign and skipped, never fatal.
  - **In-runner stage machinery + `run_tests`/`run_stage`/`run_job`/`end_test_loop`**
    — gone from the *Runner* (#29); they live only in `Preload::Host` now.
  - **`set_sig_handler`** — gone (chunk 21): zero callers; Runner/Host populate
    `{+HANDLERS}` directly.
- **What stays (and why).** `Test2::Harness2::Util::IPC`
  (`run_cmd`/`swap_io`/`set_cloexec`/`USE_P_GROUPS`) is the genuine reusable
  fork-exec primitive and is kept. `IPC::Process` survives as a thin value object;
  it retains `set_exit`/`exit`/`exit_time` (the croak-on-double-set guard prevents a
  proc being reaped twice — a real invariant, not a verdict input) and the
  `category` slot (`StageProcess` overrides it). The Runner keeps a minimal `waitpid`
  zombie-reaper built on the base (`_bring_out_yer_dead` override for the
  subreaper/detached-collector path + A3); the `yath test`/`start` commands inline
  their one-child spawn+wait on `Util::IPC::run_cmd` without a controller instance.
  Fully dismantling the base class is deferred until `Preload::Host` itself collapses
  its `run_stage`/`run_job` machinery (a separate, larger piece).

## 6. Open questions

Reserved for architectural questions raised but not yet resolved. Resolved
entries move into the relevant numbered section above.

### 6.1 Multi-run scope on a persistent runner `[target]`

**Resolved part — no run-specific *services*.** The earlier framing of this
question (a global-vs-run *service* split, with first-class "global" vs "run"
services and a `run_uuid` proxy framework) is **abandoned** (§4.4, §4.7). It was
an over-extrapolation from two concrete preload needs, which are now met
directly by **preload-stage scope**: global preload stages shared by all runs,
and run-scoped preload stages brought up/torn down per run (§4.7). No general
service infrastructure is built for this.

**Resolved — multi-run routing/lifecycle (migrated; "serialized + per-run
routing").** The persistent path now runs on the socket model alongside the
transient path. The decision was to **route per run but keep execution
serialized**: a persistent runner still runs one active run at a time (the single
in-runner active-run slot is unchanged), but each `yath run` client is routed
only its own run's data. Concurrent run *execution* (multiple runs progressing at
once) is a deliberate later step, not part of this resolution.

- **Transition routing — done.** The runner's canonical state
  (`Test2::Harness2::Runner::Monitor`) is keyed by run. `run_uuid` and `run_id`
  are the same value (a test collector's `run_uuid` is stamped from its
  `run->run_id`), so one key routes both collector transitions and
  runner-originated job mutations. A client `subscribe` request carries a
  `run_id`; the returned snapshot is filtered to that run plus a **global
  bucket** (the runner's own and preload-**stage lifecycle** transitions, which
  have no run association and broadcast to all subscribers). `forward_frame`
  consults each subscriber's run filter. A subscribe with no `run_id` is a global
  subscriber (everything) — the basis for a future `watch`-over-socket. This is
  the narrow surviving piece of the abandoned 2.0b `run_uuid` proxy match, with
  no proxy framework and no global-vs-run service split.
- **Run-scoped preload lifecycle — naming decided; feature deferred.** The
  run-qualified socket scheme is **per-run subdir**:
  `runs/<run_id>/preload-<stage>.socket` (global stages stay
  `preload-<stage>.socket`, `runner.socket` stays a single global socket). The
  `Role::Service` optional **`run_id`** consumer hook implements it: a consumer
  that provides a `run_id` (always the run's UUID — **never** an integer ordinal;
  the name `run_ord` was rejected because `run_ord` means something different in
  the UX/DB) nests its socket under `runs/<run_id>/`; a global stage leaves it
  undefined and binds the flat socket. Run-scoped preload stages *as a user
  feature* (a run requesting extra per-run preload branches) are **not built** —
  there is no trigger for one and serialized execution needs no concurrent
  run-scoped stage; only the collision-safe naming foundation is in place. This
  hook is what the concurrent-runs future (above) needs once two runs' same-named
  stages can be live at once.
- **Service lifecycle / discovery — decided.** `yath start` owns the workdir and
  spawns the persistent runner (binds `runner.socket`, runs the service loop);
  `yath run` / `spawn` discover it, connect to `runner.socket`, submit, and
  subscribe scoped to their `run_id`; `stop` sends a graceful socket shutdown.
  Liveness is socket-connect (with the `PID`-file signal fallback, §5.3). The
  runner's scheduler runs the in-memory `direct` State and dispatches to socket
  preload-stage services — none of the 1.0 `dispatch.jsonl` / `jobs.jsonl` /
  `queue.jsonl` / `run_queue.jsonl` files. The **target** discovery + dispatch
  shape lives in §5.3 (runner-socket symlink) and §4.7 / §5.2
  (stage-registers-with-runner over one shared channel); the as-shipped form and
  the remaining gap to that target are tracked in `TODO_STEPS.md` (chunks 9, 10, 12).

**Future goal — concurrent runs with earlier-run priority + backfill.** The later
step beyond serialized execution is to let a persistent runner progress **multiple
runs at once**, with **strict priority to earlier runs**: an earlier (higher
priority) run always gets first claim on slots/resources, but when it **cannot use
a free resource** (its remaining jobs are blocked — e.g. waiting on a busy
resource, a conflict, or a not-yet-`up` preload stage), the scheduler **backfills**
with jobs from later runs that *can* use that resource. No idle capacity while a
lower-priority run has runnable work. This makes `_next` (and its per-bucket
ordering) span runs in priority order rather than operating on a single active
`RUN`; the per-run scheduling structures (`PENDING_TASKS` keyed by `run_id`, the
`SORTED` bucket memo, conflict/resource gating) already carry `run_id` but the
**scheduler loop and its clear/scope points assume one active run** and must be
revisited then. Not scheduled (no `TODO_STEPS.md` chunk yet) — recorded here so the
single-active-run assumptions are known to be temporary.

**Remaining (tracked in `TODO_STEPS.md`, not blockers for the above):** concurrent
run *execution* on a persistent runner; run-scoped preload stages as a user
feature; and the connection-model / discovery / spawn / preload-as-resource
redesign now folded into §4.4 / §4.7 / §4.8 / §5.2 / §5.3. (The earlier
`watch` / flat-log item is **done** — the persistent runner + stages are
collector-wrapped and `watch` is a global socket subscriber.) The settled parts
above are authoritative and mirrored across §4.2 / §4.7 / §5.3.
