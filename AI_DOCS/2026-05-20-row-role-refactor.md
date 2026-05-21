# 2026-05-20 — Row role refactor + namespace reshuffle

## Trigger

Untracked `feedback` file at repo root captured a stage-5 review pass:

1. Turn `Test2::Harness2::Row` (base class) into a role at
   `Test2::Harness2::Role::Row`.
2. Drop the `s` plural from per-row classes — one row is not plural.
3. Move tables that are children of other tables into nested
   namespaces.
4. Drop the `Row` middle namespace entirely.

This document records the exact decisions, the full table → class
map, and the rules downstream branches need to replay.

## Why this matters for downstream work

When this commit lands on stage 5, the worktrees already started for
stages 6 / 7 / 8 (`worktrees/stage6-dsn`, `worktrees/stage7-launchers`,
`worktrees/stage8-scheduler`) need to rebase on top of it and apply
the same renames to anything they have introduced that touches a row
class. The map below is the authoritative reference for that.

## Role conversion

- `lib/Test2/Harness2/Row.pm` is **removed**.
- `lib/Test2/Harness2/Role/Row.pm` is added. It is a `Role::Tiny`
  role that itself uses `Object::HashBase` to declare its
  `+_handle` slot.
- It `requires` `TABLE`, `PRIMARY_KEY`, `COLUMNS`. It provides
  `save`, `refresh`, `TO_JSON`, and a default `JSON_COLUMNS` of `()`.
- Consumers compose the role via `Object::HashBase`'s `&` role
  prefix (introduced in HashBase 0.016), which eagerly copies the
  role's constants (notably `_HANDLE`) into the consumer at compile
  time and defers `Role::Tiny->apply_roles_to_package` until end of
  compile scope:

      package Test2::Harness2::User;
      use Object::HashBase qw{
          &Test2::Harness2::Role::Row
          <user_id <name <email
      };

  This is the canonical way to compose `Object::HashBase` and
  `Role::Tiny` together per the `AGENTS.md` "compose" rule. Do not
  write `use Role::Tiny::With; with '...';` separately — the `&`
  prefix replaces both that line *and* the redundant `+_handle`
  declaration on each consumer.

- Subclasses use `Object::HashBase`'s `@` parent prefix instead of
  `use parent`:

      package Test2::Harness2::Runner::Run::Resource;
      use Object::HashBase qw{
          @Test2::Harness2::Runner::Resource
      };

## Naming rules applied

- Drop `s` from per-row class names (one row = one entity, not
  plural).
- Drop the `Row::` namespace segment entirely; the role lives under
  `Role::Row` and rows are first-class classes under
  `Test2::Harness2::*`.
- A table with a foreign key to another table is nested under that
  parent's class namespace.
- When a child has multiple parents (e.g. `services.runner_id` and
  `services.collector_id`), pick the longest-lived owning ancestor
  (here: `Runner`).

### Explicit deviations from the feedback file

| feedback line | Final decision | Why |
| --- | --- | --- |
| `Versions.pm` (kept plural) | `Project/Version.pm` | Apply the "drop s" rule consistently. Feedback line read as a typo. |
| `Resources.pm` → `Runner/Resource.pm` | `Runner/Run/Resource.pm` | `resources` table FK is `run_id`; it captures per-run snapshots, so it nests under `Run`, not directly under `Runner`. Matches `Coverage` placement. |
| (not in feedback) | `Services.pm` → `Runner/Service.pm` | `services.runner_id` is the long-lived owner. Was top-level in feedback; nested per agreement. |
| (not in feedback) | `Jobs.pm` → `Runner/Run/Job.pm` | `jobs.run_id`; matches the `Coverage`/`Resource`/`Artifact` pattern. Was top-level in feedback; nested per agreement. |
| (not in feedback) | `JobTries.pm` → `Runner/Run/Job/Try.pm` | follows the `Job` move. |
| (not in feedback) | `ServiceState.pm` → `Runner/Service/State.pm` | follows the `Service` move. |
| (not in feedback) | `Requests.pm` → `Runner/Service/Request.pm` | follows the `Service` move. |

`Launcher.pm` stayed top-level even though `launchers.runner_id`
exists — feedback put it there and the question of whether to nest
it was not raised. If a later pass wants `Runner/Launcher.pm`, this
is the natural place to revisit.

`Artifact.pm` is `Runner/Run/Artifact.pm` per feedback, even though
the direct FK is `artifacts.collector_id` (collector → runner).
Artifacts are conceptually run output; the deeper nesting under
`Runner/Collector/Artifact` was not requested.

## Full table → class map

| Table | Old class | New class | New path |
| --- | --- | --- | --- |
| `users` | `Row::Users` | `User` | `lib/Test2/Harness2/User.pm` |
| `hosts` | `Row::Hosts` | `Host` | `lib/Test2/Harness2/Host.pm` |
| `projects` | `Row::Projects` | `Project` | `lib/Test2/Harness2/Project.pm` |
| `versions` | `Row::Versions` | `Project::Version` | `lib/Test2/Harness2/Project/Version.pm` |
| `vcs_info` | `Row::VcsInfo` | `Project::VcsInfo` | `lib/Test2/Harness2/Project/VcsInfo.pm` |
| `test_files` | `Row::TestFiles` | `Project::TestFile` | `lib/Test2/Harness2/Project/TestFile.pm` |
| `instances` | `Row::Instances` | `Instance` | `lib/Test2/Harness2/Instance.pm` |
| `runners` | `Row::Runners` | `Runner` | `lib/Test2/Harness2/Runner.pm` |
| `collectors` | `Row::Collectors` | `Runner::Collector` | `lib/Test2/Harness2/Runner/Collector.pm` |
| `services` | `Row::Services` | `Runner::Service` | `lib/Test2/Harness2/Runner/Service.pm` |
| `service_state` | `Row::ServiceState` | `Runner::Service::State` | `lib/Test2/Harness2/Runner/Service/State.pm` |
| `requests` | `Row::Requests` | `Runner::Service::Request` | `lib/Test2/Harness2/Runner/Service/Request.pm` |
| `runs` | `Row::Runs` | `Runner::Run` | `lib/Test2/Harness2/Runner/Run.pm` |
| `jobs` | `Row::Jobs` | `Runner::Run::Job` | `lib/Test2/Harness2/Runner/Run/Job.pm` |
| `job_tries` | `Row::JobTries` | `Runner::Run::Job::Try` | `lib/Test2/Harness2/Runner/Run/Job/Try.pm` |
| `artifacts` | `Row::Artifacts` | `Runner::Run::Artifact` | `lib/Test2/Harness2/Runner/Run/Artifact.pm` |
| `coverage` | `Row::Coverage` | `Runner::Run::Coverage` | `lib/Test2/Harness2/Runner/Run/Coverage.pm` |
| `schedulers` | *(new)* | `Runner::Scheduler` | `lib/Test2/Harness2/Runner/Scheduler.pm` |
| `resources` (spec) | `Row::Resources` *(was snapshot table; repurposed)* | `Runner::Resource` (+ `Runner::Run::Resource` subclass via `class_for_row`) | `lib/Test2/Harness2/Runner/Resource.pm` / `lib/Test2/Harness2/Runner/Run/Resource.pm` |
| `resource_snapshots` *(new; renamed from old `resources`)* | — | `Runner::Resource::Snapshot` | `lib/Test2/Harness2/Runner/Resource/Snapshot.pm` |
| `launchers` | `Row::Launchers` | `Launcher` | `lib/Test2/Harness2/Launcher.pm` |
| `launches` | `Row::Launches` | `Launcher::Launch` | `lib/Test2/Harness2/Launcher/Launch.pm` |

The `Test2::Harness2` handle's `_row_class` helper now uses this map
directly instead of synthesising a class name from the table name.

## Replay checklist for a downstream branch

1. Rebase onto the stage-5 tip that carries this commit.
2. Resolve conflicts mechanically using the map above:
   * Any `Test2::Harness2::Row::Foos` reference becomes the new
     class name; check the map.
   * `use parent 'Test2::Harness2::Row';` becomes an
     `Object::HashBase` `&` role import:
     `use Object::HashBase qw{ &Test2::Harness2::Role::Row ... };`
     (drop the separate `+_handle` line — the role declares it).
   * `package Test2::Harness2::Row::Foos;` becomes the new package.
3. Touch every call site: tests, services, anything that hard-codes
   a row class name.
4. `prove -Ilib -j16 -r t/` to confirm the rebase landed cleanly.

## Addendum: schedulers, resources spec/snapshot split

Captured during the same session after the rename refactor landed.
Schema-side work that should have happened in stage 4; bundled here
because stage 5 was already touching the schema + row layer.

### Schema changes

- Old `resources` table (per-sample telemetry: `run_id, type, stamp,
  payload`) renamed and reshaped:
  - Renamed to `resource_snapshots`.
  - `type` column dropped (snapshots inherit the type from their
    parent resource's `class`).
  - `run_id` dropped (reachable via `resource_id` -> `resources`).
  - New columns: `resource_snapshot_id` PK, `resource_id` FK to
    `resources`, `stamp`, `payload` (unchanged).
- New `resources` table now holds resource *specifications*, not
  samples:
  - `resource_id` PK, `runner_id` FK (required), `run_id` FK
    (nullable), `class` (text, the Perl implementation class), `spec`
    (JSON).
  - No uniqueness constraint; caller manages.
  - Indexes on `runner_id` and `run_id`.
- New `schedulers` table — one row per runner.
  - `scheduler_id` PK, `runner_id` FK UNIQUE, `class`, `spec` (JSON).
- `runs.has_resources` keeps its name; semantics shifted from "has
  resource-sample rows" to "has `resource_snapshots` rows for this
  run" (joined via `resources`). Same intent, new target table.

### Row-class dispatch

The `resources` table backs two classes that differ only in identity:

- `Test2::Harness2::Runner::Resource` — runner-global (`run_id` NULL).
- `Test2::Harness2::Runner::Run::Resource` — run-scoped (`run_id`
  set). Subclass of the base; no new columns.

Dispatch is centralised on the base class:

    sub class_for_row {
        my ($class, $row) = @_;
        return defined($row->{run_id})
            ? 'Test2::Harness2::Runner::Run::Resource'
            : 'Test2::Harness2::Runner::Resource';
    }

`Role::Row` provides a default `class_for_row` that returns the
invocant class. `Test2::Harness2`'s `fetch_all` and `insert` consult
`$class->class_for_row(\%data)` for every row and bless into the
returned class. Existing consumers (`User`, `Host`, ...) see no
behavior change because the default is identity.

Snapshots live as a flat class
(`Test2::Harness2::Runner::Resource::Snapshot`); no subclass split.

### Side effects worth knowing

- `Runner::Run` `init` now also defaults `passed`/`failed` to 0
  (schema `NOT NULL DEFAULT 0` — the insert path doesn't drop unset
  columns, so the row must supply them).
- `Runner::Run::Job::Try` `init` does the same for `passed`,
  `failed`, `subtests`, `subtests_passed`, `subtests_failed`.

### Replay note for downstream branches

If a downstream branch (stage6/7/8) already touched the old
`resources` table (snapshot-flavor) it needs to be rewritten against
this layout:

- Insert into `resources` for the spec row, then insert into
  `resource_snapshots` for each sample, referencing
  `resource_id`.
- Drop any reference to the old `resources.type` / `resources.run_id`
  columns directly on snapshot rows.

## Session-tracking note

The `feedback` file at the repo root is untracked. It is left in
place as the input record for this refactor. Once the refactor lands,
the file can be deleted; this AI doc replaces it as the durable
record.
