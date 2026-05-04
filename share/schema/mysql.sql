-- App::Yath2::Log DB backend, MySQL/Percona flavor (schema_version = 1).
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
-- Polymorphic scope on `artifacts`: `scope_kind` ENUM + `scope_id` int.
-- No DB FK (caller-managed).
--
-- Payload compression: client-side zstd. App compresses bytes before
-- INSERT and stores compressed=1. (No native zstd-capable server-side
-- compression on stock MySQL.)

CREATE TABLE archives (
    archive_id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_uuid        BINARY(16)   NOT NULL,
    archive_uuid_string CHAR(36),
    format_version      INT          NOT NULL,
    schema_version      INT          NOT NULL,
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
    spec             JSON,
    state            JSON,
    UNIQUE KEY runs_archive_uuid_uk        (archive_id, run_uuid),
    UNIQUE KEY runs_archive_uuid_string_uk (archive_id, run_uuid_string),
    UNIQUE KEY runs_archive_ord_uk         (archive_id, run_ord),
    KEY runs_archive_idx (archive_id),
    KEY runs_status_idx  (status),
    KEY runs_pass_idx    (pass),
    CONSTRAINT runs_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE
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
    status          VARCHAR(32),
    spec            JSON,
    state           JSON,
    name_when_global VARCHAR(191) GENERATED ALWAYS AS (CASE WHEN run_id IS NULL THEN name ELSE NULL END) VIRTUAL,
    UNIQUE KEY services_global_name_uk (archive_id, name_when_global),
    UNIQUE KEY services_run_name_uk    (archive_id, run_id, name),
    KEY services_archive_idx (archive_id),
    KEY services_run_idx     (run_id),
    CONSTRAINT services_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE,
    CONSTRAINT services_run_fk     FOREIGN KEY (run_id)     REFERENCES runs(run_id)         ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE jobs (
    job_id          BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT        NOT NULL,
    run_id          BIGINT        NOT NULL,
    job_ord         INT           NOT NULL,
    file            VARCHAR(1024),
    pass            TINYINT(1),
    status          VARCHAR(32),
    retry_count     INT,
    spec            JSON,
    UNIQUE KEY jobs_archive_run_ord_uk (archive_id, run_id, job_ord),
    KEY jobs_run_pass_idx (run_id, pass),
    KEY jobs_file_idx     (file(255)),
    CONSTRAINT jobs_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE,
    CONSTRAINT jobs_run_fk     FOREIGN KEY (run_id)     REFERENCES runs(run_id)         ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE job_tries (
    job_try_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job_id          BIGINT       NOT NULL,
    try_ord         INT          NOT NULL,
    status          VARCHAR(32),
    pass            TINYINT(1),
    `exit`          INT,
    exit_decoded    JSON,
    started_at      DATETIME(6),
    ended_at        DATETIME(6),
    spec            JSON,
    state           JSON,
    UNIQUE KEY job_tries_job_try_uk (job_id, try_ord),
    KEY job_tries_job_idx (job_id),
    CONSTRAINT job_tries_job_fk FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
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
    scope_kind           ENUM('archive','run','service','job_try') NOT NULL,
    scope_id             BIGINT       NOT NULL,
    artifact_kind        ENUM('events','state','spec','report','attachment','arbitrary') NOT NULL,
    format               VARCHAR(64)  NOT NULL,
    name                 VARCHAR(255),
    compressed           TINYINT(1)   NOT NULL,
    payload              LONGBLOB     NOT NULL,
    created_at           DATETIME(6)  NOT NULL,
    sealed               TINYINT(1)   NOT NULL DEFAULT 0,
    name_when_unnamed VARCHAR(8) GENERATED ALWAYS AS (CASE WHEN name IS NULL THEN '__' ELSE NULL END) VIRTUAL,
    UNIQUE KEY artifacts_archive_uuid_uk        (archive_id, artifact_uuid),
    UNIQUE KEY artifacts_archive_uuid_string_uk (archive_id, artifact_uuid_string),
    UNIQUE KEY artifacts_named_uk
        (archive_id, scope_kind, scope_id, artifact_kind, format, name),
    UNIQUE KEY artifacts_unnamed_uk
        (archive_id, scope_kind, scope_id, artifact_kind, format, name_when_unnamed),
    KEY artifacts_scope_idx
        (archive_id, scope_kind, scope_id),
    KEY artifacts_scope_kind_idx
        (archive_id, scope_kind, scope_id, artifact_kind),
    CONSTRAINT artifacts_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TRIGGER artifacts_uuid_str_ins
    BEFORE INSERT ON artifacts
    FOR EACH ROW SET NEW.artifact_uuid_string = BIN_TO_UUID(NEW.artifact_uuid);
CREATE TRIGGER artifacts_uuid_str_upd
    BEFORE UPDATE ON artifacts
    FOR EACH ROW SET NEW.artifact_uuid_string = BIN_TO_UUID(NEW.artifact_uuid);
