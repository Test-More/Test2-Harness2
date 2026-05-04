-- App::Yath2::Log DB backend, PostgreSQL flavor (schema_version = 1).
-- Tested against PostgreSQL >= 14 (column-level COMPRESSION needs PG14+).
-- UUIDs supplied client-side (gen_uuid v7).
--
-- Identity convention: every PK is `<thing>_id BIGINT`, every UUID is
-- `<thing>_uuid UUID`. UUIDs are v7 (gen_uuid). No bare `id` / `uuid`.
--
-- Polymorphic scope on `artifacts`: `scope_kind` text + `scope_id` int.
-- No DB FK (caller-managed). CHECK constraint enforces enum values.
--
-- Payload compression: server-side TOAST LZ4 via column-level
-- COMPRESSION clause. App stores RAW bytes (compressed=FALSE).

CREATE TYPE scope_kind_t    AS ENUM ('archive','run','service','job_try');
CREATE TYPE artifact_kind_t AS ENUM ('events','state','spec','report','attachment','arbitrary');

CREATE TABLE archives (
    archive_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_uuid    UUID        NOT NULL,
    format_version  INTEGER     NOT NULL,
    schema_version  INTEGER     NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL,
    sealed_at       TIMESTAMPTZ,
    UNIQUE(archive_uuid)
);

CREATE TABLE runs (
    run_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT      NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_ord         INTEGER     NOT NULL,
    run_uuid        UUID        NOT NULL,
    status          TEXT        NOT NULL,
    pass            BOOLEAN,
    "exit"          INTEGER,
    exit_decoded    JSONB,
    aborted         BOOLEAN     NOT NULL DEFAULT FALSE,
    timed_out       BOOLEAN     NOT NULL DEFAULT FALSE,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    total_jobs      INTEGER,
    passed_jobs     INTEGER,
    failed_jobs     INTEGER,
    aborted_jobs    INTEGER,
    spec            JSONB,
    state           JSONB,
    UNIQUE(archive_id, run_uuid),
    UNIQUE(archive_id, run_ord)
);

CREATE INDEX runs_archive_idx ON runs(archive_id);
CREATE INDEX runs_status_idx  ON runs(status);
CREATE INDEX runs_pass_idx    ON runs(pass);

CREATE TABLE services (
    service_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          BIGINT REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT   NOT NULL,
    status          TEXT,
    spec            JSONB,
    state           JSONB
);

-- Global service: one row per (archive, name) when run_id IS NULL.
-- Run-scoped service: one row per (archive, run, name) when run_id IS NOT NULL.
CREATE UNIQUE INDEX services_global_name_uk
    ON services(archive_id, name)
    WHERE run_id IS NULL;
CREATE UNIQUE INDEX services_run_name_uk
    ON services(archive_id, run_id, name)
    WHERE run_id IS NOT NULL;
CREATE INDEX services_archive_idx ON services(archive_id);
CREATE INDEX services_run_idx     ON services(run_id);

CREATE TABLE jobs (
    job_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT  NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          BIGINT  NOT NULL REFERENCES runs(run_id)         ON DELETE CASCADE,
    job_ord         INTEGER NOT NULL,
    file            TEXT,
    pass            BOOLEAN,
    status          TEXT,
    retry_count     INTEGER,
    spec            JSONB COMPRESSION lz4,
    UNIQUE(archive_id, run_id, job_ord)
);

CREATE INDEX jobs_run_pass_idx ON jobs(run_id, pass);
CREATE INDEX jobs_file_idx     ON jobs(file);

CREATE TABLE job_tries (
    job_try_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id          BIGINT  NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER NOT NULL,
    status          TEXT,
    pass            BOOLEAN,
    "exit"          INTEGER,
    exit_decoded    JSONB,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    spec            JSONB COMPRESSION lz4,
    state           JSONB COMPRESSION lz4,
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx ON job_tries(job_id);

CREATE TABLE subtests (
    subtest_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_try_id      BIGINT  NOT NULL REFERENCES job_tries(job_try_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    pass            BOOLEAN NOT NULL,
    count_pass      INTEGER,
    count_fail      INTEGER,
    ord             INTEGER NOT NULL
);

CREATE INDEX subtests_jobtry_pass_idx ON subtests(job_try_id, pass);
CREATE INDEX subtests_name_idx        ON subtests(name);

CREATE TABLE artifacts (
    artifact_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT          NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    artifact_uuid   UUID            NOT NULL,
    scope_kind      scope_kind_t    NOT NULL,
    scope_id        BIGINT          NOT NULL,
    artifact_kind   artifact_kind_t NOT NULL,
    format          TEXT            NOT NULL,
    name            TEXT,
    compressed      BOOLEAN         NOT NULL,
    payload         BYTEA           COMPRESSION lz4 NOT NULL,
    created_at      TIMESTAMPTZ     NOT NULL,
    sealed          BOOLEAN         NOT NULL DEFAULT FALSE,
    UNIQUE(archive_id, artifact_uuid)
);

-- Per-scope (kind, format, name) uniqueness. Standard streams have
-- name IS NULL — split into two partial indexes for "NULL distinct"
-- behavior.
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
