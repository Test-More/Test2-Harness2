# Chunk 3: Collector swap → Test2-Collector

**Date:** 2026-06-13
**Branch:** `collector-swap` (worktree `worktrees/collector-swap`, cut from `2.0d`)
**Status:** Approved design
**Migration:** chunk 3 of the 1.0→2.0 evolution (`MIGRATION.md`, `ARCHITECTURE.md` §4.1).

## Goal

Replace this repo's in-tree collector/auditor/parser pipeline with the external
**Test2-Collector** dist. Each test runs under a Test2-Collector collector that
emits a single `events.jsonl.zst` per job (try) containing **both** regular
events and transitions. The yath gatherer process reads those files instead of
scraping `stdout`/`stderr`/`exit`/`events` files and parsing TAP itself. This
repo's auditor, parsers, per-job file reader, and the in-tree Test2 formatter
are deleted in favor of Test2-Collector's.

## Decisions (user-approved)

1. **Integration model:** the runner spawns each test via `Test2::Collector`
   (`collect`/`spawn_collector`) — `run_sub` for the preload-fork path, `exec`
   otherwise. The collector owns capture + parse + audit + record.
2. **Run-level verdict:** a thin aggregator in the gatherer process consumes
   each test's `harness_final_state` and emits the run-level `harness_final`.
   The per-assertion Watcher/auditor is deleted.
3. **Scope:** file-based only this chunk. The collector writes
   `events.jsonl.zst`; the gatherer tails those files. The live transition
   socket channel + Monitor stays chunk 5.
4. **Auditor process deleted entirely.** New pipeline: gatherer → renderer
   directly (no separate auditor process).
5. **Test2-Collector change:** made directly in `~/projects/Test2/Test2-Collector`
   and committed there (separate dist, separate commit).

## The Test2-Collector change (dist update)

Today `Test2::Collector::_route_event` sends transition-facet events
(`harness_state_transition`, `harness_final_state`,
`harness_collector_finalized`) **only** to the reporter, never the recorder, so
they never reach `events.jsonl.zst`.

Add a `record_transitions` mode: when enabled (default **on when no reporter is
configured**), transition events are written to the recorder in addition to (or
instead of) the reporter. Reporter behavior is unchanged when a reporter is
configured, preserving the chunk-5 socket path. After the change, a collector
invoked with only a recorder produces one file containing the full event stream
plus all transitions and the final state, in emission order.

This is the only dist change required. No other essential capability is missing:
- `Test2::Collector::Util::Zstd::Reader` already supports incremental tailing
  (`_read_more` re-seeks past EOF; `readline` returns undef when no new frame is
  available yet; `pending_bytes`/`truncated` expose partial-frame state).
- `Recorder::File` opens with `autoflush(1)` and writes one self-contained zstd
  frame per event immediately, so frames are visible to a tailing reader as the
  test runs.

Commit the change in the Test2-Collector repo with its own message.

## New per-test execution

Per job/try, the runner runs the test under a collector instead of exec-ing it
directly with `Test2::Formatter::Stream`:

- **Preload/fork path:** inside the preloaded fork,
  `Test2::Collector::collect(is_test => 1, name => <file>, run_uuid => <run_id>,
  run_sub => sub { <existing run-test logic> },
  recorder => Test2::Collector::Recorder::Zstd->new(file =>
  "$job_root/events.jsonl.zst"), record_transitions => 1, silence_timeout =>
  <event_timeout>, lifetime_timeout => <from settings>, io_events => <setting>)`.
- **Non-fork path:** same call with `exec => [$^X, @switches, $file, @args]`
  instead of `run_sub`.

The collector forks the test child, captures stdout/stderr via `Atomic::Pipe`,
parses (TAPParser), processes (Assembler + Auditor), and records the full stream
+ transitions + `harness_final_state` + `harness_process_exit` + timeout facets
into the one `events.jsonl.zst`.

**Eliminated:** per-job `stdout`, `stderr`, `exit`, `event_timeout`,
`post_exit_timeout` files; the `events/*.jsonl` per-thread files;
`Test2::Formatter::Stream`. Timeouts move to Test2-Collector's ChildMonitor
(`silence_timeout`/`lifetime_timeout`/`orphan_timeout` → `harness_timeout`/
`harness_orphan` facets).

Retries keep the current `$job_id+$try` job-root layout: each try is a separate
collector invocation writing its own `events.jsonl.zst`.

## Gatherer (`Test2::Harness2::Collector` / `App::Yath2::Command::collector`)

**Kept:** job discovery from `queue.jsonl`/`jobs.jsonl`; runner output from
`output.log`/`error.log`/`aux_logs`; harness orchestration events
(`harness_job_queued`, `harness_job_start`, `harness_job_launch`);
`max_open_jobs`; the emit-to-action stream to the renderer.

**Changed:** the per-job reader. `Collector::JobDir` (file-scrape + TAP parse) is
replaced by a per-job `Test2::Collector::Util::Zstd::Reader` on
`$job_root/events.jsonl.zst`. Each `poll` cycle calls `readline()` until it
returns undef; each frame is decoded and wrapped as a `Test2::Harness2::Event`
with `job_id`/`run_id`/`job_try` attached, then emitted. A job is complete when
its `harness_process_exit` (and finalized) facet has been seen and the reader is
drained.

The gatherer normalizes Test2-Collector facets into the harness facet shape at
this boundary (see "Facet adaptation") so renderer churn is minimized.

**Deleted:** `Test2::Harness2::Collector::JobDir`,
`Test2::Harness2::Collector::TapParser`.

## Run-level aggregation

A thin aggregator in the gatherer process replaces `Auditor::finish()`:
- consumes each test's `harness_final_state` facet (pass, fail_count,
  assertion_count, exit, plan, halt, ...),
- tracks per-job pass/fail and retry state,
- at run end emits a `harness_final` event: `{ pass, failed => [...],
  retried => [...], halted => [...], unseen => [...] }`, matching the shape the
  test command's finalizer currently reads from the auditor.

## Facet adaptation

Normalize at the gatherer boundary; adapt the renderer only where a facet is
genuinely new.

| Renderer/consumer expects (1.0) | Test2-Collector provides | Bridge |
|---|---|---|
| `harness_job_exit` (exit/code/signal/dumped) | `harness_process_exit` (pid/wait_status) | gatherer synthesizes `harness_job_exit` from `harness_process_exit` + job identity |
| `harness_job_end` (file/retry/fail/times) | `harness_final_state` (pass/counts/exit/plan/times) | gatherer synthesizes `harness_job_end` from `harness_final_state` + exit |
| `harness_final` (run-level) | — (per-process only) | gatherer aggregator (above) |
| `from_tap` | `from_tap` | same |
| `assert`/`plan`/`control`/`trace`/`info`/`parent`/`amnesty` | same (standard Test2) | none |
| subtest markers `harness.subtest_*` | `harness.subtest_start/started/end/closed` + Assembler `parent.children` | renderer adapts subtest handling |
| raw STDOUT/STDERR lines | `from_stream`/`from_tap` facet events | renderer reads these for output display |

`Test2::Harness2::Event` stays the harness event wrapper (id/run/job/try +
`facet_data`); only the facet contents shift.

## Deletions (summary)

- `lib/Test2/Harness2/Auditor.pm`, `lib/Test2/Harness2/Auditor/Watcher.pm`
  (+ any other `Auditor/*`).
- `lib/Test2/Harness2/Collector/JobDir.pm`,
  `lib/Test2/Harness2/Collector/TapParser.pm`.
- `lib/Test2/Formatter/Stream.pm`.
- `lib/App/Yath2/Command/auditor.pm` and the auditor-process wiring in
  `App::Yath2::Command::test` (`start_auditor`); the test command wires
  gatherer → renderer directly.
- Tests for all of the above.

## Dependencies / rules

- Test2-Collector is unreleased; loaded via the `t2clib` symlink at the worktree
  root (created in this worktree). Tests/scripts that load `Test2::Collector*`
  add `use lib 't2clib';` (scripts add it to `@INC` themselves).
- The dependency points one way: `Test2::Collector` never loads
  `Test2::Harness2*` / `App::Yath2*`.

## Testing

- `prove -Ilib -j16 -r t/` green. Integration tests (`test.t`, `coverage*.t`,
  `retry.t`, `concurrency.t`, `reload.t`, `preload.t`, …) exercise the full new
  pipeline end-to-end through Test2-Collector.
- New unit tests for the gatherer's events-file reader and the run-level
  aggregator.
- Delete unit tests for removed modules (Auditor, Watcher, JobDir, TapParser,
  Formatter::Stream).

## Out of scope

- The live transition socket channel + Monitor-style state sync (chunk 5).
- Collectors wrapping non-test processes / the main harness (chunk 4).
- Any renderer rewrite beyond the facet adaptation needed to consume the new
  stream (chunk 6 is the renderer rewrite proper).

## Open items to flag

- None blocking. The single required dist capability (transitions → recorder) is
  added by this work. If, during implementation, a Test2-Collector behavior is
  found genuinely missing (e.g. a needed timeout/exit nuance the harness relied
  on), flag it for the user rather than working around it in the harness.
