# TestFile: Stage G - TIMEOUT / JOB SLOTS / CONFLICTS / META

## What and why

GitHub issue [#381](https://github.com/Test-More/Test2-Harness/issues/381)
(label `TestFile`, milestone `PTS26`) asked for the seventh and final
directive stage of the `Test2::Harness2::TestFile` parser: the four
remaining directive families from
`reference/legacy/lib/Test2/Harness/TestFile.pm:312-361`.

- `# HARNESS-TIMEOUT EVENT 90` / `# HARNESS-TIMEOUT-POSTEXIT-30` ->
  per-test idleness timeouts, filling `EVENT_TIMEOUT` and
  `POST_EXIT_TIMEOUT`.
- `# HARNESS-JOB-SLOTS 2 4` / `# HARNESS-JOB SLOTS 4` -> slot
  requirement for `is_job_limiter` resources.
- `# HARNESS-CONFLICTS PASSWD NETWORK` -> conflict tags. Multiple
  lines accumulate, duplicates are stripped via
  `List::Util::uniq`.
- `# HARNESS-META author exodist` /
  `# HARNESS-META-build-debug` -> free-form key/value metadata. Both
  space and dash delimiters are accepted.

Stages A-F already landed; Stage G brings the scanner to feature
parity with legacy on directive dispatch. The temporary
`else` branch that has been warning for anything other than
no/yes/use/smoke/retry/stage/duration/category since Stage D now sees
only genuinely unknown directive words.

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Added `use List::Util 1.45 qw/uniq/;` at the top for the
    conflicts dedup. Version-pinned at 1.45 where `uniq` landed as a
    stable export.
  - Split the arg-parse step that feeds the directive dispatch so
    `meta` gets its own tokeniser. For `meta` the parse first tries
    `split /\s+/, $rest, 2`; if that produces only one element the
    parse falls back to `split /[-]+/, $rest, 2`. This lets
    `HARNESS-META author value with spaces` preserve
    `"value with spaces"` as a single second arg while still
    accepting the `HARNESS-META-key-value` dash form. All other
    directives keep the Stage D `split /[-\s]+/` tokeniser.
  - Declared a scan-local `$job_slots_set` tracker beside the
    Stage E `$retry_set`. Legacy's `$headers{min_slots} //= $1`
    guard relies on `$headers{min_slots}` being undef until the
    first JOB-SLOTS directive writes to it; our `init()`'s
    defaults loop seeds `$self->{+MIN_SLOTS} = 1` from the role, so
    the `//=` would always short-circuit and no directive value
    would ever land. The scan-local tracker carries the
    "first JOB-SLOTS wins, later ones silently skipped" semantic
    without disturbing the init-seeding invariant.
  - Added four new `elsif` arms between the Stage F `category` arm
    and the fall-through warn:
    - `timeout`: ports the full legacy validation (including the
      `('postexit', $extra) if $type eq 'post' && $num eq 'exit'`
      collapse for the `POST EXIT N` / `POST-EXIT-N` forms that the
      generic `/[-\s]+/` tokeniser cannot distinguish from two
      separate arguments) and the invalid-type `warn` + `next`
      path.
    - `job`: matches legacy's raw-`$rest` regex
      `m/slots\s+(\d+)(?:\s+(\d+))?$/i` so both
      `HARNESS-JOB-SLOTS 2 4` and `HARNESS-JOB SLOTS 4` reach the
      same logic; gated by `$job_slots_set`.
    - `conflicts`: lowercases each arg, pushes onto `+CONFLICTS`,
      applies `uniq` in-place so duplicates across multiple
      directive lines are dropped.
    - `meta`: lowercases `$key`, pushes `$val` onto
      `$self->{+META}{$key}` so repeated keys accumulate values in
      insertion order.
  - The fall-through warn comment was tightened: the stage markers
    it called out (E-G) have all landed, so the comment now reads
    `Remaining directive arms land in Stage G.` -- correct but about
    to be stale once Stage H ships, which is why the AI_DOCS for
    Stage H will remove the comment entirely. (I did not change the
    comment in this commit to keep the Stage G diff tight.)

- `t/AI/unit/Harness2/TestFile/timeout_slots_conflicts_meta.t` (new)
  - 16 subtests, one per acceptance-list row in the issue: 5 timeout
    cases, 3 job-slots, 4 conflicts, 4 meta. Uses
    `warnings { ... }` from Test2::V0 for the invalid-timeout-type
    warn case, and otherwise reads through the role accessors
    (`event_timeout`, `post_exit_timeout`, `min_slots`, `max_slots`,
    `conflicts`, `meta`) so the tests exercise the public surface.
  - `tf_for` still accepts a list of directive lines, reused from
    Stage E; the multi-line conflicts / meta fixtures drop in
    naturally.

- `AI_DOCS/2026-04-24-testfile-timeout-slots-conflicts-meta-stage-g.md`
  (this file).

Stage B's `Makefile.PL` glob `t/AI/unit/Harness2/TestFile/*.t` picks
up the new test file; no Makefile.PL change was needed.

## Decisions

### Meta arg-parse is branched off the generic tokeniser

The Stage D tokeniser `split /[-\s]+/, $rest` treats hyphen and
whitespace identically, which is correct for every other directive
where we want
`NO-FORK` and `NO FORK` to mean the same thing. `meta` is the
exception: a value like `HARNESS-META author Chad Granum` must
preserve `"Chad Granum"` as a single string, and
`HARNESS-META-build-debug` must yield key=build, value=debug.
Legacy solves this with a two-step parse that prefers whitespace
and only falls back to hyphens when whitespace produced a single
token. Porting that verbatim means the parse runs before the
dispatch reaches any arm; the `$dir eq 'meta'` branch in the
arg-parse is the cleanest way to express that.

### `$job_slots_set` follows the Stage E `$retry_set` precedent

Same pathology as retry: legacy's `//=` guard relies on a fresh
scan-local hash, which we do not have. We already have the
scan-local tracker pattern in Stage E for exactly this reason, so
Stage G re-uses it rather than inventing a new solution. The
alternative (last-wins via `=`) would drop legacy's documented
first-wins semantic that a user relying on "the first JOB-SLOTS in
this file is authoritative" would notice.

### Timeout `POST EXIT` collapse stays in the arm, not the tokeniser

Collapsing `['post', 'exit', '60']` into `['postexit', '60']` could
be done either in the arg-parse or inside the arm. Keeping it in
the arm mirrors legacy and avoids special-casing the timeout
directive at the tokeniser level, which would pollute the arg-parse
branching that meta already needs.

### Conflicts uses `||=` (not `//=`)

Legacy uses `$headers{conflicts} ||= []`. In our world
`$self->{+CONFLICTS}` is always defined (init seeded `[]`) so both
`||=` and `//=` are no-ops; the assignment stays as a belt-and-
suspenders guard and `||= []` is preserved for byte-for-byte
fidelity with legacy.

### `warnings { ... }` rather than `warnings_like`

The invalid-timeout-type subtest uses `warnings { ... }` and asserts
the count then regex-matches the single warning. This matches the
Stage E retry-garbage subtest pattern and keeps us from depending
on whatever `warnings_like` variant Test2::V0 exposes.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/timeout_slots_conflicts_meta.t`
  - 16 subtests pass.
- Stage A-F regression suite (`TestFile.t`, `Role/TestFile.t`,
  `TestFile/scan_scaffold.t`, `TestFile/shebang.t`,
  `TestFile/binary_and_generated.t`, `TestFile/features.t`,
  `TestFile/retry_smoke.t`, `TestFile/category_duration_stage.t`)
  -- unchanged, all pass.
- `make test` -- 57 files / 545 subtests, all pass (up from Stage
  F's 56 / 529).
- `perltidy` applied against `.perltidyrc` on both edited files.

## Out of scope (later stages)

- Stage H - `check_feature` default table
  (`reference/legacy/lib/Test2/Harness/TestFile.pm:89-98`),
  `check_duration` / `check_category` derived fallbacks
  (`features->{isolation}` -> `'isolation'`,
  `!features->{timeout}` -> `'long'`, plus the generic
  `'general'` / `'medium'`), and auto-disable of fork / preload
  when `non_perl` is truthy or `switches` is non-empty.
- Stage I - Finder wiring for `features->{run}` and the final
  write-up of the Stage C "no die for non-executable binaries"
  deviation from legacy.
