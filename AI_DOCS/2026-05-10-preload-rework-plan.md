# Preload Rework — Implementation Plan

> **For agentic workers:** Use TDD inside every task. Write the failing test first, run it to confirm failure mode, implement minimum code, run to PASS, commit. Each task ends with a green commit.

**Goal:** Replace the legacy preload subsystem with the service-per-preload model spec'd in `AI_DOCS/2026-05-10-preload-rework-design.md`. Add `yath start` + `yath run` so the new subsystem can be tested at scale, then layer in the role-based complex preloads and the reloader subsystem.

**Architecture:** Each preload is a long-lived `PreloadService` process holding pre-loaded modules; harness owns a `Resource::Preload` per preload via the existing `ResourceServiceHost` pattern. Test routing happens at scheduler-time via `_resolve_preload_for_job`. Spawn IPC is async; double-fork → `Long::Jump` → `goto::file` reaches the test. Reloader is opt-in via `Role::Reloader`.

**Tech Stack:** Perl 5; `Test2::V0` for tests; `Object::HashBase`; `Role::Tiny`; `IPC::Manager`; `Long::Jump`; `goto::file`. Optional dep `Linux::Inotify2` for INotify reloader.

**Testing harness:** `AUTHOR_TESTING=1 yath -D test -j16 t/AI/` after every commit. New AI tests under `t/AI/`; ported reference tests under regular `t/`.

---

## File map

### New files

```
lib/Test2/Harness2/
  Resource/Preload.pm                  Phase 1
  PreloadService.pm                    Phase 1
  Util/PreloadDirective.pm             Phase 1  (parser for HARNESS-PRELOAD: ...)
  Role/Preload.pm                      Phase 2
  Role/Reloader.pm                     Phase 3
  Reloader/Common.pm                   Phase 3
  Reloader/HiResStat.pm                Phase 3
  Reloader/INotify.pm                  Phase 3

lib/App/Yath2/
  Command/start.pm                     Phase 1.5
  Command/run.pm                       Phase 1.5
  Options/Preload.pm                   Phase 1   (new -P parsing + harness wiring)
  Options/Reloader.pm                  Phase 3   (--reloader=mstat|inotify|none)

t/AI/unit/Harness2/
  Resource/Preload.t                   Phase 1
  PreloadService.t                     Phase 1
  resolve_preload_for_job.t            Phase 1
  PreloadDirective.t                   Phase 1
  Role/Preload.t                       Phase 2
  Role/Reloader.t                      Phase 3
  Reloader/Common.t                    Phase 3
  Reloader/HiResStat.t                 Phase 3
  Reloader/INotify.t                   Phase 3 (Test2::Require::Module)

t/AI/integration/
  preload_default_smoke.t              Phase 1
  preload_directive_routing.t          Phase 1
  preload_per_run.t                    Phase 2
  preload_reloader_compile_error.t     Phase 3
  preload_reloader_restart.t           Phase 3
  global_preload_load_fail.t           Phase 1
  per_run_preload_load_fail.t          Phase 2
  yath_start_smoke.t                   Phase 1.5
  yath_run_discovery.t                 Phase 1.5
```

### Modified files

```
lib/Test2/Harness2.pm                  Phase 1, 1.5, 2 (resolver + dispatch path)
lib/Test2/Harness2/TestFile.pm         Phase 1 (parse HARNESS-PRELOAD: directive)
lib/Test2/Harness2/Run/Job.pm          Phase 1 (carry parsed preload list)
ARCHITECTURE.md                        Phase 4 (addendum or in-place edits)
```

### Ported (regular `t/`)

```
t/preload/                             Phase 2/3 — port from reference/old2/t/preload/
                                       and reference/legacy/t/, dropping stage chains.
                                       Audit + port as the relevant phase lands.
```

---

## Phase 1 — Simple preload (`yath test -P Module`)

End state: `yath test -P SomeMod t/foo.t` spawns a global `default` preload service that pre-loads `SomeMod`, the test runs as a grandchild of the harness with `SomeMod` already in `%INC`, all existing tests still green.

### Task 1.1: HARNESS-PRELOAD directive parser

**Files:**
- Create: `lib/Test2/Harness2/Util/PreloadDirective.pm`
- Create: `t/AI/unit/Harness2/PreloadDirective.t`

**Why first:** No code depends on the parser, but TestFile and the resolver both consume its output. Pure function; perfect TDD warm-up.

**TDD shape:**
1. Write `PreloadDirective.t` covering: empty input → `[<default>]`; bare names; `<no>` alone; `<default>` alone (terminal); `<default> <no>` normalizes to `<default>`; named + `<default>`; named + `<no>`; validation rejects `<no>` mid-list, `<default>` mid-list, names after `<no>` or `<default>`.
2. Run; expect "Can't locate Test2/Harness2/Util/PreloadDirective.pm".
3. Implement: single function `parse_preload_directive($string) → \@tokens` returning the normalized list. Croak with a useful message on validation failure.
4. Run; expect PASS.
5. Commit `feat(Harness2/Util): preload directive parser`.

### Task 1.2: TestFile reads HARNESS-PRELOAD

**Files:**
- Modify: `lib/Test2/Harness2/TestFile.pm` (add scan + accessor)
- Test: `t/AI/unit/Harness2/TestFile.t` (extend existing or new subtests)

**TDD shape:**
1. Write subtests on TestFile.t: a fixture file with `# HARNESS-PRELOAD: Foo Bar <default>` parses to `[Foo, Bar, <default>]`; missing directive parses to `[<default>]`; multiple directives → use last one (or croak — pick croak); the value is exposed via `$tf->preload_preferences` and ships through `TO_JSON`.
2. Run; FAIL (no method).
3. Implement: extend TestFile's existing directive scan to recognize `HARNESS-PRELOAD`, parse via `parse_preload_directive`, store on the TestFile, expose accessor + serialize.
4. Run; PASS.
5. Commit `feat(TestFile): scan HARNESS-PRELOAD directive`.

### Task 1.3: Job carries preload preferences

**Files:**
- Modify: `lib/Test2/Harness2/Run/Job.pm` (carry `preload_preferences` from TestFile)
- Test: `t/AI/unit/Harness2/Run.t` (or new file)

**TDD shape:** Job::from_test_file copies the preference list onto the Job; accessor exposed; preserved through `TO_JSON`/`rehydrate`.

Commit: `feat(Run::Job): carry preload preferences`.

### Task 1.4: Resource::Preload (skeleton)

**Files:**
- Create: `lib/Test2/Harness2/Resource/Preload.pm`
- Create: `t/AI/unit/Harness2/Resource/Preload.t`

**Why now:** Need the Resource type before the resolver can return one.

**TDD shape:**
1. Tests cover: constructor requires `name` + `modules`; `scope` defaults to `'global'`; `services()` returns one entry pointing at `PreloadService`; `available()` returns 1; `is_usable` reflects an attribute the host can set (initial 0); `is_permanent_broken` defaults 0; `mark_permanent_broken` flips it sticky (mark_unbroken absent). Slot accounting is no-op (`assign`/`release` return without env mutation).
2. Run; FAIL.
3. Implement minimal Resource consuming `Test2::Harness2::Role::Resource`. Skip `services()` returning a real class for now — return `[]` so unit tests don't try to spawn. Add a `_set_usable($bool)` and `_set_permanent_broken` hook the host can drive.
4. Run; PASS.
5. Commit `feat(Resource::Preload): skeleton with no service yet`.

### Task 1.5: PreloadService (minimal)

**Files:**
- Create: `lib/Test2/Harness2/PreloadService.pm`
- Create: `t/AI/unit/Harness2/PreloadService.t`

**TDD shape:** Test that the service consumes `Role::Service` + `Role::ResourceService`, requires `name` + `modules`, exposes `service_started_fields` carrying preload identity. Don't yet test the BEGIN/Long::Jump path (Task 1.7 exercises it integration-style).

Commit `feat(PreloadService): skeleton with role plumbing`.

### Task 1.6: Wire Resource::Preload `services()` to PreloadService

**Files:**
- Modify: `lib/Test2/Harness2/Resource/Preload.pm` (services returns the real class spec)
- Test: extend Resource/Preload.t

**TDD shape:** Test that `services()` returns `[[PreloadService, name => $name, modules => $modules, ...]]` shape. Don't fork yet — assert via deep-equal.

Commit `feat(Resource::Preload): wire service spec`.

### Task 1.7: PreloadService BEGIN + do_preload + ready emit

**Files:**
- Modify: `lib/Test2/Harness2/PreloadService.pm`
- Test: new integration `t/AI/integration/preload_default_smoke.t`

**TDD shape:**
1. Write integration test: spawn a Test2::Harness2 with `resources => [ Resource::Preload->new(name=>'default', modules=>['Time::HiRes']) ]`, run a single test that asserts `$INC{'Time/HiRes.pm'}` is set (it would be even without preload — pick something less universal; use a fixture module under `t/lib/`).
2. The test should FAIL today (Resource::Preload doesn't actually preload anything yet).
3. Implement PreloadService's main run loop:
   - BEGIN block sets a Long::Jump anchor.
   - After BEGIN exits, the service's `start()` body runs `do_preload` (require each module in order, croak on first failure).
   - On success: emit `preload_ready` IPC to harness (new event kind), enter `run` loop.
   - On `do_preload` failure: emit nothing, exit non-zero (host role's restart-spiral counter handles the rest, but for initial-load fail we want fast permanent_broken — see Task 1.10).
4. Run integration test; PASS.
5. Commit `feat(PreloadService): do_preload + preload_ready emit`.

### Task 1.8: Harness handles `preload_ready` + `preload_broken`

**Files:**
- Modify: `lib/Test2/Harness2.pm` (`run_on_general_message` dispatch; per-resource state flip)
- Test: `t/AI/unit/Harness2.t` (new subtest)

**TDD shape:** Send a `preload_ready` IPC carrying `preload_name` + `scope` + optional `run_id`; harness flips the matching Resource::Preload's `_usable` flag to 1. `preload_broken` flips it to 0 (transient). Sticky `permanent_broken` not cleared by `preload_ready`.

Commit `feat(Harness2): handle preload_ready/preload_broken IPC`.

### Task 1.9: `_resolve_preload_for_job` resolver

**Files:**
- Modify: `lib/Test2/Harness2.pm` (add resolver method)
- Create: `t/AI/unit/Harness2/resolve_preload_for_job.t`

**TDD shape:**
1. Test matrix: name match per-run > global; `<default>` resolves per-run-default first then global-default; `<no>` returns `(undef, 'no_preload')`; transient broken → `('defer')`; all permanent_broken → `('broken', $first_name)`; default determination rules from §6.2 of the design (single role-consumer in scope, anonymous-merged `default`).
2. Implement resolver. Pure-ish; takes the harness's resource list + run + job preferences.
3. Commit `feat(Harness2): _resolve_preload_for_job`.

### Task 1.10: Permanent-broken on initial-load failure

**Files:**
- Modify: `lib/Test2/Harness2.pm` (in `service_on_start`, after starting global resource services, await readiness for any Preload resource; on permanent_broken, croak with clear message)
- Test: `t/AI/integration/global_preload_load_fail.t`

**TDD shape:**
1. Test: build harness with `Resource::Preload->new(modules=>['No::Such::Module'])`; calling `start()` should die with a message naming the missing module + the preload name.
2. Implement the await-and-check. Use the existing `_await_run_exit`-style polling pattern. Service exit before `preload_ready` → role-side fail counter trips → resource flips permanent_broken.
3. Commit `feat(Harness2): hard-fail startup on global preload load error`.

### Task 1.11: Async spawn pathway `_spawn_via_preload`

**Files:**
- Modify: `lib/Test2/Harness2.pm` (route through `_resolve_preload_for_job` in `_launch_job`; new `_spawn_via_preload`; placeholder RUNNING_JOBS entry; PENDING_SPAWN_REQUESTS map)
- Modify: `lib/Test2/Harness2/PreloadService.pm` (`request_handler_spawn_test`: pre_fork → fork → post_fork → fork → _exit(0) → grandchild process reset → Long::Jump → goto::file)
- Test: extend `t/AI/integration/preload_default_smoke.t` (already in place from Task 1.7) to exercise the actual spawn

**TDD shape:**
1. The smoke test from 1.7 launches a real test through the preload — tighten its assertions: test child's $INC contains the preloaded module BEFORE the test's own `use` runs (write a BEGIN { print "INC=" . exists $INC{'Foo/Bar.pm'} } in the fixture and assert the captured output).
2. Implement spawn pathway in tandem on both sides. Critical: the grandchild's `_exit(0)` happens in the FIRST child after the SECOND fork; the grandchild's process reset (Section 7.4 of the design) runs before Long::Jump.
3. Watchdog: PENDING_SPAWN_REQUESTS aged in `run_on_interval`, timeout default 30s. New constructor arg `preload_spawn_timeout_secs`.
4. Run smoke; PASS.
5. Commit `feat(Harness2,PreloadService): async spawn pathway`.

### Task 1.12: Process reset port from legacy

**Files:**
- Modify: `lib/Test2/Harness2/PreloadService.pm` (the grandchild reset block)
- Reference: `reference/legacy/lib/Test2/Harness/Runner/Preloader.pm` and `reference/legacy/lib/Test2/Harness/Runner/Preloader/Stage.pm` — audit for every reset they perform
- Test: `t/AI/integration/preload_default_smoke.t` extended; new fixture tests verifying $0, FindBin::$Bin, *main::DATA, signal handlers all reset

**TDD shape:**
1. Write fixture tests under `t/AI/integration/` that exercise each reset concern. Each is one tiny test file with an assertion. Run them all under preload; assert each behaves as if forked from a fresh perl.
2. Audit the legacy reset list; port each one as a separate commit so the diff stays reviewable.
3. Commit `feat(PreloadService): port process reset from legacy` (one commit, since the resets are individually trivial but conceptually one feature).

### Task 1.13: `-P` CLI option (yath test)

**Files:**
- Create: `lib/App/Yath2/Options/Preload.pm`
- Modify: `lib/App/Yath2/Command/test.pm` (consume the new options)
- Test: extend `t/AI/integration/preload_default_smoke.t` to invoke via `yath -D test -P Foo::Bar t/AI/integration/_fixtures/...` end-to-end

**TDD shape:**
1. The CLI integration test: spawn `yath -D test -P Time::HiRes <fixture>` via `IPC::Open3`, capture exit + stderr; assert pass.
2. Implement options module with repeatable `-P / --preload Module` accumulator; build a Resource::Preload with `name=>'default', modules=>\@cli_modules` IF any modules were provided; inject into harness's resources.
3. Modules consuming `Role::Preload` (Phase 2) get carved out into named preloads — for Phase 1 just dump everything into `default`. Add a TODO comment naming the Phase 2 follow-up.
4. Commit `feat(Yath2): -P flag for yath test`.

### Task 1.14: Phase 1 regression

**Files:** none (run-only)

**Steps:**
1. Run `AUTHOR_TESTING=1 yath -D test -j16 t/AI/`. Expect PASSED, file count = baseline + new tests.
2. Run a manual smoke: pick a real test from `t/AI/`, run it both with and without `-P Time::HiRes`, confirm both pass.
3. If green, commit nothing (no changes). Move to Phase 1.5.
4. If anything regressed, fix in place. Each fix = its own commit.

---

## Phase 1.5 — `yath start` + `yath run`

End state: `yath start` daemonizes a harness, `yath run t/...` connects to it (auto-discovered), runs, prints summary, exits with the run's pass/fail aggregate.

### Task 1.5.1: yath start command

**Files:**
- Create: `lib/App/Yath2/Command/start.pm`
- Test: `t/AI/integration/yath_start_smoke.t`

**TDD shape:**
1. Test: invoke `yath -D start --workdir=/tmp/...` via IPC::Open3, capture parent stdout. Assert: parent prints `started: pid=N workdir=...`, exits 0; child harness pid is alive; IPC bus file present in workdir.
2. Implement: parse args same as `yath test` (resources + preload). Construct harness. Fork twice, close STDIN/STDOUT/STDERR in the daemon child after the parent has the pid + workdir info. Parent prints + exits 0.
3. Hard-fail handling: if harness construction (which now triggers global preload startup) dies, parent exits non-zero with the error; daemon never starts.
4. Send TERM to clean up.
5. Commit `feat(Yath2): yath start command`.

### Task 1.5.2: yath run command (workdir-explicit)

**Files:**
- Create: `lib/App/Yath2/Command/run.pm`
- Test: extend yath_start_smoke.t with a `yath run --workdir=...` invocation

**TDD shape:**
1. Smoke: start a daemon, invoke `yath run --workdir=$wd t/AI/integration/_fixtures/ok.t`, assert exit 0 and pass count from stdout.
2. Implement: connect IPC handle to workdir's bus, send `queue_test_run`, subscribe to the run, render via the existing Driver+Summary chain, exit with aggregate.
3. Commit `feat(Yath2): yath run command (explicit workdir)`.

### Task 1.5.3: yath run auto-discovery

**Files:**
- Modify: `lib/App/Yath2/Command/run.pm` (add discovery path)
- Test: `t/AI/integration/yath_run_discovery.t`

**TDD shape:**
1. Test: start harness, invoke `yath run` with no flags from a cwd that resolves to the same project root, assert connection succeeds. Then start a second harness in a different workdir, invoke `yath run` again — assert it errors listing both. Then invoke `yath run --latest` — assert it picks the newest.
2. Implement: project-root walk (`.yath.rc*` or `.git`), call `App::Yath2::Util::IPC::find_ipc_files` filtered by project + user, sort by start time; 0/1/many handling per design §9.3.
3. Commit `feat(Yath2): yath run auto-discovery + --latest`.

### Task 1.5.4: Phase 1.5 regression

Same as 1.14: run full suite, fix any regressions, no-op commit if green.

---

## Phase 2 — Complex preload (Role::Preload)

End state: A module consuming `Test2::Harness2::Role::Preload` becomes its own named preload service with pre_fork / post_fork / pre_launch hooks and a custom `do_preload` entry. Per-run preloads work end-to-end.

### Task 2.1: Role::Preload contract

**Files:**
- Create: `lib/Test2/Harness2/Role/Preload.pm`
- Create: `t/AI/unit/Harness2/Role/Preload.t`

**TDD shape:** Role requires `name` (class method), `modules` (instance/class method, optional if `do_preload` provided), and provides defaults for `pre_fork`, `post_fork`, `pre_launch`, `do_preload`. Tests assert the default `do_preload` matches Phase 1 behavior (sequential require).

Commit `feat(Role::Preload): role contract`.

### Task 2.2: -P module classification

**Files:**
- Modify: `lib/App/Yath2/Options/Preload.pm` (split `-P` modules: role-consumers → own named preload, others → `default`)
- Test: extend Phase 1 CLI integration test

**TDD shape:** Write a fixture role-consumer module; pass `-P FooNonRole -P BarRoleConsumer`; assert two Resource::Preloads created, named `default` (with FooNonRole) and `Bar` (with BarRoleConsumer per its `name` method).

Commit `feat(Yath2): -P role-consumer split`.

### Task 2.3: PreloadService honors role hooks

**Files:**
- Modify: `lib/Test2/Harness2/PreloadService.pm`
- Test: `t/AI/integration/preload_role_hooks.t`

**TDD shape:** Fixture role-consumer that records calls via a temp file; assert pre_fork called once per spawn in service process, post_fork called in first child, pre_launch called in grandchild, in that order, before goto::file.

Commit `feat(PreloadService): honor role hooks`.

### Task 2.4: Per-run preloads end-to-end

**Files:**
- Modify: `lib/Test2/Harness2.pm` (`_ensure_run_service_started` already spawns per-run resource services; verify Resource::Preload included automatically via the run's `resources` list)
- Modify: `lib/Test2/Harness2/Run.pm` (accept `resources` arg with Resource::Preload entries)
- Test: `t/AI/integration/preload_per_run.t`, `t/AI/integration/per_run_preload_load_fail.t`

**TDD shape:**
1. Per-run preload smoke: a Run constructed with one Resource::Preload spawns the service when scheduler dispatches its first job; tests using the per-run preload land on it; tests using `<default>` land on the per-run one (since per-run-default rule applies); harness shutdown TERMs the per-run service.
2. Per-run preload load fail: bad module → run hard-fails (every job marked failed), harness keeps running.
3. Implement `_fail_run($run, $reason)` helper that synthesizes test_job_completed (pass=0, synth=1) for every pending+running job in the run and finalizes.
4. Commit `feat(Harness2): per-run preload end-to-end + _fail_run helper`.

### Task 2.5: Port reference preload tests

**Files:**
- Create: `t/preload/` directory with ports
- Reference: `reference/old2/t/preload/`, `reference/legacy/t/`

**Steps:**
1. Audit reference test files; list each + its intent.
2. Port one at a time, dropping stage references, rewriting directives to `HARNESS-PRELOAD: ...`. One commit per ported test.
3. Run each ported test; PASS or skip with explicit reason.

### Task 2.6: Phase 2 regression

Same shape as 1.14.

---

## Phase 3 — Reloader

End state: `--reloader=mstat|inotify|none` flag wires a reloader into preload services; file changes under project root trigger reload; compile errors flip the resource transient broken until fixed; structural changes restart the service.

### Task 3.1: Role::Reloader contract

**Files:**
- Create: `lib/Test2/Harness2/Role/Reloader.pm`
- Create: `t/AI/unit/Harness2/Role/Reloader.t`

**TDD shape:** requires `do_reload` + `watch_paths`; provides `debounce_secs`, `before_reload`, `after_reload` defaults.

Commit.

### Task 3.2: Reloader::Common

**Files:**
- Create: `lib/Test2/Harness2/Reloader/Common.pm`
- Create: `t/AI/unit/Harness2/Reloader/Common.t`

**TDD shape:**
1. `_project_root()` walks up from cwd looking for `.yath.rc*` or `.git`; tests use temp tree fixtures.
2. `_filter_inc()` filters %INC by project root.
3. `_attempt_in_place_reload($file)` happy path: simple module, `delete $INC{$file}; require $file;` succeeds.
4. `_attempt_in_place_reload($file)` Moose path: snapshot meta, reset_meta, recompile, re-apply roles (test fixture has a Moose class with one role + one attribute; modify file to add an attribute; reload; assert new accessor exists; assert old instances behave correctly).
5. `_attempt_in_place_reload($file)` compile error: returns false + sets last error; does not throw.
6. `request_restart()` sends `preload_restarting` IPC + `exec()`s. Test via mock IPC client + a stubbed exec.
7. Implement.
8. Commit `feat(Reloader::Common): shared base class`.

### Task 3.3: Reloader::HiResStat

**Files:**
- Create: `lib/Test2/Harness2/Reloader/HiResStat.pm`
- Create: `t/AI/unit/Harness2/Reloader/HiResStat.t`

**TDD shape:** poll watch paths every N ms (default 250ms); on mtime change, call `_attempt_in_place_reload`; respect debounce.

Commit `feat(Reloader::HiResStat)`.

### Task 3.4: Reloader::INotify

**Files:**
- Create: `lib/Test2/Harness2/Reloader/INotify.pm`
- Create: `t/AI/unit/Harness2/Reloader/INotify.t` (gated `Test2::Require::Module 'Linux::Inotify2'`)

**TDD shape:** croak at construction if `Linux::Inotify2` missing; on file change event, call `_attempt_in_place_reload`.

Commit `feat(Reloader::INotify)`.

### Task 3.5: PreloadService runs reloader

**Files:**
- Modify: `lib/Test2/Harness2/PreloadService.pm` (instantiate reloader after `do_preload`; drive its tick from the service `run_on_interval` hook)
- Test: `t/AI/integration/preload_reloader_compile_error.t`, `t/AI/integration/preload_reloader_restart.t`

**TDD shape:**
1. Compile-error test: write a fixture module under a temp project root; preload it; corrupt it (introduce a syntax error); send a synthetic file-change tick; assert `preload_broken` IPC sent + resource flipped is_broken; tests dispatched in this window with `<no>` fallback succeed; tests requiring this preload defer; fix the file; assert `preload_ready` clears is_broken.
2. Restart test: structural change (e.g. `_attempt_in_place_reload` declines); assert `preload_restarting` sent; service exec()s; new process emits service_started + preload_ready; harness clears is_broken.
3. Commit `feat(PreloadService): reloader integration`.

### Task 3.6: --reloader CLI option

**Files:**
- Create: `lib/App/Yath2/Options/Reloader.pm`
- Modify: `lib/App/Yath2/Command/test.pm`, `lib/App/Yath2/Command/start.pm`, `lib/App/Yath2/Command/run.pm`
- Test: extend reloader integration tests to invoke via CLI

**TDD shape:** flag value enum (mstat|inotify|none); none = no reloader; default `none` for `yath test`, propagates into Resource::Preload constructor → PreloadService.

Commit `feat(Yath2): --reloader CLI option`.

### Task 3.7: CHURN directive port

**Files:**
- Modify: `lib/Test2/Harness2/Reloader/Common.pm` (add CHURN parser + reload strategy)
- Test: `t/AI/unit/Harness2/Reloader/Common.t` extended

**TDD shape:** Parse `# HARNESS-CHURN-START` / `# HARNESS-CHURN-STOP` markers; on reload, only re-eval the CHURN sections (so module-level state survives).

Commit `feat(Reloader::Common): CHURN section reload`.

### Task 3.8: Port reference reload tests

Same shape as 2.5 but for reload tests under `reference/legacy/`.

### Task 3.9: Phase 3 regression

Same as 1.14.

---

## Phase 4 — Docs + cleanup

### Task 4.1: ARCHITECTURE.md addendum

Append a "Preload subsystem (2026-05-XX)" section describing the final architecture: module map, lifecycle, IPC kinds (`preload_ready`, `preload_broken`, `preload_restarting`, `spawn_test`), routing semantics, reloader semantics. Per CLAUDE.md the addendum form is sufficient until a full spec rewrite touches the affected sections.

Commit.

### Task 4.2: STYLE_GUIDE / CLAUDE.md if needed

If any new patterns emerged (e.g. async-IPC + placeholder RUNNING_JOBS handling) that future contributors need to follow, capture in STYLE_GUIDE.md. Skip if nothing rises to that level.

Commit only if changes.

### Task 4.3: Final author-test sweep

Run `AUTHOR_TESTING=1 yath -D test -j16 t/` (full suite, including ported tests under `t/preload/`). All green is the merge gate.

---

## Cross-cutting risks (read once before any phase)

1. **Auditor IPC routing**. After flatten Stage 4 the auditor sends test_job_* + job_release to the harness. Preload-spawned collectors use the same Collector class with the same `ipc_run`/`ipc_harness` args, so this Just Works. Verify in Task 1.11 by asserting events arrive at harness.

2. **Process reset completeness**. Missing one reset (e.g. `$0` or `*main::DATA`) makes some tests fail in subtle ways (wrong test name in output, __DATA__ missing). Task 1.12's audit must be thorough; the integration fixtures from that task are the regression net.

3. **Sticky permanent_broken across scopes**. Per design §5; mirror flatten plan's risk #11. Task 1.4's tests pin the stickiness; Task 2.4's tests pin the cross-scope rule (per-run preload_ready does not clear a global preload's permanent_broken).

4. **Long::Jump + goto::file interaction**. Both modules touch the perl stack at low level. The legacy implementation has working examples; Task 1.7 / 1.11 must port the call-site shape carefully. If Long::Jump ever fails, the test child crashes obscurely; add explicit error handling around the longjump call.

5. **Reload on unsaved file (editor temp file)**. Many editors write to `foo.pm.swp` then rename. The Inotify watcher will fire on directory events; HiResStat polls files directly. Common's reload path must handle ENOENT gracefully (wait for the rename to complete) — Task 3.2's tests cover this.

6. **`yath run` discovery vs. multi-user systems**. `find_ipc_files` filters by user already; Task 1.5.3 verifies. On shared `/tmp` filesystems with permissive umasks, double-check no info leaks.

7. **Reload cycle test flakiness**. Filesystem mtime resolution + scheduler ticks make the reloader integration tests inherently racy. Use `Time::HiRes::sleep`, not `sleep`. Use generous deadlines (5-10s) with assertion polling, not single-shot waits. Tests that flake go under `Test2::Require::AuthorTesting` and grow a comment naming the race.

---

## Self-review

**Spec coverage:**
- Architecture (§3) → covered by file map + Phase 1 tasks.
- Lifecycle (§4) → Tasks 1.7, 1.10, 1.8, 2.4.
- Resource semantics (§5) → Tasks 1.4, 1.8.
- Routing (§6) → Tasks 1.1, 1.2, 1.3, 1.9.
- Spawn pathway (§7) → Tasks 1.11, 1.12.
- Reloader (§8) → Phase 3 in full.
- CLI (§9) → Tasks 1.13, 1.5.1, 1.5.2, 1.5.3.
- Failure table (§10) → integration tests in 1.10, 2.4, 3.5.
- Testing (§11) → present in every task; ported reference tests in 2.5, 3.8.
- Phasing (§12) → matches.
- Out of scope (§13) → not in plan, correct.

**Placeholder scan:** No "TBD" or "implement later". Tasks 1.12 and 2.5/3.8 are explicit "audit and port" tasks rather than line-by-line scripts; the audit step is the work and the deliverable is "ported tests pass". Acceptable.

**Type consistency:** `_resolve_preload_for_job` return shapes consistent across §6.3 of the design and Task 1.9 tests. `preload_ready` / `preload_broken` / `preload_restarting` IPC kinds consistent across Tasks 1.7, 1.8, 3.5. `Resource::Preload` constructor args (`name`, `modules`, `scope`, `run`, `is_role_consumer`, `default_for_scope`, `_usable`, `_permanent_broken`) consistent.
