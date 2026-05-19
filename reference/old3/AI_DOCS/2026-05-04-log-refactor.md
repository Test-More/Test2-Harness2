# `new_log_refactor` — full-branch architectural refactor

Date: 2026-05-04
Branch: `new_log_refactor`

This document supersedes any per-step note that previously lived
under this filename; it covers the whole branch's M2 effort.

## Trigger

The post-Phase-3 codebase had a `LogArchive` reader with a baroque
collector pipeline (`Logger::JSONL` writer plugins, `Observer`
plugin chain, separate `TestObserver` for IPC duties, `parent_io`
machinery on every collector that tried to track its parent's
state). Two bad assumptions were baked in:

1. The collector was written as if every collector might own
   state (so every collector had auditor / observer slots, IPC
   reflectors, and so on).
2. The reader assumed it had been handed a coherent on-disk tree
   with one logger per collector and uniform path structure.

Real life: tests are state producers — their state lives in the
events they emit and gets reconstructed by an auditor sitting next
to the test-job collector. Runs and services are state actors —
their state lives in the run service / global service process
itself, and the collector merely hands the parent's stdout/stderr
through to disk. The old design tried to put state-tracking next to
every collector regardless of where the state actually lived. That
forced contortions like `parent_io` for collectors that had no
business tracking parent state and a `TestObserver` separate from
the test auditor purely because the auditor "didn't speak IPC".

This branch rewrites the collector pipeline and the on-disk reader
around the actual ownership model.

## Decisions, in M2 order

### Step 1: Drop event UUIDs and identifier mirrors

Events used to carry their own UUIDs plus a duplicated
`harness.run_id / job_id / job_try / service_name` block. Every
event is identified by its position on disk now (which collector's
events.jsonl.zst it came from); the reader injects identifiers
on read via path inspection, so the writer no longer mirrors them.

### Step 3: `LogArchive` → `Log`

Rename. The old name implied "post-run sealed thing"; the new name
covers live workdirs, sealed directories, tar.zidx files, and
SQLite databases uniformly.

### Step 4 + 5: Single Collector class, no Logger / Observer

Alternatives considered:

- **Keep the Logger plugin slot, drop only Observer.** Rejected:
  the Logger plugin existed to support pluggable on-disk formats
  (JSONL+zstd vs JSON), but every shipping case used JSONL+zstd.
  The plugin layer added cost and ambiguity for no production use.

- **Keep Observer chain, drop only Logger.** Rejected: same
  reasoning. The only Observer in the tree was `TestObserver`,
  whose duties belong on the auditor next to the test (its state
  tracking lived there anyway).

We collapsed both. The collector is now a single class that:

- Takes `type => 'Job' | 'Run' | 'Service'` plus an `id`.
- Computes its base directory via
  `Test2::Harness2::LogLayout::collector_base_dir`.
- Writes the trio (`spec.jsonl.zst`, `events.jsonl.zst`,
  `report.jsonl.zst`) directly. No logger plugin layer.
- For type=Job: carries an `Auditor::Test` instance that absorbed
  `TestObserver`'s IPC duties (`test_job_started` /
  `test_job_diagnosing` / `test_job_failing` /
  `test_job_completed` / `job_release`).
- For type=Run / type=Service: dumb pass-through, no auditor.

Pipeline: `parser -> [Auditor::Test on type=Job] -> write_phase`.

### Step 6: `collector_start` / `collector_end` IPC

Each collector emits a `collector_start` IPC message to its parent
service when it starts and a `collector_end` when its child has
exited and the audit/write phase has flushed. The parent service
ingests both into its own outgoing events stream as
`harness_collector_start` / `harness_collector_end` events.

This is what the reader walks. The depth-first `event()` iterator
starts at `services/harness/events.jsonl.zst`; on every
`harness_collector_start` it discovers, it pushes a new reader for
the child collector's `events.jsonl.zst` onto an internal stack,
serves events from the top of the stack, and pops the child's
reader on the matching `harness_collector_end`.

### Step 7: Attachments at write phase

`harness_attachment` facets carry base64-encoded blobs. The
collector decodes them and writes them under
`<base>/attachments/<filename>` during the write phase, replacing
the in-event payload with a `path` reference. Storage is
deduplicated and never has to round-trip through zstd alongside
the rest of the events stream.

### Step 17: Drop `collector_artifacts` IPC + on-disk artifacts metadata

The old design had a separate `collector_artifacts` IPC channel
plus per-collector `artifacts.json` describing what files the
collector produced. With the start/end facets reflected into the
parent's events stream and a uniform on-disk layout, the artifacts
metadata is implicit: walk the directory, you know what's there.

### Step 18 + 19: Run / harness service emit own transition events

A run service emits `run_failing` and `run_completed` events into
its own `runs/<run_id>/events.jsonl.zst` stream. The latter
carries a `collector_report` facet aggregating per-job pass/fail
state into a final run-level shape (per F17). The harness service
emits the analogous transitions for its own lifecycle.

Mirrors the rev-2 ownership rule directly: state lives in the
service process, so the service emits its own state-transition
events.

### Step 20: LIVE sentinel file

`logs/LIVE` is created by the harness collector at start and
removed at clean shutdown (or absent on crash). The reader uses
its presence to disambiguate "live workdir, expect more bytes"
from "sealed workdir, file ended cleanly".

`extract` and `archive` skip the sentinel when packaging; the
post-extract directory and tar.zidx archives never contain `LIVE`.

### Steps 8 + 9 + 10 + 25: `App::Yath2::Log` reader API

The reader is a dispatcher. `App::Yath2::Log->new(...)` picks the
backend by argument shape:

- `live => $dir` -> `Log::Live`        (live workdir)
- `dir  => $dir` -> `Log::Directory`   (sealed dir)
- `file => $f`   -> `Log::TarZIdx` or `Log::Sqlite`
                     (auto-detected by magic bytes)
- `dbh  => ...`  -> `Log::Sqlite`
- `dsn  => ...`  -> `Log::Sqlite` (or sibling DB backends)

Every backend exposes the same surface:

- Listing: `services` / `runs` / `jobs` / `tries` / `last_try`
  / `has_run` / `has_job` / `has_try` / `has_service`.
- Artifacts handle factory: `artifacts(...)` returns a
  `Log::Artifact` that speaks the per-file API
  (events / spec / report in plain / .zst / iter forms,
  `attachment`, `attachments`, `exists`, `get`, `save`).
- Depth-first event iterator: `event($timeout)`, `events()`,
  `EOE`, `reset`. The iterator descends into nested collectors
  on `harness_collector_start` and pops them on the matching
  `harness_collector_end`.
- Path-aware identifier injection: events surfaced by the
  iterator have `harness.run_id` / `job_id` / `job_try` /
  `service_name` injected based on which on-disk file they
  came from. This is the read-side replacement for the writer's
  old identifier mirroring.

### Step 11: DB backends — SQLite, Postgres, MariaDB, MySQL

`Log::DB` is the abstract base for all four; the per-flavor
classes provide the small set of backend-specific bits (DSN
construction, schema bootstrap from `share/schema/<flavor>.sql`,
UUID + JSON codecs, payload bind hooks). All four share the
listing API, the iterator, the artifacts handle, and the
extract / archive / insert primitives.

Multi-archive is the universal model (per D4 amendment): every DB
holds N archive rows; even a "single sqlite .yath file" is just
N=1 in the same table. `_resolve_archive` picks the live archive
based on the constructor's `uuid` argument (or the singleton when
N=1).

### Step 12 + 13 + 14: Test command + replay/failed/archive/extract

`test` subscribes directly to the harness IPC bus, spawns a
renderer child that opens `Log->new(live => $dir)` and iterates
events to draw output. The legacy `Streamer::Live` is gone.

`replay` / `failed` / `archive` / `extract` / `times` /
`speedtag` are rewired to the new `Log` reader.

### Step 21 (this commit batch): `inspect` command

`yath inspect <path>`: detects log type (sqlite, tar.zidx, or
directory), validates that `services/harness/spec.jsonl.zst` and
`services/harness/events.jsonl.zst` are present, and prints a
summary. `--json` for machine-readable output. For SQLite
multi-archive databases, lists every archive row with its UUID
and per-archive run count. Hard errors (missing magic bytes,
no harness service) exit 1.

### Step 22: `runs` / `exclude_runs` filters on extract / archive

Per-run scoping for partial extracts. Globals (services-without-a-
run-id, archive-root files) are always included.

### Step 26: ord ints replace UUIDs for run/job ids

UUIDs survive only as logical archive identifiers in DB rows.
Run and job ids are sequential ord ints scoped to their archive,
matching how the on-disk layout already used them.

## Architectural changes summary

- Collector: single class, type-driven behavior.
- Pipeline: `parser -> [Auditor for Job] -> write_phase`.
- IPC: `collector_start` / `collector_end` reflected into parent
  events stream; run / harness service emit own transitions
  directly into their own events streams.
- On-disk: `runs/<id>/jobs/<id>/<try>/`, `runs/<id>/services/<n>/`,
  `services/<n>/`. Each base dir holds the trio (spec / events /
  report) plus optional `attachments/`. `report.jsonl.zst`
  replaces the old `state.json`. `LIVE` sentinel at log root.
- Reader: dispatcher + 7 backends (Live, Directory, TarZIdx,
  Sqlite, Postgres, MariaDB, MySQL). Identical API surface across
  backends.
- Auditor::Test absorbs TestObserver IPC duties + tracks top-level
  subtests (so the run-level `collector_report` aggregate can
  describe per-test subtest state).

## State-producer-vs-state-consumer rule

Captured in ARCHITECTURE.md addendum. Distilled:

- Tests produce state via events. State lives nowhere else; the
  Auditor reconstructs it next to the collector. So the test-job
  collector has an auditor; the auditor handles IPC.
- Runs and services act on state. State lives in the service
  process. The collector for those is a dumb pass-through. The
  service emits its own state-transition events into its own
  outgoing events stream.

This is what made the old `parent_io` machinery and the separate
`TestObserver` redundant.

## Future work captured but not in this branch

- Archive metadata (`meta.json` at archive root) — `inspect` will
  display it once it exists.
- `LogDB` object for multi-archive databases (lists archives,
  hands back per-archive `Log` objects).
