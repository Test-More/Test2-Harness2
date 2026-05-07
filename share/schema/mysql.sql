-- App::Yath2::Log DB backend, MySQL/Percona flavor.
-- Requires MySQL >= 8.0.16 (CHECK enforcement; native JSON; recursive
-- CTEs; multi-trigger BEFORE INSERT/UPDATE).
-- All tables: ENGINE=InnoDB, CHARSET=utf8mb4, COLLATE=utf8mb4_unicode_ci.
--
-- Identity convention: every PK is `<thing>_id BIGINT`, every UUID is
-- `<thing>_uuid BINARY(16)`. UUIDs are v7 (gen_uuid). MySQL has no
-- native UUID type. We do NOT use UUID_TO_BIN's swap_flag; v7 UUIDs
-- already start with the timestamp.
--
-- Every binary UUID column has a sibling `<col>_string TEXT(36) NULL`
-- column populated by trigger on INSERT and UPDATE. Application code
-- only writes the binary column; the string column is a read-only
-- convenience for human DB users (indexed). Per F13.
--
-- Sub-archive scope on `artifacts`: three nullable FK columns
-- (`run_id`, `service_id`, `job_try_id`). A CHECK enforces "at most
-- one non-NULL" — zero non-NULL = archive-root scope; exactly one
-- non-NULL = scoped to that entity.
--
-- Payload compression: client-side zstd. App compresses bytes before
-- INSERT and stores compressed=1. (No native zstd-capable server-side
-- compression on stock MySQL.)

CREATE TABLE projects (
    project_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    UNIQUE KEY projects_name_uk (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE archives (
    archive_id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_uuid        BINARY(16)   NOT NULL,
    archive_uuid_string CHAR(36),
    archive_version     VARCHAR(64)  NOT NULL,
    created_at          DATETIME(6)  NOT NULL,
    sealed_at           DATETIME(6),
    UNIQUE KEY archives_uuid_uk        (archive_uuid),
    UNIQUE KEY archives_uuid_string_uk (archive_uuid_string)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TRIGGER archives_uuid_str_ins
    BEFORE INSERT ON archives
    FOR EACH ROW SET NEW.archive_uuid_string = BIN_TO_UUID(NEW.archive_uuid);
CREATE TRIGGER archives_uuid_str_upd
    BEFORE UPDATE ON archives
    FOR EACH ROW SET NEW.archive_uuid_string = BIN_TO_UUID(NEW.archive_uuid);

CREATE TABLE runs (
    run_id           BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id       BIGINT       NOT NULL,
    project_id       BIGINT       NOT NULL,
    run_ord          INT          NOT NULL,
    run_uuid         BINARY(16)   NOT NULL,
    run_uuid_string  CHAR(36),
    status           VARCHAR(32)  NOT NULL,
    pass             TINYINT(1),
    `exit`           INT,
    exit_decoded     JSON,
    aborted          TINYINT(1)   NOT NULL DEFAULT 0,
    timed_out        TINYINT(1)   NOT NULL DEFAULT 0,
    started_at       DATETIME(6),
    ended_at         DATETIME(6),
    total_jobs       INT,
    passed_jobs      INT,
    failed_jobs      INT,
    aborted_jobs     INT,
    times            JSON,
    child_times      JSON,
    child_wall       DOUBLE,
    spec_extras      JSON,
    state_extras     JSON,
    UNIQUE KEY runs_archive_uuid_uk        (archive_id, run_uuid),
    UNIQUE KEY runs_archive_uuid_string_uk (archive_id, run_uuid_string),
    UNIQUE KEY runs_archive_ord_uk         (archive_id, run_ord),
    KEY runs_archive_idx (archive_id),
    KEY runs_project_idx (project_id),
    KEY runs_status_idx  (status),
    KEY runs_pass_idx    (pass),
    CONSTRAINT runs_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE,
    CONSTRAINT runs_project_fk FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TRIGGER runs_uuid_str_ins
    BEFORE INSERT ON runs
    FOR EACH ROW SET NEW.run_uuid_string = BIN_TO_UUID(NEW.run_uuid);
CREATE TRIGGER runs_uuid_str_upd
    BEFORE UPDATE ON runs
    FOR EACH ROW SET NEW.run_uuid_string = BIN_TO_UUID(NEW.run_uuid);

CREATE TABLE services (
    service_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT       NOT NULL,
    run_id          BIGINT,
    name            VARCHAR(191) NOT NULL,
    role            VARCHAR(64),
    name_when_global VARCHAR(191) GENERATED ALWAYS AS (CASE WHEN run_id IS NULL THEN name ELSE NULL END) VIRTUAL,
    UNIQUE KEY services_global_name_uk (archive_id, name_when_global),
    UNIQUE KEY services_run_name_uk    (archive_id, run_id, name),
    KEY services_archive_idx (archive_id),
    KEY services_run_idx     (run_id),
    CONSTRAINT services_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE,
    CONSTRAINT services_run_fk     FOREIGN KEY (run_id)     REFERENCES runs(run_id)         ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE service_lifetimes (
    service_lifetime_id BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    service_id          BIGINT       NOT NULL,
    lifetime_ord        INT          NOT NULL,
    status              VARCHAR(32),
    type                VARCHAR(64),
    id                  VARCHAR(255),
    service_name        VARCHAR(191),
    stage_name          VARCHAR(191),
    started_at          DATETIME(6),
    ended_at            DATETIME(6),
    `exit`              INT,
    exit_decoded        JSON,
    times               JSON,
    child_times         JSON,
    child_wall          DOUBLE,
    spec_extras         JSON,
    state_extras        JSON,
    UNIQUE KEY service_lifetimes_uk     (service_id, lifetime_ord),
    KEY        service_lifetimes_service_idx (service_id),
    CONSTRAINT service_lifetimes_service_fk FOREIGN KEY (service_id) REFERENCES services(service_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE test_files (
    test_file_id    BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id      BIGINT       NOT NULL,
    relative        VARCHAR(512) NOT NULL,
    UNIQUE KEY test_files_uk         (project_id, relative),
    KEY        test_files_proj_idx   (project_id),
    CONSTRAINT test_files_project_fk FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE jobs (
    job_id          BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT        NOT NULL,
    run_id          BIGINT        NOT NULL,
    test_file_id    BIGINT       NOT NULL,
    job_ord         INT          NOT NULL,
    pass            TINYINT(1),
    status          VARCHAR(32),
    retry_count     INT,
    UNIQUE KEY jobs_archive_run_ord_uk (archive_id, run_id, job_ord),
    KEY jobs_run_pass_idx    (run_id, pass),
    KEY jobs_test_file_idx   (test_file_id),
    CONSTRAINT jobs_archive_fk   FOREIGN KEY (archive_id)   REFERENCES archives(archive_id)     ON DELETE CASCADE,
    CONSTRAINT jobs_run_fk       FOREIGN KEY (run_id)       REFERENCES runs(run_id)             ON DELETE CASCADE,
    CONSTRAINT jobs_test_file_fk FOREIGN KEY (test_file_id) REFERENCES test_files(test_file_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE job_tries (
    job_try_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_id          BIGINT       NOT NULL,
    try_ord         INT          NOT NULL,
    status          VARCHAR(32),
    pass            TINYINT(1),
    `exit`          INT,
    exit_decoded    JSON,
    queued_at       DATETIME(6),
    started_at      DATETIME(6),
    ended_at        DATETIME(6),
    pass_count      INT,
    fail_count      INT,
    assertion_count INT,
    plan            JSON,
    halt            JSON,
    times           JSON,
    child_times     JSON,
    child_wall      DOUBLE,
    spec_extras     JSON,
    state_extras    JSON,
    UNIQUE KEY job_tries_job_try_uk (job_id, try_ord),
    KEY job_tries_job_idx (job_id),
    CONSTRAINT job_tries_job_fk FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE job_specs (
    job_spec_id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_id              BIGINT       NOT NULL,
    test_file_id        BIGINT       NOT NULL,
    absolute            VARCHAR(2048),
    category            VARCHAR(64),
    duration            VARCHAR(64),
    stage               VARCHAR(64),
    features            JSON,
    switches            JSON,
    retry               INT,
    retry_isolated      TINYINT(1),
    smoke               TINYINT(1),
    isolation           TINYINT(1),
    non_perl            TINYINT(1),
    is_binary           TINYINT(1),
    event_timeout       INT,
    post_exit_timeout   INT,
    min_slots           INT,
    max_slots           INT,
    ch_dir              VARCHAR(2048),
    extras              JSON,
    UNIQUE KEY job_specs_job_uk    (job_id),
    KEY job_specs_test_file_idx    (test_file_id),
    KEY job_specs_job_idx          (job_id),
    CONSTRAINT job_specs_job_fk    FOREIGN KEY (job_id)       REFERENCES jobs(job_id)             ON DELETE CASCADE,
    CONSTRAINT job_specs_tf_fk     FOREIGN KEY (test_file_id) REFERENCES test_files(test_file_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE subtests (
    subtest_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_try_id      BIGINT       NOT NULL,
    name            VARCHAR(255) NOT NULL,
    pass            TINYINT(1)   NOT NULL,
    count_pass      INT,
    count_fail      INT,
    ord             INT          NOT NULL,
    KEY subtests_jobtry_pass_idx (job_try_id, pass),
    KEY subtests_name_idx        (name),
    CONSTRAINT subtests_job_try_fk FOREIGN KEY (job_try_id) REFERENCES job_tries(job_try_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE artifacts (
    artifact_id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id           BIGINT       NOT NULL,
    artifact_uuid        BINARY(16)   NOT NULL,
    artifact_uuid_string CHAR(36),
    run_id               BIGINT,
    service_id           BIGINT,
    job_try_id           BIGINT,
    artifact_kind        ENUM('events','state','spec','report','attachment','arbitrary') NOT NULL,
    format               VARCHAR(64)  NOT NULL,
    name                 VARCHAR(255),
    compressed           TINYINT(1)   NOT NULL,
    payload              LONGBLOB     NOT NULL,
    created_at           DATETIME(6)  NOT NULL,
    sealed               TINYINT(1)   NOT NULL DEFAULT 0,
    -- Virtual columns capture each scope's identity only when this row
    -- belongs to that scope (other FKs IS NULL). Outside the scope
    -- they are NULL, which MySQL treats as distinct in UNIQUE — so
    -- the per-scope UNIQUE only constrains the right subset of rows.
    -- An extra `__` token disambiguates NULL `name` (standard streams:
    -- events/spec/state/report) within the scope.
    run_scope_run_id          BIGINT       GENERATED ALWAYS AS (CASE WHEN run_id     IS NOT NULL AND service_id IS NULL AND job_try_id IS NULL THEN run_id     ELSE NULL END) VIRTUAL,
    service_scope_service_id  BIGINT       GENERATED ALWAYS AS (CASE WHEN service_id IS NOT NULL AND run_id     IS NULL AND job_try_id IS NULL THEN service_id ELSE NULL END) VIRTUAL,
    job_try_scope_job_try_id  BIGINT       GENERATED ALWAYS AS (CASE WHEN job_try_id IS NOT NULL AND run_id     IS NULL AND service_id IS NULL THEN job_try_id ELSE NULL END) VIRTUAL,
    archive_scope_marker      TINYINT(1)   GENERATED ALWAYS AS (CASE WHEN run_id IS NULL AND service_id IS NULL AND job_try_id IS NULL THEN 1 ELSE NULL END) VIRTUAL,
    name_token                VARCHAR(255) GENERATED ALWAYS AS (CASE WHEN name IS NULL THEN '__' ELSE name END) VIRTUAL,
    UNIQUE KEY artifacts_archive_uuid_uk        (archive_id, artifact_uuid),
    UNIQUE KEY artifacts_archive_uuid_string_uk (archive_id, artifact_uuid_string),
    UNIQUE KEY artifacts_run_uk
        (archive_id, run_scope_run_id, artifact_kind, format, name_token),
    UNIQUE KEY artifacts_service_uk
        (archive_id, service_scope_service_id, artifact_kind, format, name_token),
    UNIQUE KEY artifacts_job_try_uk
        (archive_id, job_try_scope_job_try_id, artifact_kind, format, name_token),
    UNIQUE KEY artifacts_archive_uk
        (archive_id, archive_scope_marker, artifact_kind, format, name_token),
    KEY artifacts_run_idx     (archive_id, run_id),
    KEY artifacts_service_idx (archive_id, service_id),
    KEY artifacts_job_try_idx (archive_id, job_try_id),
    KEY artifacts_kind_idx    (archive_id, artifact_kind),
    CONSTRAINT artifacts_scope_chk CHECK (
        (CASE WHEN run_id     IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN service_id IS NULL THEN 1 ELSE 0 END)
      + (CASE WHEN job_try_id IS NULL THEN 1 ELSE 0 END)
        >= 2
    ),
    CONSTRAINT artifacts_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id)   ON DELETE CASCADE,
    CONSTRAINT artifacts_run_fk     FOREIGN KEY (run_id)     REFERENCES runs(run_id)           ON DELETE CASCADE,
    CONSTRAINT artifacts_service_fk FOREIGN KEY (service_id) REFERENCES services(service_id)   ON DELETE CASCADE,
    CONSTRAINT artifacts_job_try_fk FOREIGN KEY (job_try_id) REFERENCES job_tries(job_try_id)  ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TRIGGER artifacts_uuid_str_ins
    BEFORE INSERT ON artifacts
    FOR EACH ROW SET NEW.artifact_uuid_string = BIN_TO_UUID(NEW.artifact_uuid);
CREATE TRIGGER artifacts_uuid_str_upd
    BEFORE UPDATE ON artifacts
    FOR EACH ROW SET NEW.artifact_uuid_string = BIN_TO_UUID(NEW.artifact_uuid);
