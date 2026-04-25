# Windows collector spawn PID tracking and process-group isolation

**Issue**: https://github.com/Test-More/Test2-Harness/issues/398
**Date**: 2026-04-24
**Triggered by**: @atoomic via `@Koan-Bot plan` / `@Koan-Bot implement`

## What the task was

The issue reported that `system 1, @cmd` return value was misread on Windows.
The actual investigation found two distinct problems:

1. **Fragile error guards** — both `_spawn_collector_win32` and `_launch_child_win32`
   used a combined check `!$ok || !$pid || $pid < 0` that conflated two distinct
   failure modes (eval death vs. spawn returning a non-positive PID) and included
   no explanation of what `system 1, @cmd` returns on Win32.

2. **`new_pgroup => 1` unconditionally croaked on Windows** — the code had a
   `croak` placeholder for the `Win32::Job`-backed spawn path that was never
   implemented. The spec (ARCHITECTURE.md Invariant 1) requires process-group
   isolation, but Windows lacks `fork` and `setpgid`. The deferred work was
   called out in a comment at line ~1197 of Collector.pm.

## Decisions made

### Phase 1: Harden `system 1, @cmd` spawn sites

Split the combined guard into two explicit guards:
- `croak "... (eval died): $err" if !$ok`
- `croak "... (spawn returned N): $!" if !defined $pid || $pid <= 0`

Added an explanatory comment at each site noting that `system 1, @cmd` on Win32
is `_spawnvp(P_NOWAIT, ...)` which returns the PID (positive int) on success or
-1 on failure — not an exit code.

**Alternative considered**: Replace with `Win32::Process::Create` throughout to
get a true Win32 HANDLE. Rejected because `Win32::Process` is a separate optional
distribution and adds a hard dependency for code that already works.

### Phase 2: Implement `Win32::Job`-backed `new_pgroup` spawn path

Replaced the unconditional `croak` in `_check_new_pgroup_supported_on_win32` with
a runtime check: if `Win32::Job` is loadable, the path proceeds; otherwise it
croaks with a message directing the user to install the optional module.

Added `_launch_child_win32_job` which:
- Creates a `Win32::Job` object via `Win32::Job->new()`
- Builds a properly-quoted command-line string for `CreateProcess` via helper
  `_win32_quote_arg`
- Calls `$job->spawn($exe, $cmdline, { stdout => ..., stderr => ... })` passing
  the pipe write ends directly so the child inherits them without a
  redirect-then-restore dance
- Stores the job handle in `$self->{_win32_job}` (new private `Object::HashBase`
  attribute `+_win32_job`)

Added `DESTROY` method that `delete`s `$self->{+_WIN32_JOB}`. When the last
reference to the `Win32::Job` object is dropped, Windows closes the job handle
and (because Win32::Job sets `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` by default)
terminates all processes in the job atomically — matching `kill(0-$pgid)` on Unix.

### Phase 3: Tests

Added `t/AI/unit/Collector/win32_spawn.t` (13 subtests, all green).

**Key implementation note on mocking**: `CORE::GLOBAL::system` overrides do not
intercept already-compiled `system 1, @cmd` opcodes. Solved by extracting the
call into a dedicated `_win32_spawn` method that tests can override with
`local *Test2::Harness2::Collector::_win32_spawn = sub { ... }`. This is now
the canonical mockability point for the Win32 spawn path.

The Windows-live `Win32::Job` subtest is guarded by `$^O eq 'MSWin32'` and
`eval { require Win32::Job; 1 }` SKIP blocks so CI (Linux/macOS) skips it.

## Architectural changes

- New private attribute `+_win32_job` on `Test2::Harness2::Collector`.
- New methods:
  - `_win32_spawn(@cmd)` — thin `system 1, @cmd` wrapper; mockability point
  - `_launch_child_win32_job($cmd, $out_w, $err_w)` — Win32::Job spawn path
  - `_win32_quote_arg($arg)` — Win32 CreateProcess command-line quoting
  - `DESTROY` — releases the job handle when the Collector is garbage-collected
- `_check_new_pgroup_supported_on_win32` now performs a runtime `require Win32::Job`
  check instead of unconditionally croaking.

No changes to the public API or the non-Windows code paths.

## Open questions (not resolved in this task)

- Is there a `windows-latest` GitHub Actions runner available to run Phase 2's
  live Win32::Job tests in CI?
- Should `Win32::Job` be listed as `recommends` in `dist.ini` / `Makefile.PL`?
