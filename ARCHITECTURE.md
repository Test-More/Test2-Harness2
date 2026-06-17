# ARCHITECTURE.md

Authoritative architectural spec for yath 2.0.

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
`MIGRATION.md`, not here.

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
not started, with commit refs) is tracked in `MIGRATION.md`. The intended
order, roughly:

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
   `test` / `run` command processes; see `MIGRATION.md`.
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

### 4.2 Main harness service `[target]`

**Responsibility.** One long-running **runner** service owns the canonical run
state and does scheduling and job dispatch. It is itself a collector (§4.1):
`Test2::Harness2::Runner->start` (or equivalent) launches the runner process
under a non-test collector, then runs a service loop. Each test, and each
non-test process it starts, runs under its own collector. There is **one runner
process** — the scheduler is an **object inside it**, not a separate process.

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

### 4.5 Renderers `[target]`

**Responsibility.** Format and display results — live during a run, and from
archived runs after the fact. A rewrite of 1.0's renderers.

**Contract.**

- A **base renderer (or renderer role)** knows how to locate a collector's
  `.jsonl.zst` events file from the transition state (§4.3), so concrete
  renderers consume recorded events rather than a live broadcast.
- Renderers are consumers of the transition channel for liveness and of the
  events files for detail.

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

### 4.7 Preload stage services `[migrating]`

**Responsibility.** Each preload stage runs as its own (non-test) collector
(§4.1) **and** as a service with its own unix socket (`preload-<stage>.socket`
in the workdir, §5.3). A stage holds the preloaded interpreter state from which
matching tests are forked.

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
  It marks state — `starting` / `up` / `restarting` / `down` — and the stage
  itself decides when to restart (e.g. on a preload-file change). The runner
  consumes those state updates; it does not drive the stage's restarts.
- **Restart is stage-initiated; the runner does not relaunch.** On its own
  restart trigger the stage announces `restarting` / `down`, closes its channel,
  and **exits**. The runner marks the preload resource unavailable (§4.7a) and
  its process reaper detects the exit and spawns a **fresh** stage instance, which
  reconnects and registers a new `up`. The runner never reaches in to restart a
  live stage — it only respawns one that has exited.
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

**§4.7a Preload as a resource `[target]`.** Preload availability is expressed
through the resource system: a resource representing "stage `<name>` is expected
and currently `up`" gates the jobs that require it. This unifies preload
readiness with the existing resource-gating the scheduler already does, instead
of a separate stage-readiness code path.

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
  preload stage** to request the spawn. It does not go through the runner.
  "Available" means the stage's socket accepts a connection; a socket file whose
  stage is `starting` / `restarting` / `down` (or whose connect fails) is not a
  spawn target. When multiple stages match, stage selection follows the command
  options / run-plan match (the implementation pins the exact rule).
- **IO is shared over the socket — no fd-passing dependency.** Rather than native
  descriptor passing (`SCM_RIGHTS` via `Socket::MsgHdr` / `IO::FDPass`), the stage
  **`dup2`s the accepted socket descriptor onto the child's `STDIN` / `STDOUT` /
  `STDERR`** before exec, and `yath spawn` streams its own terminal IO to/from its
  end of the socket. This gives full bidirectional IO sharing with no
  platform-dependent CPAN module, replacing the 1.0 `/proc/<pid>/fd` IO-proxying.
- **The child is detached: double-fork, no collector.** The stage **double-forks**
  the spawned process so it is reparented away and outlives neither the runner
  nor the stage once started. Unlike every other yath-started process (§4.1), a
  spawned process runs under **no collector** — it is not a harness-tracked
  result, just a process the user asked to start with preloads in place.

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

**Status.** The symmetric service-channel model below is implemented in
`Test2::Harness2::Role::Service` and carries the **runner↔stage** pair as one
bidirectional, handshaked, reused connection (the stage dials the runner and the
runner dispatches back over it). The future system-load service (chunk 7) is the
remaining consumer. Request/response **correlation ids** are not implemented yet:
the symmetric traffic in place is all one-way, and the two-way requests
(`status` / `truncate` / `subscribe` / …) are single-initiator and read their one
reply, so no correlation is needed until a service issues concurrent two-way
requests on a shared channel.

**Collector reporters (one-way, connect-out).** A per-process collector's
reporter just streams its transitions; it is not a service.

- **One connection per collector.** Frames from different collectors land on
  separate file descriptors and never interleave — atomicity by construction.
- **The reporter connects out.** The collector's reporter sink is given socket
  paths, connects to each, and writes to all of them; it makes no assumption
  about what is on the other end.
- **Message shape.** Each message is a transition event, JSON-encoded and
  zstd-compressed once into one self-contained frame, written with a blocking
  `syswrite` (retried on `EINTR`, `SIGPIPE` ignored so a vanished reader
  surfaces as a trappable error). The collector `uuid` rides on every message
  so any multiplexing reader can demultiplex. The start message additionally
  carries the collector name, the events-file path, the run association, and
  (for tests) the try number.

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
- **Identity handshake on connect.** A `SOCK_STREAM` connection accepted via
  `accept` carries no service identity, yet "reuse, never duplicate" requires each
  side to know **which** peer is on the descriptor. So a connection **exchanges a
  handshake frame identifying the peer** (stage name / system-load identifier /
  client type) immediately on connect, **before** it is registered in the
  connection set. The handshake also resolves the **simultaneous-connect race**
  (both sides dial at once): the identities let both ends detect the duplicate and
  converge on one channel (e.g. lowest identity wins) before either sends a
  request.
- **One reusable implementation.** This model is provided by a shared **Role
  and/or base class** that every service (runner, preload stages, the future
  system-load service §4.4) consumes — not re-implemented per service. It owns the
  handshake, the dedup/race resolution, and request/response correlation on the
  shared stream.

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
  tracked in `MIGRATION.md`.)

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
- **Preload stages initiate to the runner.** A stage connects to `runner.socket`
  to register and report state; the runner then dispatches jobs back over that
  same connection (§4.7). The runner does **not** open a separate connection to a
  stage to dispatch.
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
  `Role::Service` `run_ord` subdir hook implements it. Run-scoped preload stages
  *as a user feature* (a run requesting extra per-run preload branches) are
  **not built** — there is no trigger for one and serialized execution needs no
  concurrent run-scoped stage; only the collision-safe naming foundation is in
  place.
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
  the remaining gap to that target are tracked in `MIGRATION.md` (chunks 9, 10, 12).

**Remaining (tracked in `MIGRATION.md`, not blockers for the above):** concurrent
run *execution* on a persistent runner; run-scoped preload stages as a user
feature; and the connection-model / discovery / spawn / preload-as-resource
redesign now folded into §4.4 / §4.7 / §4.8 / §5.2 / §5.3. (The earlier
`watch` / flat-log item is **done** — the persistent runner + stages are
collector-wrapped and `watch` is a global socket subscriber.) The settled parts
above are authoritative and mirrored across §4.2 / §4.7 / §5.3.
