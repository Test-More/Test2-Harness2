-- App::Yath2 DuckDB schema (DB layer rewrite). DuckDB is a SYNC / READ target,
-- NOT a live logging target -- see WHY FULL FKs and CONCURRENCY below.
--
-- SOURCE OF TRUTH: this hand-written DDL is the canonical schema. DBIx::QuickORM
-- reflects it via autofill (reflect-from-DB); there are no Perl table/result
-- classes and no codegen. When this DDL changes, every flavor file under
-- share/schema/ moves together.
--
-- DuckDB is an EMBEDDED file engine (like SQLite) but with PostgreSQL-grade
-- types, so this file is a near-verbatim port of PostgreSQL.sql -- the
-- NATIVE-uuid model -- NOT the SQLite/MySQL binary-storage model. The only
-- DuckDB-specific divergences from PostgreSQL.sql are:
--   * Auto-increment: DuckDB rejects `GENERATED ALWAYS AS IDENTITY`, so each
--     host-local integer PK is `INTEGER DEFAULT nextval('<table>_seq')`, with a
--     `CREATE SEQUENCE <table>_seq` emitted immediately before its table.
--   * JSON columns use the native `JSON` type (DuckDB has no `JSONB` token).
--   * The blob column uses native `BLOB` (DuckDB has no `BYTEA` token).
--   * Timestamps use tz-naive `TIMESTAMP` (NOT PostgreSQL's `timestamptz`). The
--     QuickORM DuckDB dialect inflates datetimes with DateTime::Format::SQLite,
--     which parses a tz-naive `YYYY-MM-DD HH:MM:SS[.ffffff]` string but REJECTS a
--     `+00`/`-07` offset suffix; `TIMESTAMP` emits no offset (microsecond
--     precision is still retained in storage). `now()` is implicitly cast to a
--     local TIMESTAMP (the session TimeZone), so stamps stay server-local.
-- Everything else -- native `uuid` PKs (NO *_uuid_string mirror), native
-- tri-state `BOOLEAN` (NO 0/1 CHECK crutch), `numeric(14,4)`, the CHECK status
-- enums, the FULL set of inline `REFERENCES` FKs, and every index -- is identical
-- to PostgreSQL.sql.
--
-- WHY FULL FKs (and why DuckDB is NOT a logger target): DuckDB blocks an
-- index-maintaining UPDATE of a row that is REFERENCED by a foreign key (verified:
-- updating an indexed column -- e.g. runs.status / job_tries.result -- of a
-- referenced row raises "key ... is still referenced by a foreign key"). That
-- collides with a LIVE LOGGER's insert-then-update model, so DuckDB is excluded as
-- a logging target. It is populated ONLY by `yath db sync` / `import`, which are
-- INSERT-ONLY and write parents before children -- never insert-then-update -- so
-- every FK is satisfiable. Keeping the full FK set gives a synced DuckDB log the
-- same referential integrity as the other flavors. (DuckDB also has no
-- ALTER TABLE ADD FOREIGN KEY, so FKs cannot be added after the fact.)
--
-- CONCURRENCY: a DuckDB database file permits only ONE read-write process at a
-- time (an exclusive file lock held for the life of the holding process); other
-- processes may open it only read-only, and only once the writer has detached.
-- This single-writer constraint is the reason DuckDB is a sync/read target, not a
-- live logger. As a READ target it shines: point a read-only web server / `yath
-- db` at a finished DuckDB log. Sync writes it single-writer; readers then open
-- read-only.
--
-- DESIGN (spec AI_DOCS/2026-06-21-db-layer-rewrite-quickorm-spec.md):
--   * Run-data tables (runs, jobs, job_tries, artifacts) use UUID PKs -- native
--     `uuid` on DuckDB. The UUID is itself the host-stable sync key, stable by
--     construction (spec §0.2/§3). No *_uuid_string mirror is needed: the native
--     uuid PK is already human-readable and indexed.
--   * Natural-key entities (users, machine_users, projects, test_files, hosts)
--     use a host-local integer identity PK + a UNIQUE natural key; import/sync
--     serialize on the natural key, never the PK (spec §0.2/§3, R5/R7).
--   * NO transitions/events/binaries/log_files/collector tables (R6, §4):
--     transition + event detail lives durably inside the artifact blobs; the
--     logger folds wire transitions into the run/job/job_try summary rows.
--   * run_fields -> runs.fields JSON; job_try_fields -> job_tries.fields JSON
--     (folded, table dropped, §4). The `mode` enum is dropped (no event rows to
--     prune, §4).
--   * Timestamps use `TIMESTAMP` (microsecond precision); all stamps are
--     server-local.  Booleans are native tri-state (NULL = undecided).
--   * Column-ordering convention: fixed-width -> variable -> generated-last
--     (spec §3e).

-- ====================================================================
-- schema_meta -- the yath/schema version stamp (one row, spec §2e/§4).
-- ====================================================================
CREATE SEQUENCE schema_meta_seq;
CREATE TABLE schema_meta (
    schema_meta_id  INTEGER         DEFAULT nextval('schema_meta_seq') PRIMARY KEY,
    yath_version    TEXT            NOT NULL,
    schema_version  TEXT            NOT NULL,
    created         TIMESTAMP       NOT NULL DEFAULT now()
);

INSERT INTO schema_meta (yath_version, schema_version) VALUES ('2.000000', '2.000000');

-- ====================================================================
-- Natural-key entities (host-local integer PK + UNIQUE natural key).
-- ====================================================================

-- hosts -- host identity, so runs can be listed per host to spot a broken host
-- (spec §4). runs.host references it; machine_users.host references it.
CREATE SEQUENCE hosts_seq;
CREATE TABLE hosts (
    host_id     INTEGER         DEFAULT nextval('hosts_seq') PRIMARY KEY,
    hostname    TEXT            NOT NULL,

    UNIQUE(hostname)
);

-- users -- the app/account user who SUBMITTED a run (may differ from the OS user
-- who ran it). Natural key = username; email/auth columns deferred (spec §4/R7).
CREATE SEQUENCE users_seq;
CREATE TABLE users (
    user_id     INTEGER         DEFAULT nextval('users_seq') PRIMARY KEY,
    username    TEXT            NOT NULL,

    UNIQUE(username)
);

-- machine_users -- the OS user who RAN a run, per machine (spec §4/R7).
-- Natural/sync key = (host, username); host FK is NOT NULL.
CREATE SEQUENCE machine_users_seq;
CREATE TABLE machine_users (
    machine_user_id INTEGER     DEFAULT nextval('machine_users_seq') PRIMARY KEY,
    host_id         INTEGER     NOT NULL REFERENCES hosts(host_id),
    username        TEXT        NOT NULL,

    UNIQUE(host_id, username)
);
CREATE INDEX machine_users_host_idx ON machine_users(host_id);

-- projects -- a run needs its project. Natural key = name.
CREATE SEQUENCE projects_seq;
CREATE TABLE projects (
    project_id  INTEGER         DEFAULT nextval('projects_seq') PRIMARY KEY,
    name        TEXT            NOT NULL,

    UNIQUE(name)
);

-- test_files -- project-scoped dedup of test paths. filename = the full
-- in-project path (the LONG display name); the SHORT name = basename(filename),
-- derived at render, never stored. Same path under two projects = two rows, so
-- per-project history/coverage never merges. No fake "HARNESS INTERNAL LOG" row
-- -- the harness log is a collector now, not a test file.
CREATE SEQUENCE test_files_seq;
CREATE TABLE test_files (
    test_file_id    INTEGER     DEFAULT nextval('test_files_seq') PRIMARY KEY,
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

    added           TIMESTAMP       NOT NULL DEFAULT now(),

    version         TEXT            DEFAULT NULL,
    parameters      JSON            DEFAULT NULL,
    fields          JSON            DEFAULT NULL
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
-- VERDICT columns (spec §4/§4.1/R17, survey #5):
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

    started         TIMESTAMP       DEFAULT NULL,
    finished        TIMESTAMP       DEFAULT NULL,

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
    data            BLOB            DEFAULT NULL
);
CREATE INDEX artifact_run_idx       ON artifacts(run_uuid);
CREATE INDEX artifact_collector_idx ON artifacts(collector_uuid);
CREATE INDEX artifact_filename_idx  ON artifacts(filename);
