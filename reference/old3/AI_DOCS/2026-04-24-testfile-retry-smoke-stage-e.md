# TestFile: Stage E - HARNESS-SMOKE + HARNESS-RETRY dispatch

## What and why

GitHub issue [#379](https://github.com/Test-More/Test2-Harness/issues/379)
(label `TestFile`, milestone `PTS26`) asked for the fifth stage of the
`Test2::Harness2::TestFile` parser: add the two remaining
scheduling-affecting directive arms that legacy handles at
`reference/legacy/lib/Test2/Harness/TestFile.pm:286-302`.

- `# HARNESS-SMOKE` marks a test for elevated scheduler priority. The
  role's `rank()` helper uses `check_feature('smoke')` to read this.
- `# HARNESS-RETRY [N] [ISO]` controls retry policy. Forms: bare
  `RETRY` (retry once), `RETRY N` (retry N times), `RETRY-ISO` (retry
  once in isolation), `RETRY N ISO` / `RETRY ISO N` (order-insensitive
  count + isolation).

Stage D already handles `HARNESS-NO-RETRY`. Stage E wires the
positive / count-bearing retry forms and smoke.

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Added a scan-local `my $retry_set;` before the directive loop. The
    variable tracks whether any directive has explicitly touched
    `RETRY` during this scan. It is the substitute for legacy's
    `defined $headers{retry}` guard, which cannot be used here because
    `init()`'s defaults loop seeds `$self->{+RETRY} = 0` before `_scan`
    ever runs, so a `defined` check would always succeed and a bare
    `# HARNESS-RETRY` would fail to default `retry` to 1.
  - Wired `$retry_set = 1` into the existing `HARNESS-NO-RETRY` branch
    inside the `no` arm. This keeps the legacy sticky-NO semantics:
    `NO-RETRY` followed by a bare `RETRY` leaves retry at 0, because
    the bare-RETRY path only fires when `!$retry_set`.
  - Added the `smoke` arm:
    `$self->{+FEATURES}{smoke} = 1`.
  - Added the `retry` arm with the full legacy dispatch:
    - `@args` non-empty: iterate; numeric token sets the count,
      `iso`-prefixed token flags isolation (and defaults the count to
      1 only if no count has been set yet this scan), anything else
      warns.
    - `@args` empty and `!$retry_set`: default to
      `$self->{+RETRY} = 1`.
  - Adjusted the `else`-fall-through warn comment from "Stages E-G"
    to "Stages F-G".

- `t/AI/unit/Harness2/TestFile/retry_smoke.t` (new)
  - Nine subtests covering: smoke, bare retry, retry count, retry-ISO
    (hyphen form), retry-count-ISO, retry-ISO-count (order
    insensitive), garbage-argument warning, Stage D NO-RETRY then
    RETRY count override, and multi-line retry where the later count
    wins. Uses `warnings { ... }` from `Test2::V0` to assert the
    single expected warning on the garbage case.
  - Reuses the `write_file` / `tf_for` helper pattern established in
    Stage B / C / D test files, with `tf_for` now accepting a list of
    directive lines so multi-directive fixtures (NO-RETRY +
    RETRY 3, RETRY 2 + RETRY 5) read naturally.

- `AI_DOCS/2026-04-24-testfile-retry-smoke-stage-e.md` (this file).

Stage B's `Makefile.PL` glob `t/AI/unit/Harness2/TestFile/*.t` picks
up the new test file; no Makefile.PL edit was needed.

## Decisions

### `smoke` lives in `features->{smoke}`, not in a dedicated slot

The issue specifies `features->{smoke} = 1`. Koan-Bot's planning
comment on the issue argues for a dedicated `SMOKE` attribute, but
that is wrong for the current concrete class:

- `lib/Test2/Harness2/TestFile.pm:12-24` does **not** declare a
  `<smoke` slot on `Object::HashBase`. The role documents `smoke` as
  a typed attribute with a default of 0, but the concrete class never
  allocates a slot for it.
- `lib/Test2/Harness2/Role/TestFile.pm:121-125` -- the `rank()`
  helper -- reads smoke via `$self->check_feature('smoke')`, i.e.
  from the `features` hashref, not from a dedicated accessor.

Storing smoke in `+FEATURES{smoke}` therefore matches both the legacy
port target and the only downstream reader that exists today.

### `$retry_set` replaces legacy's `defined` guard

Legacy (`reference/legacy/lib/Test2/Harness/TestFile.pm:289-302`)
protects the bare-RETRY default with
`$headers{retry} = 1 unless @args || defined $headers{retry};`.
Legacy's `%headers` is a scan-local hash, so `$headers{retry}` is
genuinely undef until a directive touches it.

Our new `_scan` writes directly into `$self->{+RETRY}`, and
`init()`'s defaults loop seeds `$self->{+RETRY} = 0` before any
scan runs. A `defined` check would therefore always succeed, breaking
every bare-RETRY case. Introducing a scan-local `$retry_set` carries
the same "has a directive touched retry this scan?" semantic without
disturbing the init-seeding invariant that every other slot relies
on.

The tracker is also flipped by the Stage D `NO-RETRY` branch, so the
legacy sticky-NO behaviour is preserved: a bare `RETRY` after a
`NO-RETRY` does not silently re-enable retries.

### ISO branch's count default uses `unless $retry_set`, not `//=`

Legacy uses `$headers{retry} //= 1` inside the iso branch, relying on
the same `undef` starting state. For the same reason, that idiom
would be a no-op here (init seeded 0). The `unless $retry_set` form
preserves the intent: set retry to 1 only if no count has already
been recorded this scan.

### Smoke arm is trivially idempotent

Repeated `# HARNESS-SMOKE` lines re-assign the same truthy value to
the same hash key. No guard needed.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/retry_smoke.t` - 9 subtests
  pass.
- Stage A-D regression suite
  (`TestFile.t`, `Role/TestFile.t`, `TestFile/scan_scaffold.t`,
  `TestFile/shebang.t`, `TestFile/binary_and_generated.t`,
  `TestFile/features.t`) - unchanged, all pass.
- `make test` - 55 files / 521 subtests, all pass (up from Stage D's
  54 / 512).
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (later stages)

- Stages F-G - remaining directive arms (`timeout`, `category`,
  `duration`, `stage`, `conflicts`, `meta`).
- Stage H - `check_feature` default table
  (`reference/legacy/lib/Test2/Harness/TestFile.pm:89-98`),
  `check_duration`, `check_category`, and auto-disable of
  fork/preload for non-perl tests or tests with extra perl switches.
- Stage I - Finder wiring for `features->{run}` and the final
  write-up of the Stage C "no die for non-executable binaries"
  deviation.
