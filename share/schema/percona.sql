-- Test2::Harness2 Percona schema.
--
-- Shaped identically to mysql.sql: Percona Server is a drop-in MySQL
-- replacement and the same DDL works. Kept as a separate file so a
-- flavor-specific tweak in one does not silently affect the other.
--
-- Conventions:
--   * Surrogate PK on every table: `<table>_id BIGINT UNSIGNED
--     NOT NULL AUTO_INCREMENT PRIMARY KEY`.
--   * UUIDs are stored as BINARY(16). Each UUID column has a shadow
--     `<thing>_uuid_string CHAR(36)` column populated automatically by
--     BEFORE INSERT / BEFORE UPDATE triggers, so the canonical
--     human-readable form is always current without an application-
--     level write. UUIDs are generated in Perl (v7) via
--     Test2::Util::UUID; never in the database.
--   * JSON columns use the native JSON type.
--   * Timestamps are DOUBLE (fractional seconds since the epoch,
--     matching Time::HiRes::time()).
--   * Booleans use BOOLEAN (TINYINT(1) alias).
--   * Binary blobs are LONGBLOB.
--   * MySQL 8.0.16+ honors CHECK constraints; older versions parse and
--     ignore them. Application code enforces the same invariants either
--     way.
--   * Engine: InnoDB. Charset: utf8mb4 / utf8mb4_bin (BINARY collation
--     on UUID-shadow columns; case-sensitive identifiers).

SET default_storage_engine = InnoDB;

CREATE TABLE users (
    user_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(191) NOT NULL,
    email       VARCHAR(191),
    UNIQUE KEY users_name_unique (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX users_email_idx ON users(email);

CREATE TABLE hosts (
    host_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(191) NOT NULL,
    UNIQUE KEY hosts_name_unique (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE projects (
    project_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(191) NOT NULL,
    UNIQUE KEY projects_name_unique (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE versions (
    version_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id  BIGINT UNSIGNED NOT NULL,
    version     VARCHAR(191) NOT NULL,
    UNIQUE KEY versions_project_version_unique (project_id, version),
    CONSTRAINT versions_project_fk FOREIGN KEY (project_id)
        REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX versions_project_idx ON versions(project_id);

CREATE TABLE vcs_info (
    vcs_info_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id  BIGINT UNSIGNED NOT NULL,
    branch      VARCHAR(255) NOT NULL,
    revision    VARCHAR(64)  NOT NULL,
    dirty       BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE KEY vcs_info_unique (project_id, branch, revision, dirty),
    CONSTRAINT vcs_info_project_fk FOREIGN KEY (project_id)
        REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX vcs_info_project_idx ON vcs_info(project_id);

CREATE TABLE instances (
    instance_id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    instance_uuid        BINARY(16) NOT NULL,
    instance_uuid_string CHAR(36) COLLATE utf8mb4_bin NOT NULL DEFAULT '',
    host_id              BIGINT UNSIGNED NOT NULL,
    user_id              BIGINT UNSIGNED NOT NULL,
    started              DOUBLE NOT NULL,
    finished             DOUBLE,
    meta                 JSON,
    finalized            DOUBLE,
    UNIQUE KEY instances_uuid_unique (instance_uuid),
    CONSTRAINT instances_host_fk FOREIGN KEY (host_id) REFERENCES hosts(host_id),
    CONSTRAINT instances_user_fk FOREIGN KEY (user_id) REFERENCES users(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX instances_host_idx ON instances(host_id);
CREATE INDEX instances_user_idx ON instances(user_id);

CREATE TRIGGER instances_uuid_string_bi BEFORE INSERT ON instances FOR EACH ROW
    SET NEW.instance_uuid_string = LOWER(CONCAT(
        HEX(SUBSTRING(NEW.instance_uuid, 1, 4)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 5, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 7, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 9, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 11, 6))));

CREATE TRIGGER instances_uuid_string_bu BEFORE UPDATE ON instances FOR EACH ROW
    SET NEW.instance_uuid_string = LOWER(CONCAT(
        HEX(SUBSTRING(NEW.instance_uuid, 1, 4)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 5, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 7, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 9, 2)), '-',
        HEX(SUBSTRING(NEW.instance_uuid, 11, 6))));

CREATE TABLE runners (
    runner_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    instance_id BIGINT UNSIGNED NOT NULL,
    pid         BIGINT NOT NULL,
    started     DOUBLE NOT NULL,
    finished    DOUBLE,
    finalized   DOUBLE,
    CONSTRAINT runners_instance_fk FOREIGN KEY (instance_id)
        REFERENCES instances(instance_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX runners_instance_idx ON runners(instance_id);

CREATE TABLE collectors (
    collector_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    runner_id       BIGINT UNSIGNED NOT NULL,
    name            VARCHAR(191) NOT NULL,
    pid             BIGINT NOT NULL,
    watched         BIGINT,
    is_test         BOOLEAN NOT NULL DEFAULT FALSE,
    start_time      DOUBLE NOT NULL,
    stop_time       DOUBLE,
    exit_code       INT,
    exit_err        INT,
    exit_sig        INT,
    finalized       DOUBLE,
    UNIQUE KEY collectors_runner_name_unique (runner_id, name),
    CONSTRAINT collectors_runner_fk FOREIGN KEY (runner_id)
        REFERENCES runners(runner_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX collectors_runner_idx ON collectors(runner_id);

CREATE TABLE artifacts (
    artifact_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    collector_id    BIGINT UNSIGNED NOT NULL,
    filename        VARCHAR(191) NOT NULL,
    content         LONGBLOB,
    local_path      TEXT,
    CONSTRAINT artifacts_content_xor CHECK ((content IS NULL) <> (local_path IS NULL)),
    CONSTRAINT artifacts_collector_fk FOREIGN KEY (collector_id)
        REFERENCES collectors(collector_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX artifacts_collector_idx ON artifacts(collector_id);
CREATE INDEX artifacts_filename_idx  ON artifacts(filename);

CREATE TABLE runs (
    run_id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_uuid          BINARY(16) NOT NULL,
    run_uuid_string   CHAR(36) COLLATE utf8mb4_bin NOT NULL DEFAULT '',
    runner_id         BIGINT UNSIGNED NOT NULL,
    project_id        BIGINT UNSIGNED NOT NULL,
    version_id        BIGINT UNSIGNED,
    vcs_info_id       BIGINT UNSIGNED,
    user_id           BIGINT UNSIGNED NOT NULL,
    run_ord           BIGINT NOT NULL,
    started           DOUBLE,
    finished          DOUBLE,
    result            BOOLEAN,
    passed            BIGINT NOT NULL DEFAULT 0,
    failed            BIGINT NOT NULL DEFAULT 0,
    meta              JSON,
    status            VARCHAR(32) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
    has_coverage      BOOLEAN NOT NULL DEFAULT FALSE,
    has_resources     BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE KEY runs_uuid_unique (run_uuid),
    UNIQUE KEY runs_runner_ord_unique (runner_id, run_ord),
    CONSTRAINT runs_runner_fk   FOREIGN KEY (runner_id)   REFERENCES runners(runner_id)   ON DELETE CASCADE,
    CONSTRAINT runs_project_fk  FOREIGN KEY (project_id)  REFERENCES projects(project_id),
    CONSTRAINT runs_version_fk  FOREIGN KEY (version_id)  REFERENCES versions(version_id),
    CONSTRAINT runs_vcs_info_fk FOREIGN KEY (vcs_info_id) REFERENCES vcs_info(vcs_info_id),
    CONSTRAINT runs_user_fk     FOREIGN KEY (user_id)     REFERENCES users(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX runs_runner_idx   ON runs(runner_id);
CREATE INDEX runs_project_idx  ON runs(project_id);
CREATE INDEX runs_version_idx  ON runs(version_id);
CREATE INDEX runs_vcs_info_idx ON runs(vcs_info_id);
CREATE INDEX runs_user_idx    ON runs(user_id);
CREATE INDEX runs_result_idx  ON runs(result);

CREATE TRIGGER runs_uuid_string_bi BEFORE INSERT ON runs FOR EACH ROW
    SET NEW.run_uuid_string = LOWER(CONCAT(
        HEX(SUBSTRING(NEW.run_uuid, 1, 4)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 5, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 7, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 9, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 11, 6))));

CREATE TRIGGER runs_uuid_string_bu BEFORE UPDATE ON runs FOR EACH ROW
    SET NEW.run_uuid_string = LOWER(CONCAT(
        HEX(SUBSTRING(NEW.run_uuid, 1, 4)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 5, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 7, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 9, 2)), '-',
        HEX(SUBSTRING(NEW.run_uuid, 11, 6))));

CREATE TABLE services (
    service_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    collector_id    BIGINT UNSIGNED NOT NULL,
    runner_id       BIGINT UNSIGNED NOT NULL,
    run_id          BIGINT UNSIGNED,
    name            VARCHAR(191) NOT NULL,
    class           VARCHAR(191) NOT NULL,
    pid             BIGINT,
    UNIQUE KEY services_unique (runner_id, run_id, name),
    CONSTRAINT services_collector_fk FOREIGN KEY (collector_id) REFERENCES collectors(collector_id) ON DELETE CASCADE,
    CONSTRAINT services_runner_fk    FOREIGN KEY (runner_id)    REFERENCES runners(runner_id)    ON DELETE CASCADE,
    CONSTRAINT services_run_fk       FOREIGN KEY (run_id)       REFERENCES runs(run_id)       ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX services_collector_idx ON services(collector_id);
CREATE INDEX services_run_idx       ON services(run_id);

CREATE TABLE service_state (
    service_state_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    service_id          BIGINT UNSIGNED NOT NULL,
    stamp               DOUBLE NOT NULL,
    status              VARCHAR(32) NOT NULL,
    content             JSON,
    CONSTRAINT service_state_service_fk FOREIGN KEY (service_id)
        REFERENCES services(service_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX service_state_service_idx ON service_state(service_id, stamp);
CREATE INDEX service_state_status_idx  ON service_state(status);

CREATE TABLE requests (
    request_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    service_id  BIGINT UNSIGNED NOT NULL,
    requested   DOUBLE NOT NULL,
    completed   DOUBLE,
    finalized   DOUBLE,
    payload     JSON,
    response    JSON,
    CONSTRAINT requests_service_fk FOREIGN KEY (service_id)
        REFERENCES services(service_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX requests_service_idx   ON requests(service_id);
CREATE INDEX requests_completed_idx ON requests(service_id, completed);

CREATE TABLE test_files (
    test_file_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id      BIGINT UNSIGNED NOT NULL,
    relative        VARCHAR(255) NOT NULL,
    UNIQUE KEY test_files_project_relative_unique (project_id, relative),
    CONSTRAINT test_files_project_fk FOREIGN KEY (project_id)
        REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX test_files_project_idx ON test_files(project_id);

CREATE TABLE jobs (
    job_id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_id          BIGINT UNSIGNED NOT NULL,
    test_file_id    BIGINT UNSIGNED NOT NULL,
    spec            JSON,
    CONSTRAINT jobs_run_fk       FOREIGN KEY (run_id)       REFERENCES runs(run_id)             ON DELETE CASCADE,
    CONSTRAINT jobs_test_file_fk FOREIGN KEY (test_file_id) REFERENCES test_files(test_file_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX jobs_run_idx       ON jobs(run_id);
CREATE INDEX jobs_test_file_idx ON jobs(test_file_id);

CREATE TABLE job_tries (
    job_try_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_id          BIGINT UNSIGNED NOT NULL,
    try_ord         INT NOT NULL,
    started         DOUBLE,
    finished        DOUBLE,
    collector_id    BIGINT UNSIGNED,
    result          BOOLEAN,
    passed          BIGINT NOT NULL DEFAULT 0,
    failed          BIGINT NOT NULL DEFAULT 0,
    subtests        INT NOT NULL DEFAULT 0,
    subtests_passed INT NOT NULL DEFAULT 0,
    subtests_failed INT NOT NULL DEFAULT 0,
    status          VARCHAR(32) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'complete', 'broken', 'canceled')),
    UNIQUE KEY job_tries_job_try_unique (job_id, try_ord),
    CONSTRAINT job_tries_job_fk       FOREIGN KEY (job_id)       REFERENCES jobs(job_id)             ON DELETE CASCADE,
    CONSTRAINT job_tries_collector_fk FOREIGN KEY (collector_id) REFERENCES collectors(collector_id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX job_tries_job_idx       ON job_tries(job_id);
CREATE INDEX job_tries_collector_idx ON job_tries(collector_id);
CREATE INDEX job_tries_result_idx    ON job_tries(result);

CREATE TABLE launchers (
    launcher_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    runner_id       BIGINT UNSIGNED NOT NULL,
    run_id          BIGINT UNSIGNED,
    collector_id    BIGINT UNSIGNED NOT NULL,
    name            VARCHAR(191) NOT NULL,
    class           VARCHAR(191) NOT NULL,
    spec            JSON,
    pid             BIGINT,
    spawn_socket    TEXT,
    CONSTRAINT launchers_runner_fk    FOREIGN KEY (runner_id)    REFERENCES runners(runner_id)    ON DELETE CASCADE,
    CONSTRAINT launchers_run_fk       FOREIGN KEY (run_id)       REFERENCES runs(run_id)       ON DELETE CASCADE,
    CONSTRAINT launchers_collector_fk FOREIGN KEY (collector_id) REFERENCES collectors(collector_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX launchers_runner_idx    ON launchers(runner_id);
CREATE INDEX launchers_run_idx       ON launchers(run_id);
CREATE INDEX launchers_collector_idx ON launchers(collector_id);

CREATE TABLE launches (
    launch_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    launcher_id BIGINT UNSIGNED NOT NULL,
    job_id      BIGINT UNSIGNED NOT NULL,
    requested   DOUBLE NOT NULL,
    started     DOUBLE,
    CONSTRAINT launches_launcher_fk FOREIGN KEY (launcher_id) REFERENCES launchers(launcher_id) ON DELETE CASCADE,
    CONSTRAINT launches_job_fk      FOREIGN KEY (job_id)      REFERENCES jobs(job_id)           ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX launches_launcher_idx ON launches(launcher_id, started);
CREATE INDEX launches_job_idx      ON launches(job_id);

CREATE TABLE coverage (
    coverage_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_id      BIGINT UNSIGNED NOT NULL,
    project_id  BIGINT UNSIGNED NOT NULL,
    source_file VARCHAR(512) NOT NULL,
    stamp       DOUBLE NOT NULL,
    payload     JSON NOT NULL,
    UNIQUE KEY coverage_run_source_unique (run_id, source_file),
    CONSTRAINT coverage_run_fk     FOREIGN KEY (run_id)     REFERENCES runs(run_id)         ON DELETE CASCADE,
    CONSTRAINT coverage_project_fk FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8;

CREATE INDEX coverage_project_source_stamp_idx ON coverage(project_id, source_file, stamp);
CREATE INDEX coverage_project_run_idx          ON coverage(project_id, run_id);

CREATE TABLE schedulers (
    scheduler_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    runner_id    BIGINT UNSIGNED NOT NULL,
    class        VARCHAR(191) NOT NULL,
    spec         JSON,
    UNIQUE KEY schedulers_runner_unique (runner_id),
    CONSTRAINT schedulers_runner_fk FOREIGN KEY (runner_id) REFERENCES runners(runner_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE resources (
    resource_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    runner_id   BIGINT UNSIGNED NOT NULL,
    run_id      BIGINT UNSIGNED,
    class       VARCHAR(191) NOT NULL,
    spec        JSON,
    CONSTRAINT resources_runner_fk FOREIGN KEY (runner_id) REFERENCES runners(runner_id) ON DELETE CASCADE,
    CONSTRAINT resources_run_fk    FOREIGN KEY (run_id)    REFERENCES runs(run_id)       ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX resources_runner_idx ON resources(runner_id);
CREATE INDEX resources_run_idx    ON resources(run_id);

CREATE TABLE resource_snapshots (
    resource_snapshot_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    resource_id          BIGINT UNSIGNED NOT NULL,
    stamp                DOUBLE NOT NULL,
    payload              JSON NOT NULL,
    CONSTRAINT resource_snapshots_resource_fk FOREIGN KEY (resource_id) REFERENCES resources(resource_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8;

CREATE INDEX resource_snapshots_resource_stamp_idx
    ON resource_snapshots(resource_id, stamp);
