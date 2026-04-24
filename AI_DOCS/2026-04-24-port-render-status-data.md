# Port `render_status_data` to `Test2::Harness2::Util`

**Date:** 2026-04-24  
**Issue:** https://github.com/Test-More/Test2-Harness/issues/387  
**Branch:** `koan.atoomic/fix-issue-387`

## What the task was

`App::Yath2::Command::status` (line 9) imports `render_status_data` from
`Test2::Harness2::Util`, but the current `@EXPORT_OK` list did not include
the name and the sub body was missing from the file.  The module therefore
failed to compile with:

```
Test2::Harness2::Util does not export &render_status_data
  at lib/App/Yath2/Command/status.pm line 9.
```

The fix was to port the function from the reference tree
(`reference/old2/lib/Test2/Harness2/Util.pm`, lines 405-467) into the
current implementation.

## Decisions made

### Lazy `require Term::Table`

The reference implementation calls `Term::Table->new(...)` directly with
no explicit `use` or `require` at the top of the module, relying on callers
(e.g. `status.pm`, which does `use Term::Table()`) to have already loaded
it.  This is fragile.  The fix adds `require Term::Table;` at the top of
the `render_status_data` sub body so the function is self-contained and
only loads `Term::Table` on demand (only callers that actually render status
output pay the cost).

### `render_duration` via top-level `Importer`

The function formats duration columns using `render_duration` from
`Test2::Util::Times`.  The reference file imports it via
`use Importer 'Test2::Util::Times' => qw/render_duration/;` at the module
level.  The same import was added to `lib/Test2/Harness2/Util.pm` following
the existing pattern for `Importer` usage in that file.

### Test placement

The issue explicitly requested the test go under `t/unit/Util/` (not
`t/AI/`) because it is a human-directed port, not an AI-originated
implementation.  The test was placed at `t/unit/Util/render_status_data.t`.

## Alternatives considered

- **Lazy-load `render_duration` inside the sub** — rejected in favour of the
  reference's top-level import; `Test2::Util::Times` is a lightweight dep
  already used throughout the suite.

## Architectural changes

None.  This is a pure addition: one new sub, one new `use Importer` line,
one new entry in `@EXPORT_OK`.
