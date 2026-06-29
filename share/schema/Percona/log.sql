-- App::Yath2 Percona schema (DB layer rewrite, #47 / chunk DB-3).
--
-- Percona Server is a drop-in MySQL replacement; apart from this header this
-- file is byte-identical to share/schema/MySQL/log.sql (same table set, columns,
-- constraints, CHECK enums, and per-engine UUID storage). When the DDL changes,
-- every flavor file under share/schema/ moves together.
--
-- SOURCE OF TRUTH: this hand-written DDL is the canonical schema. DBIx::QuickORM
-- reflects it via autofill (reflect-from-DB); there are no Perl table/result
-- classes and no codegen. PostgreSQL/log.sql is the canonical reference (authored
-- first, #46); this is the #47 Percona port.
--
-- PER-ENGINE UUID STORAGE (spec §3/§0.2, R9):
--   * Percona (MySQL) has no native uuid type, so UUID PKs are stored as
--     BINARY(16). v7 UUIDs are generated in Perl with App::Yath2::Util::UUID
--     (lowercase); DBIx::QuickORM's UUID autotype packs/unpacks the canonical
--     hyphenated string to/from the 16-byte binary, so callers always see the
--     canonical lowercase string.
--   * The `runs` + `jobs` tables additionally carry a STORED GENERATED
--     VARCHAR(36) *_uuid_string mirror (run_uuid_string / job_uuid_string)
--     holding the human-readable form -- the two IDs a human pastes from CI
--     output (spec §3b) -- and indexed. The LOWER(CONCAT(SUBSTR(HEX(...))))
--     expression keeps the canonical string lowercase (spec §3c/R9).
--
-- TYPE MAPPING vs PostgreSQL/log.sql:
--   * native uuid                  -> BINARY(16)
--   * INTEGER GENERATED ... IDENTITY -> INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY
--   * JSONB                        -> JSON
--   * BYTEA                        -> LONGBLOB
--   * TIMESTAMPTZ + now()          -> DATETIME, DEFAULT CURRENT_TIMESTAMP.
--   * BOOLEAN / TRUE / FALSE       -> BOOLEAN (TINYINT(1)) + CHECK IN (0,1) for tri-state.
--   * NUMERIC(14,4)                -> DECIMAL(14,4)
--   * TEXT in a UNIQUE/index       -> VARCHAR(n) (cannot index unbounded TEXT).
--
-- Column-level REFERENCES are parsed but not enforced by InnoDB; they document
-- intended foreign-key relationships only. Column-ordering convention (spec §3e):
-- fixed-width -> variable -> generated last (kept consistent with PostgreSQL/log.sql).

-- ====================================================================
-- schema_meta -- the yath/schema version stamp (one row, spec §2e/§4).
-- ====================================================================
CREATE TABLE schema_meta (
    schema_meta_id  INTEGER         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    yath_version    VARCHAR(64)     NOT NULL,
    schema_version  VARCHAR(64)     NOT NULL,
    created         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO schema_meta (yath_version, schema_version) VALUES ('2.000000', '2.000000');

-- ====================================================================
-- Natural-key entities (host-local integer PK + UNIQUE natural key).
-- ====================================================================

-- hosts -- host identity, so runs can be listed per host to spot a broken host
-- (spec §4). runs.host references it; machine_users.host references it.
CREATE TABLE hosts (
    host_id     INTEGER         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    hostname    VARCHAR(255)    NOT NULL,

    UNIQUE(hostname)
);

-- users -- the app/account user who SUBMITTED a run (may differ from the OS user
-- who ran it). Natural key = username; email/auth columns deferred (spec §4/R7).
CREATE TABLE users (
    user_id     INTEGER         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(255)    NOT NULL,

    UNIQUE(username)
);

-- machine_users -- the OS user who RAN a run, per machine (spec §4/R7).
-- Natural/sync key = (host, username); host FK is NOT NULL.
CREATE TABLE machine_users (
    machine_user_id INTEGER     NOT NULL AUTO_INCREMENT PRIMARY KEY,
    host_id         INTEGER     NOT NULL REFERENCES hosts(host_id),
    username        VARCHAR(255) NOT NULL,

    UNIQUE(host_id, username)
);
CREATE INDEX machine_users_host_idx ON machine_users(host_id);

-- projects -- a run needs its project. Natural key = name.
CREATE TABLE projects (
    project_id  INTEGER         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(255)    NOT NULL,

    UNIQUE(name)
);

-- test_files -- project-scoped dedup of test paths. filename = the full
-- in-project path (the LONG display name); the SHORT name = basename(filename),
-- derived at render, never stored. Same path under two projects = two rows, so
-- per-project history/coverage never merges. No fake "HARNESS INTERNAL LOG" row
-- -- the harness log is a collector now, not a test file.
CREATE TABLE test_files (
    test_file_id    INTEGER     NOT NULL AUTO_INCREMENT PRIMARY KEY,
    project_id      INTEGER     NOT NULL REFERENCES projects(project_id),
    filename        VARCHAR(512) NOT NULL,

    UNIQUE(project_id, filename)
);

-- ====================================================================
-- Run-data tables (UUID PKs; the UUID is the host-stable sync key).
-- ====================================================================

-- runs -- one row per run. run_uuid is the backend-minted v7 UUID (spec §3/§6c),
-- stored as BINARY(16). Counters (passed/failed/to_retry/retried) AGGREGATE over
-- the run's resolved jobs (spec §4.1/R17). ran_by -> machine_users (the OS user
-- on the test machine, NOT NULL); submitted_by -> users (the account user who
-- uploaded, nullable = unknown). `fields` is the folded run_fields JSON.
-- `version` is the per-run yath/schema version stamp (spec §2e/§4).
-- run_uuid_string is the STORED-GENERATED lowercase human-readable mirror (§3b/R9).
CREATE TABLE runs (
    run_uuid        BINARY(16)      PRIMARY KEY,

    project_id      INTEGER         NOT NULL     REFERENCES projects(project_id),
    host_id         INTEGER         NOT NULL     REFERENCES hosts(host_id),
    ran_by          INTEGER         NOT NULL     REFERENCES machine_users(machine_user_id),
    submitted_by    INTEGER         DEFAULT NULL REFERENCES users(user_id),

    passed          INTEGER         DEFAULT NULL,
    failed          INTEGER         DEFAULT NULL,
    to_retry        INTEGER         DEFAULT NULL,
    retried         INTEGER         DEFAULT NULL,

    concurrency_j   INTEGER         DEFAULT NULL,
    concurrency_x   INTEGER         DEFAULT NULL,

    status          VARCHAR(16)     NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','running','complete','broken','canceled')),

    canon           BOOLEAN         NOT NULL DEFAULT 0 CHECK(canon IN (0, 1)),
    pinned          BOOLEAN         NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
    has_coverage    BOOLEAN         DEFAULT NULL CHECK(has_coverage IN (0, 1)),
    has_resources   BOOLEAN         DEFAULT NULL CHECK(has_resources IN (0, 1)),

    duration        DECIMAL(14,4)   DEFAULT NULL,

    added           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,

    version         VARCHAR(64)     DEFAULT NULL,
    parameters      JSON            DEFAULT NULL,
    fields          JSON            DEFAULT NULL,

    run_uuid_string VARCHAR(36) GENERATED ALWAYS AS (
        LOWER(CONCAT(
            SUBSTR(HEX(run_uuid),  1,  8), '-',
            SUBSTR(HEX(run_uuid),  9,  4), '-',
            SUBSTR(HEX(run_uuid), 13,  4), '-',
            SUBSTR(HEX(run_uuid), 17,  4), '-',
            SUBSTR(HEX(run_uuid), 21, 12)
        ))
    ) STORED
);
CREATE INDEX run_project_idx     ON runs(project_id);
CREATE INDEX run_host_idx        ON runs(host_id);
CREATE INDEX run_status_idx      ON runs(status);
CREATE INDEX run_canon_idx       ON runs(canon);
CREATE INDEX run_uuid_string_idx ON runs(run_uuid_string);

-- jobs -- one row per test file in a run. job_uuid = the backend job_id (already
-- a v7 gen_uuid(); spec §6c, no backend fix). passed = folded "any try passed"
-- (resolved); failed = resolved && !passed (spec §4/§4.1). NO should_retry
-- column (runtime-only, R17). NO is_harness_out: the harness internal log is a
-- collector now (collectors.job_try_uuid NULL), not a fake job.
-- job_uuid_string is the STORED-GENERATED lowercase human-readable mirror (§3b/R9).
CREATE TABLE jobs (
    job_uuid        BINARY(16)      PRIMARY KEY,

    run_uuid        BINARY(16)      NOT NULL REFERENCES runs(run_uuid),
    test_file_id    INTEGER         NOT NULL REFERENCES test_files(test_file_id),

    passed          BOOLEAN         DEFAULT NULL CHECK(passed IN (0, 1)),
    failed          BOOLEAN         DEFAULT NULL CHECK(failed IN (0, 1)),

    job_uuid_string VARCHAR(36) GENERATED ALWAYS AS (
        LOWER(CONCAT(
            SUBSTR(HEX(job_uuid),  1,  8), '-',
            SUBSTR(HEX(job_uuid),  9,  4), '-',
            SUBSTR(HEX(job_uuid), 13,  4), '-',
            SUBSTR(HEX(job_uuid), 17,  4), '-',
            SUBSTR(HEX(job_uuid), 21, 12)
        ))
    ) STORED
);
CREATE INDEX job_run_idx         ON jobs(run_uuid);
CREATE INDEX job_file_idx        ON jobs(test_file_id);
CREATE INDEX job_uuid_string_idx ON jobs(job_uuid_string);

-- job_tries -- one row per try (is_try, 1-based per R10). The PK job_try_uuid is
-- a single DERIVED uuid = derive(job_uuid, try_ord) (v7-preserving, spec §3.1) --
-- deterministic across loggers, preserves the existing try-uuid URLs. Stored as
-- BINARY(16); NOT a *_uuid_string-bearing table (mirror is run+job only, §3b).
--
-- VERDICT columns (spec §4/§4.1/R17, survey #5):
--   result          tri-state verdict: NULL = in-flight / 1 = pass / 0 = fail
--                   (the top-line "did this try pass", distinct from counts).
--   assertion_count, pass_count, fail_count -- assertion counts (NOT a pass/fail
--                   verdict; those names would collide with `result`).
--   subtests        -- top-level subtest count.
--   subtests_passed / subtests_failed -- the split (derived from the auditor's
--                   subtests[]).
-- NO stdout/stderr columns -- read on demand from the artifact blob (R6/R17).
-- `parameters` (NOT `params`); retry_limit lives in parameters, not a column.
-- `fields` is the folded job_try_fields JSON (directives).
CREATE TABLE job_tries (
    job_try_uuid    BINARY(16)      PRIMARY KEY,

    job_uuid        BINARY(16)      NOT NULL REFERENCES jobs(job_uuid),

    try_ord         INTEGER         NOT NULL,

    assertion_count INTEGER         DEFAULT NULL,
    pass_count      INTEGER         DEFAULT NULL,
    fail_count      INTEGER         DEFAULT NULL,
    subtests        INTEGER         DEFAULT NULL,
    subtests_passed INTEGER         DEFAULT NULL,
    subtests_failed INTEGER         DEFAULT NULL,
    exit_code       INTEGER         DEFAULT NULL,

    result          BOOLEAN         DEFAULT NULL CHECK(result IN (0, 1)),

    status          VARCHAR(16)     NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','running','complete','broken','canceled')),

    duration        DECIMAL(14,4)   DEFAULT NULL,

    started         DATETIME        DEFAULT NULL,
    finished        DATETIME        DEFAULT NULL,

    parameters      JSON            DEFAULT NULL,
    fields          JSON            DEFAULT NULL,

    UNIQUE(job_uuid, try_ord)
);
CREATE INDEX job_try_job_idx    ON job_tries(job_uuid);
CREATE INDEX job_try_result_idx ON job_tries(result);

-- collectors -- the universal events.jsonl.zst producer (spec hub). EVERY events
-- blob has exactly one collector. collector_uuid is the derive base, so the
-- events artifact is the row WHERE artifact_uuid = collector_uuid (offset 0 ==
-- identity, spec §3.1/R2) -- no stored events pointer needed. job_try_uuid set => a
-- test try (1:1, UNIQUE); NULL => a run/process-level producer (harness,
-- preload, system load). display_name: REQUIRED for non-test collectors, and an
-- OPTIONAL override for test collectors (NULL => resolve the LONG name via
-- test_file.filename, the SHORT name via basename). The CHECK enforces
-- "non-test collector must be named."
CREATE TABLE collectors (
    collector_uuid  BINARY(16)      PRIMARY KEY,

    run_uuid        BINARY(16)      NOT NULL     REFERENCES runs(run_uuid),
    job_try_uuid    BINARY(16)      DEFAULT NULL REFERENCES job_tries(job_try_uuid),

    display_name    VARCHAR(512)    DEFAULT NULL,

    CHECK (job_try_uuid IS NOT NULL OR display_name IS NOT NULL),
    UNIQUE(job_try_uuid)
);
CREATE INDEX collector_run_idx     ON collectors(run_uuid);

-- artifacts -- canonical run data (spec §5). artifact_uuid is DETERMINISTIC:
-- derive(collector_uuid, idx) -- events blob = offset 0 (artifact_uuid ==
-- collector_uuid), extracted binaries = offsets 1,2,... (spec §3.1/R2).
-- collector_uuid is the SINGLE owner -- reach the job_try (if any) via the
-- collector. run_uuid is denormalized + NOT NULL so a run's artifacts can be
-- purged without chasing FKs. `filename` carries the kind (no type/kind column;
-- spec §5). If `data` is populated it is canon; if NULL, read host-local
-- `local_path` (never synced/copied, spec §5).
CREATE TABLE artifacts (
    artifact_uuid   BINARY(16)      PRIMARY KEY,

    run_uuid        BINARY(16)      NOT NULL REFERENCES runs(run_uuid),
    collector_uuid  BINARY(16)      NOT NULL REFERENCES collectors(collector_uuid),

    filename        VARCHAR(512)    NOT NULL,
    local_path      VARCHAR(1024)   DEFAULT NULL,
    data            LONGBLOB        DEFAULT NULL
);
CREATE INDEX artifact_run_idx       ON artifacts(run_uuid);
CREATE INDEX artifact_collector_idx ON artifacts(collector_uuid);
CREATE INDEX artifact_filename_idx  ON artifacts(filename(255));
