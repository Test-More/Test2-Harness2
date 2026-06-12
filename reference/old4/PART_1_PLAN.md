# PART 1 PLAN — Test2::Harness2

Stage-by-stage backlog for the `Test2::Harness2` library rewrite.
Companion to `ARCHITECTURE.md` (authoritative spec), `STYLE_GUIDE.md`
(code style rules), and `AGENTS.md` (repository-wide working
guidance).

This document is structured so that each top-level numbered item is a
**stage**. The bullets beneath a stage are notes / sub-tasks for that
stage, not separate stages. Do not merge stages or jump ahead. Each
stage follows the same three-step protocol:

1. **Ask clarifying questions.** Before writing code, sync with the
   user on the open decisions in this stage.
2. **Implement.** Land the work.
3. **Request review.** Ask the user to look at the result before
   moving to the next stage.

## Working rules during Part 1

- **Do not touch `App::Yath2*`.** That is Part 2. Anything you notice
  during Part 1 that affects the future `App::Yath2` work — a CLI
  option, a renderer behavior, an output pipeline concern, a
  discovery / project-detection question — gets a note in
  **`PART_2_PLAN.md`** rather than expanding the Part-1 stage.
  Specifically: if during a stage you realise something should be
  deferred, or you uncover a design question that belongs to Part 2,
  **append a bullet to `PART_2_PLAN.md`** before continuing.
- **Never modify `reference/`.** Copy code out, modify the copy,
  leave the originals as historical reference.
- **Always check `reference/old3` first** for "how did this work in
  the old design?" — but discard anything that conflicts with
  `ARCHITECTURE.md` (most notably anything that uses or assumes
  `IPC::Manager`).
- **Match the style guide.** Pay particular attention to the eval
  patterns. Sub-second sleeps use `Time::HiRes::sleep` directly —
  no helper wrapper, no 4-arg `select`.
- It is fine to add throwaway helpers under `scripts/` to verify
  in-progress functionality, and helper drivers under `t/scripts/`
  for tests to invoke (e.g. `t/scripts/collector` for development of
  the collector — see `ARCHITECTURE.md` §5.9).

### Pre-review checks

Before declaring a stage / worktree / branch ready for human review
or merge, run these three passes against **every file the branch
touched** (`git diff --name-only $base...HEAD`) and resolve anything
they turn up before re-running the test suite:

1. **Style-guide pass.** Walk each touched file against
   `STYLE_GUIDE.md`. Common slips: `eval` patterns (check the
   return value, never raw `$@`), `croak` vs `die`, `//=`,
   `Time::HiRes::sleep`, `Object::HashBase` slot ordering,
   trailing whitespace, perltidy. Also run
   `perl scripts/audit-methods-not-functions lib` — it catches
   the "named subs in object modules must be methods" rule
   (`_flavor_from_dsn`-style functions inside object classes are
   violations).

2. **POD pass.** Verify each `.pm` follows the POD layout in
   `STYLE_GUIDE.md`: `NAME` / `DESCRIPTION` / `SYNOPSIS`
   (plus `ATTRIBUTES` for HashBase classes) at the top, inline
   POD above each public / private sub, end-of-file `SOURCE` /
   `MAINTAINERS` / `AUTHORS` / `COPYRIGHT` under `__END__`. Run
   `podchecker` and resolve every error.

3. **Util / role / base-class reuse pass.** Re-scan touched files
   for logic that already exists in `Test2::Harness2::Util`,
   `Test2::Harness2::Util::*`, `Test2::Harness2::Role::*`, or the
   DB row layer. Switch to the existing implementation. If the
   same logic appears in three-plus places across touched files,
   extract it to a util / role / base class instead of leaving
   the duplication.

Land the fixups either as cleanup commits at the end of the stage
or by amending the relevant feature commits. Mandatory, not
optional.

---

## Stage 1 — Utility layer port

> **Note on stage numbering.** The original `new_plan` listed the
> collector namespace as a single first stage that bundled in its
> dependencies (utility helpers, JSON / zstd, Stream2, the Event
> class). Stages 1, 2, and 3 here are that single conceptual stage
> broken into the three prerequisite stages they need to be in to
> actually build in order. Stage semantics are unchanged; only the
> execution order is made explicit.

The rest of the plan depends on this stage. Port the foundational
helpers from `reference/old3/lib/Test2/Harness2/Util*` (and from
`reference/old2` where it has the simpler form). Strip any
`IPC::Manager` plumbing as you copy.

- `Test2::Harness2::Util` — `mod2file`, `apply_encoding`,
  `hub_truth`, `parse_exit`, `write_file`, `write_file_atomic`,
  and the surrounding helpers. Skip `tinysleep` — sub-second
  sleeps use `Time::HiRes::sleep` directly (see `STYLE_GUIDE.md`).
- `Test2::Harness2::Util::JSON` — `Cpanel::JSON::XS` wrapper with the
  project's defaults: `encode_json`, `decode_json`,
  `encode_pretty_json`, `encode_json_file` / `decode_json_file`,
  `write_json_file_atomic`, `json_true` / `json_false`.
- `Test2::Harness2::Util::Zstd` — zstd reader / writer with the
  one-self-contained-frame-per-line `.jsonl.zst` shape used for live
  event tailing.
- `Test2::Harness2::Util::JSONL::Reader` — JSONL line iterator.
- `Test2::Harness2::Util::IPC` — low-level process helpers
  (`pid_is_running`, `set_procname`, `swap_io`,
  `list_direct_children`). Despite the module name, this is the
  process-helper bag, not anything to do with `IPC::Manager`. Keep
  the name; just delete IPC-Manager-specific helpers if any.
- `Test2::Harness2::Util::EventEmitter` — service-side helper that
  emits events through an `Atomic::Pipe` in the same wire frame
  Stream2 uses, plus the STDERR sync record. Drop the
  `Util::EventEmitter` IPC-echo logic from `reference/old3`; the new
  design does not echo IPC into events.
- `Test2::Harness2::Util::FileMonitor` — file change watcher (used
  later by the reload subsystem).
- `Test2::Harness2::Event` — the event class. `Object::HashBase`
  attributes: `facet_data`, `stream_id`, `event_id`, `stamp`.

Tests: a unit test per ported module, mirroring the surface area
exercised. JSONL / Zstd round-tripping is worth a fixture-based
test.

Open clarifying questions to ask before starting:

- Confirm the user wants the Util layer copied with their old names
  (vs. opportunistic renames during the port).
- Confirm the `Util::EventEmitter` IPC-echo logic should be deleted
  in this stage rather than later.

---

## Stage 2 — Stream2 + Event wire format

Copy `Test2::Formatter::Stream2` from `reference/old3` wholesale.
This module lives outside the `Test2::Harness2` namespace because it
loads inside test processes; the import path is unchanged from the
reference.

- Verify the formatter still constructs and emits with the ported
  `Util::EventEmitter`.
- Round-trip test: a tiny test script under `t/AI/integration/` that
  uses Stream2 as its formatter, pipes its output through an
  `Atomic::Pipe`, and verifies the receiver reads the same events
  back.

No new design decisions here; this is a port-and-test stage.

---

## Stage 3 — Collector framework + Files recorder

Implement the collector subsystem per `ARCHITECTURE.md` §5. Scope
this stage to:

- `Test2::Harness2::Collector` — the entry point and the IO loop.
  Forks once for the collected process, runs the parser → optional
  auditor → recorder pipeline, reaps the child, finalizes.
- `Test2::Harness2::Collector::Role::Parser` — role.
- `Test2::Harness2::Collector::Role::Auditor` — role.
- `Test2::Harness2::Collector::Role::Recorder` — role.
- `Test2::Harness2::Collector::Parser::IOParser` — base parser.
- `Test2::Harness2::Collector::Parser::TAPParser` — subclass adding
  TAP recognition.
- `Test2::Harness2::Collector::Auditor::Test` — the test auditor,
  ported and stripped of every IPC-Manager / observer-chain
  dependency from `reference/old3`. Synthetic event emission and
  state-transition calls into the recorder stay.
- `Test2::Harness2::Collector::Recorder::Files` — the
  testing-oriented recorder. Writes `events.jsonl`, `state.jsonl`,
  `exit` files.
- `Test2::Harness2::Collector::Recorder::DB` — **stub only this
  stage.** Implement the role surface, but leave method bodies as
  placeholders (`croak "not yet implemented"`). The real
  implementation lands in Stage 5.

Development driver: `t/scripts/collector` per `ARCHITECTURE.md`
§5.9. Use it from integration tests that exercise the collector
without a database.

Signal handling, exit-code mirroring, and error containment per
`ARCHITECTURE.md` §5.8. Make sure the collector's "real" STDERR is
saved before the redirect so caught errors can still surface.

Open clarifying questions to ask before starting:

- Where on disk does the `Files` recorder write by default? A
  caller-specified directory, a `File::Temp::tempdir`, or something
  else?
- The reference Auditor emits a small set of synthetic kinds — are
  any of them now obsolete in light of the recorder-centric design?

---

## Stage 4 — Database schema files

Land `share/schema/<flavor>.sql` for `sqlite`, `mariadb`, `mysql`,
`postgres`, and `percona`. The tables and column shapes are in
`ARCHITECTURE.md` §13. Per `STYLE_GUIDE.md`, every DDL change touches
every flavor in the same commit; this is the initial drop, so all
flavors land together.

- Use native UUID types where available; `BINARY(16)` plus a
  `*_uuid_string` shadow column populated by `BEFORE INSERT` /
  `BEFORE UPDATE` triggers where UUIDs are not native.
- `JSONB` / `JSON` where available; `TEXT` fallback otherwise.
- `BLOB` / `BYTEA` for `artifacts.content`.
- Index aggressively. Events are stored as a single artifact blob
  per collector, so writes are infrequent and batch-shaped. Reads
  (querying past runs, joining jobs to test_files / projects,
  walking artifacts) are the dominant access pattern. Add the
  indexes the read-time queries want; do not skip them on insert-cost
  grounds.
- Use `reference/old3/share/schema/SCHEMA.md` as design reference,
  but the new design's services / state / requests model is new and
  the new schema is not the same shape as `old3`'s. Treat the old
  schema as inspiration, not a target.

Open clarifying questions to ask before starting:

- Are there schema columns the user wants beyond the working
  baseline in `ARCHITECTURE.md` §13.2? (The doc explicitly says the
  set may grow.)
- The `requests` table mixes "request-response" and "fire-and-forget
  notification" use-cases; should we split them or leave them
  unified?

When this stage lands, write a quick `share/schema/SCHEMA.md`
companion describing column intent — Part 2's renderers and
read-side tooling will read directly off this schema.

---

## Stage 5 — Test2::Harness2 handle + row-object layer

Implement the database-access surface in `ARCHITECTURE.md` §4:

- `Test2::Harness2` — the handle class. Constructors `new` and
  `connect`. Owns the database handle and the `.t2h2` file.
- `Test2::Harness2.t2h2` discovery file: write on construction in
  SQLite mode (the file *is* the database). Cleanup on `DESTROY` /
  explicit `disconnect`.
- Row-object base — every table gets a small object class with
  `save` / `refresh`, attributes via `Object::HashBase`, and an
  optional `TO_JSON`. One class per table, one file per class, per
  `STYLE_GUIDE.md`.
- `fetch` / `fetch_all` / `insert` helpers on the handle.
- Bulk-insert optimization — `insert(table, \%row1, \%row2, …)` must
  use a single multi-row insert statement per flavor.
- Wire the DB recorder from Stage 3: `Test2::Harness2::Collector::Recorder::DB`
  now writes the `collectors` row at startup, the `artifacts` row
  for the event stream, and the `local_path` → `content` migration
  on finalize. Replace the `croak "not yet implemented"` placeholders.

Optional aids:

- `SQL::Abstract` for query construction where it pays for itself.

DB-access boundary (per `ARCHITECTURE.md` §4.3, §5.7):

- Parsers, auditors, and the collector core **must not** open or
  touch a `DBI` handle. Every write they need goes through a
  recorder method. The recorder is the only object in the
  collector pipeline allowed to own a `DBI` handle.
- The DB recorder itself may use raw SQL on its own `DBI` handle
  for hot paths (event-stream writes, state transitions, exit
  recording, the `local_path` → `content` migration) instead of
  going through the row-object layer.

Open clarifying questions to ask before starting:

- Should the `.t2h2` filename pattern stay
  `${USER}-${PROJECT}-${PID}.t2h2` for this stage, or do we want
  to leave room for the project-detection hooks that land in Part 2?
- Bulk inserts: is `SQL::Abstract::More` or another helper
  acceptable, or should bulk inserts go raw?

---

## Stage 6 — Non-default database backends

Add the ability to point the harness at a non-SQLite database — both
to one the user passes in via DSN and to ephemeral instances spun up
on the fly via `DBIx::QuickDB`.

- Detect at `new` / `connect` whether the target is the default
  SQLite path or a non-default DSN.
- In non-default mode, write a JSON `.t2h2` sidecar describing the
  connection (DSN, instance pid, project, user, started timestamp)
  per `ARCHITECTURE.md` §4.1.
- Use `DBIx::QuickDB` for ephemeral databases in tests; the
  reference implementation already looks at `~/dbs/<flavor>/<version>`
  for installed DB versions — copy that discovery pattern.
- Refactor any flavor-specific SQL inside the row-object layer
  behind narrow per-flavor branches (per the `STYLE_GUIDE.md`
  rule of one schema file per flavor, branching by flavor at the
  bind site).

Open clarifying questions to ask before starting:

- For the JSON sidecar: what fields does the user want surfaced
  besides DSN + pid + project + user + started?

---

## Stage 7 — Simple launchers (Default, ForkExec, Win32)

Implement the non-preload launchers per `ARCHITECTURE.md` §7.1–§7.2.
Regular launchers are **in-process objects owned by the scheduler.**
They do **not** consume `Role::Service`, do not have rows in any DB
table, and do not have an entry-point recipe / fresh-process
bootstrap. The scheduler constructs them at startup and calls
`$launcher->launch(\%spec)` directly.

- `Test2::Harness2::Role::Service` — the service event-loop role,
  used by the scheduler, resource services, and the preload
  service (Stage 10). Backoff timer (`0.05s` → `0.1s` → `0.5s` →
  `1s`), `SIGUSR1` wake-up, the `register_event_fd` hook for
  extra-FD wake sources, non-blocking child reap in the loop, and
  the upward death-watch (parent-pid change → cascade shutdown).
  See `ARCHITECTURE.md` §6.
- `Test2::Harness2::Role::Launcher` — thin contract role.
  Requires `name` and `launch(\%spec)`. **Does not consume
  `Role::Service`.** No poll loop, no DB.
- `Test2::Harness2::Launcher::ForkExec` — POSIX. Plain
  `Object::HashBase` consuming `Role::Launcher`. `launch` does
  fork+exec in the caller's process; returns
  `(ok => 1, pid => $pid)` on success.
- `Test2::Harness2::Launcher::Win32` — Windows. Same shape with
  `system(1, ...)` instead of fork+exec. Testing on Windows may
  not be possible in this stage — note "best-effort, untested"
  in commit message if so.
- `Test2::Harness2::Launcher::Default` — construction-time
  picker. Returns a `ForkExec` or `Win32` instance based on the
  platform. No delegate process, no service.
- **Delete** `Test2::Harness2::Launcher::EntryPoint` and the
  `=start` import / INIT trampoline / `feed_spec_to` helper from
  `ForkExec`, `Win32`, and `Default`. Regular launchers are not
  spawned as fresh processes anymore.
- **Delete** `Test2::Harness2::DB::Launch` and
  `Test2::Harness2::DB::Launcher`. The `launches` table is gone;
  the `launchers` table has been renamed to `preloads` and only
  the preload launcher (Stage 10) writes to it.
- Adapt / delete existing launcher tests accordingly. Add tests
  covering `launch` for `ForkExec`, `Win32` (where feasible), and
  `Default`'s picker logic.

Open clarifying questions to ask before starting:

- The Win32 launcher implementation is risky without a Windows test
  bed. Is "best-effort, untested" acceptable in this stage?
- For `Default`, should the picker honor an explicit override
  (e.g. an env var or constructor arg) for tests that want to
  force one variant on a platform that wouldn't normally select
  it? Lean yes — keep it simple.

---

## Stage 8 — Scheduler + minimal queue/run lifecycle

Implement the scheduler service plus the harness-handle methods that
front-end it (`new_runner`, `start_scheduler`, `queue_run`,
`finish`). See `ARCHITECTURE.md` §8 for the full specification.

- `Test2::Harness2::Scheduler` — consumes `Role::Service`. Owns the
  in-process resource objects **and** the in-process launcher
  objects (`ForkExec`, `Win32`, `Default`, plus any `Preload`
  proxy added in Stage 10). Walks `runs` / `jobs` for its
  `runner_id`, evaluates resources, calls
  `$launcher->launch(\%spec)` **synchronously** (no `launches`
  table — that's gone), observes `job_tries` completion (which
  the collector / auditor / recorder land into the DB), updates
  the `runs` row aggregates, and exits when the runner is
  finalized and the queue is empty.
- Resource holds: implement `$hold = $resource->allocate(...)`
  and `$hold->release`. Symmetric — release on any termination
  (success, failure, recovery-sweep cleanup). No `commit` step.
- Reap loop: scheduler reaps its own child collectors non-blocking
  every iteration (see `ARCHITECTURE.md` §6.5). On reap, look up
  `pid → (job_try_id, [$hold, …])` and release the holds.
- Dispatch state machine (see `ARCHITECTURE.md` §8.2.1): allocate
  → persist intent on `job_tries` → call `launch` → branch on
  reply (`ok` / `temporary` / `permanent`).
- In-memory preload status: per-preload `up` / `down` flag the
  scheduler maintains in memory. Stage 10 wires this up; for
  Stage 8 leave a stub or skeleton.
- Recovery sweep on scheduler start (see `ARCHITECTURE.md`
  §8.2.3): scan `job_tries` rows with `started` set, `finished`
  null, no live collector → release holds + mark stale +
  requeue. Stage 8 may stub this for the trivial-job test fixture
  but the hook must be in place.
- Port `Test2::Harness2::TestFile` and
  `Test2::Harness2::Util::Directives` from `reference/old3`. Turn
  each `TestFile` into one or more `jobs` rows at queue time.
- For this stage, **execute runs sequentially** — one run at a time,
  one job at a time. Concurrency is later (intentionally; the schema
  is concurrent-friendly but the scheduler is not, yet).
- Test: queue a run with a handful of trivial jobs through
  `ForkExec` (or `Default`) and verify a full pass leaves the
  database with all aggregate fields populated. No `launches`
  table interactions to assert against.

Open clarifying questions to ask before starting:

- The reference `TestFile` carries directives, retry policy, smoke
  flags, and a lot of edge-case metadata. Are there fields the user
  wants dropped or simplified for the initial sequential scheduler?
- For `finish` blocking semantics: poll-and-wait inside the handle,
  or rely on a row signal in the database? (Architecturally either
  works; we should pick one.)
- Recovery sweep granularity: should Stage 8 implement it fully or
  defer to Stage 10 once preload is wired in (since regular
  launchers' collectors die with the scheduler anyway, making the
  sweep mostly a no-op for Stage 8 fixtures)?

---

## Stage 9 — Resources (port + TempDir)

Port the resource classes from `reference/old3/lib/Test2/Harness2/Resource/`:

- `Test2::Harness2::Resource::JobCount`
- `Test2::Harness2::Resource::CPU`
- `Test2::Harness2::Resource::Memory`
- `Test2::Harness2::Resource::Disk`
- `Test2::Harness2::Resource::PipeLimits`
- `Test2::Harness2::Resource::UnixLimits`
- `Test2::Harness2::Resource::Throttle`

Strip every `IPC::Manager` / `Role::ResourceServiceHost` hook as you
port. Replace service-side state publication with writes to
`service_state.content`; replace cross-service requests with rows in
`requests`.

Add the new `Test2::Harness2::Resource::TempDir` resource: on
`assign`, create a unique temp directory and inject `TMPDIR` (and
any other env vars the resource decides) into the assignee's
environment. On `release`, remove the directory.

`TempDir` is enabled by default for every run. Allow the caller to
opt out via the `resources` arg (or an explicit
`no_default_resources => 1` knob). The CLI-side `--no-resource` flag
is Part 2 scope — note that in `PART_2_PLAN.md`.

Open clarifying questions to ask before starting:

- Which of the ported resources need their own service process under
  the new design? Most ran in-process under `JobCount`'s lead; do
  any genuinely need a backing service?
- Naming: `Resource::TempDir` is the obvious choice. Confirm.

---

## Stage 10 — Preload launcher (launch + spawn)

Implement the preload subsystem per `ARCHITECTURE.md` §10 and the
preload socket protocol per `ARCHITECTURE.md` §7.3.

Preloads in the new design are **flat**: each preload is one
service process; a runner may have multiple preloads but they do
**not** chain or build off each other. The staged-preload tree
from `reference/old3` is intentionally **out of scope** — do not
port it. If you find yourself wanting "stage A.1 inherits from
stage A", stop: that is the removed feature.

- `Test2::Harness2::Launcher::Preload` — the scheduler-side
  launcher object. Consumes `Role::Launcher`. Holds a connection
  (or per-call connection) to its preload service's Unix socket
  and forwards `launch` requests over the wire. Returns
  `(ok => 1)` / `(ok => 0, error => ..., temporary => 0|1)`. No
  pid; the collector writes its own row.
- The **preload service** itself — a long-lived process consuming
  `Role::Service`. Bootstraps via the `BEGIN` + `Long::Jump` +
  `goto::file` dance described in `ARCHITECTURE.md` §10.2. **Do
  not** substitute any of those three with a workaround; if you
  get stuck, stop and discuss.
- Socket protocol: length-prefixed JSON (4-byte BE uint32 length +
  JSON object). Two request types multiplexed on the same socket:
  - `launch` — scheduler-initiated; forks a collected test
    process. Replies `{ok: 1}` on success or
    `{ok: 0, error: "...", temporary: 0|1}` on failure. The
    preload service classifies the error.
  - `spawn` — external-caller-initiated (Part 2 `yath spawn`);
    forks a single process under the preloaded state with no
    collector, wires stdio, forwards signals, returns the
    child's exit code via the connection.
- The preload service's event loop selects over its socket FD
  (via `Role::Service`'s `register_event_fd` hook), `SIGUSR1`,
  and the backoff timer. Reaps its forked collectors
  non-blocking; optionally sends `SIGUSR1` to the scheduler on
  child exit.
- `Test2::Harness2::Resource::Preload` — the resource. Publishes
  per-preload up/down/restarting state via `service_state.content`.
  Tells the scheduler which preload (if any) a given test should
  run under. The scheduler's in-memory preload-status flag
  (`ARCHITECTURE.md` §8.2.2) is the runtime mirror of this.
- Multiple preloads: confirm a runner can be configured with N
  preloads side-by-side, each in its own service process, and a
  test routes to the named preload it asked for.
- Test fixture: a preload that loads (say) `Moose`, then a test
  asserting `$INC{'Moose.pm'}` is already set when the test starts.
- Spawn test fixture: open a socket connection from a tiny client
  helper, send a `spawn` request for `perl -e 'exit 7'`, verify
  the client sees exit-code 7 and `collectors` has no new row.

Open clarifying questions to ask before starting:

- The reference design detached test collectors from their preload
  stage; the new design keeps them as direct children of the
  preload service. Confirm: is the "preload service waits for its
  in-flight tests on restart" trade-off acceptable?
- How do tests declare which preload they want? `HARNESS-PRELOAD`
  directives like the legacy form, or something new?
- Should `spawn` ship in the same stage as `launch` (current plan)
  or land as a follow-up stage so launch can be reviewed first?
  Lean: same stage — the socket framing and select-loop work is
  shared, splitting it would duplicate effort.

Note for `PART_2_PLAN.md`: surface the `yath spawn` CLI on top of
this — that is Part 2 work.

---

## Stage 11 — (intentionally removed)

Stage 11 previously held a standalone "Spawn capability" stage.
That work is now part of Stage 10 — `launch` and `spawn` share the
same socket, framing, and event-loop integration, so splitting
them adds churn for no benefit. Future stage numbers continue
without renumbering: leave Stage 11 as a tombstone, advance to
Stage 12.

---

## Stage 12 — Persistent runner

Implement the persistent-runner mode per `ARCHITECTURE.md` §10.5:

- The harness handle's lifecycle is decoupled from the calling
  process. A caller can construct, start a runner, queue work, and
  exit, leaving the runner alive.
- Other processes discover running runners via the `.t2h2` files in
  the system temp directory.
- The runner cleans up its own `.t2h2` file on clean shutdown.
- Discovery additionally cleans up stale `.t2h2` files whose pids no
  longer exist when scanning.

Open clarifying questions to ask before starting:

- Does the harness handle need a `daemonize` flag, or do callers
  daemonize themselves and hand the database in to a fresh harness
  via `connect`? (Architecturally either is fine; pick the one that
  reads cleanest from a future `yath start`.)

Note for `PART_2_PLAN.md`: the `yath start` / `yath run` /
`yath stop` / `yath status` / `yath list` / `yath kill` CLI on top of
this is Part 2.

---

## Stage 13 — Reload functionality

Implement preload reload per `ARCHITECTURE.md` §10.4:

- Each preload watches the files in its `%INC` for changes (inotify
  when `Linux::Inotify2` is available, `Time::HiRes::stat`-based
  mtime polling otherwise). Reuse `Util::FileMonitor` ported in
  Stage 1.
- In-place reload path: delete-then-re-`require` for modules safe
  to reload in place; Moose-aware cleanup of meta state. Port from
  `reference/old3` where possible.
- Restart path: when in-place is not safe, `exec` a fresh preload
  process. The launcher cooperates by detecting the restart and
  re-starting the preload.
- Scheduler integration: the preload resource flips its per-preload
  state to `restarting` and holds dependent tests; flips back to
  `up` when the new preload announces ready.

Open clarifying questions to ask before starting:

- Policy for "which modules are safe to reload in-place": port the
  reference policy verbatim or rebuild it?
- Default behavior when reload fails: stay broken until manual
  restart, or auto-fail tests targeting that stage?

---

## Stage 14 — Reference audit + missing pieces

A clean-up stage: walk `reference/old3` (and `reference/old2` where
relevant) one more time, this time looking specifically for things in
the `Test2::Harness2` namespace that have not yet been ported and
should be. Common candidates:

- Helpers under `Test2::Harness2::Util::*` we haven't touched.
- Roles we missed (`Role::TestFile`, etc.).
- Edge-case auditor / parser behavior we glossed over.

Anything in `App::Yath2*` is **not** in scope — note it in
`PART_2_PLAN.md` instead.

Open clarifying questions to ask before starting:

- Is there a specific subsystem the user remembers from the
  reference that they're worried we may have skipped?

---

## Stage 15 — Final touch-ups

Polish before Part 1 is declared complete:

- POD on every shipped `.pm` per `STYLE_GUIDE.md` (start from
  `template.pod`; NAME / DESCRIPTION / SYNOPSIS at top; EXPORTS /
  PUBLIC METHODS / PRIVATE METHODS inline above each sub; SOURCE /
  MAINTAINERS / AUTHORS / COPYRIGHT under `__END__`). POD must not
  reference any `.md` file.
- Confirm the function-length cap (75 executable lines per sub) is
  honored everywhere. Port `reference/old3`'s
  `author/find-long-subs` script as a tripwire.
- Confirm the module-length cap (1000 lines of code per `.pm`,
  excluding POD) is honored. Any module over the cap gets flagged
  for human review, not silently split.
- Sweep comments: remove obvious / value-free comments, keep only
  the ones that explain non-obvious *why*.
- Pass `perltidy --profile=.perltidyrc` over `lib/` once.
- Run the full test suite under `prove -Ilib -j16 -r t/`.
- Final sweep of `PART_2_PLAN.md` — make sure every deferred item
  we noticed during Part 1 is recorded.

---

## How to update this plan

- Adding new stages: append at the bottom. Renumber only when a
  whole stage is genuinely removed; otherwise leave gaps.
- Re-scoping a stage mid-flight: edit the stage's notes in place
  with a short rationale. Do not delete prior context.
- When in doubt whether something belongs in Part 1 or Part 2: if
  it touches `App::Yath2*`, the CLI, the renderer / output pipeline,
  log archives, or the DB-as-shipped-artifact story, it's Part 2 —
  add a note to `PART_2_PLAN.md`.
