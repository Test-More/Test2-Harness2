-- App::Yath2::Log DB backend, MariaDB flavor (schema_version = 1).
-- Requires MariaDB >= 10.7 (native UUID).
-- All tables: ENGINE=InnoDB, CHARSET=utf8mb4, COLLATE=utf8mb4_unicode_ci.
--
-- Identity convention: every PK is `<thing>_id BIGINT`, every UUID is
-- `<thing>_uuid UUID`. UUIDs are v7 (gen_uuid). No bare `id` / `uuid`.
--
-- Polymorphic scope on `artifacts`: `scope_kind` ENUM + `scope_id` int.
-- No DB FK (caller-managed).
--
-- Payload compression: server-side via PAGE_COMPRESSED=1 on artifacts.
-- App stores RAW bytes (compressed=0). Compression algorithm is the
-- server-global `innodb_compression_algorithm` — set to `zstd` in
-- server config for best ratio/speed; falls back to `lz4`/`zlib` if
-- zstd not compiled in. Requires sparse-file support on the underlying
-- filesystem (ext4/xfs/btrfs OK).
--
-- Per-scope partial-uniqueness uses virtual generated columns that are
-- NULL outside their scope. MariaDB UNIQUE accepts arbitrary repeats
-- of all-NULL composite tuples, so a single non-partial UNIQUE on those
-- generated columns enforces exactly the right rule.

CREATE TABLE archives (
    archive_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_uuid    UUID         NOT NULL,
    format_version  INT          NOT NULL,
    schema_version  INT          NOT NULL,
    created_at      DATETIME(6)  NOT NULL,
    sealed_at       DATETIME(6),
    UNIQUE KEY archives_uuid_uk (archive_uuid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE runs (
    run_id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT       NOT NULL,
    run_ord         INT          NOT NULL,
    run_uuid        UUID         NOT NULL,
    status          VARCHAR(32)  NOT NULL,
    pass            TINYINT(1),
    `exit`          INT,
    exit_decoded    JSON,
    aborted         TINYINT(1)   NOT NULL DEFAULT 0,
    timed_out       TINYINT(1)   NOT NULL DEFAULT 0,
    started_at      DATETIME(6),
    ended_at        DATETIME(6),
    total_jobs      INT,
    passed_jobs     INT,
    failed_jobs     INT,
    aborted_jobs    INT,
    spec            JSON,
    state           JSON,
    UNIQUE KEY runs_archive_uuid_uk (archive_id, run_uuid),
    UNIQUE KEY runs_archive_ord_uk  (archive_id, run_ord),
    KEY runs_archive_idx (archive_id),
    KEY runs_status_idx  (status),
    KEY runs_pass_idx    (pass),
    CONSTRAINT runs_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE services (
    service_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT       NOT NULL,
    run_id          BIGINT,
    name            VARCHAR(191) NOT NULL,
    status          VARCHAR(32),
    spec            JSON,
    state           JSON,
    -- Virtual columns: NULL when out of scope.
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
    artifact_id     BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    archive_id      BIGINT       NOT NULL,
    artifact_uuid   UUID         NOT NULL,
    scope_kind      ENUM('archive','run','service','job_try') NOT NULL,
    scope_id        BIGINT       NOT NULL,
    artifact_kind   ENUM('events','state','spec','report','attachment','arbitrary') NOT NULL,
    format          VARCHAR(64)  NOT NULL,
    name            VARCHAR(255),
    compressed      TINYINT(1)   NOT NULL,
    payload         LONGBLOB     NOT NULL,
    created_at      DATETIME(6)  NOT NULL,
    sealed          TINYINT(1)   NOT NULL DEFAULT 0,
    -- Virtual generated column for "NULL distinct" semantics on the
    -- per-scope (kind, format, name) uniqueness when name IS NULL.
    -- The composite repeats arbitrarily for NULL-name rows because of
    -- MariaDB UNIQUE-NULL-distinct semantics; we add a separate
    -- generated column that flips to NULL when name IS NOT NULL so
    -- the unnamed UNIQUE only constrains the NULL-name subset.
    name_when_unnamed VARCHAR(8) GENERATED ALWAYS AS (CASE WHEN name IS NULL THEN '__' ELSE NULL END) VIRTUAL,
    UNIQUE KEY artifacts_archive_uuid_uk (archive_id, artifact_uuid),
    UNIQUE KEY artifacts_named_uk
        (archive_id, scope_kind, scope_id, artifact_kind, format, name),
    UNIQUE KEY artifacts_unnamed_uk
        (archive_id, scope_kind, scope_id, artifact_kind, format, name_when_unnamed),
    KEY artifacts_scope_idx
        (archive_id, scope_kind, scope_id),
    KEY artifacts_scope_kind_idx
        (archive_id, scope_kind, scope_id, artifact_kind),
    CONSTRAINT artifacts_archive_fk FOREIGN KEY (archive_id) REFERENCES archives(archive_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci PAGE_COMPRESSED=1;
