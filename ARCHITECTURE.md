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

Chunk 1 of the migration (mechanical renames + version bump, §1.1) has
landed: the tree carries the 2.0 names and versions but otherwise still runs
1.0 logic, and every target subsystem below remains `[target]`. Update the
tag on a section as its migration starts and completes. Current per-chunk
migration status lives in `MIGRATION.md`, not here.

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
   not just tests (§4.1, §4.2).
5. **Transition pipelining** — stop broadcasting all events everywhere; pipe
   only transitions, with Monitor-style state sync, and let consumers seek the
   `.jsonl.zst` files when they need full events (§4.3).
6. **Renderer rewrite** — a base renderer / role that knows how to locate the
   `.jsonl.zst` files (§4.5).
7. **System-load service** — gate concurrency on CPU/memory in addition to or
   instead of a static `-j` (§4.4).
8. **Database + UI inline** — rewrite the former `Test2-Harness-UI` DB+UI
   layer inline in `App::Yath2`, with `DBIx::QuickORM` schema and sqlite log
   files (§4.6).

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

### 2.3 Argument parsing: `Getopt::Yath` `[target]`

Command-line and option processing migrates to **`Getopt::Yath`**. The 1.0
`App::Yath::Options` machinery is replaced as the rename and option work lands.
Until then 1.0's option handling remains in place behind the renamed
namespaces.

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
bytes between processes go through `Atomic::Pipe` (and the collector pipeline's
unix sockets, §4.3); durable cross-process state goes to disk. If a reference
doc or a snippet of `reference/` code calls for `IPC::Manager`, treat that as
outdated and follow this document.

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

`Test2-Collector` is **not yet released or installed**. Until it is, it is
loaded from the `t2clib` symlink at the repository root (gitignored; points at
the sibling checkout's `lib/`). Scripts under `scripts/` add it to `@INC`
themselves; a test that loads `Test2::Collector*` carries a `use lib 't2clib';`
line. This scaffolding goes away once the dist is installed. The dependency
points one way: `Test2::Collector` never loads `Test2::Harness2*` or
`App::Yath2*`.

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
  collector pipeline, and yath reads the recorded result.
- **Every yath-started process is a collector.** Not just tests: services,
  workers, and the main harness process itself run as (non-test) collectors,
  so every process speaks one wire format and records one kind of events file
  (§4.2).

### 4.2 Main harness service `[target]`

**Responsibility.** One long-running service owns the canonical run state and
does scheduling and job dispatch. It is itself a collector (§4.1). Each test,
and each non-test process it starts, runs under its own collector.

**Contract.**

- The service holds the **canonical state** for a run; other components learn
  state from it (§4.3) rather than reconstructing it from raw events.
- It exposes a **unix socket** for requests (queue a run, shut down, query).
- **Completion comes from transitions, not reaping.** Collectors are not
  necessarily direct children of the service, so it must not depend on
  `waitpid` to learn that one finished; the finalized transition on the
  channel is the completion signal. Reaping is a local detail for whichever
  process forked the collector.

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
- **Other consumers get transitions from the main harness**, not directly from
  every collector. The harness is the hub.
- **Full detail is pulled on demand.** Transitions carry each collector's
  events-file path, so a renderer or other consumer that needs the full event
  stream reads that collector's `.jsonl.zst` file directly, when and if it
  cares. No component rebroadcasts the full stream.
- **Wire form.** Unix-domain stream sockets; messages are transition events,
  JSON-encoded and zstd-compressed into self-contained frames, each carrying
  the collector `uuid`. See §5.2.

### 4.4 System-load service `[target]`

**Responsibility.** Report system load (CPU, memory) so the scheduler can gate
how many tests run concurrently — in addition to, or instead of, a static
`-j`. Prototyped on the abandoned `harness_service` branch (see
`reference/harness_service/`, `t2h2_sysload`).

**Contract.**

- It is a **non-test collector** that **does not receive requests**, so it has
  **no socket of its own**. Instead it **connects to the main harness's
  socket** and streams state changes (load crossed a threshold) as they
  happen.
- The scheduler in the main harness (§4.2) consumes those updates to decide
  when a slot may open, combining the load signal with any static `-j` limit.

This is the general rule for auxiliary processes: a yath-started non-test,
non-spawn process that needs to *handle* requests gets its own unix socket;
one that only *emits* state changes connects to the main harness socket
instead.

### 4.5 Renderers `[target]`

**Responsibility.** Format and display results — live during a run, and from
archived runs after the fact. A rewrite of 1.0's renderers.

**Contract.**

- A **base renderer (or renderer role)** knows how to locate a collector's
  `.jsonl.zst` events file from the transition state (§4.3), so concrete
  renderers consume recorded events rather than a live broadcast.
- Renderers are consumers of the transition channel for liveness and of the
  events files for detail.

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

### 5.2 Transition channel: unix sockets `[target]`

The transition channel (§4.3) is **unix-domain stream sockets**
(`SOCK_STREAM`), not `Atomic::Pipe`. Each collector gets its own connection.
The contract:

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

The detailed reader/monitor and proxy-fan-out design from the abandoned 2.0b
branch is preserved under `reference/2.0b/` and will be adapted as §4.3 lands;
it is not restated here until it is committed architecture again.

## 6. Open questions

Reserved for architectural questions raised but not yet resolved. Resolved
entries move into the relevant numbered section above.

### 6.1 Global vs run services for `yath start` / `yath run` `[target]`

The driving case is `yath start` + `yath run`: global services start first
under a long-lived process, and a `yath run` arrives later with its own tests
and run-scoped services. A run needs to see global services' state plus its
own collectors, but not other runs' traffic. The transition channel (§4.3)
needs a filtering/proxy mechanism keyed on a per-collector run association to
support this, plus a first-class distinction between **global** and **run**
services. Prototyped on `reference/2.0b/` (proxy filtering on `run_uuid`); the
surrounding lifecycle and the `yath start` / `yath run` commands are not yet
designed against the migrated tree.
