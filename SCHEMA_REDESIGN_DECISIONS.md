# Schema redesign — captured decisions

Conversation worktree: `new_log_refactor`. Drives the next phase of work
extending the close-out commits already landed.

## Goal

Eliminate redundancy between `spec.jsonl` / `report.jsonl` artifacts and
the typed columns on runs/jobs/job_tries/services. Promote spec/report
content fully into typed columns + `*_extras` JSON catch-alls. Drop
`spec` / `report` artifact rows from DB-backed archives. Reconstruct
spec/report on demand from tables. Add multi-archive / multi-project
support via new `projects`, `test_files`, `job_specs`, `service_lifetimes`
tables. Apply across all four DB flavors (sqlite, postgres, mariadb,
mysql). Keep events.jsonl.zst as artifact bytes (no events table).

Non-goals: migration tools, in-flight schema upgrades. Refusal to read
older archives is sufficient — manual tools handle migration later.

## Top-level decisions

### D1. Service multi-row support

Services may restart. Each restart writes a new `report.jsonl` row and
potentially a fresh `spec.jsonl` row. Schema: introduce
`service_lifetimes` child of `services`; both spec and report data live
on `service_lifetimes` (one row per start/end cycle). `services` table
holds only identity (`name`, `role`, `run_id`).

### D2. `*_extras` JSON catch-all columns

Every entity table that previously stored full spec/report row JSON
(`runs`, `job_specs`, `job_tries`, `service_lifetimes`) gets one or two
JSON BLOB columns (`spec_extras` and/or `state_extras`) holding any
producer-emitted keys not promoted to a typed column.

- Insert: split incoming row → typed cols + extras BLOB. Promoted keys
  removed from extras before storage.
- Reconstruct: SELECT row + decode extras → merge → return hash. Typed
  cols win on key collision.
- Aggregated children (`subtests`, run-level `jobs` array) NOT stored in
  extras; reconstruction rebuilds via JOIN.

### D3. No producer-side spec nesting

`TestFile` slots flatten into the spec row root at write time (drop the
`test_file => {...}` wrapper in `RunService::request_handler_launch_job`).
Combined with the separate "drop `file` slot from TestFile" change, this
means producer JSON keys match column names exactly throughout. Insert
and reconstruct work via schema-derived column lists; no rename map.

### D4. `archive_version` single field

Drop `archives.format_version` and `archives.schema_version`. Replace
with single `archive_version TEXT` column carrying
`$App::Yath2::Log::VERSION` at write time. Add class accessor
`App::Yath2::Log->last_breaking_version` (returns hardcoded
`'2.000011'` initially). Read path refuses archives with
`archive_version < last_breaking_version`. Bump manually on future
breaking changes. No auto-migration.

### D5. `sealed_at` semantics

`sealed_at` represents the source archive's live→sealed transition
timestamp (when the harness collector removed the LIVE sentinel and
`meta.json` was minted). Equivalent to `meta.created_at`. Carried over
from source on insert; NOT stamped at end of insert. Fixed value per
archive.

### D6. Atomic insert via transaction

`DB->insert($source)` wraps the entire population pass in a DB
transaction. Any failure mid-insert → full rollback. No partial archive
rows possible. UNIQUE(archive_uuid) violations on re-insert throw
"archive already exists; not re-imported" without modification.

### D7. Project + test_file breakout

Multi-project DB support via:

- `projects(project_id, name UNIQUE)` — minimal identity, just name
  from `meta.project`.
- `runs.project_id` FK — denormalized for query speed.
- `archives` does NOT carry `project_id` — derivable via runs; not
  enforced at archive level.
- `test_files(test_file_id, project_id, file)` UNIQUE(project_id, file).
  Identity is project-scoped relative path.
- `job_specs(job_spec_id, job_id, test_file_id, ...volatile TestFile
  attrs..., extras)` UNIQUE(job_id) — per-job snapshot of TestFile
  content (category, duration, switches, etc.) so editing the test
  file between runs preserves the per-run snapshot. Cross-archive
  aggregate queries on test_file evolution become possible.
- `jobs.test_file_id` NOT NULL FK to test_files. (No "fake jobs" — old
  fake-job pattern is now services/resources, separate tables.)
- `services` does NOT carry `project_id` — derivable. Skip.

### D8. Drop spec/report artifact rows

`artifacts.artifact_kind` CHECK constraint narrows from
`('events', 'state', 'spec', 'report', 'attachment', 'arbitrary')` to
`('events', 'attachment', 'arbitrary')`. `DB->insert()` no longer writes
spec/report payload bytes — content lives entirely in typed columns +
extras. `Artifact->spec_iter` / `->report_iter` reconstruct JSONL on
demand.

### D9. Promote meta.json fields

`archives` gains typed columns for the meta.json contents:

- `archive_uuid` (already there)
- `created_at` — = `sealed_at` per D5; one column suffices, rename
  consideration: `sealed_at` keeps the user-facing meaning.
- `host`, `user`, `git_sha`, `project`, `yath_version` — promoted.
- `meta_extras BLOB` — JSON catch-all for any future meta keys.

Drop the `meta.json` arbitrary artifact write at insert time. Reconstruct
via `Log::Artifact->root.get('meta.json')` on read. `inspect` reads
columns directly.

### D10. Apply across all four flavors

`share/schema/{sqlite,mariadb,mysql,postgres}.sql` all updated in
parallel. Each commit lands all four where DDL changes.

## Per-table column lists (post-redesign)

### `archives`
```
archive_id          INTEGER PK
archive_uuid        TEXT UNIQUE
archive_version     TEXT          -- $App::Yath2::Log::VERSION at write
sealed_at           TEXT          -- source seal timestamp (meta.created_at)
host                TEXT
"user"              TEXT
git_sha             TEXT
project             TEXT          -- (denormalized; runs.project_id is the FK)
yath_version        TEXT
meta_extras         BLOB          -- JSON
```

(`format_version`, `schema_version` dropped.)

### `projects` (new)
```
project_id          INTEGER PK
name                TEXT UNIQUE
```

### `runs`
```
run_id              INTEGER PK
archive_id          INTEGER FK
project_id          INTEGER FK   -- new
run_ord             INTEGER
run_uuid            TEXT
status              TEXT
pass                INTEGER
"exit"              INTEGER
exit_decoded        BLOB
aborted             INTEGER       -- kept; semantics from legacy
timed_out           INTEGER       -- kept; semantics from legacy
started_at          TEXT
ended_at            TEXT
total_jobs          INTEGER
passed_jobs         INTEGER
failed_jobs         INTEGER
aborted_jobs        INTEGER
times               BLOB          -- JSON 4-tuple, if emitted
child_times         BLOB
child_wall          REAL
spec_extras         BLOB          -- new (catches name, harness, etc.)
state_extras        BLOB          -- new
```

(Drop `spec` and `state` BLOBs.)

### `test_files` (new)
```
test_file_id        INTEGER PK
project_id          INTEGER FK
file                TEXT          -- relative path
UNIQUE(project_id, file)
```

### `jobs`
```
job_id              INTEGER PK
archive_id          INTEGER FK
run_id              INTEGER FK
test_file_id        INTEGER FK NOT NULL    -- new
job_ord             INTEGER
pass                INTEGER
status              TEXT
retry_count         INTEGER
```

(Drop `file`, `spec` BLOB, all TestFile attr cols. Replaced by FK + job_specs.)

### `job_specs` (new)
```
job_spec_id         INTEGER PK
job_id              INTEGER FK UNIQUE      -- 1:1 with jobs
test_file_id        INTEGER FK             -- denormalized for index lookups
file_abs            TEXT
category            TEXT
duration            TEXT
stage               TEXT
features            BLOB                   -- JSON
switches            BLOB                   -- JSON
retry               INTEGER
retry_isolated      INTEGER
smoke               INTEGER
isolation           INTEGER
non_perl            INTEGER
is_binary           INTEGER
event_timeout       INTEGER
post_exit_timeout   INTEGER
min_slots           INTEGER
max_slots           INTEGER
ch_dir              TEXT
extras              BLOB                   -- conflicts, meta, comment, __test_file_class__, etc.
```

### `job_tries`
```
job_try_id          INTEGER PK
job_id              INTEGER FK
try_ord             INTEGER
status              TEXT
pass                INTEGER
"exit"              INTEGER
exit_decoded        BLOB
queued_at           TEXT          -- new
started_at          TEXT
ended_at            TEXT
pass_count          INTEGER       -- new
fail_count          INTEGER       -- new
assertion_count     INTEGER       -- new
plan                BLOB          -- new (JSON)
halt                BLOB          -- new (JSON)
times               BLOB          -- new (JSON 4-tuple)
child_times         BLOB          -- new (JSON 4-tuple)
child_wall          REAL          -- new
spec_extras         BLOB          -- new
state_extras        BLOB          -- new (catches in-stream collector_report)
```

(Drop `spec`, `state` BLOBs.)

### `services`
```
service_id          INTEGER PK
archive_id          INTEGER FK
run_id              INTEGER FK NULL
name                TEXT
role                TEXT          -- promoted from spec
```

(Drop `status`, `spec`, `state` BLOBs. Status / lifecycle moves to service_lifetimes.)

### `service_lifetimes` (new)
```
service_lifetime_id INTEGER PK
service_id          INTEGER FK
lifetime_ord        INTEGER       -- 1, 2, 3 ... per restart
status              TEXT
type                TEXT          -- collector frame field
id                  TEXT          -- collector id
service_name        TEXT          -- (duplicate of services.name; for round-trip)
stage_name          TEXT          -- preload-only future
started_at          TEXT
ended_at            TEXT
"exit"              INTEGER
exit_decoded        BLOB
times               BLOB
child_times         BLOB
child_wall          REAL
spec_extras         BLOB
state_extras        BLOB
UNIQUE(service_id, lifetime_ord)
```

### `subtests` (unchanged)
Keeps current shape. Aggregated child of `job_tries`.

### `artifacts`
```
artifact_id         INTEGER PK
archive_id          INTEGER FK
artifact_uuid       TEXT
run_id              INTEGER FK NULL
service_id          INTEGER FK NULL
job_try_id          INTEGER FK NULL
artifact_kind       TEXT          -- CHECK ('events','attachment','arbitrary')
format              TEXT
name                TEXT
compressed          INTEGER
payload             BLOB
created_at          TEXT
sealed              INTEGER       -- (review: still needed?)
```

CHECK narrowed; `'spec'`, `'report'`, `'state'` removed from allowed
kinds. Indexes unchanged.

## Producer-side changes

1. `RunService::request_handler_launch_job` — flatten TestFile spread
   into spec row (drop `test_file => {...}` wrapper). Spec row carries
   `absolute`, `relative`, `category`, etc. at root.

2. `Test2::Harness2::TestFile` — drop `file` slot. Constructor takes
   `file` argument, derives `absolute` + `relative`, doesn't store
   `file`. `TO_JSON` returns flat hash without `file` key.

3. Any reader expecting `spec.test_file.X` updates to expect `spec.X`.

## Reconstruction API

`App::Yath2::Log::Artifact` for DB backend:

- `->spec` / `->spec_zst` / `->spec_iter` — reconstruct via:
  - SELECT row from entity table.
  - Decode `spec_extras`.
  - Merge typed cols + extras (typed wins).
  - For `jobs`: also JOIN test_files (file) + job_specs.
  - For service `report_iter`: emit one row per `service_lifetimes`
    row in `lifetime_ord` order.
- `->report` / `->report_zst` / `->report_iter` — reconstruct via:
  - SELECT row from entity table.
  - Decode `state_extras`.
  - Merge typed cols + extras.
  - For `runs`: JOIN jobs + job_tries + subtests to rebuild `jobs`
    array.
  - For `job_tries`: JOIN subtests to rebuild `subtests` array.

- `->meta` (root artifact) — reconstruct meta.json from `archives`
  columns + `meta_extras`.

`Log::Live`, `Log::Directory`, `Log::TarZIdx` unchanged — spec/report
stay as on-disk artifacts there.

## What does NOT change

- `events.jsonl.zst` artifact storage. Stays.
- Attachments storage. Stays.
- Tar/Directory/Live backends' on-disk format. No change.
- Per-flavor DDL beyond the column / table list above.

## Concerns explicitly resolved

- Byte-level round-trip: not required (user OK).
- Producer key ordering inside extras: not required (user OK).
- App::Yath2DB DBIC sync: dist not yet written; will use this schema
  directly when written. No external dist coupling.
- Future-key safety: `*_extras` BLOBs catch unmapped keys.
- Migration / re-import: out of scope; reject + manual tools.
- Partial inserts: prevented by transaction wrapping.
