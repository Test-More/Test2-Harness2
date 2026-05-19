# TestFile: Stage F - HARNESS-DURATION / HARNESS-CATEGORY / HARNESS-STAGE + raw/derived split

## What and why

GitHub issue [#380](https://github.com/Test-More/Test2-Harness/issues/380)
(label `TestFile`, milestone `PTS26`) asked for the sixth stage of
the `Test2::Harness2::TestFile` parser: three scheduling-hint
directive arms plus a small contract change on the role that makes
the Stage H `check_category` / `check_duration` fallbacks possible.

Directives landed:

- `# HARNESS-DURATION-LONG` / `# HARNESS-DUR-MEDIUM` -- duration
  hints used by the Finder's `--no-long` / `--only-long` filters at
  `lib/App/Yath2/Finder.pm:752-756`. Lowercased.
- `# HARNESS-CATEGORY-IO` / `# HARNESS-CAT-NETWORK` -- category hints
  used by the scheduler. Lowercased.
- `# HARNESS-CATEGORY-LONG` (legacy sugar) -- routed into `duration`
  rather than `category`, matching legacy at
  `reference/legacy/lib/Test2/Harness/TestFile.pm:325-330`.
- `# HARNESS-STAGE-DBStage` -- preload stage name. Case-preserved.

Contract change: `Role::TestFile`'s raw `category` and `duration`
accessors now default to `undef` (were `'general'` / `'medium'`). The
raw attribute is the directive-set-or-nothing value; the derived
`'general'` / `'medium'` fallbacks are what `check_category` /
`check_duration` already apply on top. Before Stage F the two layers
were conflated, which made it impossible for Stage H's planned
`features->{isolation} -> category = 'isolation'` /
`features->{timeout} off -> duration = 'long'` overrides to
distinguish "user wrote a directive" from "default". The raw-vs-
derived split fixes that up-front so Stage H doesn't have to touch
the scanner again.

## What changed

- `lib/Test2/Harness2/Role/TestFile.pm`
  - `defaults()` now returns `category => undef, duration => undef`.
  - The ATTRIBUTES POD explicitly documents the raw-vs-derived
    contract so future readers understand why the raw accessor
    returns undef while `check_category` / `check_duration` fall
    back to `'general'` / `'medium'`.

- `lib/Test2/Harness2/TestFile.pm`
  - Added three `elsif` arms to the `_scan` directive dispatch,
    between the Stage E `retry` arm and the Stage G fall-through
    warn:
    - `stage` -- case-preserved, stores `$args[0]` directly into
      `+STAGE`.
    - `duration` / `dur` -- lowercases `$args[0]` into `+DURATION`.
    - `category` / `cat` -- lowercases `$args[0]`; if it matches
      `/^(?:long|medium|short)$/` it routes to `+DURATION` (the
      legacy "category as duration" sugar), otherwise it sets
      `+CATEGORY`.
  - Adjusted the fall-through warn comment from "Stages F-G" to
    "Stage G" since only that stage remains.

- `t/lib/Test2/Harness2/TestFile.pm`
  - Removed the `$self->{+CATEGORY} //= 'general'` and
    `$self->{+DURATION} //= 'medium'` seeds from `init()`. The
    reference implementation now lets the HashBase accessor return
    `undef` for an unseeded category/duration slot, matching the new
    role contract. Every other seed stays in place.

- `t/AI/unit/Harness2/TestFile.t`, `t/AI/unit/Harness2/Role/TestFile.t`,
  `t/AI/unit/Harness2/TestFile/scan_scaffold.t`
  - Updated the three existing assertions on the `'general'` /
    `'medium'` defaults to expect `undef`, including a matching
    "duration stays undef" pair in the "missing file" subtest of
    `scan_scaffold.t` (the previous test only checked category).

- `t/AI/unit/Harness2/TestFile/category_duration_stage.t` (new)
  - Eight subtests covering each directive form from the issue's
    acceptance list: DURATION-LONG, DUR-SHORT (alias),
    "DURATION MEDIUM" (space form), CATEGORY-IO, CAT-NETWORK
    (alias), CATEGORY-LONG (duration sugar), STAGE-DBStage
    (case preserved), and a "no directive" subtest that locks in
    the new undef defaults for category / duration / stage.
  - Reuses the `write_file` / `tf_for` helper pattern established in
    Stages B-E; `tf_for` from Stage E already accepts a list of
    directive lines, so multi-directive fixtures are trivial if
    later stages need them.

- `AI_DOCS/2026-04-24-testfile-category-duration-stage-stage-f.md`
  (this file).

The concrete `TestFile.pm` was not changed on the HashBase slot list:
`<category` and `<duration` were already declared in Stage A and the
`init()` defaults loop already seeds them from `$self->defaults`,
which now returns `undef` for both. No init logic change was needed
in the concrete class -- the undef-by-default flow works by itself.

Stage B's `Makefile.PL` glob `t/AI/unit/Harness2/TestFile/*.t` picks
up the new test file.

## Decisions

### Raw vs derived separation happens here, not in Stage H

Stage H needs three derived fallbacks in `check_category` /
`check_duration`:

- `features->{isolation}` truthy -> category = `'isolation'`
- `features->{timeout}` off -> duration = `'long'`
- Otherwise fall back to the generic `'general'` / `'medium'`.

All three overrides must be able to see that the user did **not**
write a `HARNESS-CATEGORY-*` / `HARNESS-DURATION-*` directive. The
cleanest signal is "raw accessor returned undef". Landing the
undef-raw contract now (one file, three assertion updates) is less
invasive than landing it together with the Stage H fallback logic
that will depend on it.

### `category` regex is anchored with the `(?:...)` non-capturing form

Legacy uses `m/^(long|medium|short)$/` with a capturing group that
is never read. The new form
`m/^(?:long|medium|short)$/` is identical in behaviour and avoids
the unused capture. This is the only departure from a byte-for-byte
port and is a pure readability win.

### Stage name is case-preserved

Legacy (and this stage) does **not** `lc()` the stage name:
`# HARNESS-STAGE-DBStage` stays `DBStage`. Preload stages are named
by the user and may be case-sensitive identifiers in the preload
configuration, so preserving case matters. The dedicated subtest
`HARNESS-STAGE-DBStage preserves case` locks this in.

### Reference-class init no longer seeds category/duration

`t/lib/Test2/Harness2/TestFile.pm` is the reference implementation
used by role tests and any caller that wants a drop-in TestFile.
Before Stage F its `init()` hardcoded `CATEGORY //= 'general'` /
`DURATION //= 'medium'` to keep the HashBase accessor from returning
undef. Now that the role contract explicitly allows undef as the
raw value, those seeds actively contradict the role and the
`t/AI/unit/Harness2/TestFile.t` "defaults fill in sensibly" subtest
would fail against the reference class. Removing them keeps the
reference in sync with the role.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/category_duration_stage.t`
  - 8 subtests pass.
- Stage A-E regression suite (`TestFile.t`, `Role/TestFile.t`,
  `TestFile/scan_scaffold.t`, `TestFile/shebang.t`,
  `TestFile/binary_and_generated.t`, `TestFile/features.t`,
  `TestFile/retry_smoke.t`) -- updated where needed, all pass.
- `make test` -- 56 files / 529 subtests, all pass (up from Stage
  E's 55 / 521).
- `perltidy` applied against `.perltidyrc` on all edited files.

## Out of scope (later stages)

- Stage G - remaining directive arms (`conflicts`, `meta`, the
  timeout family).
- Stage H - `check_category` / `check_duration` derived fallbacks
  (`isolation` / `long` / generic), `check_feature` default table,
  and auto-disable of fork / preload for non-perl tests or tests
  with extra perl switches.
- Stage I - Finder wiring for `features->{run}` and the final
  write-up of the Stage C "no die for non-executable binaries"
  deviation.
