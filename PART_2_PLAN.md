# PART 2 PLAN — App::Yath2 (scaffold)

**Status: scaffold.** The Part-2 work — the `yath` command, the
options layer, the output / renderer pipeline, the persistent-daemon
command set, and the optional database / web-UI back-ends — will be
specced out in detail once `PART_1_PLAN.md` is complete. This file
exists so that Part-1 work has a place to drop deferred notes as it
goes.

## When to update this file

Append a bullet to the appropriate section below whenever Part-1
work surfaces something that belongs to Part 2:

- A CLI flag or option the user mentioned in passing.
- A renderer / output-pipeline concern.
- A discovery, project-detection, or `.t2h2` consumer hook.
- Anything that depends on the `App::Yath2*` namespace and so
  cannot be implemented in Part 1.
- An open design question that we deliberately deferred so we
  could keep moving on Part 1.

Keep the note tight: one or two sentences naming the thing and the
context. Detail goes in the eventual Part-2 design doc; this file
just makes sure nothing gets lost.

When Part 1 ships, this file is the starting raw material for the
real Part-2 spec.

---

## Scope (target shape, subject to revision)

Per `ARCHITECTURE.md` §16, Part 2 covers everything `Test2::Harness2`
deliberately does not:

- The `yath` command (single binary, dispatches per sub-command).
- The options layer (`App::Yath::Script`, `Getopt::Yath`).
- The persistent-daemon command set: `yath start`, `yath run`,
  `yath stop`, `yath kill`, `yath status`, `yath list`.
- The non-daemon commands: `yath test`, `yath spawn`, `yath archive`,
  `yath extract`, `yath inspect`.
- The output pipeline: ArtifactLayer, OutputManager, filters,
  renderers.
- Read-side tooling on top of the database — querying past runs,
  rendering archived logs, exporting subsets, browsing job history.
  All the data already lives in the database from Part 1; Part 2 is
  what surfaces it to users.
- Project auto-detection (walking up looking for `.git`,
  `dist.ini`, `META.json`, `Makefile.PL`, etc.).
- The `--no-resource=<Name>` family of CLI flags (notably
  `--no-resource=TempDir`).

Out of scope for the foreseeable future (intentionally **not** Part 2):

- A separate `App::Yath2::DB` namespace. The harness already owns
  the database — there is no separate "log database" layer to wrap.
- A web UI. Was previously sketched as `App::Yath2::UI`; deferred
  indefinitely until someone explicitly wants it.

---

## Standing notes for Part 2

These notes apply directly to Part 2 work; they are recorded here
so they do not get lost as the canonical docs evolve.

- **`yath spawn`.** Built on the preload-launcher spawn socket
  (Part 1 §11 / `ARCHITECTURE.md` §7.3). Behaves "just like running
  the command" except the child inherits the preload's loaded-module
  state. The launcher emulates a normal foreground process: child
  stdout/stderr go to requester stdout/stderr, requester stdin goes
  to the child, signals are forwarded, the child's exit code becomes
  the requester's exit code.
- **`yath start` / `yath run`.** Built on the Part-1 persistent
  runner. Discovery via the `.t2h2` files written by the harness
  handle. `yath run` queues a run against the discovered runner and
  exits with the run's pass/fail status.
- **`yath stop` / `yath kill`.** Discover a runner via its `.t2h2`
  file, send it the right shutdown sequence. `stop` is graceful;
  `kill` is escalation.
- **Discovery cleanup.** Whichever Part-2 command does discovery is
  also responsible for cleaning up stale `.t2h2` files whose pids no
  longer exist. (Part 1's discovery helper, when one exists, can do
  the same; Part 2 just needs to know it's a shared responsibility.)
- **Default resources opt-out.** `Test2::Harness2::Resource::TempDir`
  is enabled by default in Part 1. Part 2 needs a `--no-resource=Name`
  flag to opt out.
- **Project auto-detection.** Part 1 accepts an explicit project
  string (and uses `t2h2` in development). Part 2 walks up from
  cwd for `.git`, `dist.ini`, `META.json`, `META.yml`,
  `Makefile.PL`, etc. to infer it.

---

## Deferred during Part 1

> Append bullets here as Part-1 work uncovers Part-2-shaped items.
> Format: `- **<short label>.** <one or two sentence note.>`

- **Util audit / pruning sweep.** Stage 1 ported the full
  `Test2::Harness2::Util*` surface from `reference/old3`. Once Part 2
  is far enough along that every realistic consumer exists, audit
  every exported function in `Test2::Harness2::Util`,
  `Util::JSON`, `Util::Zstd`, `Util::IPC`, `Util::EventEmitter`,
  `Util::FileMonitor`, and `Util::JSONL::Reader` for actual call
  sites and prune anything no consumer reaches.

- **Collector timeout CLI flags + in-test directives.** Stage 3
  added three timeouts to `Test2::Harness2::Collector->start` —
  `orphan_timeout` (default `30s`), `silence_timeout` (default `0`,
  off), and `lifetime_timeout` (default `0`, off). See
  `ARCHITECTURE.md` §5.8. Part 2 work:

  - Expose all three via CLI flags on `yath`. Legacy spells the
    nearest analogues `--event-timeout` (matches silence) and
    `--post-exit-timeout` (matches orphan); see
    `reference/legacy/lib/App/Yath/Options/Runner.pm`. There is no
    legacy analogue for `lifetime_timeout` — it is new.
  - Decide Part-2 CLI defaults. Part 1 ships zero defaults for the
    test-job timeouts on purpose: callers (and ultimately the CLI)
    own the policy. Legacy used 60 / 15 for event / post-exit, and
    those are a reasonable starting point.
  - Wire per-test directive overrides. Legacy reads
    `# HARNESS-NO-TIMEOUT`, `# HARNESS-TIMEOUT-EVENT N`, and
    `# HARNESS-TIMEOUT-POSTEXIT N` from the test file header
    (`reference/legacy/lib/Test2/Harness/TestFile.pm`). The Part-2
    test-file metadata layer needs the equivalent — including a
    new `HARNESS-TIMEOUT-LIFETIME N` directive — and must thread
    those values into the collector call site so individual tests
    can lengthen or disable any of the three timeouts.
  - Note that legacy `--post-exit-timeout` kills the orphan
    descendants from the runner; the Part-1 orphan timeout only
    flags the condition and exits the collector. If Part 2 wants
    the legacy "kill the orphan tree" behavior it has to layer
    that on separately (likely in the launcher, not the
    collector).

- **VCS context auto-detection.** Stage 4 added a `vcs_info` table
  (project_id, branch, revision, dirty) and a nullable
  `runs.vcs_info_id`. `Test2::Harness2` does NOT detect VCS state;
  whoever queues the run fills the row. Part 2's `yath run` /
  `yath test` paths need a small helper that runs
  `git rev-parse HEAD`, `git symbolic-ref HEAD`, and a clean-tree
  check (`git status --porcelain`), looks up or creates the matching
  `vcs_info` row, and stamps `runs.vcs_info_id` before queueing.
  Equivalent helpers for `hg` / `fossil` welcome but not required;
  callers can always supply the values themselves.

- **Coverage queries on `yath`.** Stage 4 added the `coverage` table
  (one row per `(coverage-producing-run, source_file)` with a JSON
  payload of subs → tests). Two Part-2 surfaces consume it:
  - `yath cover stats` — coverage summary: % files covered, %
    subs covered, untested files / subs. Aggregates over the
    latest coverage row per source file for a given
    `(project, version|vcs_info)` filter, or merges several runs
    "most recent wins per source" via the windowed query
    documented in `ARCHITECTURE.md` §13.2.
  - `yath cover select <changed-source-paths...>` — given the
    set of changed files (or specific subs), return the list of
    test files that exercise them. Looks up the latest coverage
    row per source file, unions the test sets from the JSON
    payload. `yath test --by-coverage` runs only those tests.
  Fallback policy ("use latest coverage, unless it's broken, then
  walk back N runs") is a Part-2 query-time concern; the storage
  layer just keeps per-run rows.

- **Coverage producer plugin.** The coverage data ships on events
  via the `coverage` facet. Part-2 needs the plugin that hooks
  `Devel::Cover` (or equivalent) into a running test and emits the
  facet. Reference: `reference/legacy/lib/Test2/Harness/Log/CoverageAggregator.pm`
  (aggregator only; producer side lived in legacy
  `Test2::Plugin::Cover`-style plugins).

- **Resources producer plugin + viewer.** Same shape as coverage:
  a producer plugin emits `facet_data.resource` samples; the
  recorder writes them to the `resources` table; a `yath` command
  renders the timeseries. Part 2 owns both the plugin and the
  viewer; Part 1 provides storage only.

---

## Open questions to revisit when speccing Part 2

> Append bullets here when a Part-1 stage hits a design question
> that we punted on because it's really a Part-2 concern.

*(empty — fill in as Part 1 progresses)*

---

## References

When Part 2 starts, the existing implementations are the obvious
starting point:

- `reference/old3/lib/App/Yath2/**` — most recent attempt at the
  Part-2 surface. The OutputManager / filter / renderer split and
  the persistent-daemon command set all have working code here.
  Drop everything that depends on `IPC::Manager`. Also drop the
  `App::Yath2::Log` / `App::Yath2::DB` / `App::Yath2::UI` trees:
  the new design folds everything those provided into Part 1's
  single canonical database, so there is nothing here to port —
  only the renderer, options, and command surfaces are reusable.
- `reference/old2/lib/App/Yath2/**` — earlier attempt; less complete
  but sometimes simpler.
- `reference/legacy/lib/App/Yath/**` — yath 1.0. Reference for
  historical command shapes and option names.
- `reference/old3/dist.ini` — starting point for the distribution
  setup (Dist::Zilla config, plugin list, share/ wiring). The
  dependency list there is out of date — strip the dropped
  `App::Yath2::Log` / `DB` / `UI` deps, prune anything pulled in
  solely for the IPC::Manager-era code, and add the new deps
  Part 1 brought in (DBI, DBD::SQLite, DBIx::QuickDB for tests,
  etc.). The Dist::Zilla skeleton itself is reusable as-is.

Treat all of these the same way Part 1 treats `reference/` —
copy out, modify the copy, never edit in place.
