# DB schema redesign — spec/report promotion + multi-archive support

Date: 2026-05-07
Branch: `new_log_refactor`

This document covers the second refactor pass on `new_log_refactor`. The
first pass (collector pipeline + Log reader rewrite) is documented in
`AI_DOCS/2026-05-04-log-refactor.md`. After that work landed the on-disk
and live shapes were correct, but the SQL schema still carried over
choices made before the rev-2 ownership rule existed. This pass
redesigns the schema to match. All four DB flavors (sqlite, postgres,
mariadb, mysql) move in lock-step.

## Trigger

Post-first-pass the codebase still had the following structural
problems on the DB side:

1. **Two version columns of unclear distinction.**
   `archives.format_version` plus `archives.schema_version`. Neither
   was driven by a single source of truth. Read-time refusal of older
   archives wasn't possible without picking one and stamping the other
   redundantly.

2. **BLOB duplication of spec / report bytes.** `runs.spec`,
   `runs.state`, `job_tries.spec`, `job_tries.state`, `services.spec`,
   `services.state` each held the literal JSON bytes of the matching
   `spec.jsonl` / `report.jsonl` row. The same content was *also*
   stored as `artifacts.payload` rows with `artifact_kind` of `spec`
   or `report`. Two copies, identical content, no integrity guarantee
   between them.

3. **No multi-archive aggregation surface.** No `projects` table, no
   `test_files` table. A multi-archive DB couldn't answer "show me
   every run of `t/foo.t` across these 50 archives" without parsing
   spec BLOBs row by row.

4. **`services` was single-row per service.** A run-scoped service
   that restarts mid-run produces multiple `report.jsonl` rows; the
   schema couldn't represent that, so the second start either
   overwrote the first or was silently dropped.

5. **`meta.json` lived as an `arbitrary` artifact row.** No typed
   columns for `host`, `user`, `git_sha`, `project`, `yath_version`
   etc. Filtering / grouping required parsing the JSON blob.

6. **No transaction wrap on insert.** `DB->insert($source)` populated
   tables sequentially. A mid-flight failure left a half-populated
   archive in the DB.

7. **No protection against re-import.** Calling `insert` twice with
   the same source archive silently produced two `archives` rows with
   the same `archive_uuid` (UNIQUE was not declared / not enforced
   uniformly), or partially-failing constraint violations on the
   second pass.

The redesign closes all seven.

## Decisions

These are reproduced (lightly adapted) from
`SCHEMA_REDESIGN_DECISIONS.md` (worktree root, kept as the living
source-of-truth doc). The original doc contains the per-table column
lists and "concerns explicitly resolved" notes; this AI_DOC mirrors
the substantive blocks for completeness.

### D1. Service multi-row support

Services may restart. Each restart writes a new `report.jsonl` row
and potentially a fresh `spec.jsonl` row. Schema: introduce
`service_lifetimes` as a child of `services`; both spec and report
data live on `service_lifetimes` (one row per start/end cycle). The
`services` table holds only identity (`name`, `role`, `run_id`).

### D2. `*_extras` JSON catch-all columns

Every entity table that previously stored full spec/report row JSON
(`runs`, `job_specs`, `job_tries`, `service_lifetimes`) gets one or
two JSON BLOB columns (`spec_extras` and/or `state_extras`) holding
any producer-emitted keys not promoted to a typed column.

- Insert: split incoming row into typed cols + extras BLOB. Promoted
  keys are removed from extras before storage.
- Reconstruct: SELECT row + decode extras + merge. Typed cols win on
  key collision.
- Aggregated children (`subtests`, run-level `jobs[]`) are NOT stored
  in extras; reconstruction rebuilds them via JOIN.

### D3. No producer-side spec nesting

`Test2::Harness2::TestFile` slots flatten into the spec row root at
write time. The `test_file => {...}` wrapper in
`RunService::request_handler_launch_job` is dropped. Combined with
the separate "drop `file` slot from TestFile" change, this means
producer JSON keys match column names exactly throughout. Insert and
reconstruct work via schema-derived column lists; no rename map.

### D4. `archive_version` single field

Drop `archives.format_version` and `archives.schema_version`. Replace
with a single `archive_version TEXT` column carrying
`$App::Yath2::Log::VERSION` at write time. Add class accessor
`App::Yath2::Log->last_breaking_version` (returns hardcoded
`'2.000011'` initially). The read path refuses archives with
`archive_version < last_breaking_version`. Bumped manually on future
breaking changes; no auto-migration.

### D5. `sealed_at` semantics

`sealed_at` represents the source archive's live→sealed transition
timestamp (when the harness collector removed the LIVE sentinel and
`meta.json` was minted). Equivalent to `meta.created_at`. Carried
over from source on insert; NOT stamped at end of insert. Fixed value
per archive.

### D6. Atomic insert via transaction

`DB->insert($source)` wraps the entire population pass in a DB
transaction (`begin_work` / `commit` / `rollback`). Any failure
mid-insert triggers a full rollback. No partial archive rows possible.
A pre-flight `archive_uuid` uniqueness check rejects re-imports of
the same source with a clean
`"archive already exists; not re-imported"` error rather than
letting a UNIQUE-constraint violation surface.

### D7. Project + test_file breakout

Multi-project DB support via:

- `projects(project_id, name UNIQUE)` — minimal identity, just name
  from `meta.project`.
- `runs.project_id` FK — denormalized for query speed.
- `archives` does NOT carry `project_id` — derivable via runs; not
  enforced at archive level.
- `test_files(test_file_id, project_id, file)` UNIQUE(project_id,
  file). Identity is the project-scoped relative path.
- `job_specs(job_spec_id, job_id, test_file_id, ...volatile TestFile
  attrs..., extras)` UNIQUE(job_id) — per-job snapshot of TestFile
  content (category, duration, switches, etc.) so editing the test
  file between runs preserves the per-run snapshot. Cross-archive
  aggregate queries on test_file evolution become possible.
- `jobs.test_file_id` NOT NULL FK to `test_files`. (No "fake jobs" —
  the old fake-job pattern is now services / resources, separate
  tables.)
- `services` does NOT carry `project_id` — derivable. Skip.

### D8. Drop spec/report artifact rows

`artifacts.artifact_kind` CHECK constraint narrows from
`('events', 'state', 'spec', 'report', 'attachment', 'arbitrary')`
to `('events', 'attachment', 'arbitrary')`. `DB->insert()` no longer
writes spec / report payload bytes — content lives entirely in typed
columns + extras. `Artifact->spec_iter` / `->report_iter` reconstruct
JSONL on demand.

### D9. Promote meta.json fields

`archives` gains typed columns for the meta.json contents:

- `archive_uuid` (already there)
- `sealed_at` — = `meta.created_at` per D5
- `host`, `user`, `git_sha`, `project`, `yath_version` — promoted
- `meta_extras BLOB` — JSON catch-all for any future meta keys

The `meta.json` arbitrary artifact write at insert time is dropped.
Reconstruction goes via `Log::Artifact->root.get('meta.json')` on
read. `inspect` reads columns directly.

### D10. Apply across all four flavors

`share/schema/{sqlite,mariadb,mysql,postgres}.sql` all updated in
parallel. Each commit lands all four where DDL changes.

## What landed (commit-level)

In order, on `new_log_refactor`:

- `bcf868cd5` — A1: TestFile drops the redundant `file` slot;
  `absolute` and `relative` are derived on init.
- `fd5a60c78` — A2: `RunService::request_handler_launch_job` flattens
  the TestFile spread into the spec row root (no `test_file => {...}`
  wrapper).
- `bb6697d82` — B1: `projects` table + `runs.project_id` FK.
- `746fa02fc` — B2: `test_files` + `job_specs` tables; `jobs` gains
  `test_file_id` FK.
- `d26217153` — B2.5: invert the insert flow (rows construct entity
  records before populating dependent tables); tighten
  `jobs.test_file_id` to NOT NULL.
- `811624afe` — B3: split services lifecycle into `service_lifetimes`
  for multi-row (restart) support; `services` reduces to identity
  only.
- `a0bb66dea` — B4: promote spec/report fields to typed columns on
  `runs` / `job_tries` / `service_lifetimes`; add `*_extras`
  catch-alls.
- `7404e560c` — B5: `App::Yath2::Log::Artifact` reconstructs
  spec/report from typed columns + extras for the DB backend.
- `463cff6ce` — B6: replace `format_version` / `schema_version` with
  single `archive_version` column; refuse archives below
  `last_breaking_version` at read time.
- `34c0f8267` — B7: promote meta fields to typed columns on
  `archives`; drop the `meta.json` arbitrary artifact row for the DB
  backend.
- `c40da0bb2` — B8: wrap `DB->insert` in a transaction; reject
  duplicate `archive_uuid` with a clean error before opening the
  transaction.
- `e00a1c2ce` — B9: drop `spec` / `report` artifact rows entirely;
  narrow the `artifacts.artifact_kind` CHECK to
  `('events', 'attachment', 'arbitrary')`.
- `6dd5fc1c5` — C1: cross-archive `test_file` aggregate-query test
  (under `t/AI/`) confirms the new shape supports the query the
  redesign was scoped around.

## Per-table summary (post-redesign)

Reproduced from `SCHEMA_REDESIGN_DECISIONS.md`. Quote columns are
shown as bare names; `"user"` and `"exit"` are quoted in DDL because
they are reserved words on at least one of the four flavors.

### `archives`

```
archive_id          INTEGER PK
archive_uuid        TEXT UNIQUE
archive_version     TEXT          -- $App::Yath2::Log::VERSION at write
sealed_at           TEXT          -- source seal timestamp (meta.created_at)
host                TEXT
"user"              TEXT
git_sha             TEXT
project             TEXT          -- denormalized; runs.project_id is the FK
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
project_id          INTEGER FK    -- new
run_ord             INTEGER
run_uuid            TEXT
status              TEXT
pass                INTEGER
"exit"              INTEGER
exit_decoded        BLOB
aborted             INTEGER
timed_out           INTEGER
started_at          TEXT
ended_at            TEXT
total_jobs          INTEGER
passed_jobs         INTEGER
failed_jobs         INTEGER
aborted_jobs        INTEGER
times               BLOB          -- JSON 4-tuple, if emitted
child_times         BLOB
child_wall          REAL
spec_extras         BLOB          -- new
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

(Drop `file`, `spec` BLOB, all TestFile attribute columns. Replaced
by FK + `job_specs`.)

### `job_specs` (new)

```
job_spec_id         INTEGER PK
job_id              INTEGER FK UNIQUE      -- 1:1 with jobs
test_file_id        INTEGER FK             -- denormalized
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
extras              BLOB                   -- conflicts, meta, comment, ...
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

(Drop `status`, `spec`, `state` BLOBs. Status / lifecycle moved to
`service_lifetimes`.)

### `service_lifetimes` (new)

```
service_lifetime_id INTEGER PK
service_id          INTEGER FK
lifetime_ord        INTEGER       -- 1, 2, 3 ... per restart
status              TEXT
type                TEXT          -- collector frame field
id                  TEXT          -- collector id
service_name        TEXT          -- duplicate of services.name; for round-trip
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

Aggregated child of `job_tries`; same shape as before.

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
sealed              INTEGER
```

CHECK narrowed; `'spec'`, `'report'`, `'state'` removed from allowed
kinds. Indexes unchanged.

## Reconstruction model

`spec.jsonl`, `report.jsonl`, and `meta.json` are no longer stored as
artifact bytes for DB backends. They are reconstructed on demand from
typed columns + JSON catch-alls (`spec_extras`, `state_extras`,
`meta_extras`). The reader API surface is unchanged:

- `Artifact->spec_iter` — SELECT entity row, decode `spec_extras`,
  merge typed cols with extras (typed wins on collision), yield as
  one JSONL row. For jobs, JOIN `test_files` (file) and `job_specs`.
  For services, yield one row per `service_lifetimes` entry in
  `lifetime_ord` order.
- `Artifact->report_iter` — SELECT entity row, decode `state_extras`,
  merge. For runs, JOIN `jobs` + `job_tries` + `subtests` to rebuild
  the run-level `jobs[]` aggregate. For job_tries, JOIN `subtests`
  to rebuild the `subtests[]` aggregate.
- `root->get('meta.json')` — built from `archives` typed columns +
  `meta_extras`.

Aggregated children (`subtests`, run-level `jobs[]`) are explicitly
NOT stored in extras — they are rebuilt via JOIN. Round-trip of
producer key ordering inside the merged hash is not preserved.
Round-trip of producer key ordering outside extras is preserved
because typed columns are emitted in a fixed schema-derived order.

`Log::Live`, `Log::Directory`, and `Log::TarZIdx` are unchanged —
they still store `spec.jsonl` / `report.jsonl` / `meta.json` as
on-disk artifacts. Only DB-backed archives switched to typed-column
storage.

## Producer-side changes

Two small changes on the harness side make the producer's JSON keys
match the DB column names exactly, removing the need for a rename
map at insert time:

- `Test2::Harness2::TestFile` drops the `file` slot. Constructor
  takes `file` as an argument and derives `absolute` and `relative`
  during init. `TO_JSON` returns the flat hash without a `file` key.
- `RunService::request_handler_launch_job` flattens `test_file =>
  {...}` into the spec row root. The spec row carries `absolute`,
  `relative`, `category`, etc. at the top level rather than under a
  `test_file` wrapper.

Together these mean: insert path can do schema-derived column-name
lookups directly against the producer's hash; reconstruct path emits
the same shape back unmodified. Any reader that previously expected
`spec.test_file.X` was updated to expect `spec.X`.

## Insert path

`DB->insert($source)`:

1. Open `$source` as a `Log` (any backend).
2. Read the source's `meta.json`; extract `archive_uuid`.
3. Pre-flight uniqueness check: if a row already exists in `archives`
   with that `archive_uuid`, throw
   `"archive already exists; not re-imported"`. No transaction
   opened.
4. `begin_work` on the destination DB.
5. Populate `archives` (with promoted meta columns + `meta_extras`),
   then `projects`, `runs`, `test_files`, `jobs`, `job_specs`,
   `job_tries`, `subtests`, `services`, `service_lifetimes`,
   `artifacts` (events + attachments + arbitrary only — spec /
   report / state / meta.json artifacts are skipped).
6. On success, `commit`. On any exception inside the transaction,
   `rollback` and rethrow.

The pre-flight check exists so duplicate-import fails fast with a
clean error rather than surfacing as a UNIQUE-constraint violation
mid-transaction. The transaction wrap exists so partial-population
failures (disk full, connection drop, mid-flight exception) leave
the DB in its pre-call state.

## Versioning

Per D4: a single `archives.archive_version TEXT` column carrying
`$App::Yath2::Log::VERSION` at write time. The class accessor
`App::Yath2::Log->last_breaking_version` returns the hardcoded floor
(`'2.000011'` initially). `_resolve_archive` consults the floor
during read and refuses archives below it with a clear error
indicating both the archive's stamped version and the reader's
required floor.

Format and schema versions were merged because in practice they
moved together: every change that broke the on-disk format also
broke the DB schema, and vice versa. The single column is bumped
manually on future breaking changes. There is no auto-migration —
old archives below the floor are refused, and re-stamping is a
manual-tools concern for later.

## Trade-offs / non-goals

Reproduced from `SCHEMA_REDESIGN_DECISIONS.md`:

- **Byte-level round-trip** of spec / report is not required. The
  reconstructed JSONL has the same keys and values but not
  necessarily the same key order or whitespace. Acceptable per D2.
- **Producer key ordering inside `*_extras`** is not preserved.
  Acceptable per D2.
- **No migration tooling.** Archives below `last_breaking_version`
  are refused at read time. Re-stamping / converting older archives
  is a manual-tools concern handled later.
- **No partial inserts.** Transaction wrap (D6) makes the insert
  atomic.
- **Aggregated children (`subtests`, run-level `jobs[]`) are NOT
  stored in extras.** They are rebuilt via JOIN at reconstruct time
  (D2).
- **Tar / Directory / Live backends are unchanged.** `spec.jsonl` /
  `report.jsonl` / `meta.json` stay as on-disk artifact files there.
  Only DB-backed archives switched to typed-column storage.
- **`events.jsonl.zst` still stored as artifact bytes.** No `events`
  table; events stay in `artifacts.payload` as zstd-compressed
  JSONL. Out of scope for this redesign.
- **App::Yath2DB DBIC sync** — the dist isn't written yet; when it
  is, it'll consume this schema directly. No external-dist coupling
  in this redesign.

## Pre-existing follow-up surfaced

- **F26 — DATETIME(6) vs producer time format on MariaDB / MySQL.**
  DATETIME(6) columns reject ISO-8601 with `T` / `Z` separators and
  also reject the bare epoch `time()` numbers the producer
  (`Test2::Harness2::Collector`) emits. Surfaced during B4 when test
  fixtures used ISO `T`/`Z` format on those flavors. Pre-existing
  problem; affects B3 service_lifetimes timestamps too but the
  test that would exercise it doesn't. Out of scope until a real
  MariaDB / MySQL deployment hits it. Resolution options recorded
  in `NEW_LOG_REFACTOR_FOLLOWUPS.md` F26: either a backend-side
  `_normalize_datetime` hook, or schema-side TEXT columns for parity
  with sqlite / postgres.
