-- App::Yath2::Log DB backend, PostgreSQL flavor.
-- Tested against PostgreSQL >= 15 for full zstd support; falls back
-- gracefully on older versions:
--   * PG15+ with --with-zstd : runs as written (zstd toast compression)
--   * PG14+ with --with-lz4  : runtime rewrite zstd -> lz4 at bootstrap
--   * PG14   without lz4     : runtime strips COMPRESSION; uses pglz
--   * PG13- (no GUC)         : runtime strips COMPRESSION; uses pglz
-- UUIDs supplied client-side (gen_uuid v7).
--
-- Identity convention: every PK is `<thing>_id BIGINT`, every UUID is
-- `<thing>_uuid UUID`. UUIDs are v7 (gen_uuid). No bare `id` / `uuid`.
--
-- Sub-archive scope on `artifacts`: three nullable FK columns
-- (`run_id`, `service_id`, `job_try_id`). A CHECK enforces "at most
-- one non-NULL" — zero non-NULL = archive-root scope; exactly one
-- non-NULL = scoped to that entity.
--
-- Payload compression: server-side TOAST zstd via column-level
-- COMPRESSION clause. App stores RAW bytes (compressed=FALSE).
-- App::Yath2::DB::SQL::preprocess_schema_sql probes server support
-- and downgrades to lz4 or strips the clause as needed.

CREATE TYPE artifact_kind_t AS ENUM ('events','attachment','arbitrary');

CREATE TABLE projects (
    project_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT   NOT NULL,
    UNIQUE(name)
);

CREATE TABLE archives (
    archive_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_uuid    UUID        NOT NULL,
    archive_version TEXT        NOT NULL,
    sealed_at       TIMESTAMPTZ,
    host            TEXT,
    "user"          TEXT,
    git_sha         TEXT,
    project         TEXT,
    yath_version    TEXT,
    meta_extras     JSONB COMPRESSION zstd,
    UNIQUE(archive_uuid)
);

CREATE TABLE runs (
    run_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT      NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    project_id      BIGINT      NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
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
    times           JSONB COMPRESSION zstd,
    child_times     JSONB COMPRESSION zstd,
    child_wall      DOUBLE PRECISION,
    spec_extras     JSONB COMPRESSION zstd,
    state_extras    JSONB COMPRESSION zstd,
    UNIQUE(archive_id, run_uuid),
    UNIQUE(archive_id, run_ord)
);

CREATE INDEX runs_archive_idx ON runs(archive_id);
CREATE INDEX runs_project_idx ON runs(project_id);
CREATE INDEX runs_status_idx  ON runs(status);
CREATE INDEX runs_pass_idx    ON runs(pass);

CREATE TABLE services (
    service_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT NOT NULL REFERENCES archives(archive_id) ON DELETE CASCADE,
    run_id          BIGINT REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT   NOT NULL,
    role            TEXT
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

CREATE TABLE service_lifetimes (
    service_lifetime_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_id          BIGINT      NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    lifetime_ord        INTEGER     NOT NULL,
    status              TEXT,
    type                TEXT,
    id                  TEXT,
    service_name        TEXT,
    stage_name          TEXT,
    started_at          TIMESTAMPTZ,
    ended_at            TIMESTAMPTZ,
    "exit"              INTEGER,
    exit_decoded        JSONB COMPRESSION zstd,
    times               JSONB COMPRESSION zstd,
    child_times         JSONB COMPRESSION zstd,
    child_wall          DOUBLE PRECISION,
    spec_extras         JSONB COMPRESSION zstd,
    state_extras        JSONB COMPRESSION zstd,
    UNIQUE(service_id, lifetime_ord)
);

CREATE INDEX service_lifetimes_service_idx ON service_lifetimes(service_id);

CREATE TABLE test_files (
    test_file_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id      BIGINT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    relative        TEXT   NOT NULL,
    UNIQUE(project_id, relative)
);

CREATE INDEX test_files_project_idx ON test_files(project_id);

CREATE TABLE jobs (
    job_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archive_id      BIGINT  NOT NULL REFERENCES archives(archive_id)   ON DELETE CASCADE,
    run_id          BIGINT  NOT NULL REFERENCES runs(run_id)           ON DELETE CASCADE,
    test_file_id    BIGINT  NOT NULL REFERENCES test_files(test_file_id) ON DELETE CASCADE,
    job_ord         INTEGER NOT NULL,
    pass            BOOLEAN,
    status          TEXT,
    retry_count     INTEGER,
    UNIQUE(archive_id, run_id, job_ord)
);

CREATE INDEX jobs_run_pass_idx     ON jobs(run_id, pass);
CREATE INDEX jobs_test_file_idx    ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id          BIGINT  NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER NOT NULL,
    status          TEXT,
    pass            BOOLEAN,
    "exit"          INTEGER,
    exit_decoded    JSONB,
    queued_at       TIMESTAMPTZ,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    pass_count      INTEGER,
    fail_count      INTEGER,
    assertion_count INTEGER,
    plan            JSONB COMPRESSION zstd,
    halt            JSONB COMPRESSION zstd,
    times           JSONB COMPRESSION zstd,
    child_times     JSONB COMPRESSION zstd,
    child_wall      DOUBLE PRECISION,
    spec_extras     JSONB COMPRESSION zstd,
    state_extras    JSONB COMPRESSION zstd,
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx ON job_tries(job_id);

CREATE TABLE job_specs (
    job_spec_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id              BIGINT  NOT NULL REFERENCES jobs(job_id)             ON DELETE CASCADE,
    test_file_id        BIGINT  NOT NULL REFERENCES test_files(test_file_id) ON DELETE CASCADE,
    absolute            TEXT,
    category            TEXT,
    duration            TEXT,
    stage               TEXT,
    features            JSONB COMPRESSION zstd,
    switches            JSONB COMPRESSION zstd,
    retry               INTEGER,
    retry_isolated      BOOLEAN,
    smoke               BOOLEAN,
    isolation           BOOLEAN,
    non_perl            BOOLEAN,
    is_binary           BOOLEAN,
    event_timeout       INTEGER,
    post_exit_timeout   INTEGER,
    min_slots           INTEGER,
    max_slots           INTEGER,
    ch_dir              TEXT,
    extras              JSONB COMPRESSION zstd,
    UNIQUE(job_id)
);

CREATE INDEX job_specs_test_file_idx ON job_specs(test_file_id);
CREATE INDEX job_specs_job_idx       ON job_specs(job_id);

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
    archive_id      BIGINT          NOT NULL REFERENCES archives(archive_id)   ON DELETE CASCADE,
    artifact_uuid   UUID            NOT NULL,
    run_id          BIGINT                   REFERENCES runs(run_id)           ON DELETE CASCADE,
    service_id      BIGINT                   REFERENCES services(service_id)   ON DELETE CASCADE,
    job_try_id      BIGINT                   REFERENCES job_tries(job_try_id)  ON DELETE CASCADE,
    artifact_kind   artifact_kind_t NOT NULL,
    format          TEXT            NOT NULL,
    name            TEXT,
    compressed      BOOLEAN         NOT NULL,
    payload         BYTEA           COMPRESSION zstd NOT NULL,
    created_at      TIMESTAMPTZ     NOT NULL,
    sealed          BOOLEAN         NOT NULL DEFAULT FALSE,
    CHECK (
        (CASE WHEN run_id     IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN service_id IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN job_try_id IS NULL THEN 1 ELSE 0 END)
        >= 2
    ),
    UNIQUE(archive_id, artifact_uuid)
);

-- Per-scope (artifact_kind, format, name) uniqueness. One partial
-- index per scope kind, plus one for archive-root (all FKs NULL).
-- Postgres treats NULLs as distinct in UNIQUE by default, so the
-- partial predicates also serve as the "NULL-distinct" guard.
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
