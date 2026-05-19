# Preload Rework — Design

Date: 2026-05-10
Status: design (pre-implementation)
Branch: `preload_rework`
Source notes: `preload_rework` (user), `gemini-preload-rework.md`, plus
brainstorming dialogue captured in this document.

## 1. Goals

Replace the legacy preload subsystem with a service-per-preload model
that aligns with the post-`flatten-run-service` architecture (single
harness service, harness-as-subreaper, resources as the slot-accounting
spine).

A preload is a long-lived perl process that has already `require`'d a
set of modules. When a test wants to launch under that preload, the
harness asks the preload service to spawn the test child, which
double-forks (reparenting to the harness) and then jumps into the test
file with `%INC` already populated.

The legacy concept of "stages" (chains of dependent preloads) is gone.
Each preload is independent. Complex preloads can implement a role to
get pre-fork / post-fork / pre-launch hooks, a custom `do_preload`
entry, and a fixed name. Reloading is opt-in via a separate role with
two implementations (HiResStat, INotify).

## 2. Non-goals

- Preload chains / multi-stage preloads. Each preload stands alone.
- Slot-based concurrency limits on preloads. A preload is "ready or
  not", not "ready with N free slots". Concurrency arbitration stays
  with JobCount and the other resource limiters.
- A new directive language. The legacy DSL (HARNESS-STAGE-FOO,
  HARNESS-PRELOAD-FOO, etc.) is replaced by a single
  `HARNESS-PRELOAD: ...` ordered preference list.
- Reloader fallback chains. If the user requests `--reloader=inotify`
  and `Linux::Inotify2` is missing, croak — do not silently downgrade
  to HiResStat.
- A `Module::Refresh`-backed reloader. Module::Refresh does not handle
  Moose correctly, so we do not ship it.

## 3. Architecture

### 3.1 Module map

```
lib/Test2/Harness2/
  Resource/Preload.pm           # the Resource (Role::Resource consumer)
  PreloadService.pm             # the service process (Role::Service consumer)
  Role/Preload.pm               # role complex preloads consume
  Role/Reloader.pm              # role reloaders consume
  Reloader/Common.pm            # shared base: project root, %INC filter, debounce
  Reloader/HiResStat.pm
  Reloader/INotify.pm
```

`Resource::Preload` is what the harness holds in its resource set. It
owns one `PreloadService` child process spawned via the existing
`ResourceServiceHost` role (the same path JobCount and friends use).
`PreloadService` runs its full lifecycle inside a `BEGIN` block so the
test child can `Long::Jump` out of `BEGIN`, completely unwind the stack,
and then `goto::file` into the test. After the jump, the child looks
like `perl -Ilib t/foo.t` was invoked directly, except `%INC` is
pre-populated.

### 3.2 Process tree

```
harness  (sub_reaper, owns RUN_PIDS)
 ├── resource service: jobcount
 ├── resource service: cpu
 ├── preload service: Preload:default        (global)
 │    └── (transient fork during spawn — exits immediately)
 ├── preload service: Preload:Foo            (global, named via role)
 ├── preload service: Preload:<rid>:Bar      (per-run, named via role)
 ├── collector  (test grandchild, reparented from preload double-fork)
 │    └── test interpreter
 └── collector  (test grandchild for a `<no>` job — direct fork-exec)
      └── test interpreter
```

Test processes are always grandchildren of the harness either way
(direct fork-exec for `<no>` jobs, double-fork-then-reparent for
preloaded jobs). Harness's existing run_on_pid handles both uniformly.

### 3.3 IPC bus naming

| Service | Bus name |
|---|---|
| Global preload `default` | `Preload:default` |
| Global preload `Foo` | `Preload:Foo` |
| Per-run preload `Bar` for run id `R1` | `Preload:R1:Bar` |

Reuses the existing IPC::Manager service-name conventions.

## 4. Lifecycle

### 4.1 Global preloads

- Spawned in `Test2::Harness2::service_on_start` after global resource
  services come up. Use `start_resource_services(scope=>'global')` —
  the role machinery already handles tracking and RUN_PIDS
  registration under `__global__`.
- Stop only at harness shutdown.
- Initial module load failure: service exits non-zero. The role's
  `_fail_service` flips the resource to `permanent_broken`. Additionally,
  the harness blocks during `service_on_start` until each global
  preload has emitted either `preload_ready` (success) or has its
  resource flagged `permanent_broken` (fail). On any global-preload
  permanent_broken, the harness aborts startup with a clear error. For
  `yath start` this happens in the parent before backgrounding, so the
  user sees a non-zero exit on the terminal.

### 4.2 Per-run preloads

- Spawned in `_ensure_run_service_started` alongside per-run resource
  services, scope=run, run_id keyed.
- Terminated when the run finalizes via the existing
  `_teardown_run_service` -> `_kill_run` cascade.
- Initial module load failure: service exits non-zero, resource flips
  `permanent_broken`. The harness then hard-fails the entire run —
  every job in the run is force-failed via a new `_fail_run($run, $reason)`
  helper that synthesizes a `test_job_completed` (pass=0, synth=1) for
  each pending or running job and finalizes the run. The harness keeps
  running other runs.

### 4.3 Tests vs. preload readiness

- `Resource::Preload::is_usable` returns false until the service has
  emitted both `service_started` (Role::Service standard) AND a new
  `preload_ready` event after `do_preload` completes successfully.
- The scheduler's existing `_evaluate_resources_for` defers when
  `!is_usable`, so any test that resolves to a not-yet-ready preload
  waits.
- Tests resolving to `<no>` route through the existing direct-fork
  path; they never touch the Resource::Preload at all and launch
  immediately, even before any preload is ready.

## 5. Resource semantics

`Resource::Preload` is a Role::Resource consumer with these specifics:

- `needed(job=>$job)` — true if this preload's name appears in the
  job's resolved preload assignment (set by Section 6's resolver).
- `available()` — returns 1 (no slot accounting). The yes/no decision
  is purely "is the service ready", which `is_usable` answers.
- `assign()`/`release()` — pure markers. No env vars set, no slot
  decrement. They exist so the existing scheduler bookkeeping
  (assign_id, release on cleanup) works without special-casing
  preloads.
- `is_permanent_broken` — true after initial-load failure or after
  the restart-spiral cap is exceeded. **Sticky**: once set, no
  `preload_ready` IPC clears it. The only way back is a fresh
  harness invocation. This is critical when the harness hosts both
  global and per-run preloads of the same name — a per-run
  `preload_ready` from a freshly started run-scoped service must
  not clear the global resource's permanent_broken flag (and vice
  versa). The flag lives on the per-(scope, run, name) Resource
  object, mirroring the rule the
  `Test2::Harness2::Role::ResourceServiceHost` already enforces for
  resource services more broadly (see flatten-run-service plan,
  cross-cutting risk #11).
- `is_broken` (transient) — true during a reload-restart cycle, after
  a reload-compile error (until the user fixes the file), or after a
  spawn-IPC timeout while the service is being investigated.

The Resource also carries:

- `name` — string
- `scope` — `'global'` or `'run'`
- `run` — Run object when scope is `'run'`
- `modules` — arrayref of module names (anonymous-merged for `default`,
  single-element for role-named preloads)
- `is_role_consumer` — bool, true when the underlying preload class
  consumes `Role::Preload`
- `default_for_scope` — bool, computed once at construction (Section
  6.2) and cached

## 6. Test → preload routing

### 6.1 Directive

```
# HARNESS-PRELOAD: name1 name2 <default>
```

Whitespace-separated, ordered preference list. Tokens:

- bare name — try this specific preload (per-run scope first, then
  global)
- `<default>` — try the scope's default preload; if no default exists
  in any scope, fall through to no-preload. `<default>` IMPLIES `<no>`
  follows it (writing `<default> <no>` is redundant; we normalize).
- `<no>` — accept running with no preload (direct fork-exec)

Validation rules:

- If `<default>` is present it must be the last entry.
- If `<no>` is present and `<default>` is not, `<no>` must be the last
  entry.
- Named entries cannot follow `<default>` or `<no>`.
- Empty/missing directive normalizes to `<default>`.
- `<no>` alone means strict opt-out: no preload acceptable.

### 6.2 Default determination per scope

Computed once per scope at preload set construction:

- **Per-run default**: if exactly one preload exists in the run scope
  AND it is a role consumer with a `name`, that one is the per-run
  default. Otherwise no per-run default.
- **Global default**: in priority order:
  1. The `default` preload (the anonymous-merged bucket of bare `-P`
     modules) if it exists.
  2. Otherwise, if exactly one global preload exists and it is a role
     consumer, that one.
  3. Otherwise, no global default.

`<default>` resolves per-run-default first, falls through to
global-default.

### 6.3 Resolver

A new helper `_resolve_preload_for_job($run, $job)` lives on the
harness. Returns one of:

- `(undef, 'no_preload')` — caller takes the existing direct-fork
  path.
- `($preload_resource, 'preload')` — caller takes the new spawn-via-
  preload path.
- `('defer')` — the only acceptable preloads are currently transient
  broken; retry next tick.
- `('broken', $first_preferred_name)` — list exhausted with no usable
  resolution; caller routes through `broken_resource_behavior`
  (skip/fail/abort).

Algorithm:

1. Read the job's resolved preload list (parsed at TestFile-scan time
   from `HARNESS-PRELOAD:`; default `[<default>]`).
2. Walk in order. For each entry:
   - `<no>`: return `(undef, 'no_preload')`.
   - `<default>`: substitute the per-run default (if exists for
     `$run`), else the global default; if neither, return
     `(undef, 'no_preload')` (the implicit `<no>` fallback).
   - bare name: look up. Per-run scope first, then global. If
     matched: check state.
3. State check on a matched candidate:
   - `is_permanent_broken`: skip to next entry.
   - `is_broken` (transient): record a "deferred-because-broken" flag
     and continue scanning (a later entry may be usable now).
   - usable: return `($resource, 'preload')`.
4. If list exhausted with no usable match:
   - If anything was deferred-because-broken: return `('defer')`.
   - Else: return `('broken', $first_preferred_name)` so
     `broken_resource_behavior` decides.

## 7. Spawn pathway

### 7.1 Async spawn IPC

1. Scheduler's `_launch_job` calls `_resolve_preload_for_job`.
2. If `(undef, 'no_preload')` → existing `_spawn_collector_for_job`
   path, no change.
3. If `($preload_resource, 'preload')` → new path
   `_spawn_via_preload($run, $job, $preload_resource, %opts)`:
   - Build the spawn payload (`test_file_abs`, `env`, `run_id`,
     `job_id`, `job_try`, `launch` override if any, `auditor`).
   - Record a placeholder RUNNING_JOBS entry:
     ```
     { run, job, pid => undef, awaiting_preload_pid => 1,
       preload_name => $name, preload_scope => $scope,
       sent_at => time, ... }
     ```
   - Send async IPC `spawn_test` to the preload service's bus.
   - Add to `PENDING_SPAWN_REQUESTS` keyed by `(run_id, job_id)` for
     timeout tracking.
   - Return immediately.

### 7.2 Preload service handles `spawn_test`

In `request_handler_spawn_test` (no response — async):

1. Fire `pre_fork` callback if role-implemented.
2. `fork()` → first child.
3. First child: fire `post_fork` callback if role-implemented; `fork()`
   again → grandchild. The first child MUST then call
   `POSIX::_exit(0)` immediately — no cleanup, no flushing, no
   destructors. The reparenting hinges on this: the grandchild can
   only become a direct child of the harness sub_reaper once the
   first child has died, so any delay here widens the orphan
   window during which run_on_pid would see an unattributable pid.
   Use `_exit`, not `exit`, because `exit` runs END blocks and
   destructors that can raise events the harness will see and
   misattribute.
4. Grandchild: fire `pre_launch` callback if role-implemented; reset
   process-level state (Section 7.4); call `Long::Jump::longjump` with
   a payload identifying the test to run.
5. Long::jump returns control to the BEGIN's setjump point with
   that payload. Main script body sees the payload, then calls
   `goto::file($test_file_abs)` to load the test file as `__FILE__`.
6. The test runs as a normal Collector child — the same Collector
   class spawn args, the same auditor wiring. The auditor's IPC
   targets (ipc_run, ipc_harness, ipc_parent) all point at the
   harness, exactly as for the direct-fork path post-Stage-4 of the
   flatten.

### 7.3 Harness picks up the spawn

The auditor's `test_job_started` (already routed to the harness) lands
with `collector_pid` and `test_pid`. The harness's existing
`_handle_test_job_started` is augmented to:

- Resolve the placeholder `RUNNING_JOBS` entry by `(run_id, job_id)`.
- Populate pid + assign_id + assigned_resources (preload + any
  limiters).
- Register the pid in `RUN_PIDS` (kind=collector).
- Drop the matching `PENDING_SPAWN_REQUESTS` entry.

From this point on the job is indistinguishable from a direct-spawn
job for reaping, watchdog, and finalization purposes.

### 7.4 Process reset before goto::file

Port from `reference/legacy/` the full set of process-level resets
that a clean test child needs. Audit the legacy implementation when
writing the implementation plan; expected items include:

- `*main::DATA = *main::DATA{IO};` reset (so __DATA__ in the test file
  isn't shadowed by anything the preload pulled in)
- `$0 = $test_file_abs;`
- `FindBin::again()` — many test suites and their helpers use
  `FindBin::$Bin` to locate fixtures and lib paths relative to the
  test file. After `goto::file` the FindBin globals still reflect the
  preload service's `$0`; calling `again()` recomputes them against
  the new `$0`. If `FindBin` was loaded by the preload, call
  `FindBin::again` directly; if not yet loaded, the test's own
  `use FindBin` will compute the right values on first load and no
  reset is needed.
- Reset signal handlers to default
- Reset `$ENV{...}` per spawn payload
- Clear `@INC` mutations or restore original where the preload may
  have temporarily added paths
- Drop `__PACKAGE__` weirdness — the test runs as `main`
- Anything else legacy did

The plan's Stage 1 will inventory these and port them.

### 7.5 Watchdog interaction

`PENDING_SPAWN_REQUESTS` ages on each `run_on_interval` tick. If an
entry exceeds `preload_spawn_timeout_secs` (new constructor arg,
default 30s) without `test_job_started` arriving:

- Flip the preload resource to `is_broken` (transient).
- Drop the placeholder RUNNING_JOBS entry, release any committed
  resources, scheduler-mark the job pending again, drop the pending
  spawn entry.
- The job re-dispatches on the next scheduler tick; if the preload's
  restart cycle brings it back to ready, the spawn happens normally.

## 8. Reloader

### 8.1 Role contract — `Test2::Harness2::Role::Reloader`

```
requires 'do_reload';     # ($self, \@changed_files, $service)
requires 'watch_paths';   # ($self) returns arrayref of paths
sub debounce_secs { 0.25 }
sub before_reload { }
sub after_reload  { }
```

### 8.2 Common base — `Reloader/Common.pm`

- `_project_root()` — walks up from cwd looking for `.yath.rc*` or
  `.git`. Caches. The same logic `App::Yath2`'s rc-file discovery
  uses; the goal is "watch only files inside the user's project".
- `_filter_inc()` — snapshots `%INC` after preload init, drops anything
  not under `_project_root()`.
- `_attempt_in_place_reload($file)` — wrapped in `eval`:
  - File contains `# HARNESS-CHURN-START` / `# HARNESS-CHURN-STOP`
    markers → CHURN-section reload (port from legacy).
  - Package is Moose (has `Moose::Meta::Class` for it) → Moose-aware
    reload. Legacy's path was broken; rewrite fresh. The fresh path
    must:
    1. Snapshot the existing meta (attribute list, role list, parent
       classes, immutability flag) before invalidating.
    2. Reset/remove the metaclass (e.g.
       `Class::MOP::remove_metaclass_by_name`) so the re-require
       builds a new meta from scratch instead of merging into stale
       state.
    3. `delete $INC{$file}; require $file;` to recompile.
    4. After the new meta lands: re-apply any roles the file did not
       re-apply itself (compare snapshot vs. new role list);
       regenerate accessors and re-`make_immutable` if the original
       was immutable.
    5. Rebless tracked instances if the service is keeping any (the
       default service does not track instances; this is a hook for
       complex preloads).
  - Otherwise → `delete $INC{$file}; require $file;` and rebless any
    tracked instances.
  - On eval failure → see Section 8.4 (compile-error path).
- `_reload_or_restart($file)` — if `_attempt_in_place_reload` returns
  ok, done. If it raises a "restart needed" sentinel (e.g. structural
  change the strategy can't handle), call `request_restart`.
- `request_restart()` — sends `preload_restarting` IPC to harness,
  then `exec()`s the service binary with the same construction args
  (IPC::Manager's standard re-exec pattern; if not provided, custom).

### 8.3 Implementations

- **`Reloader::HiResStat`** — polls `stat()` on watch paths every N
  ms (configurable, default 250ms). Cheap; no kernel feature needed.
- **`Reloader::INotify`** — uses `Linux::Inotify2`. Croaks at
  construction time if the dep is missing. No fallback.

### 8.4 Compile-error path (the routine edit-save case)

When `_attempt_in_place_reload` `eval`s and the require/compile dies:

- Reloader sends `preload_broken` IPC to the harness with reason
  `reload_compile_error` and the failing file + error string.
- Harness flips the matching Resource::Preload to `is_broken`
  (transient).
- The service does NOT restart. The bad-but-still-loaded process
  state persists (the file's previous version is what's in the
  service's memory).
- Reloader keeps watching. On the next file change (the user fixing
  the typo), it retries the eval. On success it sends `preload_ready`
  → harness clears `is_broken`. Tests resume.
- Restart-spiral counter does NOT apply to this path (only to actual
  process crashes during initial load and to service exits). Compile
  errors during edit-save cycles are routine; tests that need the
  preload defer; the user fixes; the system resumes naturally.

### 8.5 Restart cycle (structural change)

When `_reload_or_restart` decides a restart is required:

1. Reloader sends `preload_restarting` IPC to harness.
2. Harness flips the matching Resource::Preload to `is_broken`
   (transient). Scheduler defers all jobs that resolve to this preload;
   `<no>`-fallback jobs unaffected.
3. Reloader `exec()`s the service with original args.
4. New process's BEGIN runs, do_preload runs, on success emits
   `service_started` + `preload_ready`.
5. Harness clears `is_broken` on receiving `preload_ready`.
6. If the new process's do_preload fails → resource stays `is_broken`,
   becomes `is_permanent_broken` after `max_restart_attempts` tries
   (existing role logic). Tests requiring this preload then route
   through `broken_resource_behavior`.

### 8.6 CLI

- `--reloader=mstat|inotify|none` (default `none` for `yath test`,
  configurable for `yath start`/`yath run` later).
- The flag becomes a `Resource::Preload` constructor arg propagated
  into the `PreloadService`.

## 9. CLI + commands

### 9.1 `yath test` — augment

- `-P Module` (repeatable).
  - Modules consuming `Test2::Harness2::Role::Preload` claim their
    own service named by the role's `name`.
  - Bare modules merge into the `default` preload service in CLI
    order.
- `--reloader=mstat|inotify|none`. Default `none`.
- Existing flags untouched.

### 9.2 `yath start` — new

- Daemonizes: forks twice, parent prints
  `started: pid=<n> workdir=<path>` plus the IPC bus address to the
  terminal then exits 0. Child becomes the harness service with no
  controlling terminal, no STDOUT/STDERR redirection beyond the
  harness's own logging.
- Accepts the same `-P`, `--reloader`, resource flags as `yath test`.
  Builds the harness, calls `start()`, runs the IPC service loop until
  `terminate` arrives.
- Workdir: explicit `--workdir=...` or autogenerate
  `~/.yath/run-<uuid>/`. Prints the chosen workdir on the start line
  so `yath run` can find it.
- Exits non-zero from the parent if global preload load fails before
  backgrounding (Section 4.1).

### 9.3 `yath run` — new

- Connects to a running harness via its workdir (or `--workdir=...`).
- **Auto-discovery when no `--workdir` and no env var**: scan the IPC
  dirs (`$TMPDIR`, `/dev/shm`) using
  `App::Yath2::Util::IPC::find_ipc_files` for files matching the
  current project + user signature (project name from
  `_project_root()` basename, user from `$<`/`getpwuid`). Liveness-
  check each candidate (the helper already does this). Sort survivors
  by start time, newest first.
  - 0 matches → "no harness found, run `yath start` first" with non-
    zero exit
  - 1 match → use it
  - >1 match → print the list (workdir + start time + pid) and:
    - `--latest` → use the newest by start time
    - `--workdir=<path>` → use that one
    - otherwise → exit with the listing as the error message and a
      hint about both flags
- **`--latest`** — explicit "use the most recently started harness for
  this project" shortcut even when no ambiguity exists; convenient in
  scripts.
- Sends `queue_test_run` over IPC with the file list (same payload
  `request_handler_queue_test_run` already accepts).
- Subscribes to `run_state_update` + the run's event stream from the
  harness.
- Renders progress + summary using the same renderer chain `yath test`
  uses (Driver + Summary).
- Per-run flags: `--reloader=...` (per-run reloader override; for now
  stored in the run spec but only honored when per-run preload
  services land in a follow-up implementation).
- Exits with the run's pass/fail aggregate.

### 9.4 Daemon invariants

- The harness daemon doesn't preload modules at queue time. Per-run
  preloads (future) are spawned on first job dispatch, as already
  designed.
- One harness per workdir. `yath start` refuses if the workdir already
  has a live harness pid.
- `yath stop` is out of scope for this plan; existing `terminate` IPC
  is the documented escape hatch for the duration.

## 10. Failure / error handling — consolidated table

| Event | Effect |
|---|---|
| Global preload module load fails | harness aborts startup with clear error; non-zero exit. `yath start` parent reports + exits non-zero before backgrounding. |
| Per-run preload module load fails | run hard-fails (every job marked failed via `_fail_run`); harness keeps running other runs; emit `run_completed` with all-fail aggregate. |
| Reload in-place compile error (eval fail) | reloader sends `preload_broken`; resource flips `is_broken` transient with reason `reload_compile_error`; service stays up; on next file change, retry eval; success → `preload_ready` clears `is_broken`. No restart-spiral counted. |
| Reload structural-change restart fails (new process load fail) | resource stays `is_broken`; restart-spiral counter trips after `max_restart_attempts` → `is_permanent_broken`; from then on tests requiring this preload route through `broken_resource_behavior`. |
| Spawn IPC dropped (no `test_job_started` in `preload_spawn_timeout_secs`) | resource flips `is_broken`; placeholder RUNNING_JOBS dropped, resources released, job re-dispatched on next tick; if persistently failing, restart-spiral applies. |
| Test crashes after spawn (the regular case) | unchanged — collector watchdog from Stage 6 of the flatten handles it. |
| Preload service crashes mid-run | `run_on_pid` sees the exit; role restart logic re-spawns; resource `is_broken` until ready. Spawn requests in flight time out and re-dispatch. |

## 11. Testing

- **Unit (new under `t/AI/`)**:
  - `Resource::Preload` slot semantics + state transitions
  - `Role::Preload` contract and required-method enforcement
  - `Role::Reloader` contract
  - `Reloader::HiResStat` change detection (synthetic mtime advance)
  - `Reloader::Common._project_root` discovery (with fixture trees)
  - `_resolve_preload_for_job` resolver matrix (every combination of
    `<default>`, `<no>`, named, missing, with and without per-run/
    global defaults, with broken/usable mixes)

- **Integration (new under `t/AI/integration/`)**:
  - `yath test -P SomeMod` end-to-end smoke
  - `HARNESS-PRELOAD` directive end-to-end (3-4 representative paths
    through the matrix)
  - Per-run preload startup + teardown (when per-run preloads land)
  - Reloader compile-error transient-broken cycle (write bad code,
    observe defer; fix code, observe resume)
  - Reloader structural-change restart cycle (touch a file, observe
    is_broken → is_usable transition, test still runs)
  - Failure cascades (global fail → harness abort; per-run fail →
    run hard-fail)
  - `yath start` daemonize + parent exit semantics
  - `yath run` discovery (0 / 1 / many harnesses present)

- **Ported from reference (under regular `t/`, NOT `t/AI/`)**:
  - Audit `reference/old2/t/` and `reference/legacy/t/` for
    preload-related integration tests.
  - Port them updating: drop stage references; collapse multi-stage
    chains to single preload; rewrite directive checks for the new
    `HARNESS-PRELOAD: ...` shape; rewire IPC assertions for the new
    bus names. Keep test intent + golden assertions intact.
  - These are human-authored work being preserved; they live in
    regular `t/` and run alongside the new AI-authored tests.

## 12. Implementation phasing

The plan to follow this design will sequence work as:

1. **Step 1 — Simple preload (`yath test -P`)**: `Resource::Preload`
   minimal; `PreloadService` minimal (no role); routing resolver;
   spawn IPC; process-reset port; integration smoke.
2. **Step 1.5 — `yath start` + `yath run`**: daemonize, IPC discovery,
   client renderer wiring. Needed for testing the rest of the
   subsystem at scale.
3. **Step 2 — Complex preload (role)**: `Role::Preload`; pre/post/pre-
   launch callbacks; custom `do_preload`; per-run preloads end-to-end.
4. **Step 3 — Reloader**: `Role::Reloader`; `Common`; HiResStat;
   INotify; CHURN port; restart cycle; compile-error transient path;
   CLI flag.

Each phase ends green on the full `t/AI/` suite plus any ported
tests under `t/`, with author tests on (`AUTHOR_TESTING=1`).

## 13. Out of scope (follow-ups)

- `yath stop` (use `terminate` IPC)
- Per-run reloader override (`yath run --reloader=...`) — stored in
  spec but unhonored until the per-run preload spawn lands
- Memory-aware preload scheduling (the Utilizer-style hint in the
  gemini doc) — defer
- Concurrent runs as a default (already a one-line follow-up to the
  RunService flatten; orthogonal)
