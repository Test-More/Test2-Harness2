# TestFile: Stage B — shebang parsing

## What and why

GitHub issue [#376](https://github.com/Test-More/Test2-Harness/issues/376)
(label `TestFile`, milestone `PTS26`) asked for the second stage of the
`Test2::Harness2::TestFile` parser: port the legacy `_parse_shbang`
function and wire it into the line-1 dispatch hole that Stage A (#375)
left behind.

Until this landed, `switches` stayed at the role default `[]` and
`non_perl` stayed at `0` for every test file regardless of its shebang.
Stage H will later use both to decide whether fork / preload are safe —
they are not, when extra perl switches like `-T` or `-Mblib` are
present, and preload is nonsensical for `#!/usr/bin/bash` runners.

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Added `_parse_shbang` as a method, verbatim from
    `reference/legacy/lib/Test2/Harness/TestFile.pm:370-399`. The
    regex, the `grep { m/\S/ } split /\s+/, $1` tokenizer, and the
    return shapes (`{line, switches}` / `{line, non_perl}` / `{}`) are
    preserved byte-for-byte.
  - Replaced the Stage B placeholder in `_scan` with the line-1
    dispatch: when `$ln == 1` and the line starts with `#!`, call
    `_parse_shbang`, store `_shbang`, copy `switches` on a perl
    shebang, set `non_perl` on a non-perl shebang, and `next`. An
    empty `{}` return drops through to the ordinary directive path so
    line-1 non-shebangs still reach HARNESS-* dispatch.

- `t/AI/unit/Harness2/TestFile/shebang.t` (new)
  - Direct `_parse_shbang` coverage for perl/non-perl/env-perl/env-bash
    shebangs, `-w`, `-t -w`, `-Mblib`, `undef`, and non-shebang lines.
  - End-to-end scan coverage for six fixtures: plain perl, `-w`,
    `env perl -t -w`, bash, no-shebang, `HARNESS-` on line 1.

- `Makefile.PL`
  - Added `t/AI/unit/Harness2/TestFile/*.t` to the TESTS glob.
    Stage A's `scan_scaffold.t` and the new `shebang.t` both live
    under this previously-unlisted subdirectory; without this change
    `make test` silently skipped them. A regeneration of Makefile.PL
    from `dist.ini` should keep the new glob entry.

## Decisions

### Verbatim port

The regex `(?: \s (-.+) )?` under `/xi` and the `grep` filter are
load-bearing against edge cases the legacy test suite documents
(`#!/usr/bin/env perl -t -w`, `#!/usr/bin/perl -Mblib`,
`#!/usr/bin/perl` with no switches). Preserving them byte-for-byte
rules out rewrite regressions.

### Empty-hash guard

`_parse_shbang` returns `{}` when the input is undefined or has no
`#!`. In `_scan` the dispatch is guarded by `if ($shbang && %$shbang)`
so that:
- `_SHBANG` slot is never overwritten with an empty hash,
- `next` is not triggered for a line that turned out not to be a
  shebang, so an unusual first line (e.g. `# HARNESS-NO-FORK`) still
  reaches the directive branches below.

### Slot writes are additive only

- `SWITCHES` is written only when the parse produced a `switches`
  arrayref (perl shebang) — a non-perl shebang keeps `SWITCHES` at its
  role default `[]`, never `undef`.
- `NON_PERL` is only *set to 1*; it is never cleared. The role default
  is `0`, so no reset is needed.

### Makefile.PL regeneration note

The TESTS glob is maintained by hand (see commit `c98873b20`). Future
stages that add new subdirectories under `t/AI/unit/Harness2/TestFile/`
will not need another Makefile.PL entry — the `t/AI/unit/Harness2/TestFile/*.t`
glob covers every stage's tests that drop into this directory.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/shebang.t` — 7 subtests pass.
- `perl -Ilib t/AI/unit/Harness2/TestFile/scan_scaffold.t` — Stage A
  regression clean.
- `perl -Ilib t/AI/unit/Harness2/TestFile.t` and
  `.../Role/TestFile.t` — unaffected, pass.
- `make test` — 50 files / 481 subtests, all pass (up from 48/469
  before the TESTS glob update surfaced the TestFile subdir).
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (later stages)

- Stage C — binary detection, generated-runner sentinel.
- Stages D–G — HARNESS-* directive dispatch.
- Stage H — `check_feature` / `check_duration`, fork/preload
  suppression when `switches` is non-empty or `non_perl` is truthy.
