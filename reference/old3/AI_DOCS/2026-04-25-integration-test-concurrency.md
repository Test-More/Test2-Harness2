# Integration test concurrency: prefer HARNESS-CONFLICTS

Date: 2026-04-25
Scope: tests under `t/Yath/integration/` (and any future test that
spawns a nested yath via `App::Yath2::Tester`).

## TL;DR

- **Use `# HARNESS-CONFLICTS YATH`** at the top of every integration
  test that spawns nested yath / shares `YATH_IPC_DIR` /
  `YATH_PERSISTENCE_DIR`.
- **Do not use `Test2::Plugin::Immiscible`.** It has been removed
  from this repo. Don't reintroduce it.
- The `# HARNESS-CONFLICTS NAME` directive is the harness-native
  mutex; `Test2::Harness2::TestFile` parses it and the scheduler
  honours it. That covers everything we run.

## Background

`reference/old2/t/Yath/integration/help.t` (the seed of the port that
landed in commit `01897d9a0`) carried two parallel concurrency
controls:

```perl
# HARNESS-CONFLICTS YATH        # not present in the original
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });
```

`Test2::Plugin::Immiscible` is a file-lock based mutex
(`flock` on `./.immiscible-test.lock`) that serialises any two
processes that `use` it. Originally it was the only way to keep
parallel test invocations from stomping on each other when the
runner did not parse `HARNESS-*` directives -- e.g. when a developer
ran `perl t/foo.t` directly.

That fallback is dead weight in this codebase:

1. CI invokes the integration suite through `yath test`, which
   parses `HARNESS-CONFLICTS` and refuses to run two tests sharing
   the same tag in parallel.
2. Direct `perl -Ilib t/Yath/integration/foo.t` invocations are
   serial by definition -- there's no harness running them in
   parallel.
3. We control which tests live under `t/Yath/integration/`. They
   all spawn nested yath via `App::Yath2::Tester`, and they all
   declare the same `HARNESS-CONFLICTS YATH` tag.

So `# HARNESS-CONFLICTS YATH` alone is sufficient. Adding the
flock fallback was theatre.

## Why HARNESS-CONFLICTS is preferred

| Property                   | `HARNESS-CONFLICTS NAME` | `Test2::Plugin::Immiscible` |
|----------------------------|--------------------------|-----------------------------|
| Where the lock lives       | scheduler in-memory      | file on disk                |
| Activation path            | runner reads directive   | module loaded at compile    |
| Granularity                | per-tag (multiple groups)| global (any two `use`-ers)  |
| Self-describing            | yes (visible at top of file) | no (buried in imports)  |
| Survives a stuck process   | yes (no on-disk state)   | sometimes (stale lockfile)  |
| Works under `prove`        | no                       | yes                         |
| Works under `yath test`    | yes                      | yes (but redundant)         |

We are committed to running the integration suite through
`yath test`, so the "works under `prove`" row does not buy us
anything; everything else favours the directive.

## The rule for new integration tests

Every test under `t/Yath/integration/` should look like this in the
opening lines:

```perl
# HARNESS-CONFLICTS YATH
use Test2::V0;

# ... other imports ...

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
```

- `# HARNESS-CONFLICTS YATH` -- one tag for all integration tests
  that share the nested-yath state. Two such tests will never run
  concurrently under the scheduler.
- `Test2::Harness2::Test::Yath` -- the wrapper from `t/lib/`
  that sets `YATH_TESTER_INIT=1` and re-exports `yath` /
  `make_example_dir`. Drives the in-tree V2 pin assertion so we
  notice if a stale CPAN install of `App::Yath::Script::V2`
  shadows our local rewrite.

If a future integration test legitimately *can* run alongside the
others (e.g. it does not touch IPC dirs, persistence dirs, or
spawn yath at all), pick a different tag rather than dropping the
directive entirely. Tags are cheap.

## What was removed

Commit `78fda8b7c` (folded into the squash that produced
`01897d9a0`) removed `lib/Test2/Plugin/Immiscible.pm` outright.
It had no consumers left after `t/Yath/integration/help.t` switched
to `HARNESS-CONFLICTS`. The `.gitignore` entry for
`.immiscible-test.lock` was left in place: harmless, and it
predates this work.

## Cross-references

- `t/Yath/integration/help.t` -- canonical example.
- `t/lib/Test2/Harness2/Test/Yath.pm` -- the integration-test
  wrapper. Re-exports `yath()` from `App::Yath2::Tester`.
- `lib/Test2/Harness2/TestFile.pm` -- parses
  `# HARNESS-CONFLICTS NAME` lines into `$test->conflicts`.
- `reference/old2/lib/Test2/Harness2.pm:425` (`HARNESS-CONFLICTS-XXX`)
  -- original spec for the directive.
- PR #424, review thread `discussion_r3141745290` -- the comment
  from `@troglodyne` that prompted the migration.
