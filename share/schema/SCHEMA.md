# Log DB Schema (review draft)

This document describes the relational schema used by the four DB-backed
`App::Yath2::Log` backends — `Log::Sqlite`, `Log::Postgres`, `Log::MariaDB`,
`Log::MySQL`. The corresponding `CREATE` statements live under
`share/schema/<flavor>.sql`.

It is the review document for **M2 step 14a** of the new_log_refactor
branch. No Perl code lives in this commit. Implementation of the four
`Log::*` DB backends follows in step 14b+.

## 1. Goals and ground rules

- A `.yath` file (or a server DB) holds **one or more archives**. Single-
  archive `.yath` files are the common case; multi-archive servers (or
  multi-archive `.yath` files) are allowed.
- An archive corresponds to a single sealed log dir or tar. The same `run`
  may appear in multiple archives; therefore `run_uuid` is **not** globally
  unique, but is unique **within an archive**.
- Identifiers in the on-disk log are **ord ints** (`run_ord`, `job_ord`,
  `try_ord`); UUIDs exist only on archives and runs. Service identity is
  `name` (no `service_uuid`). Jobs and tries have no UUID. (Per
  `NEW_LOG_REFACTOR_QUESTIONS.md` B2 + F1.)
- Every primary-key column is named `<thing>_id`. Every UUID column is
  `<thing>_uuid`. We never use bare `id` or bare `uuid`. (Per
  `LOG_ARCHIVE_DB_QUESTIONS.md` Q6.)
- The DB backends are **sealed-only**. Live writes go through
  `Log::Directory`; only sealed logs ever land in the DB. (Per
  `LOG_ARCHIVE_DB_QUESTIONS.md` Q10.)
- Schema starts at `schema_version = 1`. No migration tooling yet (per
  M2/K16 carried).

## 2. Tables

There are seven tables shared across all four flavors:

```
archives        one row per archive (always)
runs            run-scope summary (one per run per archive)
services        service-scope summary (global or run-scoped)
jobs            job-scope summary
job_tries       per-try summary
subtests        top-level subtests of each try (for fast pass/fail lookup)
artifacts       events / spec / state / report / attachment / arbitrary
                payloads (polymorphic scope)
```

There is **no** separate `attachments` table — attachments are just
artifacts with `artifact_kind = 'attachment'` and a non-NULL `name`.

There is **no** `formats` table — `format` is just a column on
`artifacts`.

### 2.1 archives

Always present, even single-archive `.yath` files (a single archive is
just one row).

| column          | type                       | notes                                                  |
|-----------------|----------------------------|--------------------------------------------------------|
| archive_id      | BIGINT PK                  | auto-increment                                         |
| archive_uuid    | UUID / BINARY(16) / TEXT   | unique, indexed; native UUID where supported           |
| archive_uuid_string | TEXT                   | binary-stored flavors only (MySQL/Percona); trigger-populated; for human use |
| format_version  | INT                        | LogArchive on-disk format version                      |
| schema_version  | INT                        | DB schema version for migrations                       |
| created_at      | timestamp                  | when archive was created                               |
| sealed_at       | timestamp NULL             | non-NULL once writes finished                          |

**Constraints:** `UNIQUE(archive_uuid)`.

### 2.2 runs

| column         | type             | notes                                                  |
|----------------|------------------|--------------------------------------------------------|
| run_id         | BIGINT PK        |                                                        |
| archive_id     | BIGINT FK        | → archives                                             |
| run_ord        | INT              | sequential per archive, starts at 0                    |
| run_uuid       | UUID / BINARY / TEXT |                                                    |
| run_uuid_string | TEXT             | MySQL/Percona only                                     |
| status         | TEXT             | 'queued'\|'running'\|'passed'\|'failed'\|'aborted'     |
| pass           | BOOLEAN NULL     |                                                        |
| exit           | INT NULL         | raw waitstatus or NULL on crash                        |
| exit_decoded   | JSON NULL        | parse_exit() output                                    |
| aborted        | BOOLEAN          | true if the run was aborted (default false)            |
| timed_out      | BOOLEAN          | true if any job timed out (default false)              |
| started_at     | timestamp NULL   |                                                        |
| ended_at       | timestamp NULL   |                                                        |
| total_jobs     | INT NULL         |                                                        |
| passed_jobs    | INT NULL         |                                                        |
| failed_jobs    | INT NULL         |                                                        |
| aborted_jobs   | INT NULL         | per F17                                                |
| spec           | JSON NULL        | full run spec (decoded)                                |
| state          | JSON NULL        | final/most-recent run state (matches last report row)  |

**Constraints:**
- `UNIQUE(archive_id, run_uuid)` — same run can appear in multiple archives but is unique within an archive (per B2).
- `UNIQUE(archive_id, run_ord)` — within an archive, run ords are unique.

**Indexes:** `(archive_id)`, `(status)`, `(pass)`.

### 2.3 services

| column     | type             | notes                                                    |
|------------|------------------|----------------------------------------------------------|
| service_id | BIGINT PK        |                                                          |
| archive_id | BIGINT FK        | → archives                                               |
| run_id     | BIGINT FK NULL   | NULL = global service; non-NULL = run-scoped             |
| name       | TEXT             | service name (the service identifier)                    |
| status     | TEXT NULL        |                                                          |
| spec       | JSON NULL        |                                                          |
| state      | JSON NULL        |                                                          |

**Constraints:** `UNIQUE(archive_id, run_id, name)` — global services
unique per archive; run-scoped unique per run. (Note: per F1, services
have **no** `service_uuid`.)

### 2.4 jobs

| column      | type             | notes                                                |
|-------------|------------------|------------------------------------------------------|
| job_id      | BIGINT PK        |                                                      |
| archive_id  | BIGINT FK        | → archives (denormalized convenience)                |
| run_id      | BIGINT FK        | → runs                                               |
| job_ord     | INT              | sequential per run, starts at 0 (per B2)             |
| file        | TEXT             | test file path                                       |
| pass        | BOOLEAN NULL     |                                                      |
| status      | TEXT NULL        |                                                      |
| retry_count | INT              | max try ord + 1                                      |
| spec        | JSON NULL        | TestFile-derived                                     |

**Constraints:** `UNIQUE(archive_id, run_id, job_ord)`.

**Indexes:** `(run_id, pass)`, `(file)`.

### 2.5 job_tries

| column       | type           | notes                                |
|--------------|----------------|--------------------------------------|
| job_try_id   | BIGINT PK      |                                      |
| job_id       | BIGINT FK      | → jobs                               |
| try_ord      | INT            | starts at 0 (per B2)                 |
| status       | TEXT NULL      |                                      |
| pass         | BOOLEAN NULL   |                                      |
| exit         | INT NULL       | raw waitstatus                       |
| exit_decoded | JSON NULL      | per B8 amendment                     |
| started_at   | timestamp NULL |                                      |
| ended_at     | timestamp NULL |                                      |
| spec         | JSON NULL      |                                      |
| state        | JSON NULL      | matches report.jsonl.zst row content |

**Constraints:** `UNIQUE(job_id, try_ord)`.

### 2.6 subtests

Top-level subtests of each try, projected for fast pass/fail lookup.
Populated when the try is sealed. (Per F9.)

| column     | type           | notes                  |
|------------|----------------|------------------------|
| subtest_id | BIGINT PK      |                        |
| job_try_id | BIGINT FK      | → job_tries            |
| name       | TEXT           |                        |
| pass       | BOOLEAN        |                        |
| count_pass | INT NULL       | nested assertion count |
| count_fail | INT NULL       |                        |
| ord        | INT            | insertion order        |

**Indexes:** `(job_try_id, pass)`, `(name)`.

### 2.7 artifacts

The actual events / spec / state / report / attachment / arbitrary
payloads. Polymorphic scope.

| column          | type                       | notes                                                 |
|-----------------|----------------------------|-------------------------------------------------------|
| artifact_id     | BIGINT PK                  |                                                       |
| archive_id      | BIGINT FK                  | → archives (denormalized; always set)                 |
| artifact_uuid   | UUID / BINARY / TEXT       | unique within (archive_id)                            |
| artifact_uuid_string | TEXT                  | MySQL/Percona only                                    |
| scope_kind      | TEXT                       | 'archive' \| 'run' \| 'service' \| 'job_try'         |
| scope_id        | BIGINT                     | references archive_id / run_id / service_id / job_try_id depending on scope_kind. **No DB FK** because polymorphic; integrity is application-managed. |
| artifact_kind   | TEXT (or ENUM)             | 'events' \| 'state' \| 'spec' \| 'report' \| 'attachment' \| 'arbitrary' |
| format          | TEXT                       | 'jsonl' \| 'json' \| 'csv' \| 'html' \| ...           |
| name            | TEXT NULL                  | filename for `attachment` and `arbitrary` kinds; NULL for the standard streaming kinds |
| compressed      | BOOLEAN                    | payload is zstd-compressed                            |
| payload         | BYTEA / LONGBLOB / BLOB    | raw bytes (possibly zst)                              |
| created_at      | timestamp                  |                                                       |
| sealed          | BOOLEAN                    | append streams: true once null sentinel landed (default false) |

**Constraints:**
- `CHECK (scope_kind IN ('archive','run','service','job_try'))`.
- `UNIQUE(archive_id, scope_kind, scope_id, artifact_kind, format, name)` —
  `name` allows multiple `arbitrary` files per scope; standard streams
  (kind `events`/`state`/`spec`/`report`) have `name IS NULL` and so are
  unique by `(scope_kind, scope_id, artifact_kind, format)`. (Most
  flavors emulate "NULL distinct" via `COALESCE(name, '')`.)
- `UNIQUE(archive_id, artifact_uuid)`.

**Indexes:** `(archive_id, scope_kind, scope_id)`,
`(archive_id, scope_kind, scope_id, artifact_kind)`.

## 3. Polymorphic scope on `artifacts` — design choice

The user gave us two acceptable shapes (`LOG_ARCHIVE_DB_QUESTIONS.md` Q9):

- **(A) Link tables** (one per scope kind: `archive_artifacts`,
  `run_artifacts`, `service_artifacts`, `job_try_artifacts`): clean
  referential integrity, but every read needs a join across multiple
  link tables, and every artifact insert needs an extra link insert.
- **(B) Polymorphic single column** (`scope_kind` + `scope_id`): simpler
  schema and queries; no DB-enforced referential integrity for the
  scope link.

**We chose (B).** The artifacts table is the single largest table in
the schema (one row per stream + one per attachment + one per arbitrary
file), and almost every read of it is keyed by `(archive_id, scope_kind,
scope_id, ...)`. Joining four link tables on every access for a property
the application already knows from context (the caller asked for a
job_try's events.jsonl) buys nothing. The cost of (B) is only the loss
of one ON DELETE CASCADE rule that we don't actually use — sealed-only
archives are essentially append-only; we never expect to delete a job
or service mid-archive. Application code enforces the scope_id ↔
scope_kind invariant on insert.

The CHECK constraint on `scope_kind` enforces the four-value enum.

## 4. UUID storage per flavor

UUIDs are v7 (time-ordered) supplied client-side via
`Test2::Util::UUID::gen_uuid`. No DB-side UUID generation.

| Flavor       | Native UUID? | Storage           | `_string` companion | Trigger?              |
|--------------|--------------|-------------------|---------------------|-----------------------|
| PostgreSQL   | yes (`UUID`) | `UUID`            | n/a                 | n/a                   |
| MariaDB      | yes (`UUID`, since 10.7) | `UUID` | n/a                 | n/a                   |
| MySQL/Percona| no           | `BINARY(16)` (no swap_flag — v7 is already time-ordered) | yes (`<col>_string` indexed) | yes — see §4.1 |
| SQLite       | no           | `TEXT(36)`        | n/a (already text)  | n/a                   |

We require MariaDB ≥ 10.7 (no fallback for older). MySQL ≥ 8.0.16
(CHECK enforced; native JSON; recursive CTEs available).

For SQLite we use `TEXT(36)` rather than `BLOB(16)`. The user expressed
a preference for human-readable uuids in the SQLite shell; a 36-char
text column is half a byte more per row but vastly more useful for
manual exploration of a `.yath` file.

### 4.1 MySQL/Percona `_string` companion

Every binary-stored UUID column gets a sibling `<col>_string` TEXT(36)
column populated by trigger on INSERT and UPDATE. The trigger uses
`BIN_TO_UUID(<col>)`. Application code only ever writes the binary
column; the string column is a read-only convenience for human DB
users. The string column is indexed.

```sql
CREATE TRIGGER archives_uuid_str_ins
    BEFORE INSERT ON archives
    FOR EACH ROW SET NEW.archive_uuid_string = BIN_TO_UUID(NEW.archive_uuid);

CREATE TRIGGER archives_uuid_str_upd
    BEFORE UPDATE ON archives
    FOR EACH ROW SET NEW.archive_uuid_string = BIN_TO_UUID(NEW.archive_uuid);
```

Same pattern for `runs.run_uuid` → `run_uuid_string` and
`artifacts.artifact_uuid` → `artifact_uuid_string`. Per F13.

## 5. JSON storage per flavor

| Flavor       | JSON type | Notes                                              |
|--------------|-----------|----------------------------------------------------|
| PostgreSQL   | `JSONB`   | indexable, native                                  |
| MariaDB      | `JSON`    | LONGTEXT alias + check (≥ 10.2)                    |
| MySQL/Percona| `JSON`    | native, ≥ 5.7                                      |
| SQLite       | `JSONB`   | requires SQLite ≥ 3.45 (per K8b answer)            |

App code encodes/decodes UTF-8 JSON the same way for all four flavors.

## 6. Bytes columns

| Flavor       | Type      | Cap                                                |
|--------------|-----------|----------------------------------------------------|
| PostgreSQL   | `BYTEA`   | ~1 GB (with TOAST LZ4 column compression on PG14+)|
| MariaDB      | `LONGBLOB`| 4 GB; rely on `PAGE_COMPRESSED=1` for server compression where supported |
| MySQL/Percona| `LONGBLOB`| 4 GB; client-side zstd only                        |
| SQLite       | `BLOB`    | 1 GB compile default                               |

App stores zstd-compressed bytes for all flavors except where the server
provides equivalent transparent compression. `compressed` column tracks
which is which:

- SQLite, MySQL/Percona: `compressed=1`, payload is zstd.
- PostgreSQL ≥ 14: `compressed=0`, payload is raw, server uses TOAST LZ4
  column compression.
- MariaDB: `compressed=0`, payload is raw, table is `PAGE_COMPRESSED=1`
  with `innodb_compression_algorithm = zstd` (server config).

(Per K8c carried.)

## 7. Charset and collation

For MySQL and MariaDB:

```
DEFAULT CHARSET = utf8mb4 COLLATE utf8mb4_unicode_ci
```

PostgreSQL uses the database default (typically UTF-8). SQLite stores
text as UTF-8 by default; UUID text columns use `COLLATE BINARY` to
keep the index byte-wise.

## 8. SQLite open-time PRAGMAs

The schema file itself does not include PRAGMAs. The `Log::Sqlite`
backend applies these at every connection open:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous   = NORMAL;
PRAGMA busy_timeout  = 5000;
PRAGMA foreign_keys  = ON;
PRAGMA temp_store    = MEMORY;
```

Per Q18 in the abandoned LOG_ARCHIVE_DB_QUESTIONS.md.

## 9. SQLite-as-`.yath` detection

`Log->new(file => $path)` detects whether `$path` is a SQLite database
or a tar.zidx archive by reading the first 16 bytes:

- SQLite first 16 bytes == `"SQLite format 3\0"` → `Log::Sqlite`.
- Otherwise → `Log::TarZIdx` (tar.zidx footer at offset filesize-32).

Per K2.

When the SQLite file holds **one** archive, `Log->new(file => $path)`
returns the singleton archive (no `uuid` arg required). When it holds
**multiple** archives, the caller must pass `uuid => $u` or the
constructor throws "ambiguous; specify uuid => …". (Per K3 + F11.)

## 10. Schema versioning + migrations

`archives.schema_version` tracks the schema version used to write the
archive. Schema starts at `1`. There is no migration tooling in this
round — once we ship a v2 schema, a separate migration step reads `v1`
archives and writes `v2` (per K16/M16 carried).

## 11. Indexes — summary

```
archives:    UNIQUE(archive_uuid)
             UNIQUE(archive_uuid_string)               -- MySQL/Percona only
runs:        UNIQUE(archive_id, run_uuid)
             UNIQUE(archive_id, run_ord)
             INDEX(archive_id)
             INDEX(status)
             INDEX(pass)
             UNIQUE(archive_id, run_uuid_string)       -- MySQL/Percona only
services:    UNIQUE(archive_id, run_id, name)
             INDEX(archive_id)
             INDEX(run_id)
jobs:        UNIQUE(archive_id, run_id, job_ord)
             INDEX(run_id, pass)
             INDEX(file)
job_tries:   UNIQUE(job_id, try_ord)
             INDEX(job_id)
subtests:    INDEX(job_try_id, pass)
             INDEX(name)
artifacts:   UNIQUE(archive_id, scope_kind, scope_id, artifact_kind, format, name)
             UNIQUE(archive_id, artifact_uuid)
             INDEX(archive_id, scope_kind, scope_id)
             INDEX(archive_id, scope_kind, scope_id, artifact_kind)
             UNIQUE(archive_id, artifact_uuid_string)  -- MySQL/Percona only
```

## 12. Per-flavor file map

```
share/schema/SCHEMA.md       (this document)
share/schema/sqlite.sql
share/schema/postgres.sql
share/schema/mariadb.sql
share/schema/mysql.sql
```

Each `.sql` file is a standalone `CREATE TABLE ... CREATE INDEX ...
CREATE TRIGGER ...` script. Backends apply them verbatim on first open
of an empty DB. The doc lives in the same directory because the
project's top-level `/docs/` is gitignored.

## 13. Open questions for review

- Is the polymorphic-scope choice (§3) acceptable? The previous round
  used four nullable typed FKs (DP2=B in the old doc); the user OK'd
  link tables in principle. We picked single-column polymorphic (B in
  the old terminology) for query simplicity. Speak up here if you'd
  prefer either alternative.
- `format` column is unconstrained text — should we lift the format
  list (`jsonl`, `json`, `csv`, `html`, ...) into a CHECK constraint or
  keep it open-ended for future formats? Currently open-ended.
- Should `aborted` and `timed_out` on `runs` instead live as
  enum-like values inside `status`? They're called out separately per
  F12c so the failed/replay commands can filter without parsing
  status text.
