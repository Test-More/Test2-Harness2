# TestFile: Stage H - derived check_* helpers and fork/preload auto-disable

## What and why

GitHub issue [#382](https://github.com/Test-More/Test2-Harness/issues/382)
(label `TestFile`, milestone `PTS26`) asked for the eighth stage: the
derived view methods that consumers (notably
`App::Yath2::Finder::exclude_file` at
`lib/App/Yath2/Finder.pm:744-756`, and the eventual scheduler) use
to ask "what should this test's effective timeout / fork / category /
duration be, applying all the policy fallbacks?".

After Stages A-G every directive populates a raw slot on the
TestFile, but consumers want a derived view:

- `check_feature(name, default)` -- user's setting, or a per-feature
  default (`timeout=1, fork=1, preload=1, stream=1, run=1,
  isolation=0, smoke=0, io_events=1`), or the caller-supplied
  override.
- `check_duration` -- user's raw duration, or `'long'` when timeout
  is disabled, or `'medium'`.
- `check_category` -- user's raw category, or `'isolation'` when the
  isolation feature is on, or `'general'`.
- `check_stage` / `check_min_slots` / `check_max_slots` -- raw
  slot, or undef.

Stage H also lands the fork/preload safety override from
`reference/old2/lib/Test2/Harness2/TestFile.pm:418-430`: tests with
non-perl shebangs, binary files, or perl shebangs carrying any
switch other than `-w` cannot be forked or preloaded. Putting this
inside `check_feature('fork')` / `check_feature('preload')` means
every consumer gets it without opting in. Critically the override
fires **before** the user's explicit `features->{fork|preload}` is
consulted -- a user writing `# HARNESS-USE-FORK` on a
`#!/usr/bin/bash` test still gets `check_feature('fork') == 0`,
because the runner cannot honour the request.

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Added a file-scope lexical `%DEFAULTS` table with the eight
    feature defaults ported from
    `reference/legacy/lib/Test2/Harness/TestFile.pm:89-98`.
  - Added `check_feature`, `check_duration`, `check_category`,
    `check_stage`, `check_min_slots`, `check_max_slots` on the
    concrete class. Each calls `$self->scan` at entry so the helper
    API makes scan an implicit invariant. `_SCANNED++` in `_scan`
    keeps the repeated calls idempotent.
  - `check_feature` implements the fork/preload override before the
    features-hash lookup. The override checks, in order: non-perl,
    binary, then iterates `+SWITCHES` and returns 0 as soon as any
    non-`-w` switch is seen.
  - `check_duration` and `check_category` use the raw-undef sentinel
    that Stage F landed to distinguish "user wrote a directive" from
    "default": a defined raw accessor short-circuits to the user's
    value before any derived fallback runs.

- `t/AI/unit/Harness2/TestFile/check_helpers.t` (new)
  - 13 subtests covering: the eight per-feature defaults, the
    caller-default override, directive-set features, the full
    duration / category fallback chains, stage/slots pass-through,
    the fork/preload override matrix (perl-w-only, perl-T,
    perl-w-Mblib, bash shebang, binary fixture,
    USE-FORK-beats-safety), and a lazy-scan ward asserting that
    `check_feature` triggers `_scan` on first call.
  - Reuses the `write_file` / `tf_for` helper pattern established in
    Stages B-G; adds a `tf_bytes` sibling for the random-bytes
    binary fixture (the space-joining `tf_for` cannot produce
    binary content).

- `AI_DOCS/2026-04-24-testfile-check-helpers-stage-h.md` (this file).

Stage B's `Makefile.PL` glob `t/AI/unit/Harness2/TestFile/*.t` picks
up the new test file; no Makefile.PL change was needed.

## Decisions

### Helpers live on the concrete class, not the role

The helpers must call `$self->scan`, which is only defined on the
concrete class. They also read several HashBase slots directly
(`+NON_PERL`, `+IS_BINARY`, `+SWITCHES`, `+FEATURES`, `+CATEGORY`,
`+DURATION`, `+STAGE`, `+MIN_SLOTS`, `+MAX_SLOTS`) -- the role has no
notion of storage, so it can't do that either.

This means the concrete class shadows the role's simpler
`check_feature` / `check_duration` / `check_category` stubs for
instances of `Test2::Harness2::TestFile`. The role stubs remain
available for anyone else consuming the role directly, which is
fine -- those consumers have their own storage model and their own
scan (or none), and should override if they want the derived
behaviour.

### Safety override fires before the features hash

Legacy/old2 put the fork/preload disable in `test_settings()`; Stage
H moves it inside `check_feature`, as the issue specifies, so no
caller has to remember to consult a separate gate. The override
short-circuits **before** consulting `features->{fork|preload}` on
purpose: user intent (`# HARNESS-USE-FORK`) cannot overrule a
run-time incompatibility (non-perl shebang, taint mode, etc.). The
dedicated subtest
`safety override beats explicit HARNESS-USE-FORK` locks this in.

### `-w` is the one switch that does not disable fork/preload

`-w` toggles warnings and does not require a fresh interpreter, so a
test using `#!/usr/bin/perl -w` can still run under fork/preload.
Every other switch (`-T` taint mode, `-Mblib`, `-Ilib/...`, etc.)
either changes interpreter state in a way a preloaded parent cannot
carry, or demands interpreter-level behaviour that must be picked up
at startup. Legacy's old2 treated `-w` as the sole exception; Stage
H preserves that.

### `%DEFAULTS` is a file-scope lexical

The table is a constant-shaped hash that only `check_feature` reads.
Keeping it as a `my` lexical (not a package `our` variable) means no
class outside this file can poke at it and quietly introduce
consumer-specific defaults. If another module ever wants the same
table, we'll promote the table at that time, not now.

### `check_feature(undef, ...)` not guarded

The role's stub `check_feature` guards against `undef` feature names
with `return $default unless defined $name;`. Stage H's richer
version does not. Calling `check_feature(undef)` at runtime is a
caller bug (no valid code path passes undef), and guarding against
it here would mean silently absorbing a bug. Perl's own warning for
the implicit `$DEFAULTS{undef}` lookup is acceptable noise.

### Lazy scan is a public behaviour change

Before Stage H, consumers had to call `$tf->scan` explicitly before
reading derived state. Now `check_*` helpers do it themselves. This
changes the public contract: any consumer that previously relied on
"I haven't called scan, so the TestFile is at construction-time
defaults" now sees scanned values once they call `check_*`.
The trade-off is worth it: every real consumer will either want the
scanned value, or it will already have called scan itself.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/check_helpers.t` -- 13
  subtests pass.
- Stage A-G regression suite (`TestFile.t`, `Role/TestFile.t`,
  `TestFile/scan_scaffold.t`, `TestFile/shebang.t`,
  `TestFile/binary_and_generated.t`, `TestFile/features.t`,
  `TestFile/retry_smoke.t`, `TestFile/category_duration_stage.t`,
  `TestFile/timeout_slots_conflicts_meta.t`) -- unchanged, all
  pass.
- `make test` -- 58 files / 558 subtests, all pass (up from Stage
  G's 57 / 545).
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (next stage)

- Stage I - wiring Finder to the new `check_*` helpers, porting
  legacy unit tests for directive coverage, and the final write-up
  of the Stage C "no die for non-executable binaries" deviation
  from legacy (deferred from Stage C per the original issue spec).
