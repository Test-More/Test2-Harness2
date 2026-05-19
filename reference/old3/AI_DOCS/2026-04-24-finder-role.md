# Finder Role and App::Yath2::Finder Stabilisation

## What the task was and what triggered it

The task started as implementing test-file discovery as an asynchronous service
using the double-fork collector+worker pattern already used for other services
in the harness.  After significant work on that design, Chad (exodist) reviewed
and redirected: discovery does not need to be asynchronous.  A simple role
defining the finder interface is sufficient; `App::Yath2::Finder` can run
synchronously in the calling process.

## Decisions made

### Design pivot: synchronous finder, not a service

**Original design:** `App::Yath2::Finder::Service` would fork as a run-scoped
resource service, run `find_files()` in the worker, and send the file list back
to `RunService` via IPC.  The empty pending queue would act as a natural gate
preventing test execution until discovery completed.

**Final design:** A `App::Yath2::Role::Finder` role defining the interface
(`requires 'find_files'`, provides `finder_name()`); `App::Yath2::Finder`
consumes it.  Discovery happens inline, in whatever process calls
`find_files()`.

**Why rejected:** Chad's direction was that the added complexity of the
double-fork pattern is not justified for file discovery.  Synchronous is
simpler, easier to test, and sufficient for the use case.  The role still
allows alternative async finders to be plugged in later without interface
changes.

### Role::Tiny conflict that triggered the pivot

During the service implementation, composing both
`Test2::Harness2::Role::Service` and `Test2::Harness2::Role::ResourceService`
into a single class caused a `Role::Tiny` method-conflict error on
`run_on_start` and `tinysleep`.  Resolving this would have required a
non-trivial Role::Tiny resolution shim.  Chad's redirect arrived at this point,
making the conflict moot.

### Methods added to Test2::Harness2::Role::TestFile

`App::Yath2::Finder` calls `check_feature`, `check_duration`, `check_category`,
and `rank` on test-file objects.  These methods existed in `reference/old2` but
had not been ported.  They were added to the role rather than to the concrete
class so that all TestFile implementations automatically satisfy the contract.

- `check_feature($name, $default)` — looks up a named feature flag from the
  test file's `features` hash, returning `$default` if absent.
- `check_duration()` — returns `$self->defaults->{duration} // 'medium'`.
- `check_category()` — returns `$self->defaults->{category} // 'general'`.
- `rank()` — numeric scheduling priority; smoke tests rank lowest (run first),
  isolation tests rank highest.

### Finder init() defaults

`App::Yath2::Finder` was originally designed to be constructed only through the
Options layer (which sets every attribute via CLI parsing).  Constructing it
directly (e.g., in tests or programmatic callers) crashed because several
attributes (`default_search`, `default_at_search`, `extensions`,
`exclude_patterns`, `exclude_files`) were left undef.  `init()` now sets
safe defaults for all of these.

### Nil-guard for settings in default_search logic

Line 591 of `Finder.pm` read `$settings->check_group('run')` unconditionally.
When `$settings` is undef (direct construction), this crashes.  A `$settings &&`
guard was added.

## Architectural changes introduced

- **`lib/App/Yath2/Role/Finder.pm`** (new) — the finder role contract.
- **`lib/App/Yath2/Finder.pm`** — now explicitly consumes
  `App::Yath2::Role::Finder`; `init()` sets safe defaults; nil-guard on
  `$settings`.
- **`lib/Test2/Harness2/Role/TestFile.pm`** — `check_feature`, `check_duration`,
  `check_category`, `rank` added.
- **`t/AI/unit/Yath2/Finder.t`** (new) — unit tests for `App::Yath2::Finder`
  covering basic discovery, extension filtering, all exclusion mechanisms,
  default search paths, and the empty-search error path; includes a
  `does_role` assertion.

## What was created then removed

- `lib/App/Yath2/Finder/Service.pm` — the async worker service (deleted).
- `lib/App/Yath2/Finder/Resource.pm` — the resource wrapper (deleted).
- `t/AI/unit/Yath2/Finder/Service.t` and `Resource.t` — tests for the above (deleted).
- Transient modifications to `Test2::Harness2::Run` (`finder_pending` slot,
  `add_pending_files`, `from_finder_resource`) and `Test2::Harness2.pm`
  (`finder_config` branch in `request_handler_queue_test_run`) — all reverted.
