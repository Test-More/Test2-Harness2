# ARCHITECTURE.md

Authoritative architectural spec for the `Test2::Harness2` rewrite.

This document is **grown as work lands**. It only describes architecture
that has been decided and committed. Speculative future sections do not
belong here — when in doubt, leave the section out until the work that
forces the decision arrives.

Style and formatting rules live in `STYLE_GUIDE.md`. Per-agent /
contributor preferences live in `AGENTS.md`. This file owns process
topology, module boundaries, contracts between subsystems, on-wire
formats, and any other decisions that constrain how the code fits
together.

## Conventions for this document

- **Add sections only for committed architecture.** A subsystem belongs
  here once its shape is stable enough that other code is built against
  it. Work-in-progress designs live in `AI_DOCS/<date>-<slug>.md` (or in
  agent / human notes) until the design lands.
- **Section numbering may be reserved.** When a major subsystem is
  known to be coming but not yet designed, a numbered stub with a
  one-line "TBD" placeholder is acceptable so cross-references stay
  stable. Do not pre-fill speculative content.
- **Deviations are recorded in-place.** If something ships that
  contradicts an existing section here, append an addendum section to
  this document explaining and justifying the deviation. The
  authoritative spec stays in one place.
- **User-facing strings never reference this file.** POD, command
  help, and diagnostic strings restate the relevant rule in plain
  prose instead of pointing at internal docs. `STYLE_GUIDE.md`
  ("POD style") and `AGENTS.md` ("Referencing AI docs from code")
  cover this in detail.
- **Regular code comments may cite this file**, with a specific section
  identifier (e.g. `# See ARCHITECTURE.md §2 "Foundational rules"`).
  Bare tokens like `D6` or `step 4+5` are not acceptable.

## 1. Project scope

This is the in-progress 2.0 rewrite of yath. Everything ships in a
single distribution (`Test2-Harness2`), split across two namespaces
by concern:

- **`Test2::Harness2`** owns **producing results**: running tests,
  orchestrating collectors (§4.1, §4.2), schedulers, launchers, and
  preloads. Results are recorded to disk (each collector writes a
  per-process event log); see §1's note on the database.
- **`App::Yath2`** owns **the user interface**: parsing user input
  (command-line arguments are processed with `Getopt::Yath`), feeding
  tests-to-run into `Test2::Harness2`, and formatting / displaying
  results (live render, archived render, querying past runs).

Both namespaces live under `lib/` in this repository and ship as
parts of the same distribution. The split is a code-level
separation of concerns; it is not a distribution boundary and not a
process boundary. `App::Yath2` consumes `Test2::Harness2` through
its public API; `Test2::Harness2` knows nothing about `App::Yath2`.

The `yath` command itself is provided by `App::Yath::Script` (an
external module that discovers and loads our `App::Yath2`
implementation). This distribution does not ship its own `yath`
binary.

The harness is **not database-driven**. Results are produced and
recorded to disk by the collector pipeline: each collected process's
events stream to a `jsonl.zst` log written by a recorder (§2.3,
§4.1, §4.2). Cross-process coordination does not flow through a
database. A database is a **deferred** concern — when it arrives it
will be used to store / archive logs, not as the live coordination
substrate — and its schema will be defined with `DBIx::QuickORM`
(§2.3).

## 2. Foundational rules

These are non-negotiable. New code must follow them; any future
exception must be recorded as an addendum to this document.

### 2.1 Object orientation

- Objects use `Object::HashBase`.
- Roles use `Role::Tiny` / `Role::Tiny::With`.
- Inheritance uses `parent`, not `base`.
- `Object::HashBase` and `Role::Tiny` compose freely — `Object::HashBase`
  may be used inside roles and by classes that consume roles. Do not
  reach for a heavier framework around an imagined incompatibility.

Style rules tied to object orientation (slot ordering, "named subs in
object modules must be methods, not functions", and the rest) are in
`STYLE_GUIDE.md`.

### 2.2 UUIDs

UUIDs are generated in Perl, using `Test2::Util::UUID`, never in the
database. They are v7; do not re-pack bits for index locality — v7 is
already time-ordered.

### 2.3 Databases

The harness is no longer database-driven (§1). A database is a
**deferred** concern: results are recorded to disk by the collector
pipeline, and a database — when it lands — is for storing / archiving
those logs, not for live cross-process coordination. The rules below
fix the decisions already made so the DB layer is built consistently
once it arrives; nothing here is wired up yet.

- The schema is defined with **`DBIx::QuickORM`** (schema-as-Perl),
  not hand-written DDL files and not `DBIx::Class`.
- UUIDs are still generated in Perl as v7 (§2.2), never by the
  database.
- Non-default flavors (Postgres, MySQL, MariaDB, Percona) are
  driver-loaded on demand; their `DBD::*` modules are Suggests /
  Recommends in `dist.ini`, never hard requires.
- `DBIx::QuickDB` is used for ephemeral test databases and for
  spinning up non-default flavors on the fly.

### 2.4 No `IPC::Manager`

Earlier rewrite attempts (`reference/old3` in particular) routed
cross-process coordination through `IPC::Manager`. That layer turned
out to be too bulky for the shape of work the harness does. The new
architecture **does not use `IPC::Manager`**.

If a reference doc, a design note, or a snippet of `reference/` code
calls for `IPC::Manager`, treat that as outdated and follow this
document instead. The transport is `Atomic::Pipe` (mixed-mode, with
zstd compression on the wire) for transient bytes between processes;
the collector pipeline (§4.1, owned by `Test2-Collector` per §2.7) is
the first consumer.
Durable cross-process state, where needed later, goes to disk, not
through a live coordination daemon.

### 2.5 Minimum Perl version

The harness targets **Perl 5.38.0** (released 2023-07-02) as its
floor. Every shipped module starts with `use v5.38;`, which enables
`strict`, `warnings`, and the stable `signatures` feature in one
line.

Capabilities the codebase may rely on at this floor:

- Subroutine signatures became stable in Perl 5.36 (2022-05-28).
  5.36 dropped the `experimental::signatures` warning, so no
  `no warnings 'experimental::signatures'` incantation is needed.
- 5.38 added `//=` and `||=` default-value operators inside
  signatures. `sub foo ($x //= compute())` applies the default when
  the argument is missing **or** undef; `||=` applies it when the
  argument is missing or falsy. Plain `=` continues to apply the
  default only when the argument is missing.

`STYLE_GUIDE.md` ("Minimum Perl and subroutine signatures") owns the
usage rule: signatures are mandatory for every named sub, method,
and anonymous sub whose argument handling fits within what
signatures support; fall back to `@_` only when signatures cannot
express the call shape.

### 2.6 Reference trees are immutable

`reference/` holds prior iterations (`legacy/`, `old2/`, `old3/`,
`old4/`, `botched/`) for reading. Nothing under `reference/` is
edited in place. When borrowing, copy out and modify the copy.
`reference/old3` and `reference/old4` are the most recent and usually
the right starting point for "how did this used to work" questions;
when their answer conflicts with this document, this document wins
and the conflict gets flagged.

### 2.7 The collector comes from `Test2-Collector`

The collector pipeline — spawn one process, capture everything it
produces, feed it through `parser -> processors -> recorder + reporter`
— is **not** part of this distribution. It was extracted to the
standalone **`Test2-Collector`** distribution (`Test2::Collector`
namespace; working checkout at `~/projects/Test2/Test2-Collector`).
That distribution's own `ARCHITECTURE.md` is the authoritative spec
for the collector contract; §4.1 here documents only the boundary the
harness consumes, plus the Monitor, which deliberately stayed behind.

The dependency points one way: `Test2::Collector` never loads
`Test2::Harness2*` or `App::Yath2*`. `Test2-Collector` is a hard
dependency of this distribution; see §4.1 "Status" for how it is
loaded until it is released and installed.

## 3. Repository layout

Top-level layout that architecture depends on:

- `lib/Test2/Harness2/` — harness library code.
- `lib/Test2/Harness2/Util/` — leaf utility modules.
- `lib/Test2/Harness2/Role/` — `Role::Tiny` roles consumed by harness
  code.
- `t/` — human-authored tests.
- `t/AI/` — AI-generated tests, mirroring `t/`'s subdirectory layout.
- `reference/` — historical iterations; immutable, see §2.6.
- `AI_DOCS/<YYYY-MM-DD>-<slug>.md` — durable context for non-trivial
  decisions that the code and commit history cannot carry alone.

## 4. Subsystems

Subsystem sections land here as their architecture is decided. Each
section should describe:

1. The subsystem's responsibility and where it lives in `lib/`.
2. The contract it exposes to the rest of the harness (constructor
   arguments, public methods, events, schema rows, on-wire bytes —
   whichever apply).
3. Invariants the subsystem promises to its callers, and invariants it
   relies on from its inputs.
4. Failure modes and how they surface (return codes, recorded events,
   thrown exceptions).

Subsections will be numbered `4.1`, `4.2`, … in the order they are
designed. Numbering is stable once assigned; if a subsystem is
removed, its number is retired, not reused.

### 4.1 Collector

**Responsibility.** The collector spawns one process (test or
otherwise), captures everything it produces, and feeds it through

    bytes  ->  parser  ->  processors  ->  recorder + reporter

where the **recorder** sink gets the full event stream (one
`jsonl.zst` events file per collector) and the **reporter** sink gets
only the transitions (§4.2, §5.2).

That machinery lives in the external **`Test2-Collector`**
distribution (§2.7). Its `ARCHITECTURE.md` is the authoritative spec
for everything inside the collector boundary: the pipeline stages and
their roles, the sink classes (`Recorder::JSONL` / `Zstd` / `FIFO` /
`Socket` / `Pipe`), the formatter contract
(`Test2::Formatter::Collector`, selected via `T2_FORMATTER`), raw-TAP
fallback parsing, transition stamping, and the safety / lifecycle
controls (silence / lifetime / orphan timeouts, watched parent,
process-group signaling).

**Status — swap landed, dist not yet installed.** The pre-extraction
copies (`lib/Test2/Harness2/Collector*` minus the Monitor,
`Test2::Formatter::Stream2*`, `Test2::Harness2::Event`) are deleted;
the drivers, the Monitor, and the tests run against
`Test2::Collector*`. `Test2-Collector` is still under review — not
released, not installed — so until it is, it is loaded from the
`t2clib` symlink at the repository root (gitignored; points at a
sibling checkout's `lib/`). The `scripts/t2h2_*` drivers add it to
`@INC` themselves when the symlink exists; tests that load
`Test2::Collector*` carry a `use lib 't2clib'` line. Both scaffolds
go away when the dist is installed and becomes an ordinary hard
dependency.

**Extraction differences.** The extracted collector deliberately
changed a few things relative to the pre-extraction code, so old
branches and `reference/` reading must not be taken as spec:

- **Unified sinks.** In-tree, the base recorder wrote the events file
  *and* pushed transition notifications to unix sockets, with a
  `Recorder::Test` subclass routing transitions to the sockets wrapped
  in a `{type => "transition", payload => {...}}` envelope. Extracted,
  one sink abstraction serves both streams — the collector itself
  routes by facet (transitions to the `reporter`, everything else to
  the `recorder`), the envelope is gone, and transitions are plain
  events stamped with a `harness_collector` identity facet (an
  optional `transition_frame` attribute re-wraps them for consumers
  that multiplex streams).
- **Auto-wired test pipeline.** The `Assembler` → `Auditor` processor
  chain is wired automatically for `is_test` jobs instead of being the
  caller's job.
- **Renames.** `Test2::Harness2::Collector*` → `Test2::Collector*`;
  `Test2::Formatter::Stream2` → `Test2::Formatter::Collector`.

**What stayed behind.** The **Monitor**
(`Test2::Harness2::Collector::Monitor`) was deliberately not
extracted: cross-process monitoring, scheduling, run-history storage,
and rendering are out of scope for `Test2-Collector` and belong to
the harness. It speaks the extracted transition shape (plain stamped
events, no envelope), and treats the `exited` transition a plain
(non-test) collector emits as that collector's completion.

**Monitor.** `Collector::Monitor` is the read side of the transitions channel
(§5.2): its non-blocking `poll` reads whatever is available, folds each
message into per-collector state (keyed by the message `uuid`, so any number
of test and service collectors may share one monitor), and returns the
payloads (list context) or their count (scalar). It
answers queries — `tests` / `services`, per-collector `status` / `events_file`
/ `final_state` — and drain-on-call deltas (`new_collectors`, `new_failing`,
`new_diagnosing`, `new_completed`, `new_test_exits`, `new_finalized`) for
callers that act on changes. It exposes its file descriptors so a caller can
select on them and block until there is something to poll. `t2h2_collector`
uses it; `App::Yath2` and the scheduler (to free a slot when a test exits) are
the intended future consumers.

A monitor can also **proxy**: `add_proxy($name, $target, %filter)` forwards
messages it reads on to downstream sockets (any number of named proxies),
sending the verbatim cached compressed frame (§5.2).
With no filter the proxy gets everything; `global => 1` restricts it to
collectors with no `run_uuid`, and `run_uuid => $u` / `run_uuids => \@u`
restrict it to the named runs (combinable, and the runs need not exist yet).
So a proxy added mid-run does not see collectors half-way through their
lifecycle, `add_proxy` first replays — subject to the same filter — the
buffered messages of every not-yet-complete collector, so a downstream monitor
reconstructs the matching state. `remove_proxy($name)` stops forwarding.

Each collector carries a `run_uuid` (required for tests, optional for
services; absent ⇒ global), sent in its start message; the monitor tracks it
and filters proxies on it.

**Failure modes.** Collector-internal failure modes (timeouts, orphans,
watched-parent death, reap errors, signal escalation) are owned and
documented by `Test2-Collector`. The harness observes them the same way it
observes everything else: as recorded events in the events file and as
transitions / final state on the transitions channel.

### 4.2 Harness orchestration

The main harness is an **orchestrator of collectors**. The shape below
directly answers yath 1.0's bottlenecks (one process re-reading every
event from every test, everything broadcast everywhere, per-event
database rows, heavy file polling); it is decided architecture, being
built out now.

- **One collector per collected process.** Each test runs under its own
  collector (`test -> parser -> processors (auditor) -> recorder +
  reporter`). The full event stream goes to that collector's compressed
  `jsonl.zst` events file; only the transitions go to the harness.
- **Every harness-started process is a collector.** Anything the
  harness spawns — services, workers, and the main harness process
  itself — runs as a (non-test) collector, so every process, test or
  otherwise, speaks one wire format and records one kind of events
  file.
- **Completion comes from transitions, not reaping.** Collectors are
  not necessarily direct children of the harness, so the harness must
  not depend on `waitpid` to learn that one finished. The final-state /
  finalized messages on the transitions channel are the completion
  signal; reaping is a local detail for whichever process actually
  forked the collector.
- **Transitions are the shared state.** Transition events — plus any
  events the harness itself adds — are the primary state shared
  between processes and forwarded to consumers (renderers, schedulers,
  loggers). No component rebroadcasts the full per-event stream.
- **Consumers pull detail on demand.** The state carried by the
  transitions includes each collector's events-file path (sent on the
  `starting` transition), so a renderer or other consumer that needs
  full events reads that collector's `jsonl.zst` file directly, when
  and if it cares.

## 5. Cross-cutting concerns

Reserved for things that cut across multiple subsystems once more than
one exists — wire formats shared between processes, error / event
taxonomies, shutdown ordering, schema migration policy, and similar.

### 5.1 Event compression: measured conclusions

The event encoding spans the test child (which serializes and sends
events), the collector pipeline (which receives, decodes, and records
them), and the on-disk events file. The compression decisions below are
shared across that whole path. They were settled by measurement, not
assumption; recorded here so they are not relitigated. The
implementation now lives in `Test2-Collector` (§2.7), but the
conclusions bind both distributions — anything in the harness that
reads or writes these formats inherits them.

- **Compress each event in the test child before sending it over the
  pipe.** Compressing the JSON in the writer and decompressing in the
  collector is cheaper end-to-end than sending uncompressed JSON: the
  zstd cost is small next to the cost of pushing the larger uncompressed
  payload through the pipe. The on-wire form is therefore a zstd frame,
  not raw JSON.

- **Pass an already-compressed frame through verbatim whenever
  possible.** When an event still carries the compressed frame it
  arrived on (its `compressed_form`) and nothing downstream modified it,
  the recorder writes that frame to the events file as-is. This is the
  common case and is effectively free — no recompression. The
  collector / auditor already decompresses every event to process it, so
  the decompressed JSON is available too, but the recorder prefers the
  verbatim frame and only recompresses the rare event an auditor
  actually changed.

- **Do not buffer / batch writes to the events file.** Batching the
  per-event `syswrite`s (and/or merging many events into one larger zstd
  frame) was prototyped and benchmarked against real captured events.
  Writing to the events file is not a meaningful cost: `syswrite` lands
  in the page cache (no `fsync`, no disk wait), and at the worst-case
  rate measured the write time was a sub-1% slice of what the pipeline
  already spends decompressing and processing the same events. The
  per-event recorder is already near-optimal because of verbatim
  passthrough above. Batching's only real upside was a smaller events
  file (merging frames compresses better), but that is a disk-size win,
  not a speed win, and it would cost added recompression CPU, a flush
  timer wired through the collector loop, a new "flush before notifying
  the transition pipes" ordering invariant, and a change to the
  one-frame-per-record file format every reader depends on. The
  complexity is not worth the benefit, so the recorder writes one zstd
  frame per event, immediately, with no buffer.

### 5.2 Transition channel: unix sockets

The collector notifies interested listeners about a small set of
per-collector occurrences -- the C<starting> message, each state transition
(C<failing> / C<diagnosing> / C<completed>), the final state, and
C<harness_collector_finalized>. These are low-frequency, high-value messages,
distinct from the high-volume per-event stream that goes to the events file.
They are the substrate of §4.2: the harness learns everything it knows about
a collector — including that it completed — from this channel.

The transition channel is **unix-domain stream sockets** (C<SOCK_STREAM>), not
C<Atomic::Pipe>. The earlier iteration multiplexed all collectors over one
shared pipe; the current design gives each collector its own connection. The
contract:

- **One connection per collector.** A listener (typically a
  L<Test2::Harness2::Collector::Monitor> in C<listen> mode) accepts one
  connection per collector. Frames from different collectors land on separate
  file descriptors and can never interleave -- atomicity by construction,
  rather than relying on each message fitting in C<PIPE_BUF>.
- **The reporter connects out.** The collector's C<reporter> sink (a
  C<Test2::Collector::Recorder::Socket>) is given socket paths; it
  C<connect()>s to each and writes to all of them. It makes no assumption
  about what is on the other end.
- **Message shape.** Each message is an ordinary transition event, stamped
  with a C<harness_collector> identity facet, JSON-encoded and
  zstd-compressed once into one self-contained frame, then written to each
  socket with a blocking C<syswrite> (retried on C<EINTR>, C<SIGPIPE> ignored
  so a vanished reader surfaces as a trappable error). There is no
  C<< {type =E<gt> ...} >> envelope; a consumer that multiplexes transitions
  with other records on one stream can opt into a wrapper via the collector's
  C<transition_frame> attribute. Readers split a connection's byte stream on
  zstd frame boundaries (the shared zstd C<FrameBuffer>, also used by the
  events-file reader).
- **uuid in every payload.** The collector C<uuid> rides on every message (not
  just the first). Per-connection identity would allow sending it once, but the
  monitor's proxy fan-out and unmanaged-feed paths multiplex collectors and
  have no per-connection context; keeping the uuid everywhere lets all paths
  demultiplex identically. The uuid is cheap on these rare messages. The
  C<starting> transition additionally carries the collector name, the
  events-file path, the run association, and (for tests) the try number.
- **Monitor modes.** Managed: the monitor owns the listening socket, accepts
  connections, and reads framed messages in a non-blocking C<poll()>; it
  exposes its file descriptors for an external C<IO::Select> loop. Unmanaged:
  some other component owns the socket(s) and feeds the monitor already-decoded
  payloads.
- **Proxy fan-out** forwards the verbatim cached compressed frame (no
  recompression) to downstream sockets, preserving the global / C<run_uuid>
  filtering.

The earlier in-tree implementation wrapped each message in a
C<< {type =E<gt> "transition", payload =E<gt> {...}} >> envelope; that
envelope is gone. The Monitor consumes the plain-event shape above.

## 6. Open questions

Reserved for architectural questions that have been raised but not yet
resolved. Each entry should name the question, link to the work
forcing the decision, and note who is expected to answer it. Resolved
entries move into the relevant numbered section above and are removed
from this list.

### 6.1 Global vs run services for `yath start` / `yath run` (future)

The proxy filtering needed for this is now in place (§4.1): a proxy can be
restricted to `global => 1` and/or specific `run_uuid`s, and collectors carry
a `run_uuid`. What remains is the surrounding machinery that will B<use> it.

The driving case is `yath start` + `yath run`: global services start first
under a long-lived process, and a `yath run` arrives later with its own tests
and run-scoped services. The `run` will attach a proxy filtered to
`global => 1` plus its own `run_uuid`, so it sees the global services' state
and its own collectors but not other runs' traffic.

Still to do (not started): a first-class distinction between B<global> and
B<run> services (today "global" is simply "no `run_uuid`"); the run lifecycle
that assigns a `run_uuid` and feeds tests in after services are up; and the
`yath start` / `yath run` commands that wire a filtered proxy per run.
