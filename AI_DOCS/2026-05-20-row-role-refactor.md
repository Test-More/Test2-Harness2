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
  role.
- It `requires` `TABLE`, `PRIMARY_KEY`, `COLUMNS`. It provides
  `save`, `refresh`, `TO_JSON`, and a default `JSON_COLUMNS` of `()`.
- Consumers continue to use `Object::HashBase` for storage and
  compose the role via `use Role::Tiny::With; with 'Test2::Harness2::Role::Row';`
  — `Object::HashBase` and `Role::Tiny` compose per
  `ARCHITECTURE.md` and `AGENTS.md`.

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
| `resources` | `Row::Resources` | `Runner::Run::Resource` | `lib/Test2/Harness2/Runner/Run/Resource.pm` |
| `launchers` | `Row::Launchers` | `Launcher` | `lib/Test2/Harness2/Launcher.pm` |
| `launches` | `Row::Launches` | `Launcher::Launch` | `lib/Test2/Harness2/Launcher/Launch.pm` |

The `Test2::Harness2` handle's `_row_class` helper now uses this map
directly instead of synthesising a class name from the table name.

## Replay checklist for a downstream branch

1. Rebase onto the stage-5 tip that carries this commit.
2. Resolve conflicts mechanically using the map above:
   * Any `Test2::Harness2::Row::Foos` reference becomes the new
     class name; check the map.
   * `use parent 'Test2::Harness2::Row';` becomes
     `use Role::Tiny::With; with 'Test2::Harness2::Role::Row';`.
   * `package Test2::Harness2::Row::Foos;` becomes the new package.
3. Touch every call site: tests, services, anything that hard-codes
   a row class name.
4. `prove -Ilib -j16 -r t/` to confirm the rebase landed cleanly.

## Session-tracking note

The `feedback` file at the repo root is untracked. It is left in
place as the input record for this refactor. Once the refactor lands,
the file can be deleted; this AI doc replaces it as the durable
record.
