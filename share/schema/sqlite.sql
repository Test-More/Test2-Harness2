-- Test2::Harness2 SQLite schema.
--
-- Conventions:
--   * Every table has a `<table>_id INTEGER PRIMARY KEY AUTOINCREMENT`
--     surrogate key. Foreign keys reference these.
--   * UUIDs are stored as TEXT (canonical 36-character form). SQLite has
--     no native UUID type. UUIDs are generated in Perl via
--     Test2::Util::UUID (v7), never in the database.
--   * Timestamps are REAL (fractional seconds since the epoch -- the
--     same shape Time::HiRes::time() produces). Application sets them;
--     no SQL defaults.
--   * JSON columns are TEXT. The application encodes / decodes; no
--     JSON-typed columns or constraints because broad SQLite portability
--     matters more than column-typed JSON validation.
--   * Booleans are INTEGER 0 / 1.
--   * Binary blobs are BLOB.
--
-- Recommended PRAGMAs (the connecting code applies these, not the
-- schema):
--
--   PRAGMA journal_mode = WAL;
--   PRAGMA synchronous   = NORMAL;
--   PRAGMA busy_timeout  = 5000;
--   PRAGMA foreign_keys  = ON;
--   PRAGMA temp_store    = MEMORY;

CREATE TABLE users (
    user_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    email       TEXT,
    UNIQUE(name)
);

CREATE INDEX users_email_idx ON users(email);

CREATE TABLE hosts (
    host_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    UNIQUE(name)
);

CREATE TABLE projects (
    project_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    UNIQUE(name)
);

CREATE TABLE versions (
    version_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    version     TEXT    NOT NULL,
    UNIQUE(project_id, version)
);

CREATE INDEX versions_project_idx ON versions(project_id);

CREATE TABLE vcs_info (
    vcs_info_id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    branch      TEXT    NOT NULL,
    revision    TEXT    NOT NULL,
    dirty       INTEGER NOT NULL DEFAULT 0,
    UNIQUE(project_id, branch, revision, dirty)
);

CREATE INDEX vcs_info_project_idx ON vcs_info(project_id);

CREATE TABLE instances (
    instance_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    instance_uuid   TEXT    NOT NULL COLLATE BINARY,
    host_id         INTEGER NOT NULL REFERENCES hosts(host_id),
    user_id         INTEGER NOT NULL REFERENCES users(user_id),
    started         REAL    NOT NULL,
    finished        REAL,
    meta            TEXT,
    finalized       REAL,
    UNIQUE(instance_uuid)
);

CREATE INDEX instances_host_idx ON instances(host_id);
CREATE INDEX instances_user_idx ON instances(user_id);

CREATE TABLE runners (
    runner_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    instance_id INTEGER NOT NULL REFERENCES instances(instance_id) ON DELETE CASCADE,
    pid         INTEGER NOT NULL,
    started     REAL    NOT NULL,
    finished    REAL,
    finalized   REAL
);

CREATE INDEX runners_instance_idx ON runners(instance_id);

CREATE TABLE collectors (
    collector_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    runner_id       INTEGER NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    pid             INTEGER NOT NULL,
    watched         INTEGER,
    type            TEXT    NOT NULL,
    start_time      REAL    NOT NULL,
    stop_time       REAL,
    exit_code       INTEGER,
    finalized       REAL,
    UNIQUE(runner_id, name)
);

CREATE INDEX collectors_runner_idx ON collectors(runner_id);
CREATE INDEX collectors_type_idx   ON collectors(type);

CREATE TABLE artifacts (
    artifact_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    collector_id    INTEGER NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    filename        TEXT    NOT NULL,
    content         BLOB,
    local_path      TEXT,
    CHECK ((content IS NULL) <> (local_path IS NULL))
);

CREATE INDEX artifacts_collector_idx ON artifacts(collector_id);
CREATE INDEX artifacts_filename_idx  ON artifacts(filename);

CREATE TABLE runs (
    run_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_uuid    TEXT    NOT NULL COLLATE BINARY,
    runner_id   INTEGER NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    project_id  INTEGER NOT NULL REFERENCES projects(project_id),
    version_id  INTEGER          REFERENCES versions(version_id),
    vcs_info_id INTEGER          REFERENCES vcs_info(vcs_info_id),
    user_id     INTEGER NOT NULL REFERENCES users(user_id),
    run_ord     INTEGER NOT NULL,
    started     REAL,
    finished    REAL,
    result      INTEGER,
    passed      INTEGER NOT NULL DEFAULT 0,
    failed      INTEGER NOT NULL DEFAULT 0,
    meta        TEXT,
    status      TEXT    NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
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
    service_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    collector_id    INTEGER NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    runner_id       INTEGER NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    run_id          INTEGER          REFERENCES runs(run_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    class           TEXT    NOT NULL,
    pid             INTEGER
);

CREATE UNIQUE INDEX services_unique_idx
    ON services(runner_id, IFNULL(run_id, 0), name);

CREATE INDEX services_collector_idx ON services(collector_id);
CREATE INDEX services_run_idx       ON services(run_id);

CREATE TABLE service_state (
    service_state_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id          INTEGER NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    stamp               REAL    NOT NULL,
    status              TEXT    NOT NULL,
    content             TEXT
);

CREATE INDEX service_state_service_idx ON service_state(service_id, stamp);
CREATE INDEX service_state_status_idx  ON service_state(status);

CREATE TABLE requests (
    request_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id  INTEGER NOT NULL REFERENCES services(service_id) ON DELETE CASCADE,
    requested   REAL    NOT NULL,
    completed   REAL,
    finalized   REAL,
    payload     TEXT,
    response    TEXT
);

CREATE INDEX requests_service_idx   ON requests(service_id);
CREATE INDEX requests_completed_idx ON requests(service_id, completed);

CREATE TABLE test_files (
    test_file_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id      INTEGER NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    relative        TEXT    NOT NULL,
    UNIQUE(project_id, relative)
);

CREATE INDEX test_files_project_idx ON test_files(project_id);

CREATE TABLE jobs (
    job_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    test_file_id    INTEGER NOT NULL REFERENCES test_files(test_file_id),
    spec            TEXT
);

CREATE INDEX jobs_run_idx       ON jobs(run_id);
CREATE INDEX jobs_test_file_idx ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id          INTEGER NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    try_ord         INTEGER NOT NULL,
    started         REAL,
    finished        REAL,
    collector_id    INTEGER          REFERENCES collectors(collector_id) ON DELETE SET NULL,
    result          INTEGER,
    passed          INTEGER NOT NULL DEFAULT 0,
    failed          INTEGER NOT NULL DEFAULT 0,
    subtests        INTEGER NOT NULL DEFAULT 0,
    subtests_passed INTEGER NOT NULL DEFAULT 0,
    subtests_failed INTEGER NOT NULL DEFAULT 0,
    status          TEXT    NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
    UNIQUE(job_id, try_ord)
);

CREATE INDEX job_tries_job_idx       ON job_tries(job_id);
CREATE INDEX job_tries_collector_idx ON job_tries(collector_id);
CREATE INDEX job_tries_result_idx    ON job_tries(result);

CREATE TABLE launchers (
    launcher_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    runner_id       INTEGER NOT NULL REFERENCES runners(runner_id) ON DELETE CASCADE,
    run_id          INTEGER          REFERENCES runs(run_id) ON DELETE CASCADE,
    collector_id    INTEGER NOT NULL REFERENCES collectors(collector_id) ON DELETE CASCADE,
    name            TEXT    NOT NULL,
    class           TEXT    NOT NULL,
    spec            TEXT,
    pid             INTEGER,
    spawn_socket    TEXT
);

CREATE INDEX launchers_runner_idx    ON launchers(runner_id);
CREATE INDEX launchers_run_idx       ON launchers(run_id);
CREATE INDEX launchers_collector_idx ON launchers(collector_id);

CREATE TABLE launches (
    launch_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    launcher_id INTEGER NOT NULL REFERENCES launchers(launcher_id) ON DELETE CASCADE,
    job_id      INTEGER NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    requested   REAL    NOT NULL,
    started     REAL
);

CREATE INDEX launches_launcher_idx ON launches(launcher_id, started);
CREATE INDEX launches_job_idx      ON launches(job_id);
