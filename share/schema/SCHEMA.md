# Test2::Harness2 — share/schema

Companion to the per-flavor SQL files in this directory:

- `sqlite.sql` — default backend; SQLite 3.45+.
- `postgres.sql` — PostgreSQL; uses native `UUID` / `JSONB` / `BYTEA`.
- `mysql.sql` — MySQL 8.0+ (older versions parse and ignore `CHECK`
  constraints; application enforces the same invariants). UUID
  columns are `BINARY(16)` with a `CHAR(36)` shadow populated by
  triggers.
- `mariadb.sql` — MariaDB 10.7+. Uses the native `UUID` type (added
  in 10.7, Feb 2022); no shadow column, no triggers.
- `percona.sql` — Percona Server (MySQL fork). Same UUID shape as
  `mysql.sql`.

All flavors carry the same set of tables and columns; type and constraint
syntax differ. A DDL change touches every flavor in the same commit.

## Type conventions

| Concept    | sqlite                  | postgres                | mariadb         | mysql / percona |
|------------|-------------------------|-------------------------|-----------------|-----------------|
| PK         | `INTEGER PRIMARY KEY AUTOINCREMENT` | `BIGSERIAL` | `BIGINT UNSIGNED AUTO_INCREMENT` | `BIGINT UNSIGNED AUTO_INCREMENT` |
| UUID       | `TEXT COLLATE BINARY`   | `UUID`                  | `UUID`          | `BINARY(16)` + `CHAR(36)` shadow populated by triggers |
| JSON       | `TEXT`                  | `JSONB`                 | `JSON`          | `JSON`          |
| Timestamp  | `REAL` (epoch seconds, hi-res) | `DOUBLE PRECISION` | `DOUBLE`     | `DOUBLE`        |
| Boolean    | `INTEGER` 0 / 1         | `BOOLEAN`               | `BOOLEAN`       | `BOOLEAN`       |
| Binary     | `BLOB`                  | `BYTEA`                 | `LONGBLOB`      | `LONGBLOB`      |

UUIDs are generated in Perl (v7) via `Test2::Util::UUID`. The database
never generates them. On MySQL and Percona a shadow
`<thing>_uuid_string` column is kept in sync by `BEFORE INSERT` /
`BEFORE UPDATE` triggers so human-readable UUIDs are always available
without an application write. PostgreSQL and MariaDB use the native
`UUID` type and need neither the shadow column nor the triggers.

Timestamps store fractional seconds since the epoch — the value
`Time::HiRes::time()` returns. No SQL defaults; the application stamps every
row.

## Tables

Each table has a surrogate integer primary key named `<table>_id`. Foreign
keys reference these.

### users
- `name` (unique) — login / display name.
- `email` — optional contact address (indexed).

### hosts
- `name` (unique) — system hostname running an instance.

### projects
- `name` (unique) — project the harness is collecting for.

### versions
- `project_id` → `projects`
- `version` — free-form released-version string (semver tag, tarball
  version, etc.). Used for runs against shipped releases.
- Unique on `(project_id, version)`.

### vcs_info
VCS context for runs done during development (no release tag). A run
may reference a `version_id`, a `vcs_info_id`, both, or neither.

- `project_id` → `projects`
- `branch` — caller-supplied branch / ref label.
- `revision` — caller-supplied sha / hash / rev string. VCS-agnostic.
- `dirty` — boolean; true when the working tree differed from the
  committed `revision` when the run was queued.
- Unique on `(project_id, branch, revision, dirty)` — clean and
  dirty rows for the same revision are distinct.
- `Test2::Harness2` does not auto-detect VCS context; the queueing
  tool (`yath`, CI, etc.) fills these fields.

`users`, `hosts`, `projects`, and `versions` are deduplicated by natural key.

### instances
One row per harness instance. In SQLite mode there is exactly one row per
database file.

- `instance_uuid` — v7 UUID.
- `host_id` / `user_id` — context.
- `started` / `finished` — lifecycle timestamps.
- `meta` — JSON catch-all for instance metadata.
- `finalized` — timestamp set once no further runs will be accepted.

### runners
- `instance_id` → `instances`
- `pid` — runner process pid.
- `started` / `finished` / `finalized` — lifecycle timestamps.

### collectors
One row per collector process.

- `runner_id` → `runners`
- `name` — unique per runner.
- `pid` — collector's own pid.
- `watched` — pid of the collected process (nullable until forked).
- `type` — `'service'`, `'test job'`, etc. (indexed).
- `start_time` / `stop_time` — collected-process lifecycle.
- `exit_code` — exit code of the collected process (nullable).
- `finalized` — timestamp the recorder finished its bookkeeping for this
  collector.

### artifacts
Files produced by collectors. Carries either inline bytes or a path on disk,
never both.

- `collector_id` → `collectors`
- `filename` — human label / on-disk basename.
- `content` — binary payload (nullable; recorder migrates `local_path`
  bytes into here on finalize).
- `local_path` — absolute path to the on-disk content (nullable).
- `CHECK ((content IS NULL) <> (local_path IS NULL))` — exactly one is
  non-null at any time.

### runs
- `run_uuid` — v7 UUID (unique).
- `runner_id` → `runners`
- `project_id` → `projects`
- `version_id` → `versions` (nullable; release context)
- `vcs_info_id` → `vcs_info` (nullable; dev context)
- `user_id` → `users`
- `run_ord` — integer ordering of runs under a runner. Unique on
  `(runner_id, run_ord)`.
- `started` / `finished` — lifecycle.
- `result` — boolean; true if all jobs passed.
- `passed` / `failed` — aggregate job counts.
- `meta` — JSON.
- `status` — `'pending'` / `'running'` / `'complete'` / `'broken'`
  / `'canceled'`. Scheduler reads `'canceled'` as the signal to stop
  dispatching new jobs and terminate in-flight ones.
- `has_coverage` — boolean; true when this run produced coverage
  rows. Pre-filter for coverage queries without a join.
- `has_resources` — boolean; same as has_coverage but for
  resource-sample rows.

### services
- `collector_id` → `collectors`
- `runner_id` → `runners`
- `run_id` → `runs` (nullable; null for runner-global services).
- `name` — unique per `(runner_id, run_id)` (e.g. `'scheduler'`).
- `class` — Perl class implementing the service.
- `pid` — service process pid. Populated by the service itself so other
  processes can `SIGUSR1` it to break its poll-loop sleep.

### service_state
Append-only state log; most recent row wins.

- `service_id` → `services`
- `stamp` — when the row was written (hi-res).
- `status` — `'starting'` / `'up'` / `'down'` / `'stopping'` /
  `'stopped'` / `'broken'`.
- `content` — JSON; service-managed publication of state (resource
  availability picture, etc.).

### requests
One row per request directed at a service. Unified shape for both
request / response and fire-and-forget notifications.

- `service_id` — addressee.
- `requested` — insertion timestamp.
- `completed` — set when the service finishes handling (nullable until
  done).
- `finalized` — set when the requester acknowledges (nullable; some
  requests are deleted on ack instead).
- `payload` — JSON request body.
- `response` — JSON response (nullable; fire-and-forget keeps null).

### test_files
- `project_id` → `projects`
- `relative` — path relative to project root.
- Unique on `(project_id, relative)`.

### jobs
- `run_id` → `runs`
- `test_file_id` → `test_files`
- `spec` — JSON launch spec (env, args, directives, retry policy, etc.).

### job_tries
- `job_id` → `jobs`
- `try_ord` — try number starting at 1. Unique on `(job_id, try_ord)`.
- `started` / `finished` — lifecycle.
- `collector_id` → `collectors` (nullable; set when the collector is
  assigned).
- `result` — boolean pass / fail.
- `passed` / `failed` — assertion counts.
- `subtests` / `subtests_passed` / `subtests_failed` — top-level subtest
  counts.
- `status` — same lifecycle enum as `runs.status`.

### launchers
- `runner_id` → `runners`
- `run_id` → `runs` (nullable; null for runner-global launchers).
- `collector_id` → `collectors`
- `name` — launcher's display name.
- `class` — Perl class.
- `spec` — JSON construction spec.
- `pid` — launcher pid (same `SIGUSR1` wake-up convention as services).
- `spawn_socket` — Unix socket path when the launcher supports `spawn`
  (nullable).

### launches
- `launcher_id` → `launchers`
- `job_id` → `jobs`
- `requested` — when the scheduler added the row.
- `started` — when the launcher started the process (nullable until
  started).

The `launches(launcher_id, started)` index is the one the launcher's poll
loop walks each tick: rows whose `started` is null and whose `launcher_id`
matches.

### coverage
Per-coverage-run snapshot keyed by source file. See `ARCHITECTURE.md`
§13.2 for the payload shape and the canonical queries.

- `run_id` → `runs` (`ON DELETE CASCADE`).
- `project_id` → `projects` (`ON DELETE CASCADE`) — denormalized for
  the project+source_file lookup index.
- `source_file` — covered file path.
- `stamp` — hi-res timestamp.
- `payload` — JSON. `subs`: map of sub-name → list of
  `"test_file[#subtest]"` strings. `file_level`: tests that touched the
  file but no specific sub. `meta`: producer info.
- Unique on `(run_id, source_file)`.

Most runs do not produce coverage. The harness writes coverage rows
only when a coverage-producing plugin (`Test2::Plugin::Cover` /
`Devel::Cover` driver / etc.) was active for the run. Each such run
writes a *complete* snapshot so the run remains useful on its own
even if other runs are pruned. No dedup across runs.

### resources
Per-sample telemetry rows. Resource events ship on the event stream
(`facet_data.resource`) when a producer plugin (CPU sampler, memory
sampler, custom resource) is active.

- `run_id` → `runs` (`ON DELETE CASCADE`).
- `type` — short identifier (`'cpu'`, `'memory'`, etc.).
- `stamp` — hi-res timestamp.
- `payload` — JSON; producer-defined shape.
- Indexed by `(run_id, type, stamp)` for sequential single-timeseries
  reads.

## Index strategy

Every foreign key has its own index. Read-time access patterns
(`runs → jobs → job_tries → artifacts` joins, scheduler walking the
unstarted-launches stripe, services querying their `service_state` history)
each get a covering index. Write-time cost is acceptable: events are written
as a single per-collector blob, so the row-write rate stays low and
batch-shaped.
