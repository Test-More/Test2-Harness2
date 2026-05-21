-- Test2::Harness2 PostgreSQL schema.
--
-- Conventions:
--   * Surrogate PK on every table: `<table>_id BIGSERIAL PRIMARY KEY`.
--   * UUID columns use the native UUID type. Generated in Perl via
--     Test2::Util::UUID (v7); never in the database.
--   * JSON columns are JSONB.
--   * Timestamps are DOUBLE PRECISION (fractional seconds since the
--     epoch, matching Time::HiRes::time()). Application sets them; no
--     SQL defaults.
--   * Booleans use the native BOOLEAN type.
--   * Binary blobs are BYTEA.
--
-- Compression:
--   TOAST handles per-column compression automatically for any value
--   that pushes its row past TOAST_TUPLE_THRESHOLD (~2KB). The DDL
--   does not specify a compression algorithm so the schema loads on
--   every supported PG version. The server's `default_toast_compression`
--   setting picks the algorithm; on PG 14+ admins should set
--   `default_toast_compression = 'lz4'` in postgresql.conf for faster
--   compress/decompress and slightly better ratio on the JSONB payload
--   columns (notably `coverage.payload` and `resources.payload`).
--   When PG eventually adds ZSTD as a TOAST algorithm the same GUC
--   picks it up with no schema change required.

CREATE TABLE users (
    user_id     BIGSERIAL    PRIMARY KEY,
    name        TEXT         NOT NULL,
    email       TEXT,
    UNIQUE(name)
);

CREATE INDEX users_email_idx ON users(email);

CREATE TABLE hosts (
    host_id     BIGSERIAL    PRIMARY KEY,
    name        TEXT         NOT NULL,
    UNIQUE(name)
);

CREATE TABLE projects (
    project_id  BIGSERIAL    PRIMARY KEY,
    name        TEXT         NOT NULL,
    UNIQUE(name)
);

CREATE TABLE versions (
    version_id  BIGSERIAL    PRIMARY KEY,
    project_id  BIGINT       NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    version     TEXT         NOT NULL,
    UNIQUE(project_id, version)
);

CREATE INDEX versions_project_idx ON versions(project_id);

CREATE TABLE vcs_info (
    vcs_info_id BIGSERIAL PRIMARY KEY,
    project_id  BIGINT    NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    branch      TEXT      NOT NULL,
    revision    TEXT      NOT NULL,
    dirty       BOOLEAN   NOT NULL DEFAULT FALSE,
    UNIQUE(project_id, branch, revision, dirty)
);

CREATE INDEX vcs_info_project_idx ON vcs_info(project_id);

CREATE TABLE instances (
    instance_id     BIGSERIAL        PRIMARY KEY,
    instance_uuid   UUID             NOT NULL,
    host_id         BIGINT           NOT NULL REFERENCES hosts(host_id),
    user_id         BIGINT           NOT NULL REFERENCES users(user_id),
    started         DOUBLE PRECISION NOT NULL,
    finished        DOUBLE PRECISION,
    meta            JSONB,
    finalized       DOUBLE PRECISION,
    UNIQUE(instance_uuid)
);

CREATE INDEX instances_host_idx ON instances(host_id);
CREATE INDEX instances_user_idx ON instances(user_id);

CREATE TABLE runners (
    runner_id   BIGSERIAL        PRIMARY KEY,
    instance_id BIGINT           NOT NULL REFERENCES instances(instance_id) ON DELETE CASCADE,
    pid         BIGINT           NOT NULL,
    started     DOUBLE PRECISION NOT NULL,
    finished    DOUBLE PRECISION,
    finalized   DOUBLE PRECISION
);

CREATE INDEX runners_instance_idx ON runners(instance_id);

CREATE TABLE collectors (
    collector_id    BIGSERIAL        PRIMARY KEY,
    runner_id       BIGINT           NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    name            TEXT             NOT NULL,
    pid             BIGINT           NOT NULL,
    watched         BIGINT,
    type            TEXT             NOT NULL,
    start_time      DOUBLE PRECISION NOT NULL,
    stop_time       DOUBLE PRECISION,
    exit_code       INTEGER,
    finalized       DOUBLE PRECISION,
    UNIQUE(runner_id, name)
);

CREATE INDEX collectors_runner_idx ON collectors(runner_id);
CREATE INDEX collectors_type_idx   ON collectors(type);

CREATE TABLE artifacts (
    artifact_id     BIGSERIAL    PRIMARY KEY,
    collector_id    BIGINT       NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    filename        TEXT         NOT NULL,
    content         BYTEA,
    local_path      TEXT,
    CHECK ((content IS NULL) <> (local_path IS NULL))
);

CREATE INDEX artifacts_collector_idx ON artifacts(collector_id);
CREATE INDEX artifacts_filename_idx  ON artifacts(filename);

CREATE TABLE runs (
    run_id      BIGSERIAL        PRIMARY KEY,
    run_uuid    UUID             NOT NULL,
    runner_id   BIGINT           NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    project_id  BIGINT           NOT NULL REFERENCES projects(project_id),
    version_id  BIGINT                    REFERENCES versions(version_id),
    vcs_info_id BIGINT                    REFERENCES vcs_info(vcs_info_id),
    user_id     BIGINT           NOT NULL REFERENCES users(user_id),
    run_ord     BIGINT           NOT NULL,
    started     DOUBLE PRECISION,
    finished    DOUBLE PRECISION,
    result      BOOLEAN,
    passed      BIGINT           NOT NULL DEFAULT 0,
    failed      BIGINT           NOT NULL DEFAULT 0,
    meta          JSONB,
    status        TEXT             NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
    has_coverage  BOOLEAN          NOT NULL DEFAULT FALSE,
    has_resources BOOLEAN          NOT NULL DEFAULT FALSE,
    UNIQUE(run_uuid),
    UNIQUE(runner_id, run_ord)
);

CREATE INDEX runs_runner_idx  ON runs(runner_id);
CREATE INDEX runs_project_idx ON runs(project_id);
CREATE INDEX runs_version_idx  ON runs(version_id);
CREATE INDEX runs_vcs_info_idx ON runs(vcs_info_id);
CREATE INDEX runs_user_idx    ON runs(user_id);
CREATE INDEX runs_result_idx  ON runs(result);

CREATE TABLE services (
    service_id      BIGSERIAL    PRIMARY KEY,
    collector_id    BIGINT       NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    runner_id       BIGINT       NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    run_id          BIGINT                REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT         NOT NULL,
    class           TEXT         NOT NULL,
    pid             BIGINT
);

CREATE UNIQUE INDEX services_unique_idx
    ON services(runner_id, COALESCE(run_id, 0), name);

CREATE INDEX services_collector_idx ON services(collector_id);
CREATE INDEX services_run_idx       ON services(run_id);

CREATE TABLE service_state (
    service_state_id    BIGSERIAL        PRIMARY KEY,
    service_id          BIGINT           NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    stamp               DOUBLE PRECISION NOT NULL,
    status              TEXT             NOT NULL,
    content             JSONB
);

CREATE INDEX service_state_service_idx ON service_state(service_id, stamp);
CREATE INDEX service_state_status_idx  ON service_state(status);

CREATE TABLE requests (
    request_id  BIGSERIAL        PRIMARY KEY,
    service_id  BIGINT           NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    requested   DOUBLE PRECISION NOT NULL,
    completed   DOUBLE PRECISION,
    finalized   DOUBLE PRECISION,
    payload     JSONB,
    response    JSONB
);

CREATE INDEX requests_service_idx   ON requests(service_id);
CREATE INDEX requests_completed_idx ON requests(service_id, completed);

CREATE TABLE test_files (
    test_file_id    BIGSERIAL    PRIMARY KEY,
    project_id      BIGINT       NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    relative        TEXT         NOT NULL,
    UNIQUE(project_id, relative)
);

CREATE INDEX test_files_project_idx ON test_files(project_id);

CREATE TABLE jobs (
    job_id          BIGSERIAL    PRIMARY KEY,
    run_id          BIGINT       NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    test_file_id    BIGINT       NOT NULL REFERENCES test_files(test_file_id),
    spec            JSONB
);

CREATE INDEX jobs_run_idx       ON jobs(run_id);
CREATE INDEX jobs_test_file_idx ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_id      BIGSERIAL        PRIMARY KEY,
    job_id          BIGINT           NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER          NOT NULL,
    started         DOUBLE PRECISION,
    finished        DOUBLE PRECISION,
    collector_id    BIGINT                    REFERENCES collectors(collector_id) ON DELETE SET NULL,
    result          BOOLEAN,
    passed          BIGINT           NOT NULL DEFAULT 0,
    failed          BIGINT           NOT NULL DEFAULT 0,
    subtests        INTEGER          NOT NULL DEFAULT 0,
    subtests_passed INTEGER          NOT NULL DEFAULT 0,
    subtests_failed INTEGER          NOT NULL DEFAULT 0,
    status          TEXT             NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx       ON job_tries(job_id);
CREATE INDEX job_tries_collector_idx ON job_tries(collector_id);
CREATE INDEX job_tries_result_idx    ON job_tries(result);

CREATE TABLE launchers (
    launcher_id     BIGSERIAL    PRIMARY KEY,
    runner_id       BIGINT       NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    run_id          BIGINT                REFERENCES runs(run_id) ON DELETE CASCADE,
    collector_id    BIGINT       NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    name            TEXT         NOT NULL,
    class           TEXT         NOT NULL,
    spec            JSONB,
    pid             BIGINT,
    spawn_socket    TEXT
);

CREATE INDEX launchers_runner_idx    ON launchers(runner_id);
CREATE INDEX launchers_run_idx       ON launchers(run_id);
CREATE INDEX launchers_collector_idx ON launchers(collector_id);

CREATE TABLE launches (
    launch_id   BIGSERIAL        PRIMARY KEY,
    launcher_id BIGINT           NOT NULL REFERENCES launchers(launcher_id) ON DELETE CASCADE,
    job_id      BIGINT           NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    requested   DOUBLE PRECISION NOT NULL,
    started     DOUBLE PRECISION
);

CREATE INDEX launches_launcher_idx ON launches(launcher_id, started);
CREATE INDEX launches_job_idx      ON launches(job_id);

CREATE TABLE coverage (
    coverage_id BIGSERIAL        PRIMARY KEY,
    run_id      BIGINT           NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    project_id  BIGINT           NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    source_file TEXT             NOT NULL,
    stamp       DOUBLE PRECISION NOT NULL,
    payload     JSONB            NOT NULL,
    UNIQUE(run_id, source_file)
);

CREATE INDEX coverage_project_source_stamp_idx ON coverage(project_id, source_file, stamp DESC);
CREATE INDEX coverage_project_run_idx          ON coverage(project_id, run_id);

CREATE TABLE schedulers (
    scheduler_id BIGSERIAL PRIMARY KEY,
    runner_id    BIGINT    NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    class        TEXT      NOT NULL,
    spec         JSONB,
    UNIQUE(runner_id)
);

CREATE TABLE resources (
    resource_id BIGSERIAL PRIMARY KEY,
    runner_id   BIGINT    NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    run_id      BIGINT             REFERENCES runs(run_id) ON DELETE CASCADE,
    class       TEXT      NOT NULL,
    spec        JSONB
);

CREATE INDEX resources_runner_idx ON resources(runner_id);
CREATE INDEX resources_run_idx    ON resources(run_id);

CREATE TABLE resource_snapshots (
    resource_snapshot_id BIGSERIAL        PRIMARY KEY,
    resource_id          BIGINT           NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    stamp                DOUBLE PRECISION NOT NULL,
    payload              JSONB            NOT NULL
);

CREATE INDEX resource_snapshots_resource_stamp_idx
    ON resource_snapshots(resource_id, stamp);
