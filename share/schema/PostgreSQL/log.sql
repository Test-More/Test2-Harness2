-- App::Yath2 PostgreSQL schema (DB layer rewrite, TODO-46 / chunk DB-2).
--
-- SOURCE OF TRUTH: this hand-written DDL is the canonical schema. DBIx::QuickORM
-- reflects it via autofill (reflect-from-DB); there are no Perl table/result
-- classes and no codegen. When this DDL changes, every flavor file under
-- share/schema/ moves together.
--
-- PostgreSQL is the most-capable flavor and is authored first (TODO-46); the other
-- engines port from this in TODO-47 (per-engine UUID storage: native uuid on
-- PostgreSQL + MariaDB 10.7+, BINARY(16) on MySQL/Percona, BLOB(16) on SQLite).
--
-- DESIGN (spec AI_DOCS/2026-06-21-db-layer-rewrite-quickorm-spec.md):
--   * Run-data tables (runs, jobs, job_tries, artifacts) use UUID PKs -- native
--     `uuid` on PostgreSQL. The UUID is itself the host-stable sync key, stable
--     by construction (spec §0.2/§3). No *_uuid_string mirror is needed on
--     PostgreSQL: the native uuid PK is already human-readable and indexed.
--   * Natural-key entities (users, machine_users, projects, test_files, hosts)
--     use a host-local integer identity PK + a UNIQUE natural key; import/sync
--     serialize on the natural key, never the PK (spec §0.2/§3, R5/R7).
--   * NO transitions/events/binaries/log_files/collector tables (R6, §4):
--     transition + event detail lives durably inside the artifact blobs; the
--     logger folds wire transitions into the run/job/job_try summary rows.
--   * run_fields -> runs.fields JSON; job_try_fields -> job_tries.fields JSON
--     (folded, table dropped, §4). The `mode` enum is dropped (no event rows to
--     prune, §4).
--   * Timestamps use `timestamptz` (microsecond precision); all stamps are
--     server-local.  Booleans are native tri-state (NULL = undecided).
--   * Column-ordering convention: fixed-width -> variable -> generated-last,
--     PG alignment-descending where it matters (spec §3e).

-- ====================================================================
-- schema_meta -- the yath/schema version stamp (one row, spec §2e/§4).
-- ====================================================================
CREATE TABLE schema_meta (
    schema_meta_id  INTEGER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    yath_version    TEXT            NOT NULL,
    schema_version  TEXT            NOT NULL,
    created         TIMESTAMPTZ     NOT NULL DEFAULT now()
);

INSERT INTO schema_meta (yath_version, schema_version) VALUES ('2.000000', '2.000000');

-- ====================================================================
-- Natural-key entities (host-local integer PK + UNIQUE natural key).
-- ====================================================================

-- hosts -- host identity, so runs can be listed per host to spot a broken host
-- (spec §4). runs.host references it; machine_users.host references it.
CREATE TABLE hosts (
    host_id     INTEGER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hostname    TEXT            NOT NULL,

    UNIQUE(hostname)
);

-- users -- the app/account user who SUBMITTED a run (may differ from the OS user
-- who ran it). Natural key = username; email/auth columns deferred (spec §4/R7).
CREATE TABLE users (
    user_id     INTEGER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username    TEXT            NOT NULL,

    UNIQUE(username)
);

-- machine_users -- the OS user who RAN a run, per machine (spec §4/R7).
-- Natural/sync key = (host, username); host FK is NOT NULL.
CREATE TABLE machine_users (
    machine_user_id INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    host_id         INTEGER     NOT NULL REFERENCES hosts(host_id),
    username        TEXT        NOT NULL,

    UNIQUE(host_id, username)
);
CREATE INDEX machine_users_host_idx ON machine_users(host_id);

-- projects -- a run needs its project. Natural key = name.
CREATE TABLE projects (
    project_id  INTEGER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        TEXT            NOT NULL,

    UNIQUE(name)
);

-- test_files -- project-scoped dedup of test paths. filename = the full
-- in-project path (the LONG display name); the SHORT name = basename(filename),
-- derived at render, never stored. Same path under two projects = two rows, so
-- per-project history/coverage never merges. No fake "HARNESS INTERNAL LOG" row
-- -- the harness log is a collector now, not a test file.
CREATE TABLE test_files (
    test_file_id    INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id      INTEGER     NOT NULL REFERENCES projects(project_id),
    filename        TEXT        NOT NULL,

    UNIQUE(project_id, filename)
);

-- ====================================================================
-- Run-data tables (UUID PKs; the UUID is the host-stable sync key).
-- ====================================================================

-- runs -- one row per run. run_uuid is the backend-minted v7 UUID (spec §3/§6c).
-- Counters (passed/failed/to_retry/retried) AGGREGATE over the run's resolved
-- jobs (spec §4.1/R17). ran_by -> machine_users (the OS user on the test
-- machine, NOT NULL); submitted_by -> users (the account user who uploaded,
-- nullable = unknown). `fields` is the folded run_fields JSON. `version` is the
-- per-run yath/schema version stamp (spec §2e/§4).
CREATE TABLE runs (
    run_uuid        UUID            PRIMARY KEY,

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

    status          TEXT            NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','running','complete','broken','canceled')),

    canon           BOOLEAN         NOT NULL DEFAULT FALSE,
    pinned          BOOLEAN         NOT NULL DEFAULT FALSE,
    has_coverage    BOOLEAN         DEFAULT NULL,
    has_resources   BOOLEAN         DEFAULT NULL,

    duration        NUMERIC(14,4)   DEFAULT NULL,

    added           TIMESTAMPTZ     NOT NULL DEFAULT now(),

    version         TEXT            DEFAULT NULL,
    parameters      JSONB           DEFAULT NULL,
    fields          JSONB           DEFAULT NULL
);
CREATE INDEX run_project_idx ON runs(project_id);
CREATE INDEX run_host_idx    ON runs(host_id);
CREATE INDEX run_status_idx  ON runs(status);
CREATE INDEX run_canon_idx   ON runs(canon);

-- jobs -- one row per test file in a run. job_uuid = the backend job_id (already
-- a v7 gen_uuid(); spec §6c, no backend fix). passed = folded "any try passed"
-- (resolved); failed = resolved && !passed (spec §4/§4.1). NO should_retry
-- column (runtime-only, R17). NO is_harness_out: the harness internal log is a
-- collector now (collectors.job_try_uuid NULL), not a fake job.
CREATE TABLE jobs (
    job_uuid        UUID            PRIMARY KEY,

    run_uuid        UUID            NOT NULL REFERENCES runs(run_uuid),
    test_file_id    INTEGER         NOT NULL REFERENCES test_files(test_file_id),

    passed          BOOLEAN         DEFAULT NULL,
    failed          BOOLEAN         DEFAULT NULL
);
CREATE INDEX job_run_idx  ON jobs(run_uuid);
CREATE INDEX job_file_idx ON jobs(test_file_id);

-- job_tries -- one row per try (is_try, 1-based per R10). The PK job_try_uuid is
-- a single DERIVED uuid = derive(job_uuid, try_ord) (v7-preserving, spec §3.1) --
-- deterministic across loggers, preserves the existing try-uuid URLs.
--
-- VERDICT columns (spec §4/§4.1/R17, survey TODO-5):
--   result          tri-state verdict: NULL = in-flight / TRUE = pass / FALSE =
--                   fail (the top-line "did this try pass", distinct from counts).
--   assertion_count, pass_count, fail_count -- assertion counts (NOT a pass/fail
--                   verdict; those names would collide with `result`).
--   subtests        -- top-level subtest count.
--   subtests_passed / subtests_failed -- the split (derived from the auditor's
--                   subtests[]).
-- NO stdout/stderr columns -- read on demand from the artifact blob (R6/R17).
-- `parameters` (NOT `params`); retry_limit lives in parameters, not a column.
-- `fields` is the folded job_try_fields JSON (directives).
CREATE TABLE job_tries (
    job_try_uuid    UUID            PRIMARY KEY,

    job_uuid        UUID            NOT NULL REFERENCES jobs(job_uuid),

    try_ord         INTEGER         NOT NULL,

    assertion_count INTEGER         DEFAULT NULL,
    pass_count      INTEGER         DEFAULT NULL,
    fail_count      INTEGER         DEFAULT NULL,
    subtests        INTEGER         DEFAULT NULL,
    subtests_passed INTEGER         DEFAULT NULL,
    subtests_failed INTEGER         DEFAULT NULL,
    exit_code       INTEGER         DEFAULT NULL,

    result          BOOLEAN         DEFAULT NULL,

    status          TEXT            NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','running','complete','broken','canceled')),

    duration        NUMERIC(14,4)   DEFAULT NULL,

    started         TIMESTAMPTZ     DEFAULT NULL,
    finished        TIMESTAMPTZ     DEFAULT NULL,

    parameters      JSONB           DEFAULT NULL,
    fields          JSONB           DEFAULT NULL,

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
    collector_uuid  UUID            PRIMARY KEY,

    run_uuid        UUID            NOT NULL     REFERENCES runs(run_uuid),
    job_try_uuid    UUID            DEFAULT NULL REFERENCES job_tries(job_try_uuid),

    display_name    TEXT            DEFAULT NULL,

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
    artifact_uuid   UUID            PRIMARY KEY,

    run_uuid        UUID            NOT NULL REFERENCES runs(run_uuid),
    collector_uuid  UUID            NOT NULL REFERENCES collectors(collector_uuid),

    filename        TEXT            NOT NULL,
    local_path      TEXT            DEFAULT NULL,
    data            BYTEA           DEFAULT NULL
);
CREATE INDEX artifact_run_idx       ON artifacts(run_uuid);
CREATE INDEX artifact_collector_idx ON artifacts(collector_uuid);
CREATE INDEX artifact_filename_idx  ON artifacts(filename);
