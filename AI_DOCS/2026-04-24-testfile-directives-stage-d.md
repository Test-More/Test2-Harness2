# TestFile: Stage D - HARNESS-NO/YES/USE directive dispatch

## What and why

GitHub issue [#378](https://github.com/Test-More/Test2-Harness/issues/378)
(label `TestFile`, milestone `PTS26`) asked for the fourth stage of
the `Test2::Harness2::TestFile` parser: teach `_scan` to dispatch the
feature-toggle directive family that legacy handles at
`reference/legacy/lib/Test2/Harness/TestFile.pm:265-307`.

The feature toggles are by far the most-used directive family in
real-world `.t` files:

- `# HARNESS-NO-FORK`, `# HARNESS-NO-PRELOAD`, `# HARNESS-NO-STREAM`,
  `# HARNESS-NO-TIMEOUT`, `# HARNESS-NO-IO-EVENTS`, `# HARNESS-NO-RUN`
- `# HARNESS-USE-ISOLATION`, `# HARNESS-YES-STREAM`
- `# HARNESS-NO-RETRY` (special-cased into the `retry` attribute, not
  into `features`)

Before Stage D, every one of these lines reached the placeholder
comment at the bottom of the `_scan` loop body and fell out of the
loop on the next iteration, leaving `features` and `retry` untouched.

Stages A-C had already put every prerequisite slot and scaffolding
piece in place: `<features` and `<retry` are declared on
`Object::HashBase`, `init()` seeds `+FEATURES = {}` through the
role-defaults loop, `_scan` captures `HARNESS-(.+)` into `$1` via
`last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/` at line 87,
and `scan()` remains a lazy, caller-driven entry point (not
auto-invoked from `init()`).

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Replaced the Stage A placeholder
    `# Stages D-G will dispatch the matched directive here.` at line 89
    with a verbatim port of legacy's `no` / `yes` / `use` arms.
  - Port shape: split `$1` on `/[-\s]+/` with limit 2 to peel off the
    directive word, then normalise the remainder with
    `s/\s+(?:#.*)?$//` (trailing whitespace / trailing comment) and
    split it again to collect `@args`. Collapse `@args` to a
    canonical feature name via `lc(join '_' => @args)`.
  - `no` arm: `$feature eq 'retry'` routes to `$self->{+RETRY} = 0`,
    everything else routes to `$self->{+FEATURES}{$feature} = 0`.
  - `yes` and `use` arms: both set `$self->{+FEATURES}{$feature} = 1`.
  - `else` arm: `warn "Unknown harness directive ..."`. This is a
    temporary placeholder for Stages E-G; their directive words
    (`timeout`, `category`, `duration`, `stage`, `conflicts`, `meta`)
    will be caught before falling through and the warn branch will
    naturally stop firing for any legitimate directive.

- `t/AI/unit/Harness2/TestFile/features.t` (new)
  - Nine subtests, one per directive family from the issue acceptance
    list, plus a tenth assertion that confirms no `__WARN__` handler
    saw the unknown-directive message for any valid directive. The
    subtests assert through the role accessors (`feature`, `features`,
    `retry`) rather than reaching into the internal hash, so the
    public surface is what's under test.
  - Reuses the `write_file` / `tf_for` helper pattern established in
    Stage B's `shebang.t` and Stage C's `binary_and_generated.t`. The
    fixtures are minimal: shebang, one HARNESS- line, then a
    `use strict;` stop-condition that the scan loop's existing
    `next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/` picks up.

- `AI_DOCS/2026-04-24-testfile-directives-stage-d.md` (this file).

The `Makefile.PL` TESTS glob `t/AI/unit/Harness2/TestFile/*.t` added
in Stage B already covers the new test file. No Makefile.PL edit was
needed.

## Decisions

### Verbatim port of the legacy dispatch

The split-join mechanics in legacy are load-bearing against real-world
directive lines: trailing inline comments
(`# HARNESS-NO-FORK  # legacy`), multi-word features
(`IO-EVENTS` -> `io_events`), whitespace-separated forms
(`HARNESS NO FORK`). The `/[-\s]+/` alternation for both split passes
handles all of them. Rewriting the port would risk regressing on
examples the legacy test corpus already exercises, so Stage D ports
byte-for-byte and lets Stage H add the validation layer on top.

### `retry` special-case stays inside the `no` arm

Legacy folds the `retry` branch under `no` rather than breaking it out
as a separate `retry` arm, because the directive line is spelled
`HARNESS-NO-RETRY` - the user writes "no retry", the parser reads the
`no` prefix and then asks "is the feature word `retry`?". Mirroring
that keeps the shape of the code readable against any user writing a
`.t` file.

### `HARNESS-NO-RETRY` must not leak into `features`

The feature-toggle test covers this explicitly
(`ok(!exists $tf->features->{retry})`). Without the explicit
assertion, a regression that dropped the `if/else` inside the `no`
arm would still pass test 9's `is($tf->retry, 0)` - the autoviv of
`features->{retry}` would just be invisible. The `!exists` check is
the guard.

### Temporary `warn` placeholder

Legacy's same `else` branch emits the same warn line. Keeping it here
until Stages E-G land serves two purposes: it keeps behaviour exactly
aligned with legacy during the rollout window, and it produces an
immediate regression signal if Stage E-G add a directive word that
accidentally falls through to the else. The Stage D test file treats
a stray warn as a test failure (see the `__WARN__` capture at the
top), so a regression in the dispatch arms fails loudly rather than
silently.

### Fixture format: shebang + directive + `use strict;`

Every Stage D fixture is three lines. The shebang keeps the scanner
on its Perl path (so `non_perl` stays 0 as a side-control); the
directive line exercises the dispatch; the `use strict;` line is the
stop-condition the Stage A loop logic expects so the scanner doesn't
try to read past the directive. This format reuses the same mental
model Stage B and Stage C fixtures established and keeps the test
diffs boring.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/features.t` - 9 subtests +
  one ward, all pass, no warnings.
- Stage A-C regression suite
  (`TestFile.t`, `Role/TestFile.t`, `TestFile/scan_scaffold.t`,
  `TestFile/shebang.t`, `TestFile/binary_and_generated.t`) - unchanged,
  all pass.
- `make test` - 54 files / 512 subtests, all pass (up from Stage C's
  53 / 502).
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (later stages)

- Stages E-G - remaining directive arms (`timeout`, `category`,
  `duration`, `stage`, `conflicts`, `meta`).
- Stage H - `check_feature` default table
  (`reference/legacy/lib/Test2/Harness/TestFile.pm:89-98`), and
  auto-disable of fork/preload for non-perl tests or tests with
  extra perl switches.
- Stage I - Finder wiring for `features->{run}`, and the final
  write-up of the Stage C "no die for non-executable binaries"
  deviation.
