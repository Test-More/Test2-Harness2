# Test2::Harness2 Architecture

This document is the single authoritative description of the yath 2.0
rewrite. It supersedes every earlier `ARCHITECTURE.md` under
`reference/`. Companion documents:

- `STYLE_GUIDE.md` — code style rules.
- `AGENTS.md` — repository-wide agent / contributor guidance.
- `PART_1_PLAN.md` — stage-by-stage backlog for the `Test2::Harness2`
  namespace (this document's scope).
- `PART_2_PLAN.md` — scaffold for the future `App::Yath2` namespace
  work; not in scope for Part 1.

The rewrite is split into two parts:

- **Part 1 — `Test2::Harness2`.** The harness library plus
  `Test2::Formatter::Stream2`. Library API only; no `App::Yath2`
  callers, no command-line interface. This document specifies Part 1.
- **Part 2 — `App::Yath2`.** The user-facing `yath` command, options
  layer, renderer driver, output pipeline, persistent-daemon command
  set, log archive / extract / database backends. To be specified
  later (see `PART_2_PLAN.md`).

The two parts share a distribution but the harness library must remain
usable without any `App::Yath2*` module loaded — see §3 (Dependency
contract).

---

# Part I — Specification

## 1. Terminology

- **Harness handle** — a live `Test2::Harness2` object. Owns the
  database connection, the `.t2h2` discovery file on the filesystem,
  and the API used to start runners, queue runs, query state, and
  attach to an existing instance. There is no separate harness service
  process: the harness *is* the database plus the helper services it
  spawns on demand.
- **Database** — the SQLite (or, eventually, PostgreSQL / MySQL /
  MariaDB / Percona) backend that holds every piece of state about
  runners, runs, jobs, services, collectors, artifacts, and requests.
  All inter-process state flows through the database. There is no
  IPC bus, no message broker, no `IPC::Manager`.
- **.t2h2 file** — for the default SQLite mode this is the SQLite
  database file itself. For non-SQLite backends it is a JSON sidecar
  describing how to connect to the real database. Either way it is
  the discovery artifact other commands look for.
- **Runner** — a row in the `runners` table created by
  `$harness->new_runner`. Owns a set of services (notably the
  scheduler) and zero or more runs. A runner can be finalized,
  signaling "no more runs are coming".
- **Service** — a long-lived process consuming
  `Test2::Harness2::Role::Service`. Runs an event loop that
  selects over its work sources (DB tables, registered sockets,
  signals) and writes results back. The scheduler, every resource
  service, and every preload service is a service. Regular
  launchers are **not** services.
- **Scheduler** — `Test2::Harness2::Scheduler`. Exactly one per
  runner. Drives run + job execution: claims queued runs, evaluates
  resources, dispatches each job to a launcher in-process (or over
  the preload socket), reaps results.
- **Launcher** — a class consuming
  `Test2::Harness2::Role::Launcher`. The role is a thin contract
  (`name`, `launch(\%spec)`); it does **not** consume
  `Role::Service`. Regular launchers (`Default`, `ForkExec`,
  `Win32`) are plain in-process objects owned by the scheduler.
  The preload launcher (`Preload`) is a proxy object owned by the
  scheduler that talks to its long-lived preload service over a
  per-preload Unix socket. The socket carries both `launch` and
  `spawn` requests — see §7.3.
- **Collector** — `Test2::Harness2::Collector`. A child process
  forked to wrap a *collected* process. Its parent is the
  scheduler (for regular launches) or a preload service (for
  preload launches). Reads the collected
  process's stdout / stderr through `Atomic::Pipe`s in mixed-data
  mode, runs the bytes through a parser → optional auditor →
  recorder pipeline, and finalizes the collector row in the database
  when the collected process exits. Every test job and every service
  process is wrapped by a collector. Spawns are not.
- **Spawn** — a detached process produced by the `spawn` message
  on a preload service's request socket (eventually surfaced as
  `yath spawn`). Spawns do **not** get a collector; they
  double-fork and are intended to emulate "just running the
  command", inheriting the preload state but otherwise behaving
  like a normal foreground process.
- **Parser** — consumes the bytes the collector reads from the
  collected process. Two kinds of bytes coexist on the same pipe:
  raw text and structured event bursts framed by `Atomic::Pipe`'s
  mixed-data-mode burst API. The parser produces
  `Test2::Harness2::Event` objects.
- **Auditor** — optional parser-tap that watches the event stream,
  injects synthetic events when needed, and tracks pass/fail state.
  Only test-job collectors have an auditor; service collectors do
  not.
- **Recorder** — the sink of the event pipeline. Writes events,
  records the collector's exit code, records state transitions
  emitted by the auditor, and is responsible for handling external
  artifacts (screenshots, etc.). The default recorder is the
  `DB` recorder (writes to disk + the database). A `Files` recorder
  exists for development and tests of the collector in isolation.
- **Resource** — a class consuming
  `Test2::Harness2::Role::Resource`. Resources mediate access to
  things tests need (CPU slots, memory, temp directories, preloads,
  etc.). Some resources are pure in-process state owned by the
  scheduler; others need a backing service process to manage real
  out-of-process state. Resources are configured per runner
  (`start_scheduler(resources => ...)`) and per run
  (`queue_run(resources => ...)`).
- **Project** — the unit a run is scoped to. Currently a freeform
  string (for development `t2h2` is fine); auto-detection by
  `App::Yath2` is Part 2 scope. Stored in `projects.name`.

## 2. Process topology

```
caller process (test runner script, `yath …` command later)
 └── Test2::Harness2 handle (in-process; no daemon)
      ├── scheduler service                       (one process per runner)
      │    ├── resource services                  (one per resource that declares it needs a service)
      │    ├── preload services                   (one per configured preload — see §10)
      │    │    └── collector ↔ test process       (per job launched from this preload)
      │    └── collector ↔ test process            (per non-preload job — direct child of scheduler)
      └── …
```

Key invariants:

- **No central message bus.** Almost all cross-process state flows
  through the database. Services do not generally talk to each other
  directly; they poll the DB, process work, write responses to the
  DB. The one exception is the preload-service request socket
  (§10): scheduler ↔ preload `launch` / `spawn` requests run over a
  per-preload Unix socket because they are short, synchronous, and
  do not need DB durability. Beyond that, `SIGUSR1` is used purely
  as an early-wake hint to break a service out of a sleep when
  there is known new work. On platforms where `SIGUSR1` is
  unsupported the harness still works — wake-up just falls back to
  the next poll-cycle sleep expiry.
- **No long-lived harness daemon.** The `Test2::Harness2` object lives
  in the caller's process. The scheduler, resource services, and
  preload services are independent processes; they outlive the
  constructing caller only when explicitly daemonized.
- **Regular launchers are in-process, not separate processes.**
  `ForkExec`, `Win32`, and `Default` are plain Perl objects that
  live inside the scheduler. The scheduler calls
  `$launcher->launch(\%spec)` directly. The fork+exec (or Win32
  `system(1, …)` equivalent) happens in the scheduler process, so
  the new collector is a **direct child of the scheduler**. There
  is no `launches` table, no poll loop, and no separate launcher
  process for the simple case.
- **Preload launchers are the only launcher type that backs a
  service.** A preload-launcher object lives in the scheduler and
  proxies to its long-lived preload service process over a Unix
  socket. Test processes started under a preload are direct
  children of that preload service, not of the scheduler.
- **Every collected process is wrapped by exactly one collector.**
  The collector is the collected process's direct parent (fork+exec
  on POSIX, `system(1, …)` on Windows). Collectors do not
  double-fork. Reaping is the responsibility of whichever service
  is the collector's direct parent — the scheduler for non-preload
  jobs, the owning preload service for preload jobs.
- **Spawns are the only un-collected processes.** Their lifetime is
  controlled by the requester, not by the harness.
- **Upward death-watch cascades shutdown.** Every long-lived process
  in the tree (services and collectors alike) watches its parent
  pid. If the parent goes away the watcher terminates its own
  children, finalizes what it can, and exits. A scheduler death
  brings down the preload services and collectors it owned; a
  preload-service death brings down the collectors it owned. The
  rule exists so no test process is ever left running past the
  service that started it. See §5.x and §6.x.

## 3. Namespaces and dependency contract

`Test2-Harness2` ships several top-level namespaces; the rewrite uses
only the first two:

| Namespace                   | Scope                                                                                                                          |
|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `Test2::Harness2`           | The library. Database, schema, scheduler, services, collectors, launchers, resources, preloads, recorders. Specified here.    |
| `Test2::Formatter::Stream2` | In-test Test2 formatter that serializes events over `Atomic::Pipe` to its test-job collector. Lives outside `Test2::Harness2` because it loads inside test processes. Copied wholesale from `reference/old3`. |
| `App::Yath2`                | User-facing CLI, options layer, persistent daemons, render output pipeline. **Part 2 scope.** Not loaded by `Test2::Harness2`. |

Hard rules:

- `Test2::Harness2` **must not** `use`, `require`, or otherwise
  name-reach into any `App::Yath2*` namespace. Classes or objects
  from those namespaces are accepted only when the caller passes
  them in as constructor or runtime arguments — at which point the
  harness treats them as opaque Perl objects. Dynamic loading is
  acceptable only when driven by user-provided options that
  explicitly request `App::Yath2*` functionality.
- `App::Yath2` may freely depend on `Test2::Harness2`. The harness
  is its platform.

All run state, log artifacts, and per-job data live in the runner's
database from the moment they are produced — see §4. There is no
separate "log artifact" namespace and no DB-as-archive layer to bolt
on later; the database *is* the archive.

## 4. The database is the source of truth

There is exactly one place where state lives: the runner's database.
Every service is a database client. Cross-process communication is
"write a row, expect another process to notice it and write a row in
response". The database is what gives the system its consistency
guarantees, durability, and crash-recovery story; nothing else.

Default backend: SQLite. The schema is written so that
PostgreSQL / MySQL / MariaDB / Percona work as well; the SQL files
under `share/schema/<flavor>.sql` are kept in lock-step. SQLite is
the only flavor the harness ever starts on its own; the others are
discovered via DSN (with `DBIx::QuickDB` available for ephemeral test
setups). See §16 for the rebuild from `reference/old3`'s schema.

### 4.1 The `.t2h2` discovery file

Every running harness leaves a discovery file in the user's system
temporary directory. The default name is:

```
${SYSTEM_TMPDIR}/${USER}-${PROJECT}-${PID}.t2h2
```

Two forms:

- **Default mode (SQLite).** The `.t2h2` file *is* the SQLite
  database. Open it directly via `DBD::SQLite`.
- **Non-default mode** (Postgres, MariaDB, MySQL, Percona, or an
  externally hosted SQLite). The `.t2h2` file is a JSON document
  describing how to connect (DSN, username, etc.) plus the harness's
  pid, started timestamp, project, and user. Opening it dispatches
  to the real database.

The `.t2h2` file is cleaned up when the harness exits cleanly.
Discovery code (e.g. `App::Yath2` in Part 2) is responsible for
also cleaning up stale `.t2h2` files whose pid no longer exists
when it scans the directory.

### 4.2 The handle API

```perl
# Create a new SQLite-backed harness. .t2h2 file is created.
my $h = Test2::Harness2->new;

# Attach to an existing harness.
my $h = Test2::Harness2->connect($dsn_or_path);

# Spin up a runner (inserts a row into `runners`).
my $r = $h->new_runner;

# Start the scheduler service for that runner.
my $s = $r->start_scheduler(
    resources => [
        [$resource_class, \%resource_settings],
        ...
    ],
    launchers => [
        [$launcher_class, $launcher_name, \%launcher_settings],
        ...
    ],
);

# Queue a run. Returns a Run object the caller can refresh and inspect.
my $run = $s->queue_run(
    jobs      => [ {...}, {...} ],
    resources => [...],          # adds to / overrides per-runner resources for this run
    launchers => [...],          # adds to / overrides per-runner launchers for this run
    env       => { ... },        # env applied to all jobs in this run
);

# Block until no more runs will be queued; the scheduler shuts down
# when its queue drains.
$r->finish;

# Pull result.
$run->refresh;
return $run->result;
```

### 4.3 Generic row API

Every database table has a corresponding **DB row class** under
`Test2::Harness2::DB::*` that holds column data and nothing else.
These classes are the persistence layer; they are deliberately
"dumb" — load, refresh, save, transform-for-display, no business
logic. They compose `Test2::Harness2::Role::Row`, which provides:

- `$row->save` — write any changed fields back to the row.
- `$row->refresh` — re-fetch the row and update fields in place.

Class-name derivation from table name is mechanical (depluralise
the table name with `ies $<gt> y`, `ches $<gt> ch`, then strip
trailing `s`; then CamelCase the snake_case segments; then prefix
with `Test2::Harness2::DB::`). The conversion lives in
`Test2::Harness2::Util::table_to_db_class`. Examples:

- `users` → `Test2::Harness2::DB::User`
- `job_tries` → `Test2::Harness2::DB::JobTry`
- `preloads` → `Test2::Harness2::DB::Preload`
- `service_state` → `Test2::Harness2::DB::ServiceState`
- `vcs_info` → `Test2::Harness2::DB::VcsInfo`

There is no maintained table → class hash; the conversion is the
contract.

The harness handle exposes generic fetch/insert helpers:

- `$h->fetch($table, %where)` → one row object.
- `$h->fetch_all($table, %where)` → list of row objects.
- `$h->insert($table, \%row1, \%row2, …)` → list of newly-inserted
  row objects. Implementations must optimize multi-row inserts —
  fast bulk insertion is required, not optional.

Implementation: hand-written SQL on raw `DBI`, optionally aided by
`SQL::Abstract`. **No `DBIx::Class`.**

### 4.4 Logic-class / row-class split

Tables with non-trivial behavior (`Scheduler`, `Service`,
`Launcher`, `Resource`, `Run`, `Collector`, `JobTry`, …) get a
second class — a **logic class** — at the canonical
`Test2::Harness2::*` path (e.g. `Test2::Harness2::Runner::Scheduler`,
`Test2::Harness2::Runner::Service`). Lookup-only tables (`User`,
`Host`, `Project`, `TestFile`, `VcsInfo`, `Version`, `Instance`)
do **not** get a logic class — the DB row is the only object.

The logic class holds a `row` slot referencing its DB row and
implements behavior (signal handling, dispatch loops, transient
caches, etc.). Mutators on the logic class read columns through
the row, mutate the row's hash, and call `$self->row->save`:

```perl
sub cancel {
    my $self = shift;
    $self->row->{status} = 'canceled';
    $self->row->save;
}
```

External consumers of the schema (`App::Yath2`, reporting tooling,
ultraviewer) import `Test2::Harness2::DB::*` classes directly and
never see logic methods. Internal mutating code — and only that
code — uses the logic classes in `Test2::Harness2::*`. This makes
the mutator surface a class-level boundary, not a documentation
convention.

When a single table backs multiple logic classes (e.g.
`resources` backs both `Runner::Resource` for runner-global rows
and `Runner::Run::Resource` for run-scoped rows), the dispatch
lives in the logic layer (a logic factory on the handle inspects
the row data and picks the logic class). The DB row class is
always the same.

Column delegation on logic classes is installed by
`use Test2::Harness2::Util::DBDelegate '<table>';`, which:

- Loads the matching DB row class,
- Verifies its `TABLE` matches,
- Installs a `ROW` constant (`'row'`), a `row` accessor, and
  `TABLE` / `DB_CLASS` class methods,
- Installs one reader per column that delegates to the row.

Setters are deliberately not installed; mutations are an explicit
two-step (`$self->row->{col} = $val; $self->row->save`).
`Object::HashBase` remains unaware of the `row` slot — it is an
injected hash key, not a HashBase attribute.

Collectors and auditors **never** touch the database directly. Every
write a collector or auditor needs to make goes through its
**recorder** (see §5.7). The recorder is the only object in the
collector pipeline allowed to own a `DBI` handle. This keeps the
`Files` recorder a viable swap-in for development and tests — if
collectors or auditors reached past the recorder to write SQL, the
non-DB recorder would be useless.

The recorder itself may use raw SQL on its own `DBI` handle for
performance; it does not need to go through the row-object layer
for hot paths (event-stream writes, state transitions, exit
recording). Bulk inserts inside the recorder are expected to use
the same multi-row insert pattern the row-object layer uses.

## 5. Collector subsystem

### 5.1 Topology

```
parent service              (scheduler for regular launches; preload service for preload launches; any service that needs to collect a process)
   |
   | fork                   (in-process launcher fork; or preload service fork)
   v
collector process
   |  build mixed-data Atomic::Pipes for STDOUT and STDERR
   |  fork
   v                               .---------------------.
collector parent (collector loop)  | collector child     |
   |                               | replace IO with pipes
   |                               | exec / run sub
   |                               | (or goto::file for preloads)
   |                               `---------------------'
```

The fork into the collector is a single fork (no double-fork). The
collector's parent — the scheduler for regular launches, the
preload service for preload launches — keeps the collector's pid
in its tracking state and reaps it on exit (via non-blocking
`waitpid` inside its event loop, see §6.5). The reap entry is the
signal the scheduler uses to release the resource hold for that
job; see §8.

### 5.2 Entry point

```perl
my $pid = fork // die "fork: $!";
return if $pid;          # parent (the spawning service / launcher) returns

# In the collector process:
require Test2::Harness2::Collector;
Test2::Harness2::Collector->start(
    exec      => \@argv,               # one of:
    run       => sub { ... },          #   exec OR run sub
    parser    => 'Test2::Harness2::Collector::Parser::...',
    auditor   => 'Test2::Harness2::Collector::Auditor::...',  # optional
    recorder  => 'Test2::Harness2::Collector::Recorder::...',
);

# Should not be reached.
exit 0;
```

`start` does the rest:

1. Inserts the collector row in the `collectors` table with
   `pid` = our own pid, `watched` filled in once the collected
   process is forked, `start time` = now, and `type` = `service`,
   `test job`, etc. Insertion goes through the recorder so the
   `Files` recorder can do the equivalent for tests-without-a-DB.
2. Creates the mixed-mode `Atomic::Pipe`s for STDOUT and STDERR.
3. Forks. In the child, replaces STDOUT / STDERR with the pipes,
   then either `exec`s `@exec` or `goto`-style invokes the `run`
   sub.
4. In the collector parent, runs the event pipeline (parser →
   optional auditor → recorder) over the pipes until the collected
   child exits.
5. Waits on the child to collect its exit code. Stamps `stop time`
   and `exit code` on the collector row via the recorder.
6. Sets `finalized` on the collector row (also via the recorder) so
   downstream readers know the row is closed. Exits 0.

**Test-job process groups.** When the collected process is a test
job (i.e. `type = 'test job'`), the child calls
`POSIX::setpgid(0, 0)` post-fork / pre-`exec` (or pre-`goto::file`
in the preload case) to enter a **fresh process group of its own**.
The collector itself stays in its parent's process group (the
scheduler for regular launches; the preload service for preload
launches). This isolates the test: a test that does
`kill 'TERM', 0` (or otherwise signals its own process group)
reaches only its own descendants, never the collector, the
scheduler, the preload service, or any other part of the harness
tree. Service collectors and their collected services do not get
this treatment — they stay in their parent's group so a
deliberate sweep can reach them.

### 5.3 Pipe protocol

Stdout and stderr are wrapped by `Atomic::Pipe` in mixed-data mode.
On the same pipe both:

- **Raw text** — anything the collected process writes via `print`,
  `warn`, `printf`, etc.
- **Framed event bursts** — atomic message bursts written through
  the `write_message` API. The wire format is shared between
  `Test2::Formatter::Stream2` (used inside test processes) and
  anything else that wants to emit structured events.
- **Zstd-compressed bursts** are first-class. `Atomic::Pipe` exposes
  the bytes both compressed and decompressed; the recorder may
  pass through the still-compressed form when writing
  `events.jsonl.zst` (frame-per-line), avoiding a recompression
  hop. Refer to the `Atomic::Pipe` source under
  `~/projects/Atomic-Pipe` for the wire details and zstd handling.

STDOUT bursts are paired with a small **sync record** on STDERR
(also via `write_message`). The collector uses the sync record to
keep interleaved raw STDOUT / STDERR output ordered correctly
against the events that bracket it. Buffering is configurable per
`start()` call (`buffering => 0` disables it for live-tail-priority
callers, in which case STDERR sync markers are dropped and raw
output is dispatched in strict pipe-arrival order). A
`flush_interval` (default `0.25s`, `0` disables) caps how long
buffered records may sit waiting for an event-pair: when the
interval elapses with items pending, the collector force-flushes
so a long quiet stretch between structured events does not hide
raw output indefinitely.

There is **no cross-kind FIFO guarantee** between a raw `print` and
a `write_message` on the same fd from the same producer (a known
property of pipe scheduling — see `reference/old3` Addendum A for
the long-form analysis). Producers must not rely on it. In normal
use the pacing of test output makes the race invisible; tests that
deliberately interleave both kinds in a tight loop need to insert
their own pacing or use a dedicated pipe for one of the streams.

### 5.4 Event pipeline

**Test-job collector:**

```
collected stdout / stderr
  → Parser    (frames → events; TAP lines → events; raw lines → STDOUT/STDERR events)
  → Auditor   (pass/fail, plan / count reconciliation, synthetic events)
  → Recorder  (writes events; updates state; handles attachments)
```

**Service collector:**

```
service stdout / stderr
  → Parser    (frames → events; raw lines → STDOUT/STDERR events; TAP not recognized)
  → Recorder  (writes events; no auditor)
```

Per the rule from `reference/old3` §12.3: **TAP is a test-collector-only
input.** Service collectors do not parse TAP; lines that resemble
TAP are wrapped in `STDOUT` / `STDERR` events like any other raw
output.

### 5.5 Parsers

Live under `lib/Test2/Harness2/Collector/Parser/`. They consume the
bytes the collector reads and emit `Test2::Harness2::Event` objects.
Initial set, ported and renamed from `reference/old3`:

- `Test2::Harness2::Collector::Role::Parser` — the role.
- `Test2::Harness2::Collector::Parser::IOParser` — base. Wraps each
  raw line in `from_stream` + `info` facets; decodes message bursts
  directly into events.
- `Test2::Harness2::Collector::Parser::TAPParser` — subclass of
  `IOParser` that additionally recognizes TAP and converts TAP
  lines to events. Used only inside test-job collectors.

Parsers do not stamp `run_id` / `job_id` / `job_try` onto events —
that provenance is carried by the surrounding collector row and the
parent service rows.

### 5.6 Auditors

`Test2::Harness2::Collector::Auditor::Test` consumes
`Test2::Harness2::Collector::Role::Auditor`. Responsibilities:

- Track assertions, plans, nested subtests (recursively), errors,
  halt status, the child's exit code.
- Emit synthetic events for subtest announcements, plan / count
  mismatches, and recoveries from malformed TAP.
- Drive state transitions on the recorder. The recorder exposes a
  state-transition method (see §5.7) that the auditor calls when
  the job moves between meaningful states (`starting` → `running`
  → `diagnosing` / `failing` → `completed`, etc.).

Only test-job collectors install an auditor. Service collectors run
without one.

### 5.7 Recorders

Recorders consume `Test2::Harness2::Collector::Role::Recorder` and
form the sink of the event pipeline. **The recorder is the only
object in the collector pipeline that may touch the database.**
Parsers, auditors, and the collector core itself must route every
write through one of the recorder methods below. The recorder is
free to use raw SQL on its own `DBI` handle for performance; nobody
else gets that handle.

The role surface:

- `record_event($event)` — append the event to the event stream.
  May fast-path the compressed-bytes form when the parser hands the
  recorder a pre-encoded `zst` frame.
- `record_state($state, $extra)` — called by the auditor when the
  collected process transitions between states.
- `record_exit($exit)` — called when the collected process exits.
- `record_artifact(\%spec)` — called when an event implies an
  external artifact (a screenshot file, etc.) needs to be tracked.
- `finalize` — called at the very end. Closes any open files,
  finalizes the database row, etc. Recorders are responsible for
  setting the `finalized` column on their collector row through
  this method.

Two recorders ship in Part 1:

- `Test2::Harness2::Collector::Recorder::Files` — simple, no
  database. Writes:
  - `events.jsonl` — JSONL event stream, one event per line.
  - `state.jsonl` — JSONL stream of state transitions.
  - `exit` — single file holding the exit code.
  Used by the development collector helper script (`t/scripts/collector`)
  and by integration tests that exercise the collector without a DB.
- `Test2::Harness2::Collector::Recorder::DB` — production recorder.
  Writes:
  - The `collectors` row (insert at startup; update with `stop
    time`, `exit code`, `finalized` at the end).
  - `events.jsonl.zst` on disk at `${workdir}/events/<UUID>.jsonl.zst`.
    One self-contained zstd frame per event for live-tail support;
    multiple compressed bursts coming off the pipe pass through to
    the file without recompression. The UUID exists only to give the
    file a unique name; it does not need to be referenced after the
    artifact lands in the database.
  - An `artifacts` row pointing at the events file via `local_path`
    (the full path including the UUID).
    When the collector finishes the recorder reads the events file
    back into the `content` column, clears `local_path`, and
    **unlinks the on-disk file**. The UUID is discarded.
  - Additional `artifacts` rows for any external file the auditor
    or parser flagged (screenshots, etc.); same `local_path` →
    `content` migration policy. External files the user supplies a
    permanent path for are kept in `local_path` and not migrated;
    that is a per-artifact recorder decision.
  - State transition rows in the appropriate table (`job_tries`
    state, `service_state` for services).

### 5.8 Timeouts

The collector enforces three independent timeouts. All three are
configurable per `start()` call; passing `0` disables a given
timeout. `silence_timeout` and `lifetime_timeout` apply to **test
jobs only** (`type => 'test job'`); service collectors ignore them.

**Silence timeout** (`silence_timeout`, default `0`). While the
collected process is still running, the collector tracks the gap
since the last byte arrived on either pipe. When that gap reaches
the limit, the collector:

1. Emits a synthetic event into the stream with the shape

   ```
   facet_data => {
       harness_timeout => { kind => 'silence', limit_seconds => $N, delta_seconds => $d, stamp => $t },
       errors          => [{ tag => 'TIMEOUT', fail => 1, from_harness => 1, details => '...' }],
       info            => [{ tag => 'TIMEOUT', debug => 1, important => 1, details => '...' }],
   }
   ```

   The `fail => 1` error makes the auditor turn the run into a
   failure.

2. Sends `SIGTERM` to the collected process. If the child has not
   exited after the standard kill-grace
   (`DEFAULT_KILL_TIMEOUT` = 5s), the collector sends `SIGKILL`.
   The kill state machine runs *inside* the IO loop — the collector
   keeps draining pipes while waiting for the child to die, so the
   child's final output is not lost to a blocked pipe.

3. Calls `record_exit($status, { timed_out => 'silence' })` so the
   recorder can flag the condition independently of the synthetic
   error event (a database consumer should be able to distinguish a
   timeout-induced failure from an in-test failure without scanning
   the event stream).

**Lifetime timeout** (`lifetime_timeout`, default `0`). Same event
and kill behavior as the silence timeout, but triggered by total
runtime rather than idle time. Useful as an outer guard for tests
that livelock while still printing output. The recorder receives
`timed_out => 'lifetime'`. No previous version of yath had this;
silence/post-exit have legacy analogues but a hard runtime cap is
new.

**Orphan timeout** (`orphan_timeout`, default `30`).

The collector cannot rely on its child closing its pipes when it
exits. A test (or a service) may fork further processes that inherit
STDOUT / STDERR and outlive the original child; those descendants
keep the pipes open after the child has been reaped. If the collector
waits for EOF in that case it waits forever.

To handle this, the collector polls `waitpid($child, WNOHANG)` inside
its select loop. Once the child has been reaped, the collector tracks
how long it has been since any byte arrived on either pipe. If that
quiet interval reaches the configured **orphan-timeout** (default
`30s`), the collector:

1. Emits a synthetic event into the stream:

   ```
   facet_data => {
       harness_orphan => {
           stamp         => <hi-res time>,
           quiet_seconds => <timeout used>,
           wait_status   => <reaped status>,
       },
       info => [{ tag => 'ORPHAN', debug => 1, details => '...' }],
   }
   ```

   The event flows through the auditor (if present) and the recorder
   like any other event.

2. Calls `record_exit($status, { orphaned => 1 })` so the recorder
   can surface the condition. The `Files` recorder writes an
   `orphaned` marker file alongside `exit`; the DB recorder sets the
   `job_tries.orphaned` boolean.

3. Exits the IO loop. The collector itself **does not** kill the
   orphan descendants — they are left to be cleaned up by whatever
   process-group policy is in effect higher up (the parent
   scheduler or preload service, plus the death-watch cascade in
   §5.10 / §6.6).

The orphan condition is a diagnostic, not a failure. The collector
itself returns `0` regardless — the collected process's pass/fail
signal lives in the event stream (auditor + recorder), not in the
collector's exit code. The orphan timeout is configurable per
`start()` call (`orphan_timeout => $seconds`); `0` disables the
check.

The reference implementation (`reference/legacy`) has the conceptual
analogue — `--post-exit-timeout`, see
`reference/legacy/lib/Test2/Harness/Runner.pm:152` `check_timeouts` —
but applies it from the runner against the test's process group
rather than from a per-process collector, and uses it to kill the
descendants rather than to drop a flag. The behavior here is more
conservative: detect, annotate, move on.

The silence timeout is the analogue of legacy `--event-timeout`
(same `check_timeouts` code path). The lifetime timeout has no
legacy analogue; it is new in `Test2::Harness2`. All three timeouts
will be exposed via the future yath CLI and, eventually, via
in-test directives — see `PART_2_PLAN.md`.

### 5.9 Signals and errors

Collectors install signal handlers for `SIGTERM`, `SIGINT`,
`SIGQUIT`, `SIGUSR1`, `SIGUSR2`, `SIGHUP`, `SIGPIPE`:

- `SIGUSR1` / `SIGUSR2` / `SIGHUP` / `SIGPIPE` — ignored. Tests
  use these for their own coordination; the collector must survive
  them.
- `SIGTERM` / `SIGINT` / `SIGQUIT` — forwarded to the collected
  process. The collector itself does **not** exit on these. It
  keeps draining the pipes and finalizing; the collected process
  exiting is what ends the collector.

Collectors work hard to keep going on errors:

- Every recoverable exception is caught (`my $ok = eval { ...; 1 }`
  per `STYLE_GUIDE.md`). Two things happen on a caught exception:
  print the error to the *real* STDERR (saved before the redirect
  in §5.2) and insert a synthetic error event into the event
  stream via the recorder. The collector then continues.
- Collectors exit `0` whenever the pipeline finished cleanly,
  regardless of the collected process's own exit status — that
  status is recorded into the event stream, not propagated to the
  collector's exit code. Collectors exit `255` only when they
  themselves fail internally before they could finish their job.

### 5.10 Upward death-watch

Collectors watch their parent pid for the same reason services do
(see §6.6). The collector captures `getppid()` at start and checks
it once per IO-loop iteration. If the captured pid no longer
matches:

1. Send `SIGTERM` to the collected child.
2. Keep draining the pipes during the standard kill-grace
   (`DEFAULT_KILL_TIMEOUT`, 5s).
3. `SIGKILL` the child if it is still alive.
4. Emit a synthetic event into the stream marking
   `harness_orphan` with a reason of `'parent_died'` (distinct
   from the orphan-timeout case in §5.8), so consumers can see
   why the collector tore down early.
5. Call `record_exit($status, { parent_died => 1 })` so the
   recorder can persist the condition (`job_tries.parent_died`
   boolean in the DB recorder; a marker file in the `Files`
   recorder).
6. Finalize the collector row and exit.

On Linux the collector may additionally arm `PR_SET_PDEATHSIG`
for an instant wake on parent death — same optimization status
as in §6.6.

The rule is non-negotiable: no test process is ever allowed to
outlive the service that launched its collector. A scheduler
crash, a preload-service crash, or any other parent death must
result in the collected children being torn down rather than
left running. Combined with the death-watch on services
themselves (§6.6) this guarantees clean cascade shutdown of the
entire harness tree.

### 5.11 Development helper script

For early development (before the launcher subsystem is in place),
ship a `t/scripts/collector` script that wraps the entry point:

```
t/scripts/collector <Parser::Class> <Recorder::Class> [<Auditor::Class>] -- <CMD> <ARGS...>
```

It reads the class names, builds the entry-point call, and lets the
test exercise the collector end-to-end against a synthetic child.
The `Files` recorder is the typical recorder for this script.

## 6. Service framework

`Test2::Harness2::Role::Service` defines the contract for every
long-lived helper process in the harness tree (scheduler, resource
services, preload services). Regular launchers do not consume
`Role::Service` — they are plain in-process objects owned by the
scheduler. See §7.

### 6.1 The event loop

A service is an event loop. Each iteration:

1. Check the service's termination flag (a column on its
   `service_state` row, or on its dedicated service-table row).
   Exit cleanly if it is set.
2. Wait for an event with `select` (or the platform equivalent),
   using a timeout derived from the current backoff. The wait
   returns early on any of:
   - A readable FD the service registered via the event-loop hook
     (e.g. the preload service's request socket — see §10).
   - A signal (`SIGUSR1` and friends — see §6.2).
   - The backoff timer expiring.
3. **Reap children** non-blocking (`waitpid(-1, WNOHANG)` in a
   loop). Any service that forks children — scheduler, preload
   service — owns reaping them in its own loop. See §6.5.
4. Service the upward **death-watch** (§6.6): if the parent pid
   has gone away, begin cascade shutdown.
5. Read whatever the service is interested in from the database
   (`requests` rows, work-table rows, etc.) and from any FD that
   was readable.
6. Process whatever work was found, writing responses back to the
   database / socket as appropriate.
7. If anything was done this iteration, immediately loop again
   (non-blocking).
8. If nothing was done, advance the backoff before the next
   iteration: `0.05s`, `0.1s`, `0.5s`, then `1s` as the maximum.
   Any iteration that did work resets the backoff. Use
   `Time::HiRes::sleep` (or `select` with a sub-second timeout)
   so the wake-up actually takes effect — see `STYLE_GUIDE.md`.

This pacing is deliberate. Continuous polling with no sleep would
hammer the database; long sleeps add latency. The backoff plus the
`SIGUSR1` wake-up plus the readable-FD wake-up is the balance.

### 6.1.1 Registering extra wake sources

`Role::Service` exposes a small hook that lets a consumer register
additional readable FDs for the loop to select on:

```perl
$self->register_event_fd($fh, sub { $self->handle_socket_request($fh) });
```

When `$fh` becomes readable the loop calls the callback before
moving on to the rest of the iteration. The hook exists so the
preload service (and any future service that needs synchronous IPC)
can integrate its socket without bespoke loop code.

### 6.2 SIGUSR1 wake-ups

On platforms where it is supported, services install a no-op
`SIGUSR1` handler. Other processes that have just written work into
the database can send `SIGUSR1` to a service's pid (read from
`services.pid`) to interrupt its sleep early. The service's next
iteration sees the new work without waiting for the backoff to
expire.

`SIGUSR1` is an optimization, not a contract. On platforms that
don't support signals (some Win32 contexts) the harness still
works; the sleep simply expires on its own schedule. The preload
service also wakes on socket-readable in addition to `SIGUSR1`,
which makes `SIGUSR1` even less critical for that service.

### 6.3 Service state and requests

Two tables drive service behavior:

- `service_state` — every service writes a new row whenever its
  status changes (`starting`, `up`, `down`, `stopping`, `stopped`,
  `broken`). The most-recent row for a given `service_id` is the
  current state. `content` is a JSON column the service uses to
  publish state to readers (notably resources publish their
  availability picture here).
- `requests` — one row per request directed at a service.
  `service_id` identifies the addressee, `payload` is the request
  body, `response` is the answer, `completed` is set when the
  service has finished. If the service has nothing meaningful to
  return, `response` stays null but `completed` is still set so the
  requester can confirm completion.

Requests are deleted by the requester after it reads the response,
unless a per-service flag asks the service to keep history. In the
keep-history mode the request row is preserved and `finalized` is
set after the response is read.

### 6.4 Service collectors

Every service runs under its own collector. The collector's parser
+ recorder do for the service what they do for tests: capture every
byte of stdout / stderr the service prints, produce events, and
record them. Service collectors run without an auditor.

A service does not have to emit structured events. If it just
prints diagnostic text, the parser wraps each line as a
`STDOUT` / `STDERR` event and the recorder captures it. Services
that want to emit structured events use the same wire frame as
`Stream2` (the service-side helper from `reference/old3`'s
`Util::EventEmitter`, ported into the new tree).

The collector outlives its service: when the service exits, the
collector finalizes and exits too. The process that started the
service (its parent — the scheduler for resource and preload
services; the caller's harness handle for the scheduler itself)
reaps the collector.

### 6.5 Child reaping

Every service that forks children is responsible for reaping them
in its own event loop, non-blocking:

```perl
while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
    my $status = $?;
    $self->on_child_exit($pid, $status);
}
```

Reaping happens once per loop iteration before any DB work, so a
child that exited mid-sleep is recognized on the next wake. The
service is also free to install a `SIGCHLD` handler that signals
the loop to wake early; the handler must not call `waitpid` itself,
only flag the loop.

Examples by service:

- **Scheduler.** Reaps collectors it spawned via in-process
  launchers (regular launchers). Also reaps its preload services,
  resource services, and any other direct children. On collector
  reap, looks up `pid → (job_try_id, resource hold)` in its
  in-memory map and releases the hold (see §8).
- **Preload service.** Reaps collectors it forked from its
  preloaded process. On reap, optionally signals the scheduler
  via `SIGUSR1` so the scheduler picks up the `job_tries`
  completion sooner. The collector itself already wrote its exit
  bookkeeping via the recorder.
- **Resource services.** Same pattern if the resource service
  forks children; most do not.

### 6.6 Upward death-watch

Every service watches its parent pid. The check runs once per
event-loop iteration. On POSIX:

```perl
my $orig_ppid = getppid();
# ...later, each loop iteration...
if (getppid() != $orig_ppid) {
    $self->begin_cascade_shutdown();
}
```

When `getppid()` no longer matches the value captured at startup
(typically because the parent died and the OS reparented to init
or to a subreaper), the service:

1. Stops accepting new work — closes its request socket, ignores
   further DB requests addressed to it.
2. Signals every child it owns: `SIGTERM`, brief grace period,
   `SIGKILL` if still alive. Children include collectors started
   by this service plus any helper subprocesses.
3. Reaps each child as it exits.
4. Finalizes its own `service_state` row (`status='broken'` with
   a note that the parent died), best-effort.
5. Exits.

The cascade is depth-first: a scheduler death takes down every
preload service and direct-child collector. Each preload service,
seeing its parent gone, takes down its own collectors in turn. No
test process is ever orphaned past the chain of services that
launched it.

On Linux the service may additionally arm `PR_SET_PDEATHSIG` to
get an instant wake on parent death rather than waiting for the
next iteration. Treat that as an optimization, not a substitute
for the `getppid()` check — the loop must work on platforms
without it.

The same death-watch lives on **collectors**, see §5.x. The
mechanism there is identical; the rule is repeated under §5
because the collector loop is structured differently from the
service loop.

## 7. Launchers

`Test2::Harness2::Role::Launcher` is a thin contract role declaring
what every launcher must provide. Launchers are **not** services in
their own right. Most are plain in-process objects owned by the
scheduler; only the preload launcher backs a separate service
process, and even then the scheduler-side object is a proxy that
talks to the service over a Unix socket.

### 7.1 Common contract

`Role::Launcher` requires:

- **`name`** — short identifier used for logging and for routing
  jobs to a specific launcher.
- **`launch(\%spec)`** — synchronously start one collector + test
  process pair for the given spec. The spec carries the test
  binary / argv, env, cwd, job_try_id, and any other per-launch
  metadata the scheduler has assembled.

`launch` returns one of:

- `(ok => 1, pid => $pid)` — process started. `pid` is set only
  for launchers whose `launch` forks in the scheduler's process
  (regular launchers); preload launchers return `ok` without a
  pid because the test process is a child of the preload service
  rather than of the scheduler.
- `(ok => 0, error => $reason, temporary => 0|1)` — start failed.
  When `temporary` is true the scheduler returns the job to the
  queue and tries again on a future loop. When false the
  scheduler fails the job_try with `$reason` and does not retry
  on this launcher (the unavailable-action / fallback policy in
  §8.3 may still queue a fallback launch through `Default`).

Launchers do not poll the database. There is no `launches` table.
The scheduler decides which launcher handles each job and calls
`launch` directly. The resulting collector becomes a child of
either the scheduler (regular launchers) or the preload service
(preload launchers); see §5.1 and §6.5 for reaping responsibilities.

### 7.2 Implementations

- `Test2::Harness2::Launcher::ForkExec` — POSIX. Plain
  `Object::HashBase` object consuming `Role::Launcher`. Its
  `launch` does `fork` + `exec` inside the caller's process
  (the scheduler) to start the collector. The collector then
  forks once more for the collected process per §5.1. Returns
  the collector's pid.
- `Test2::Harness2::Launcher::Win32` — Windows. Same shape; uses
  the `system(1, …)` window trick instead of `fork` + `exec`.
- `Test2::Harness2::Launcher::Default` — construction-time picker.
  Inspects the platform and returns a `ForkExec` or `Win32`
  instance. No delegate process, no extra address space; the
  scheduler uses the returned object directly.
- `Test2::Harness2::Launcher::Preload` — preload-aware launcher.
  Holds a connection (or per-call connection) to its preload
  service's Unix socket and forwards `launch` over the wire.
  See §10 for the service side and the socket protocol.

Regular launchers are constructed at scheduler startup and live
for the scheduler's lifetime. There is no "start a launcher as a
fresh process" recipe; no `=start` import, no INIT trampoline.
The preload service has its own `BEGIN` / `Long::Jump` /
`goto::file` bootstrap recipe described in §10.2 — that recipe
is preserved as-is.

### 7.3 Preload socket protocol

Each preload service listens on a Unix socket whose path is
recorded in `preloads.socket`. The same socket carries two
request types:

- `launch` — scheduler-initiated; start a collected test process
  out of this preload.
- `spawn` — external-caller-initiated (e.g. `yath spawn` in Part 2);
  start a single command out of this preload with no collector.

Framing: each message is a length-prefix (`4-byte big-endian
unsigned`) followed by a JSON object. Requests and replies use
the same framing. Connections are accepted on the socket; the
scheduler may keep a long-lived connection per preload for `launch`
traffic, while external `spawn` clients typically connect
per-request.

`launch` request:

```
{ "type": "launch", "spec": { ...launch spec... } }
```

`launch` reply (one of):

```
{ "ok": 1 }
{ "ok": 0, "error": "<reason>", "temporary": 0|1 }
```

The reply carries no pid and no collector_id. The collector
writes its own row to `collectors` once it has started; the
scheduler reads the DB to learn that the test is running.

`spawn` request:

```
{ "type": "spawn", "spec": { argv, env, cwd, ... } }
```

`spawn` lifetime: the preload service forks the requested process
(under the preloaded state, no collector) and wires:

- The new process's STDOUT and STDERR to the requester's
  STDOUT / STDERR (the FDs come over the socket via SCM_RIGHTS,
  or via a side-channel — implementation detail).
- The requester's STDIN to the new process's STDIN.

The preload service forwards signals from the requester to the
spawned child. The spawned child's exit code becomes the
requester's exit code. Spawns are double-forked into a new
process group so they outlive the connection handler. They do
not appear in `collectors`. They exist so commands like `yath spawn`
(Part 2) can run a single command with the preload's in-memory
advantage without paying for the full test-job framing.

### 7.4 Error classification

A preload service that returns `temporary => 1` is telling the
scheduler "this attempt could not be served right now, but the
problem is not the launch spec itself — try again." Examples:

- The preload is mid-restart (in-place reload, or `exec`-restart
  per §10.4).
- A transient OS-level fork failure (`EAGAIN` from `fork` because
  of an RLIMIT brush).
- A short-lived resource the preload owns is exhausted right now
  but expected to recover.

A preload service that returns `temporary => 0` is telling the
scheduler "this attempt is genuinely broken — do not retry on
me." Examples:

- The launch spec references a test file that does not exist.
- The preload has decided it cannot service this kind of job at
  all (compatibility mismatch).
- A required module failed to load in the preload's `%INC` and
  the preload cannot fork tests out of itself until it is
  reloaded.

The classification is made by the preload service at the moment
it generates the error. The scheduler does not second-guess it
(see §8 for the retry / fallback decision tree). Permanent errors
feed the unavailable-action / fallback path in §8.3.

## 8. Scheduler

`Test2::Harness2::Scheduler` is a service. There is exactly one
scheduler per runner; its row in `services` has `name = 'scheduler'`,
`runner_id = $runner_id`, and `run_id IS NULL` (the scheduler is
global to the runner, not per-run).

The scheduler owns:

- In-process resource objects (see §9).
- In-process launcher objects (see §7) — `ForkExec`, `Win32`, or
  `Default` for the regular launchers, plus one `Preload`
  proxy-object per configured preload.
- The supervisory relationship for any preload service or
  resource service it started — reaping and restart policy live
  here.

### 8.1 Responsibilities

- Watch the `runs` table for queued runs that belong to its runner.
  A run is "queued" when its row exists but `started` is null.
- For each runnable run, evaluate resources. The scheduler asks
  each resource whether the run can proceed and how many slots it
  can grant.
- Walk `jobs` for the run, choose the next job to dispatch based
  on resource availability, and decide which launcher should
  handle it.
- Call `$launcher->launch(\%spec)` directly. For regular launchers
  this fork+execs in the scheduler's process. For preload
  launchers the call goes over the preload service's Unix socket.
  Both paths are synchronous from the scheduler's point of view.
- Update `runs.passed`, `runs.failed`, `runs.result` in real time
  as `job_tries` complete. Set `runs.started` / `runs.finished`
  appropriately.
- When `runs.status` flips to `canceled`, stop dispatching further
  jobs for that run and terminate any in-flight jobs by setting a
  terminate flag on their collectors via the recorder's state
  path.
- Reap own children non-blocking each loop iteration (see §6.5):
  collectors started by regular launchers, supervised preload
  services, supervised resource services.
- Exit when the runner is finalized and the queue is empty.

For the first iteration the scheduler executes runs sequentially
(`yath test`-style) — one run at a time, one job at a time inside
that run. Concurrency support arrives in a later stage.

### 8.2 Resource assignment

The resource API is symmetric `allocate` / `release` (see §9). For
every job the scheduler:

1. Asks each configured resource `needed($job)` and
   `available()`. If the job needs a resource that is not
   available it is deferred.
2. Calls `$hold = $resource->allocate($job, $need)` on each
   granting resource to take its slot(s). The hold is an opaque
   token the scheduler keeps until the attempt terminates.
3. Calls `$launcher->launch(\%spec)` (see §8.2.1 below).
4. On *any* termination of the attempt — normal exit, fail,
   `temporary` error, `permanent` error, recovery-sweep cleanup —
   calls `$hold->release` on every hold the attempt was using.
   Release is unconditional; there is no separate "commit" step.

Resources backed by services publish their state to the scheduler
via `service_state.content`. The scheduler's resource object reads
that JSON to decide availability without having to wait on a
synchronous request.

### 8.2.1 The dispatch state machine

For each dispatched attempt:

1. **Allocate holds.** `$hold = $resource->allocate(...)` for
   every needed resource. If any required resource cannot
   allocate, the job is deferred and no holds are taken.
2. **Persist intent.** Insert (or update) the `job_tries` row
   for this attempt with `started = now()` and the chosen
   launcher recorded in the row.
3. **Call `launch`.** Synchronous. Branch on the return:
   - `ok => 1` — slot is filled. Store
     `(job_try_id => [$hold, $hold, ...])` in the in-memory map.
     For regular launchers, also store `pid => job_try_id` so the
     reap loop can resolve the pid back to the holds.
   - `ok => 0, temporary => 1` — release every hold, clear the
     `started` timestamp on the `job_tries` row (or insert a new
     try row, per the retry policy in §11), and let the next
     loop iteration pick the job up again.
   - `ok => 0, temporary => 0` — release every hold and fail the
     `job_try` with `error` as the reason via the recorder
     pathway. If the failing launcher was a specialized one (a
     preload), the unavailable-action / fallback path in §8.3
     may also queue a `Default`-launcher attempt so the
     downstream stream still sees a deterministic skip / fail
     row. Permanent errors do **not** retry on the same launcher.
4. **Wait for completion.** Two paths:
   - Regular launcher: the collector is a direct child of the
     scheduler. The non-blocking reap loop (§6.5) catches its
     exit. Look up `pid → job_try_id → holds` and release.
   - Preload launcher: the collector is a child of the preload
     service. The scheduler watches for the matching `job_tries`
     completion via DB poll, woken by `SIGUSR1` from the preload
     service when a child exits. On completion, look up
     `job_try_id → holds` and release.

### 8.2.2 In-memory preload status

The scheduler holds an in-memory `up` / `down` flag per preload
launcher object. On boot the flag mirrors whether the scheduler
has confirmed the preload service is accepting socket connections.
While `up`, the scheduler issues `launch` calls against the
preload without first round-tripping through the DB. The error
path:

- Connect / write / read fails on the socket → flip flag to
  `down`, treat the in-flight attempt as `temporary` (job
  returned to queue), respawn the preload service.
- A `temporary => 1` reply from the preload → leave flag `up`,
  return job to queue.
- A `permanent` reply → leave flag `up`, fail the job_try.

When a preload service is `down` the scheduler skips it for the
pass (does not dispatch to it) and respawns it on its supervisory
path. When the respawned service announces ready, the flag flips
back to `up`. There is no `preloads.health` column; the status
lives in memory only and is rebuilt on scheduler restart by
attempting fresh connections.

### 8.2.3 Recovery sweep on startup

Every scheduler-start (cold start or restart after a crash) runs
a recovery sweep before accepting new work:

- Scan `job_tries` for rows whose `started` is non-null and
  `finished` is null. For each:
  - If the collector row exists and the `collectors.pid` is still
    alive — this is an in-flight attempt that survived the
    scheduler restart (only possible for preload-launched jobs,
    since regular-launched collectors die with the scheduler).
    Re-bind it to its preload service and reattach the holds.
  - Otherwise — the attempt is stale. Release any holds the row
    referenced and mark the `job_try` `broken` with a synthetic
    "scheduler restart while attempt in flight" reason via the
    recorder pathway, then let the retry policy decide whether to
    requeue.

The sweep is what makes resource-hold leaks recoverable. A
scheduler that crashes mid-`launch` is otherwise indistinguishable
from one that allocated holds and forgot to release them.

### 8.3 Unavailable-action launches and fallback

When a job cannot run because a needed resource is permanently
broken, because the job's declared minimum exceeds what any
resource can ever grant, or because a specialized launcher
returned a `temporary => 0` permanent error, the scheduler does
not silently drop the job. Instead it dispatches an
**unavailable-action launch** through the `Default` launcher: a
real collector launch of a tiny Perl one-liner that either
`Test2::skip_all`s or `die`s with a reason string naming the
underlying cause. The resulting `job_tries` row carries the same
shape real failures do, so renderers and downstream consumers see
a uniform stream.

The two unavailable-action kinds are `skip` and `fail`. The kind
is chosen per policy (resource-side `broken_resource_behavior`:
`skip`, `fail`, or `abort` — where `abort` switches the rest of
the run to `fail`-everything mode; launcher-side permanent errors
default to `fail`).

**Unavailable-action launches always go through the `Default`
launcher**, never through a preload or any other specialized
launcher. The point is to record a deterministic skip / fail
regardless of what state the rest of the launch fleet is in: a
broken preload, a permanent error from a specialized launcher, or
a resource that knocked out the launcher the job would normally
have used must not also knock out the unavailable-action path.

`Default` is in-process (see §7.2). It cannot become "unreachable"
the way a separate process could; the only way it can fail is if
its in-process `fork` / `exec` itself fails, which is a critical,
runner-ending condition. In that case the scheduler aborts: mark
the run `canceled` / `broken`, fail every remaining `job_tries`
row with a synthetic "default launcher unavailable" error via the
recorder pathway, finalize the runner, and exit. Do not silently
swallow this — the operator needs to see that the runner died
because its fallback launcher was unusable.

Note: a `temporary => 1` reply from a specialized launcher does
**not** feed this fallback path. Temporary errors just return the
job to the queue for a later attempt (see §8.2.1).

## 9. Resources

`Test2::Harness2::Role::Resource` defines what every resource must
implement. The role surface:

- `needed($self, $job)` — does this job need this resource? Returns
  the quantity requested (or `0` / falsy for "no").
- `available($self, $job, $need)` — given the current state, can
  this resource grant `$need` units to `$job` right now?
- `allocate($self, $job, $need)` — take the requested units and
  return an opaque hold token. The token responds to `release`
  to give the units back.
- `status($self)` — return a hashref describing the resource's
  current state. Used in two places:
  - As the JSON payload that the resource service (if any) writes
    into `service_state.content`.
  - As the response of the `status` request the harness handle
    exposes.

The hold returned by `allocate` is the only handle the scheduler
keeps for an in-flight attempt. **There is no `commit` step.**
`allocate` already assumes the units will be used; calling
`$hold->release` is the only way to give them back, and the
scheduler does so unconditionally when the attempt terminates
(normal exit, failure, temporary or permanent launcher error,
recovery-sweep cleanup). The same code path handles every
termination — release is symmetric and lifecycle-agnostic. See
§8.2 for how the scheduler drives this.

A resource may declare one or more **service methods** named
`service_<name>_start`. Each such method returns a starter for a
service the resource needs (e.g. a database connection coordinator,
a shared-job-slot tracker). A resource with no `service_*_start`
methods (e.g. `JobCount`) runs entirely inside the scheduler
process. A resource with N such methods spawns N services when
attached.

Services started for a resource are not the resource. The resource
object stays in the scheduler. The service it spawned is a helper
that publishes state through `service_state.content`, and the
resource object reads that state to answer its in-process
questions.

### 9.1 Ported resources

From `reference/old3`:

- `Test2::Harness2::Resource::JobCount`
- `Test2::Harness2::Resource::CPU`
- `Test2::Harness2::Resource::Memory`
- `Test2::Harness2::Resource::Disk`
- `Test2::Harness2::Resource::PipeLimits`
- `Test2::Harness2::Resource::UnixLimits`
- `Test2::Harness2::Resource::Throttle`
- `Test2::Harness2::Resource::Preload` (treated separately — see §10)

### 9.2 TempDir resource

A resource that creates a fresh temporary directory per assigned
job and exports it as `TMPDIR` (and friends) in the job's
environment. On release it removes the directory.

`TempDir` is enabled by default. The eventual `App::Yath2` CLI will
expose a `--no-resource=TempDir` (or similarly-named) flag to opt
out; until that flag exists the harness API accepts an explicit
opt-out from the caller.

This replaces the legacy "harness rewrites `$ENV{TMPDIR}`" behavior
described in earlier iterations.

## 10. Preloads

A preload is a long-lived Perl service process that loads a set of
modules during a `BEGIN` block and then forks fresh test processes
from that loaded state. It exists to amortize per-test startup cost
(loading Moose, DBIx::Class, the app under test, etc.) across many
test runs.

Preloads are a launcher type (see `Launcher::Preload`) **and** a
resource type (see `Resource::Preload`):

- The **resource** owns scheduling decisions: which tests prefer
  which preload, when each preload is up/down, when to skip vs
  defer when a preload is broken.
- The **launcher** owns execution. The scheduler-side
  `Launcher::Preload` object is a proxy that forwards `launch`
  requests over a Unix socket to its preload service; the
  service itself is what forks tests.

### 10.1 Shape — flat, not staged

Each preload is **one service process**. No tree, no parent /
child stages, no chained `%INC` inheritance. A runner may have
**multiple preloads** configured (e.g. one preloading Moose,
another preloading a heavy app harness), each running independently
in its own process; they do not build on each other.

```
scheduler process
├── preload service P1 (one process, BEGIN-bootstrapped)
├── preload service P2 (one process, BEGIN-bootstrapped)
└── preload service P3 (...)
```

Earlier rewrite attempts (and `reference/old3`) modeled preloads as
a tree of "stages" where a child stage inherited its parent's
loaded modules via fork. That functionality is **deliberately
removed** from the new design. If a use case really needs the
loaded-module set of preload A *plus* the loaded-module set of
preload B, the user defines a third preload C that loads both. Each
preload stands alone.

Each preload service registers itself in `services` and also gets a
row in `preloads` with a unique name (`preloads.name`). The
`preloads.socket` column carries the absolute path of the Unix
socket the service listens on; the `preloads.pid` column carries
the service's process id (so the scheduler can `SIGUSR1` it).

### 10.2 BEGIN-block bootstrap

Each preload service must be a **fresh process**, started by exec —
not by fork — so that no Perl state has been initialised before the
preload's own `BEGIN`. The scheduler starts a preload service by
exec-ing the standard preload entrypoint with the service spec
passed in via an inherited fd / argv. The `BEGIN` does three
things:

1. Declares a `Long::Jump::setjump` target at the top of the
   block.
2. Loads (`use` / `require`) every module the preload is
   configured for.
3. Opens the request socket (`preloads.socket`), publishes its
   pid + socket path into the DB, and enters the service event
   loop (in the same `BEGIN`).

When a test needs to run out of this preload, the service forks
in response to a `launch` request. In the forked child it:

1. Long-jumps back to the top of the `BEGIN`.
2. Resets process state (`$0`, signal handlers, ENV slots that
   should not leak, etc.).
3. Uses `goto::file` to substitute the test script for the
   `BEGIN`'s body.

The result is a Perl process that behaves as if the test had been
started normally — but with every preloaded module already in
`%INC`.

The three Perl tricks above — `Long::Jump`, `goto::file`, and
process state cleanup — are **load-bearing**. If implementation
gets stuck on any of them, **stop and discuss**. Replacing any of
them with `do $file`, an `eval`-of-source, or similar workaround
breaks the preload's semantics in subtle ways and is not an
acceptable shortcut.

### 10.3 Launching a test from a preload

When a test should run under preload P, the scheduler:

1. Writes a length-prefixed JSON `launch` request to P's socket
   (see §7.3 for the framing).
2. Blocks on the reply.

The preload service:

1. Receives the request via the event loop (woken by socket
   readability — see §6.1).
2. Validates the spec. On a permanent problem it replies
   `{ok: 0, error: "...", temporary: 0}` and goes back to
   reading the socket. On a temporary problem it replies
   `{ok: 0, error: "...", temporary: 1}`.
3. On success, forks. The fork target is the `Long::Jump` /
   `goto::file` dance from §10.2.
4. Replies `{ok: 1}` after the fork has been committed. The
   reply carries no pid and no collector_id — the collector
   itself writes its row to `collectors` once it has started.
5. The newly forked process is the **collector** for the test
   job. It in turn forks the test process per §5.1, with the
   preload's `%INC` carried into the test via the goto target.

The collector behaves exactly like a collector for a non-preloaded
test would: it parses, audits, records. The preload service reaps
the collector on exit (non-blocking, in its event loop — see §6.5)
and optionally sends `SIGUSR1` to the scheduler so the scheduler
picks up the `job_tries` completion without waiting for its next
poll.

There is no detachment / double-fork dance and no separate
"intermediary" process. The collector is a direct child of P, the
service. When P goes away (reload, crash) the collectors P already
started are still P's children — P's shutdown path tears them down
per the death-watch / cascade rules in §6.6 (and the collectors'
own death-watch in §5.10 reinforces it).

### 10.4 Reload (later stage)

Reload functionality lands in a later Part-1 stage (see
`PART_1_PLAN.md`). The expected shape:

- Each preload watches the files in its `%INC` for changes (via
  inotify when available, mtime fallback otherwise — both ported
  from `reference/old3`).
- On a change that is safe to apply in place (pure-Perl modules
  with no XS state, no metaclass surgery), the preload reloads
  the module in its already-running process. Moose-aware reload
  is required.
- When in-place reload is not possible the preload `exec`s a
  fresh copy of itself so the next test starts from a clean
  preload again.

Scheduler integration: the preload resource publishes per-preload
up/down/restarting state through `service_state.content`. The
scheduler holds tests targeted at a preload that is down until the
state flips back to up.

### 10.5 Persistent runner (later stage)

The "persistent runner" model (eventually exposed as `yath start` /
`yath run` in Part 2) is also a later Part-1 stage:

- The harness keeps running after the original caller exits.
- Other processes discover the running harness via the `.t2h2`
  file (see §4.1).
- The harness cleans up its own `.t2h2` file on exit. The discovery
  scan additionally cleans up stale `.t2h2` files whose pids no
  longer exist.

## 11. TestFile and directives

`Test2::Harness2::TestFile` is the unit of "thing we will run as a
test". Ported from `reference/old3` along with its directives
library (`Test2::Harness2::Util::Directives`). Responsibilities:

- Scan a test file for `HARNESS-*` directives (job slots, conflicts,
  preload requirements, retry policy, timeout overrides, smoke
  flagging, etc.).
- Expose those directives to the scheduler so it can decide what to
  launch where.
- Carry the test file's relative path, project association, and
  derived attributes (binary, shebang, retry policy, etc.).

The scheduler turns each TestFile into one or more `jobs` rows when
a run is queued.

## 12. Utilities (port from `reference/old3`)

The following utility modules are required for Part 1 and should be
ported (and renamed where necessary) from `reference/old3/lib/`:

- `Test2::Harness2::Util` — `mod2file`, `apply_encoding`,
  `hub_truth`, `parse_exit`, `write_file`, `write_file_atomic`,
  and the other helpers documented in `STYLE_GUIDE.md`. Do
  **not** port `tinysleep` — `Time::HiRes::sleep` is the sub-
  second sleep primitive (see `STYLE_GUIDE.md`).
- `Test2::Harness2::Util::JSON` — `Cpanel::JSON::XS` wrapper
  with the project's defaults (`encode_json`, `decode_json`,
  `encode_pretty_json`, file-level helpers,
  `write_json_file_atomic`, `json_true` / `json_false`).
- `Test2::Harness2::Util::Zstd` — zstd reader / writer for the
  one-frame-per-line `.jsonl.zst` shape used by the DB recorder.
- `Test2::Harness2::Util::JSONL::Reader` — line-oriented JSONL
  reader used by tooling that reads the on-disk event stream.
- `Test2::Harness2::Util::IPC` — process helpers
  (`pid_is_running`, `set_procname`, `swap_io`,
  `list_direct_children`).
- `Test2::Harness2::Util::Directives` — directive parser.
- `Test2::Harness2::Util::EventEmitter` — service-side event
  emitter library that mirrors `Stream2`'s wire format on
  `Atomic::Pipe`. Used by services that want to emit structured
  events.
- `Test2::Harness2::Util::FileMonitor` — file change watcher used
  by the reload subsystem.
- `Test2::Harness2::Event` — the single event class everything
  emits.

`Test2::Formatter::Stream2` is copied wholesale from
`reference/old3` (no rename, no rewrite).

## 13. Database schema

The schema lives at `share/schema/<flavor>.sql` for each flavor we
support: `sqlite`, `mariadb`, `mysql`, `postgres`, `percona`. All
flavors move together; a DDL change touches every file in the same
commit.

### 13.1 Type conventions

- **UUIDs.** Use Test2::Util::UUID (which loads `UUID.pm`) to
  generate UUIDs in Perl. These are v7, so no bit-reordering for
  index locality is needed. Use the database's native UUID type
  where available; otherwise `BINARY(16)` plus a `uuid_string`
  shadow column populated automatically via a `BEFORE INSERT` /
  `BEFORE UPDATE` trigger (so the human-readable form is always
  current without an application-level write). Current mapping:
  PostgreSQL and MariaDB use the native `UUID` type (MariaDB ≥
  10.7, which is the supported floor); MySQL and Percona use the
  `BINARY(16)` + shadow + trigger form; SQLite stores the canonical
  36-char string directly.
- **JSON.** Use `JSONB` or `JSON` columns where the flavor
  supports them. Fall back to `TEXT` storing JSON-encoded strings
  on flavors that don't.
- **Binary blobs.** `BLOB` / `BYTEA` for `artifacts.content`.
- **Indexes.** Index aggressively. The harness writes events as a
  single artifact blob per collector (not row-per-event), so the
  write path is infrequent, batch-shaped, and not the bottleneck.
  Reads — querying past runs, filtering jobs, walking artifacts —
  are the dominant access pattern, especially once Part 2's
  read-side tooling lands. Optimise for read-time joins and
  lookups; do not skip an index because of insert cost.

### 13.2 Tables

The set below is the working baseline; columns may grow as
implementation proceeds. Every table backs a row object per §4.3.

**users**
- `name`
- `email`

**hosts**
- `name` — system hostname.

**instances** — one row per harness instance; in SQLite mode there
is exactly one entry per database file.
- `instance_uuid`
- `host_id` → `hosts`
- `user_id` → `users`
- `started` — timestamp
- `finished` — timestamp (nullable)
- `meta` — JSON
- `finalized` — timestamp set once no further runs will be
  accepted; nullable.

**runners**
- `instance_id` → `instances`
- `pid`
- `started`
- `finished` (nullable)
- `finalized` (nullable; mirrors `instances.finalized` shape)

**projects**
- `name`

**versions**
- `version`
- `project_id` → `projects`

**vcs_info** — VCS context for runs done during development (no
release tag). Optional companion to `versions`. A run may reference
a `version_id` (release tarball), a `vcs_info_id` (dev work), both
(a dev run that happens to land on a tagged commit), or neither (no
version context supplied).
- `project_id` → `projects`
- `branch` — caller-supplied branch / ref label (free-form string).
- `revision` — caller-supplied sha / hash / rev string. VCS-agnostic.
- `dirty` — boolean. True when the working tree differed from the
  committed `revision` at the moment the run was queued. The dirty
  and clean rows for the same `(project, branch, revision)` are
  distinct rows; clients querying "what's the latest clean coverage
  for revision X?" can filter on `dirty = FALSE`.
- The harness does not auto-detect this; the queueing tooling
  (`yath` / CI / whatever) fills these fields. `Test2::Harness2`
  treats them as opaque labels.

**hosts**, **users**, **projects**, **versions** are
deduplicated-by-natural-key.

**collectors** — one row per collector process.
- `runner_id` → `runners`
- `name` — unique per runner
- `pid` — collector's own pid
- `watched` — pid of the collected process (nullable until forked)
- `type` — `service`, `test job`, etc.
- `start time` — when the collected process started
- `stop time` — when the collected process stopped (nullable)
- `exit code` — exit code from the collected process (nullable)
- `finalized` — timestamp the collector finished its bookkeeping;
  set by the recorder.

**artifacts** — files produced by collectors.
- `collector_id` → `collectors`
- `filename`
- `content` — binary payload (nullable)
- `local_path` — absolute path to the on-disk content (nullable)
- Invariant: exactly one of `content` / `local_path` is non-null
  at any time. Recorder moves payloads from `local_path` to
  `content` when the collector finalizes.

**services**
- `collector_id` → `collectors`
- `runner_id` → `runners`
- `run_id` → `runs` (nullable; null for runner-global services)
- `name` — unique per `(runner_id, run_id)`; e.g. `scheduler`.
- `class` — Perl class implementing the service.
- `pid` — the service process's pid. Populated by the service on
  start so other processes can send it `SIGUSR1` to break its
  poll-loop sleep (see §6.1, §6.2). Cleared / left to go stale on
  clean shutdown; readers must treat a non-running pid as "no
  wake-up available, fall through to next poll".

**service_state** — append-only, most-recent row wins.
- `service_id` → `services`
- `stamp` — timestamp
- `status` — enum: `starting`, `up`, `down`, `stopping`,
  `stopped`, `broken`.
- `content` — JSON; service-managed publication of state. The
  primary channel a resource service uses to publish "what slots
  are available" to its scheduler-side resource object.

**requests**
- `service_id` → `services`
- `requested` — when the request was inserted
- `completed` — when the service finished handling (nullable until
  done)
- `finalized` — when the requester has acknowledged the response
  (nullable; some requests are deleted on ack instead — see §6.3)
- `payload` — JSON
- `response` — JSON (nullable)

**runs**
- `run_uuid`
- `runner_id` → `runners`
- `project_id` → `projects`
- `version_id` → `versions` (nullable; release context)
- `vcs_info_id` → `vcs_info` (nullable; dev context)
- `user_id` → `users`
- `run_ord` — integer, unique per runner; orders runs.
- `started` (nullable until scheduler claims the run)
- `finished` (nullable until run completes)
- `result` (nullable bool; true if all jobs passed, false if any
  failed)
- `passed` — int
- `failed` — int
- `meta` — JSON
- `status` — enum: `pending` (queued), `running` (scheduler has
  claimed it), `complete` (finished, see `result` for pass/fail),
  `broken` (harness-side failure that prevented completion),
  `canceled` (user / tooling asked the scheduler to stop). The
  scheduler reads `status='canceled'` as the cue to terminate
  in-flight jobs and stop dispatching for this run.
- `has_coverage` — boolean. True when at least one `coverage` row
  is associated with this run. Lets queries pre-filter coverage-
  producing runs cheaply without a join.
- `has_resources` — boolean. True when at least one `resources` row
  is associated with this run. Same role as `has_coverage` for the
  resources stream.

**test_files**
- `relative` — path relative to project root
- `project_id` → `projects`

**jobs**
- `run_id` → `runs`
- `test_file_id` → `test_files`
- `spec` — JSON; full launch spec (env, args, directives, etc.).

**job_tries**
- `job_id` → `jobs`
- `try_ord` — try number, starting at 1.
- `started` (nullable)
- `finished` (nullable)
- `collector_id` → `collectors`
- `result` (nullable bool)
- `passed` — assertion count
- `failed` — assertion count
- `subtests` — top-level subtest count
- `subtests_passed`
- `subtests_failed`
- `status` — enum: same values as `runs.status` (`pending` /
  `running` / `complete` / `broken` / `canceled`).
- `orphaned` — boolean. True when the collector reaped the collected
  process but its pipes stayed open past the orphan-timeout (a
  descendant inherited the pipe and outlived the parent). Diagnostic
  only — does not change pass/fail. See §5.8.
- `timed_out` — short string. `'silence'` when the collector killed
  the test for going quiet past the silence-timeout; `'lifetime'`
  when it killed the test for exceeding its maximum lifetime;
  `NULL` / empty otherwise. The synthetic `TIMEOUT` error event in
  the stream already drives pass/fail through the auditor — this
  column exists so consumers can distinguish a timeout-induced
  failure from an in-test failure without scanning the event
  stream. See §5.8.

**preloads**
- `name`
- `class` — Perl class implementing the preload service.
- `spec` — JSON; construction spec.
- `runner_id` → `runners`
- `run_id` → `runs` (nullable; null for runner-global preloads,
  set for run-scoped preloads).
- `collector_id` → `collectors`
- `pid` — the preload service's process id. Same role as
  `services.pid`: the scheduler signals it with `SIGUSR1` to wake
  its event loop. The preload service also wakes on socket
  readability, so `SIGUSR1` is best-effort here.
- `socket` — Unix socket path the preload service listens on.
  Carries both `launch` (scheduler-side) and `spawn` (external-
  caller-side) requests per §7.3.

Regular launchers (`ForkExec`, `Win32`, `Default`) do **not** have
rows in `preloads`. They are in-process objects owned by the
scheduler — see §7. The `launches` request-queue table from
earlier iterations is removed: dispatch is synchronous in-process
for regular launchers and synchronous over the socket for preload
launchers; there is no DB row per launch request.

**coverage** — per-coverage-run snapshot keyed by source file.
Coverage data ships on events (the `coverage` facet) when a
producer plugin (`Test2::Plugin::Cover` or similar) is active.
Most runs do NOT produce coverage; only designated runs (nightly,
opt-in) do. Each such run writes a **complete** snapshot — one
row per source file with coverage data. The full snapshot is
deliberate: if every other run is pruned, this run's rows still
give a complete picture.
- `run_id` → `runs` (`ON DELETE CASCADE`)
- `project_id` → `projects` — denormalized for index efficiency
- `source_file` — the covered file's path
- `stamp` — hi-res timestamp; used for "latest coverage for X"
  ordering and for "merge several runs, most-recent wins on
  duplicates" queries
- `payload` — JSON. Shape:
  ```
  {
    "subs": {
      "Foo::bar":  ["t/01-foo.t", "t/baz.t#nested-subtest"],
      "Foo::frob": ["t/01-foo.t"]
    },
    "file_level": ["t/00-load.t"],
    "meta": { "managers": ["Devel::Cover"] }
  }
  ```
- Unique on `(run_id, source_file)`.

The matching `runs.has_coverage` boolean lets callers find
coverage-producing runs without a join.

Typical queries:

- **Tests for changed source `lib/Foo.pm` (latest):**
  ```sql
  SELECT payload FROM coverage
  WHERE project_id = ? AND source_file = 'lib/Foo.pm'
  ORDER BY stamp DESC LIMIT 1;
  ```
- **Merge several partial coverage runs (most-recent wins per
  source file):**
  ```sql
  WITH ranked AS (
    SELECT c.*, ROW_NUMBER() OVER (
      PARTITION BY source_file ORDER BY stamp DESC
    ) AS rn
    FROM coverage c WHERE c.run_id IN (?, ?, ?)
  )
  SELECT source_file, payload FROM ranked WHERE rn = 1;
  ```

**resources** — per-sample telemetry rows. Resource events ship on
the event stream (`facet_data.resource`) when a producer plugin
(CPU sampler, memory sampler, custom resource) is active. Most
runs do not produce resources; runs that do write one row per
sample.
- `run_id` → `runs` (`ON DELETE CASCADE`)
- `type` — short identifier (`'cpu'`, `'memory'`, custom names).
- `stamp` — hi-res timestamp of the sample.
- `payload` — JSON; producer-defined shape.
- Indexed by `(run_id, type, stamp)` so reads of a single
  timeseries (one resource type within one run) are sequential.

The matching `runs.has_resources` boolean lets callers find
resource-producing runs without a join.

Typical queries:

- **CPU timeline for a run:**
  ```sql
  SELECT stamp, payload FROM resources
  WHERE run_id = ? AND type = 'cpu' ORDER BY stamp;
  ```
- **All resource types present in a run:**
  ```sql
  SELECT DISTINCT type FROM resources WHERE run_id = ?;
  ```

**Compression for `coverage.payload` and `resources.payload`** —
both payload columns can grow large; compression is configured per
flavor at the DDL level (transparent to readers):

- PostgreSQL: TOAST handles per-column compression automatically
  for rows past the toast tuple threshold. The DDL does not pin an
  algorithm — admins set the server-wide
  `default_toast_compression` GUC. On PG 14+ this should be `lz4`
  for the faster compress / decompress path. When PG eventually
  adds ZSTD as a TOAST algorithm, the same GUC picks it up with no
  schema migration.
- MariaDB: `payload JSON COMPRESSED` (per-column attribute, zlib
  under the hood, requires InnoDB).
- MySQL / Percona: no per-column attribute available — the two
  tables instead carry
  `ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8` for page-level InnoDB
  compression. Coarser than per-column but it is the only portable
  option.
- SQLite: no native option. The recorder may zstd-encode the JSON
  before insert if size becomes a concern; not done by default.

### 13.3 Existing reference schema

`reference/old3/share/schema/` already contains a `sqlite.sql`,
`mariadb.sql`, `mysql.sql`, `postgres.sql`, and a `SCHEMA.md` write-up
that explains rationale for many design decisions. Treat the
reference SQL as a starting point. Where the new schema deviates
(notably: services / state / requests model is new; the `artifacts`
table replaces the old logging artefacts; the IPC-Manager log
filenames are gone), follow this document.

## 14. Recorder + artifacts pipeline

While a collector is live, the DB recorder writes the in-progress
event stream to a single file at
`${workdir}/events/<UUID>.jsonl.zst`. The UUID exists only to give
the file a unique name; nothing else uses it after the run. The
file uses the one-self-contained-zstd-frame-per-line layout so
other readers can tail it via `Test2::Harness2::Util::Zstd`.

The `artifacts` row points at that file via `local_path` (full
path including the UUID). When the collector exits, its recorder:

1. Reads the file contents into the row's `content` column.
2. Clears `local_path` on the row.
3. Unlinks the on-disk file.

Once finalized the row carries the full event stream without any
external path dependency; the database is self-contained.

Artifacts other than the primary events file (screenshots, debug
captures, etc.) follow the same `local_path` → `content` migration
pattern by default. A recorder may choose to leave a particular
artifact in `local_path` (e.g. a permanent on-disk path the user
supplied explicitly) — that is a per-artifact decision.

## 15. Workdir

The harness creates a temporary working directory at construction:

```
File::Temp::tempdir('t2h2-$$-XXXXXX', TMPDIR => 1)
```

The workdir holds **exactly two** things:

1. **In-progress events files**, at
   `${workdir}/events/<UUID>.jsonl.zst`, one per active collector.
   Each file is unlinked as soon as its content has been migrated
   into the corresponding `artifacts` row (see §14).
2. **Test-job temp directories**, allocated by
   `Test2::Harness2::Resource::TempDir` (see §9.2). One sub-dir per
   running test job; each is removed when the resource releases.

Nothing else lives here. No `logs/`, no per-service log tree, no
per-run snapshots, no archive manifests. Everything else is in the
database. The harness handle owns the workdir and removes it on
clean shutdown; whatever stragglers remain (unmigrated event files
on a crash, leaked TempDir directories) get removed with it.

A future stage may grow per-runner workdir overrides for the
persistent-daemon use case; that lands when the persistent runner
work does (see §10.5).

## 16. What is **not** in scope for Part 1

The following all belong to Part 2 (`PART_2_PLAN.md`):

- The `yath` command, its options layer, persistent-daemon command
  set (`yath start`, `yath run`, `yath stop`, `yath kill`,
  `yath status`, `yath list`, `yath inspect`, `yath spawn`,
  `yath archive`, `yath extract`).
- The output pipeline (ArtifactLayer, OutputManager, filters,
  renderers).
- Any read-side tooling on top of the database (querying past runs,
  rendering archived logs, etc.). The database holds everything;
  Part 2 is what shows it to users.
- Project auto-detection (walking up looking for `.git`, dist
  metadata, etc.).
- Anything else in the `App::Yath2` namespace.

If Part-1 work surfaces a question or design choice that affects
Part 2, note it in `PART_2_PLAN.md` rather than expanding scope
here.

## 17. What this rewrite drops from the previous attempts

For anyone reading `reference/old3`'s ARCHITECTURE.md, these are the
deliberate departures:

- **`IPC::Manager` is gone.** No bus, no per-service IPC identities,
  no command↔harness handshake, no message routing rules. All
  inter-process communication is the database.
- **No harness service.** `Test2::Harness2` is a library handle; the
  scheduler is what plays the "long-lived process" role, and only
  when explicitly started.
- **No run service.** The scheduler tracks per-run state directly in
  the `runs` / `jobs` / `job_tries` tables; there is no separate
  per-run process. (`reference/old3`'s last addendum had already
  removed `RunService`; the new design never reintroduces it.)
- **No `IPC::Manager`-style collector detachment.** Test-job
  collectors are direct children of the service that launched
  them — the scheduler for regular launches, the preload service
  for preload launches. Reaping is by that parent service in its
  own event loop (§6.5).
- **No `ipc_run` / `ipc_parent` / `ipc_harness` triplet.** Collectors
  identify themselves via their `collectors` row; everything else
  is read from the database.
- **No artifact-announcement IPC.** The recorder writes the
  `artifacts` row directly when it has the artifact's coordinates.
- **No bus-based event echo.** Services that want to log their own
  IPC activity just record events; the recorder takes care of the
  rest.
- **No detached-collector preload dance.** A test launched by a
  preload is collected by a collector that is itself a child of
  the preload process. Restarting a preload waits for its in-flight
  tests rather than detaching them.
- **No preload stage tree.** Preloads no longer chain. Each preload
  is one process; multiple preloads run independently and do not
  inherit each other's `%INC`. The "stage A.1 → stage A → root"
  hierarchy in `reference/old3` is gone.

When porting code from `reference/old3` (parsers, auditor,
resources, directives, utilities), strip every `IPC::Manager`,
`ipc_parent`, `ipc_run`, `ipc_harness`, `ipcm_info`, and related
plumbing. Replace per-collector IPC announcements with recorder
calls. Replace per-service IPC handlers with database polling.

## 18. Project name in development

Until `App::Yath2`'s auto-detection lands, the `project` field in
the database can be populated with a static placeholder — `t2h2`
works for development and tests. Auto-detection (walking up for
`.git`, `dist.ini`, `META.json`, `Makefile.PL`, etc.) is Part 2
scope.
