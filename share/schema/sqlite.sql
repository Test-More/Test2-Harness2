-- App::Yath2::Log DB backend, SQLite flavor (schema_version = 1).
-- Requires SQLite >= 3.45 (JSONB).
--
-- The Log::Sqlite backend applies these PRAGMAs at every connection
-- open (NOT here in the schema):
--
--   PRAGMA journal_mode = WAL;
--   PRAGMA synchronous   = NORMAL;
--   PRAGMA busy_timeout  = 5000;
--   PRAGMA foreign_keys  = ON;
--   PRAGMA temp_store    = MEMORY;
--
-- Identity convention: every PK is `<thing>_id INTEGER`, every UUID
-- column is `<thing>_uuid TEXT(36) COLLATE BINARY`. UUIDs are v7
-- (gen_uuid). No bare `id` / `uuid` columns.
--
-- Polymorphic scope on `artifacts`: `scope_kind` text + `scope_id` int.
-- No DB FK (caller-managed). CHECK constraint enforces enum values.
--
-- Payload compression: client-side zstd. App compresses bytes before
-- INSERT and stores compressed=1. SQLite has no native compression.

CREATE TABLE archives (
    archive_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_uuid    TEXT    NOT NULL COLLATE BINARY,
    format_version  INTEGER NOT NULL,
    schema_version  INTEGER NOT NULL,
    created_at      TEXT    NOT NULL,
    sealed_at       TEXT,
    UNIQUE(archive_uuid)
);

CREATE TABLE runs (
    run_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_ord         INTEGER NOT NULL,
    run_uuid        TEXT    NOT NULL COLLATE BINARY,
    status          TEXT    NOT NULL,
    pass            INTEGER,
    "exit"          INTEGER,
    exit_decoded    BLOB,
    aborted         INTEGER NOT NULL DEFAULT 0,
    timed_out       INTEGER NOT NULL DEFAULT 0,
    started_at      TEXT,
    ended_at        TEXT,
    total_jobs      INTEGER,
    passed_jobs     INTEGER,
    failed_jobs     INTEGER,
    aborted_jobs    INTEGER,
    spec            BLOB,
    state           BLOB,
    UNIQUE(archive_id, run_uuid),
    UNIQUE(archive_id, run_ord)
);

CREATE INDEX runs_archive_idx ON runs(archive_id);
CREATE INDEX runs_status_idx  ON runs(status);
CREATE INDEX runs_pass_idx    ON runs(pass);

CREATE TABLE services (
    service_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          INTEGER REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    status          TEXT,
    spec            BLOB,
    state           BLOB
);

-- (archive_id, run_id, name) unique. SQLite treats two NULLs as distinct
-- in UNIQUE, but here run_id NULL means "global service for this archive"
-- and we want at most one such row per (archive_id, name). Use a
-- COALESCE-based partial uniqueness with two indexes for clarity.
CREATE UNIQUE INDEX services_global_name_uk
    ON services(archive_id, name)
    WHERE run_id IS NULL;
CREATE UNIQUE INDEX services_run_name_uk
    ON services(archive_id, run_id, name)
    WHERE run_id IS NOT NULL;
CREATE INDEX services_archive_idx ON services(archive_id);
CREATE INDEX services_run_idx     ON services(run_id);

CREATE TABLE jobs (
    job_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          INTEGER NOT NULL REFERENCES runs(run_id)         ON DELETE CASCADE,
    job_ord         INTEGER NOT NULL,
    file            TEXT,
    pass            INTEGER,
    status          TEXT,
    retry_count     INTEGER,
    spec            BLOB,
    UNIQUE(archive_id, run_id, job_ord)
);

CREATE INDEX jobs_run_pass_idx ON jobs(run_id, pass);
CREATE INDEX jobs_file_idx     ON jobs(file);

CREATE TABLE job_tries (
    job_try_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id          INTEGER NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER NOT NULL,
    status          TEXT,
    pass            INTEGER,
    "exit"          INTEGER,
    exit_decoded    BLOB,
    started_at      TEXT,
    ended_at        TEXT,
    spec            BLOB,
    state           BLOB,
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx ON job_tries(job_id);

CREATE TABLE subtests (
    subtest_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_try_id      INTEGER NOT NULL REFERENCES job_tries(job_try_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    pass            INTEGER NOT NULL,
    count_pass      INTEGER,
    count_fail      INTEGER,
    ord             INTEGER NOT NULL
);

CREATE INDEX subtests_jobtry_pass_idx ON subtests(job_try_id, pass);
CREATE INDEX subtests_name_idx        ON subtests(name);

CREATE TABLE artifacts (
    artifact_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    artifact_uuid   TEXT    NOT NULL COLLATE BINARY,
    scope_kind      TEXT    NOT NULL,
    scope_id        INTEGER NOT NULL,
    artifact_kind   TEXT    NOT NULL,
    format          TEXT    NOT NULL,
    name            TEXT,
    compressed      INTEGER NOT NULL,
    payload         BLOB    NOT NULL,
    created_at      TEXT    NOT NULL,
    sealed          INTEGER NOT NULL DEFAULT 0,
    CHECK (scope_kind IN ('archive','run','service','job_try')),
    CHECK (artifact_kind IN ('events','state','spec','report','attachment','arbitrary')),
    UNIQUE(archive_id, artifact_uuid)
);

-- (archive_id, scope_kind, scope_id, artifact_kind, format, name) unique.
-- For standard kinds (`events`/`state`/`spec`/`report`) `name` is NULL;
-- SQLite's default UNIQUE treats NULLs as distinct, so we split into
-- two partial indexes.
CREATE UNIQUE INDEX artifacts_named_uk
    ON artifacts(archive_id, scope_kind, scope_id, artifact_kind, format, name)
    WHERE name IS NOT NULL;
CREATE UNIQUE INDEX artifacts_unnamed_uk
    ON artifacts(archive_id, scope_kind, scope_id, artifact_kind, format)
    WHERE name IS NULL;

CREATE INDEX artifacts_scope_idx
    ON artifacts(archive_id, scope_kind, scope_id);
CREATE INDEX artifacts_scope_kind_idx
    ON artifacts(archive_id, scope_kind, scope_id, artifact_kind);
