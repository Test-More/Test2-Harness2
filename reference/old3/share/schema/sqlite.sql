-- App::Yath2::Log DB backend, SQLite flavor.
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
-- Sub-archive scope on `artifacts`: three nullable FK columns
-- (`run_id`, `service_id`, `job_try_id`). A CHECK enforces "at most
-- one non-NULL" — zero non-NULL = archive-root scope; exactly one
-- non-NULL = scoped to that entity.
--
-- Payload compression: client-side zstd. App compresses bytes before
-- INSERT and stores compressed=1. SQLite has no native compression.

CREATE TABLE projects (
    project_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT    NOT NULL,
    UNIQUE(name)
);

CREATE INDEX projects_name_idx ON projects(name);

CREATE TABLE archives (
    archive_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_uuid    TEXT    NOT NULL COLLATE BINARY,
    archive_version TEXT    NOT NULL,
    sealed_at       TEXT,
    host            TEXT,
    "user"          TEXT,
    git_sha         TEXT,
    project         TEXT,
    yath_version    TEXT,
    meta_extras     BLOB,    -- JSON catch-all for meta.json keys not promoted
    UNIQUE(archive_uuid)
);

CREATE TABLE runs (
    run_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    project_id      INTEGER NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
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
    times           BLOB,    -- JSON 4-tuple
    child_times     BLOB,    -- JSON
    child_wall      REAL,
    spec_extras     BLOB,    -- JSON
    state_extras    BLOB,    -- JSON
    UNIQUE(archive_id, run_uuid),
    UNIQUE(archive_id, run_ord)
);

CREATE INDEX runs_archive_idx ON runs(archive_id);
CREATE INDEX runs_project_idx ON runs(project_id);
CREATE INDEX runs_status_idx  ON runs(status);
CREATE INDEX runs_pass_idx    ON runs(pass);

CREATE TABLE services (
    service_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          INTEGER REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    role            TEXT
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

CREATE TABLE service_lifetimes (
    service_lifetime_id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id          INTEGER NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    lifetime_ord        INTEGER NOT NULL,
    status              TEXT,
    type                TEXT,
    id                  TEXT,
    service_name        TEXT,
    stage_name          TEXT,
    started_at          TEXT,
    ended_at            TEXT,
    "exit"              INTEGER,
    exit_decoded        BLOB,    -- JSON
    times               BLOB,    -- JSON 4-tuple
    child_times         BLOB,    -- JSON
    child_wall          REAL,
    spec_extras         BLOB,    -- JSON
    state_extras        BLOB,    -- JSON
    UNIQUE(service_id, lifetime_ord)
);

CREATE INDEX service_lifetimes_service_idx ON service_lifetimes(service_id);

CREATE TABLE test_files (
    test_file_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id      INTEGER NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    relative        TEXT    NOT NULL,
    UNIQUE(project_id, relative)
);

CREATE INDEX test_files_project_idx ON test_files(project_id);

CREATE TABLE jobs (
    job_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id)   ON DELETE CASCADE,
    run_id          INTEGER NOT NULL REFERENCES runs(run_id)           ON DELETE CASCADE,
    test_file_id    INTEGER NOT NULL REFERENCES test_files(test_file_id) ON DELETE CASCADE,
    job_ord         INTEGER NOT NULL,
    pass            INTEGER,
    status          TEXT,
    retry_count     INTEGER,
    UNIQUE(archive_id, run_id, job_ord)
);

CREATE INDEX jobs_run_pass_idx     ON jobs(run_id, pass);
CREATE INDEX jobs_test_file_idx    ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id          INTEGER NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER NOT NULL,
    status          TEXT,
    pass            INTEGER,
    "exit"          INTEGER,
    exit_decoded    BLOB,
    queued_at       TEXT,
    started_at      TEXT,
    ended_at        TEXT,
    pass_count      INTEGER,
    fail_count      INTEGER,
    assertion_count INTEGER,
    plan            BLOB,    -- JSON
    halt            BLOB,    -- JSON
    times           BLOB,    -- JSON 4-tuple
    child_times     BLOB,    -- JSON
    child_wall      REAL,
    spec_extras     BLOB,    -- JSON
    state_extras    BLOB,    -- JSON
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx ON job_tries(job_id);

CREATE TABLE job_specs (
    job_spec_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id              INTEGER NOT NULL REFERENCES jobs(job_id)             ON DELETE CASCADE,
    test_file_id        INTEGER NOT NULL REFERENCES test_files(test_file_id) ON DELETE CASCADE,
    absolute            TEXT,
    category            TEXT,
    duration            TEXT,
    stage               TEXT,
    features            BLOB,    -- JSON
    switches            BLOB,    -- JSON
    retry               INTEGER,
    retry_isolated      INTEGER,
    smoke               INTEGER,
    isolation           INTEGER,
    non_perl            INTEGER,
    is_binary           INTEGER,
    event_timeout       INTEGER,
    post_exit_timeout   INTEGER,
    min_slots           INTEGER,
    max_slots           INTEGER,
    ch_dir              TEXT,
    extras              BLOB,    -- JSON; conflicts, meta, comment, __test_file_class__, etc.
    UNIQUE(job_id)
);

CREATE INDEX job_specs_test_file_idx ON job_specs(test_file_id);
CREATE INDEX job_specs_job_idx       ON job_specs(job_id);

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
    archive_id      INTEGER NOT NULL REFERENCES archives(archive_id)   ON DELETE CASCADE,
    artifact_uuid   TEXT    NOT NULL COLLATE BINARY,
    run_id          INTEGER          REFERENCES runs(run_id)           ON DELETE CASCADE,
    service_id      INTEGER          REFERENCES services(service_id)   ON DELETE CASCADE,
    job_try_id      INTEGER          REFERENCES job_tries(job_try_id)  ON DELETE CASCADE,
    artifact_kind   TEXT    NOT NULL,
    format          TEXT    NOT NULL,
    name            TEXT,
    compressed      INTEGER NOT NULL,
    row_count       INTEGER,
    payload         BLOB    NOT NULL,
    created_at      TEXT    NOT NULL,
    sealed          INTEGER NOT NULL DEFAULT 0,
    CHECK (
        (CASE WHEN run_id     IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN service_id IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN job_try_id IS NULL THEN 1 ELSE 0 END)
        >= 2
    ),
    CHECK (artifact_kind IN ('events','attachment','arbitrary')),
    UNIQUE(archive_id, artifact_uuid)
);

-- Per-scope (artifact_kind, format, name) uniqueness. Split into one
-- partial index per scope kind so each only constrains rows belonging
-- to that scope (the other two FKs IS NULL). Archive-root scope = all
-- three FKs NULL.
CREATE UNIQUE INDEX artifacts_run_uk
    ON artifacts(archive_id, run_id, artifact_kind, format, name)
    WHERE run_id IS NOT NULL AND service_id IS NULL AND job_try_id IS NULL;
CREATE UNIQUE INDEX artifacts_service_uk
    ON artifacts(archive_id, service_id, artifact_kind, format, name)
    WHERE service_id IS NOT NULL AND run_id IS NULL AND job_try_id IS NULL;
CREATE UNIQUE INDEX artifacts_job_try_uk
    ON artifacts(archive_id, job_try_id, artifact_kind, format, name)
    WHERE job_try_id IS NOT NULL AND run_id IS NULL AND service_id IS NULL;
CREATE UNIQUE INDEX artifacts_archive_uk
    ON artifacts(archive_id, artifact_kind, format, name)
    WHERE run_id IS NULL AND service_id IS NULL AND job_try_id IS NULL;

CREATE INDEX artifacts_run_idx        ON artifacts(archive_id, run_id);
CREATE INDEX artifacts_service_idx    ON artifacts(archive_id, service_id);
CREATE INDEX artifacts_job_try_idx    ON artifacts(archive_id, job_try_id);
CREATE INDEX artifacts_kind_idx       ON artifacts(archive_id, artifact_kind);
