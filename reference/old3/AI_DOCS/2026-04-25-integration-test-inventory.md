# Integration test inventory: ports from `reference/old2/t/Yath/integration/`

Date: 2026-04-25
Companion to: `2026-04-25-integration-test-concurrency.md`.

## Why this exists

`reference/old2/t/Yath/integration/` ships 35 end-to-end tests that exercise
yath as a subprocess via `App::Yath2::Tester`. The 2.0 rewrite has not
re-implemented every command/flag those tests poke at, so most of them
cannot pass today. Rather than wait for full feature parity before
porting, we ported all 35 in one pass and gated the ones that depend on
unfinished features behind `plan skip_all => "TODO: ..."`.

That gives us:

- A complete map of the integration surface, in-tree and runnable.
- A green test suite (35/35 exit 0).
- A scannable list of "what's still missing" -- every TODO message
  names the feature we're waiting on.

When a feature lands, drop the `skip_all` + `__END__` lines from the
matching `t/Yath/integration/*.t` and run the test against the new
implementation. The body underneath is the original old2 file, modulo
the wrapper switch (`Test2::Harness2::Test::Yath` instead of
`App::Yath2::Tester`) and the `# HARNESS-CONFLICTS YATH` directive
described in the companion doc.

## Status by category

Legend:
- **PASS** -- assertions actually run against the current branch.
- **AUTHOR** -- gated on `Test2::Require::AuthorTesting` from the original
  port; runs only with `AUTHOR_TESTING=1`.
- **HARNESS-ONLY** -- gated on `$ENV{TEST2_HARNESS_ACTIVE}`; only runs
  when invoked through `yath test` itself.
- **TODO** -- this work added a `plan skip_all` with a reason.

### A. Help / info

| Test     | Status | Notes |
|----------|--------|-------|
| `help.t` | PASS   | 20/20 inner assertions; the canonical reference. |

### B. Smoke / basic test runner

| Test         | Status | Reason for gating |
|--------------|--------|-------------------|
| `test.t`     | TODO   | `--ext / --exclude-file / --exclude-list / --durations` not implemented |
| `test-w.t`   | PASS   | Verifies `perl -w` shebang isolation. |
| `smoke.t`    | TODO   | Plugin loading (`-p+SmokePlugin`) and `-D` dev-libs not aligned |

### C. Persistent runner / daemon lifecycle

| Test                     | Status | Reason for gating |
|--------------------------|--------|-------------------|
| `persist.t`              | TODO   | Persistent runner daemon (start/stop/run/which/reload/watch) not implemented |
| `plugin.t`               | TODO   | Plugin loading + daemon lifecycle not wired |
| `preload.t`              | TODO   | Preload (`-P`) modules + daemon lifecycle not wired |
| `reload.t`               | TODO   | Reload of preloaded modules requires daemon mode |
| `reload_syntax_error.t`  | AUTHOR | Daemon recovery from syntax errors during reload |

### D. Coverage

| Test          | Status | Reason for gating |
|---------------|--------|-------------------|
| `coverage.t`  | TODO   | `--cover-write / --cover-from` not implemented |
| `coverage2.t` | TODO   | Per-test JSONL coverage aggregation not implemented |
| `coverage3.t` | TODO   | `--cover-files / --cover-agg` + bzip2 logs not implemented |
| `coverage4.t` | AUTHOR | Coverage by-test aggregation; depends on `--cover-agg=ByTest` |

### E. Resources

| Test         | Status | Reason for gating |
|--------------|--------|-------------------|
| `resource.t` | TODO   | Resource plugins (`-R`) not implemented |

### F. Discovery

| Test                  | Status | Reason for gating |
|-----------------------|--------|-------------------|
| `includes.t`          | TODO   | `-I` / `--unsafe-inc` include handling not aligned |
| `nested_includes.t`   | TODO   | Nested includes / `HARNESS-*` parsing not aligned |
| `projects.t`          | TODO   | `projects` command output not aligned |

### G. Failure / retry / signals / timeouts

| Test                     | Status        | Reason for gating |
|--------------------------|---------------|-------------------|
| `failed.t`               | TODO          | `failed` command not aligned with current log format |
| `failure_cases.t`        | TODO          | `--et / --pet` exception/timeout flags not implemented |
| `retry.t`                | TODO          | `--retry` flag and `--project` flag not implemented |
| `show_buffer_timeout.t`  | TODO          | `--event-timeout` flag and verbose buffer rendering not implemented |
| `signals.t`              | AUTHOR        | Signal handling edge cases. |

### H. Output / formatting / replay / logging / stamps / times

| Test            | Status | Reason for gating |
|-----------------|--------|-------------------|
| `encoding.t`    | TODO   | Verbose UTF-8 renderer output not aligned |
| `log_dir.t`     | TODO   | `--log-dir / -L` flag and JSONL log not yet wired |
| `replay.t`      | TODO   | `replay` command not aligned with current log/streamer format |
| `stamps.t`      | TODO   | Plugin loading + event timestamp rendering not aligned |
| `speedtag.t`    | TODO   | `speedtag` command output not aligned |
| `tapsubtest.t`  | TODO   | TAP subtest verbose rendering not aligned |
| `times.t`       | TODO   | `times` command output not aligned |
| `verbose_env.t` | PASS   | Verbosity env-var preservation across nested yath. |

### I. Concurrency / slots

| Test                | Status        | Reason for gating |
|---------------------|---------------|-------------------|
| `concurrency.t`     | TODO          | Job concurrency scheduling not validated against current scheduler |
| `slots_per_job.t`   | HARNESS-ONLY  | Standalone test that asserts `T2_HARNESS_MY_JOB_CONCURRENCY` is set; only meaningful when run through `yath test`. |
| `slots_per_job2.t`  | HARNESS-ONLY  | Same; uses `# HARNESS-JOB-SLOTS 1 3`. |
| `slots_per_job3.t`  | HARNESS-ONLY  | Same; uses `# HARNESS-JOB-SLOTS 2`. |

### J. Init

| Test     | Status | Reason for gating |
|----------|--------|-------------------|
| `init.t` | TODO   | `init` command not yet ported to this branch |

## Aggregate

| Status        | Count |
|---------------|-------|
| PASS (real)   | 3     |
| AUTHOR-gated  | 3     |
| HARNESS-ONLY  | 3     |
| TODO          | 26    |
| **Total**     | **35** |

`make test` (and the new `ubuntu-script-branch` CI job) sees all 35 as
green: the TODOs exit 0 via `plan skip_all`, and the AUTHOR / HARNESS-ONLY
tests already exit 0 via their original guards.

## How to revisit a TODO

When a feature lands:

1. Open `t/Yath/integration/<name>.t`.
2. Delete the prelude up to and including `__END__`:

   ```perl
   # HARNESS-CONFLICTS YATH
   use Test2::V0;
   plan skip_all => "TODO: ...";
   __END__
   ```

3. The body below is the (verbatim) old2 test, with the wrapper switch
   already applied (`use Test2::Harness2::Test::Yath qw/yath/;` instead
   of `use App::Yath2::Tester qw/yath/;`).
4. Run it: `perl -Ilib t/Yath/integration/<name>.t`. Adjust assertions
   if current output drifted from old2 (the `summary` rule from PR #424
   applies: prefer adjusting the test over changing user-visible
   strings).
5. Drop the AI_DOC entry for that test, or replace its row with `PASS`.

## Concurrency tag

All ported tests carry `# HARNESS-CONFLICTS YATH` so the scheduler
serialises them under `yath test`. Each test's nested yath gets its own
temp `YATH_IPC_DIR` and `YATH_PERSISTENCE_DIR` (see
`App::Yath2::Tester:25`), so cross-test interference isn't expected
even without the directive -- it's there as a safety net while the
suite is mostly skip_all and feature work is in flight. If a future
group of tests provably has no shared resources with another group,
they can take a more specific tag (`YATH_HELP`, `YATH_DAEMON`, ...)
to allow parallelism within `yath test`. Don't bother before there's
a measurable wall-clock win.

## Cross-references

- `t/Yath/integration/help.t` -- the working example.
- `t/lib/Test2/Harness2/Test/Yath.pm` -- the wrapper every integration
  test uses.
- `AI_DOCS/2026-04-25-integration-test-concurrency.md` -- the
  HARNESS-CONFLICTS rule + Immiscible removal record.
- `reference/old2/t/Yath/integration/` -- the source of every port.
