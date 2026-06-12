# TestFile: Stage C - binary detection + generated-runner sentinel

## What and why

GitHub issue [#377](https://github.com/Test-More/Test2-Harness/issues/377)
(label `TestFile`, milestone `PTS26`) asked for the third stage of the
`Test2::Harness2::TestFile` parser: teach `_scan` to recognise two
file-content edge cases the legacy parser handled.

1. **Binary tests.** Compiled C tests (or anything `-B` reports as
   binary) cannot be scanned line-by-line.
2. **Generated yath-runner tests.** Auto-generated wrappers start with a
   `# THIS IS A GENERATED YATH RUNNER TEST` comment that means "do not
   run me directly" -- translated to `features->{run} = 0`.

Stages A (#375, `_scan` scaffold) and B (#376, shebang parsing) had
already set up everything Stage C needed as scaffolding: the
`_SCANNED++` guard, the `-e $self->{+ABSOLUTE}` short-circuit, the
`Object::HashBase` slots `<is_binary <non_perl <features`, and the
`init()` loop that seeds every role-defaulted slot (so `+FEATURES`
is a real `{}` hashref by the time `_scan` runs, and `{run} = 0`
autovivifies cleanly).

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Replaced the Stage A placeholder `return if $self->{+IS_BINARY};`
    with a real detection block at the top of `_scan`:

    ```perl
    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        return;
    }

    return if $self->{+IS_BINARY};
    ```

    The `-B _ && !-z _` reuses the `stat(2)` already cached by the
    preceding `-e $self->{+ABSOLUTE}` test. The `return if ... IS_BINARY`
    immediately below is kept for the rehydration case where a
    `TestFile` is constructed with `is_binary => 1` but no `_scanned`.
  - Added the generated-runner sentinel branch inside the scan loop,
    between the shebang block and the comment-skip:

    ```perl
    if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
        $self->{+FEATURES}{run} = 0;
        next;
    }
    ```

    `next`, not `last`: downstream `# HARNESS-*` directives after the
    sentinel must still be parsed when Stages D-G land.

- `t/AI/unit/Harness2/TestFile/binary_and_generated.t` (new)
  - 4 subtests covering the binary short-circuit, the `-z` exemption
    for empty files, the perl-shebang-then-sentinel path (with an
    extra `lives { scan }` + `_scanned` latch assertion standing in
    for the `next`-not-`last` proof until Stage F can tighten it with
    a post-sentinel HARNESS-* directive), and the leading-whitespace
    regex shape.

The `Makefile.PL` TESTS glob added in Stage B (`t/AI/unit/Harness2/TestFile/*.t`)
already covers the new file. No Makefile.PL edit was needed.

## Decisions

### Lazy detection in `_scan`, not `init`

Legacy detected binaries in `init()` (`reference/legacy/lib/Test2/Harness/TestFile.pm:77-81`).
Stage C moves this into `_scan` deliberately, so a `TestFile` rehydrated
from JSON for a path that no longer exists on disk (or is not yet
present in the environment) still constructs cleanly; the binary check
only fires when the harness actually looks at the file.

### `-B _ && !-z _` ordering

The `_` filetest operator reads the stat buffer of the *immediately
preceding* filetest. The `-e $self->{+ABSOLUTE}` at the top of `_scan`
populates it; nothing between that line and the binary block may
perform another `stat(2)` or the cache is lost. This is why the block
sits right after the `-e` guard.

### No `die` for non-executable binaries

Legacy's `init()` dies with "Cannot run binary test file '$file': file
is not executable." when `IS_BINARY && !is_executable`. Stage C
intentionally does **not** carry this over. The new design defers
run/exec decisions to the runner, not the parser: a `TestFile` is a
description of what the file says about itself, and it is legitimate
for the runner to skip an un-runnable file rather than abort parsing.
This is the only observable deviation from legacy in Stage C. The
issue defers the final write-up of this deviation to Stage I (when
the Finder wiring lands), so no `ARCHITECTURE.md` addendum is added
at this stage.

### `next`, not `last`

The sentinel uses `next` so the rest of the file is still scanned -
generated wrappers sometimes emit `# HARNESS-CATEGORY-IO` or similar
after the sentinel, and those must reach the directive-dispatch path
once Stages D-G land. Stage C cannot assert that those post-sentinel
directives take effect yet (no dispatch), but a comment in the new
test file points Stage F at the place to add the stronger assertion.

### Hardcoded `#` in the sentinel regex

The rest of `_scan` uses `\Q$comment\E` to honour a non-`#` comment
character on non-Perl files. The sentinel regex uses a hardcoded `#`
because the sentinel is yath-specific and yath only ever generates
`#`-commented Perl wrappers. This matches legacy
(`reference/legacy/lib/Test2/Harness/TestFile.pm:256`).

### Kept the `return if $self->{+IS_BINARY}` guard

Even though the new block above already flips `IS_BINARY` from cold,
the second `return if $self->{+IS_BINARY};` below it is kept as a
cheap defensive guard: if a caller ever constructs a `TestFile` with
`is_binary => 1` and `_scanned => 0` (odd but possible under
rehydration edge cases), the binary-early-out still fires without
needing to walk through the file-read path.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/binary_and_generated.t` -
  5 subtests pass.
- `perl -Ilib t/AI/unit/Harness2/TestFile.t`,
  `perl -Ilib t/AI/unit/Harness2/Role/TestFile.t`,
  `perl -Ilib t/AI/unit/Harness2/TestFile/scan_scaffold.t`,
  `perl -Ilib t/AI/unit/Harness2/TestFile/shebang.t` - all pass,
  Stage A and Stage B behaviour unchanged.
- `make test` - 53 files / 502 subtests, all pass.
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (later stages)

- Stages D-G - HARNESS-* directive dispatch (category, duration,
  stage, fork/preload, conflicts, timeouts, retry).
- Stage H - `check_feature` / `check_duration` helpers, fork/preload
  suppression when `switches` is non-empty or `non_perl` is truthy.
- Stage I - wiring `features->{run} == 0` into Finder filtering, plus
  the final write-up of the "no `die` for non-executable binaries"
  deviation from legacy.
