# Chunk 4 — Collectors Everywhere (step 1: the runner) — Design

**Date:** 2026-06-14  **Branch:** `collectors-everywhere` (off `2.0d`)
**Status:** approved-for-autonomous-execution (user deferred review)

## Goal (scoped)

ARCHITECTURE §4.1/§4.2: every yath-started process should run under a collector,
not just test jobs. Full "collectors everywhere" presumes the harness service
(§4.2) and the transition channel (§4.3), which are later chunks. **This chunk
does the first safe, independently-testable step:**

- Wrap the **`yath test` runner process** in a **non-test** `Test2::Collector`
  (`is_test => 0`) that records `runner-events.jsonl.zst` in the workdir.
- The gatherer (`Test2::Harness2::Collector`) **reads that events file** (via a
  JobReader-style reader) instead of polling flat `output.log` / `error.log`.

So the runner's stdout/stderr become first-class, timestamped harness events in
the same wire format and reader path as job events, plus a `harness_process_exit`.

## Out of scope (deferred to §4.2/§4.3)

- Collecting the gatherer/collector command itself (needs a consumer for its
  transitions → the service).
- The unix-socket transition channel + Monitor state folding.
- Harness-as-service / scheduler-owns-state / completion-via-transitions.
- The spawn-infra daemon and persistent-runner `start`/`watch` output paths —
  those keep `output.log`/`error.log` for now (compatibility shim).

## Design

### 1. Wrap the runner (lib/App/Yath2/Command/test.pm, `start_runner`)
Today `start_runner` does `IPC->spawn(stdout => output.log, stderr => error.log,
command => [<runner cmd>])`. Change the spawned child to become a non-test
collector parent, mirroring the test path's `Runner::Job::spawn_params` /
`_collector_exit_code` idiom:

- `command => sub { my $info = Test2::Collector::collect(is_test => 0, name =>
  'runner', exec => [<runner cmd>], recorder =>
  Test2::Collector::Recorder::Zstd->new(file => $runner_events_file)); POSIX::_exit(_collector_exit_code($info)); }`
- The collector parent MUST `_exit` with the runner child's wait status (reuse
  the `_collector_exit_code` logic: collector-failure → 255, else child err/sig)
  so `IPC::set_proc_exit` / runner-death detection is unchanged.
- `runner_events_file` = `$workdir/runner-events.jsonl.zst` (a shared constant).
- Keep `RUNNER_PID` = the spawned (collector parent) pid; `runner_exited` stays
  `kill(0,$pid)` — unchanged.

### 2. Gatherer reads the runner events file (lib/Test2/Harness2/Collector.pm)
Replace `process_runner_output` (the `output.log`/`error.log`/`aux_logs` tailer)
with a reader over `runner-events.jsonl.zst`, built on the existing
`Collector/JobReader.pm` (which already opens `*.jsonl.zst` and re-wraps records
as `Test2::Harness2::Event`s). Generalize JobReader (or add a thin
`RunnerReader`) for the non-test stream:
- It carries `run_id` but no `job_id` (runner-level events; job_id 0/undef like
  the synthetic harness events `_harness_event` uses).
- Emit the runner's stdout/stderr facets so the renderer shows them the way it
  showed the old `INTERNAL`-tagged lines (preserve `tag => 'INTERNAL'`,
  `debug => 1` for stderr). The collector's IOParser already produces stream
  facets; map/wrap them to the harness `info` shape the renderer expects.
- Drive it from the `process` loop next to the job readers; it reaches `done`
  on the runner's `harness_process_exit`.

### 3. Keep liveness/abort logic untouched
`runner_exited` / `runner_done` stay `kill(0,$RUNNER_PID)` based. No change to
completion/abort.

## Risks (from scoping)
- **Exit-status fidelity** — the collector parent must exit with the runner
  child's status (reuse `_collector_exit_code`). Main correctness risk.
- **Output ordering** — stdout+stderr become one ordered stream instead of two
  independently-tailed files; runner-message ordering in rendered output may
  shift. Verify against runner-output integration tests.
- **Other consumers** of `output.log`/`error.log` (`start.pm`, `watch.pm`) —
  left on the flat files (shim) this chunk.

## Tests
- Unit: the runner-events reader turns a fixture `runner-events.jsonl.zst` into
  harness info events (stdout → info, stderr → info+debug) + a process_exit.
- Integration: `yath test` runner output (e.g. a runner diagnostic / preload
  message) still appears in the rendered output, now sourced from the events
  file. Confirm exit-status handling (a runner that dies non-zero is still
  detected).
- Full `prove -Ilib -j16 -r t/` stays green.

## Verification gate
Suite green at `-j16`; runner output visible in render; runner-death/exit
handling unchanged.
