# DB Layer Rewrite — DBIx::QuickORM, transition-driven logger, multi-DB sync — SPEC (staging doc)

**Status:** SPECCING ONLY. This document is the spec. No edits to `ARCHITECTURE.md`,
`TODO_STEPS.md`, `TODO_TASKS.md`, or `TODO_DONE.md` are made now — another agent owns
those; their proposed changes are *captured here* (§A, §B) for a later merge agent.
Execution happens in a **worktree** later. This doc lives in `AI_DOCS/` (new file, no
conflict).

**Source:** the `dbthoughts` doc (repo root) + decisions taken in discussion 2026-06-21.

**Research basis:** an 11-agent research sweep over live `lib/` + `reference/*`
(findings + synthesis archived in the session; key file pointers inline below).

---

## 0. Framing — what this is

A **from-scratch rewrite** of the database layer, NOT a refactor of the current
DBIx::Class schema into DBIx::QuickORM. The two are different enough that incremental
conversion is not worth it. The current DBIC layer is kept only as a **reference** to
port behaviour from. The web UX is rebuilt on top of the new layer afterward.

**Hybrid principle (key):** two references inform the new schema in *different
dimensions*:
- `reference/dbix_quickorm/` supplies the **mechanics / approach** — QuickORM autofill,
  per-flavor UUID storage, artifacts-as-blobs. But it branched off a **different runner
  backend**, so *what* it stores is **inaccurate** to today's harness — do **not** port
  its column set verbatim.
- the **current branch's DBIC schema** (`reference/old_db` after the move) supplies the
  **accurate data model** — the columns / what is actually stored — because the current
  branch iterated to the correct data.
- the new schema = QuickORM-style mechanics + current-branch data + **new tables**
  (`artifacts`, `machine_users`) − **dropped tables** (collector, events, and likely
  others). *(No `transitions` table — R6.)*

Core invariant: the runner / `yath test` critical path imports **zero** DB code today
(verified: `test.pm` + `Test2::Harness2/*` have no `App::Yath2::Schema` / `RunProcessor`
imports). The DB+web stack is entirely opt-in (renderers, plugins, separate commands).
So moving it out keeps the runner suite green.

### 0.1 ORM model (settled)

- **DBIx::QuickORM, no hand-written table/result classes.** Connect, let the ORM
  reflect the schema map **from the database itself**, operate on the returned
  ORM/connection object. No `ResultSet` equivalents, no `Schema::Loader`-style codegen.
- SQL **DDL files are the source of truth**; the DB is built from them and QuickORM
  reflects them.
- **QuickORM** = the live ORM (autofill reflect-from-DB). **QuickDB** = spinning
  ephemeral / test databases — both test fixtures *and* an ephemeral PostgreSQL used for
  logging + webapp during a run.
- **All DB code lives under `App::Yath2`** (schema, row classes, Flavor, importer, sync,
  controllers, and the logger). The backend `Test2::Harness2` layer accesses **no DB in
  either direction** (verified — see §2). This deliberately deviates from the reference,
  which parked the schema in `Test2::Harness2::Schema`.
- Reference that proves the QuickORM mechanics end-to-end (namespace aside):
  `reference/dbix_quickorm/share/schema/*.sql` +
  `reference/dbix_quickorm/lib/Test2/Harness2/Schema.pm` (autofill + per-dialect Flavor
  registry). Port the *mechanics*, re-home under `App::Yath2`.

### 0.2 Key strategy (settled — corrected 2026-06-21)

PK choice is **not** the same as sync identity. Every table that participates in
import/sync needs a **host-stable serialization key**, but it is not always the PK:

| Table class | PK | Host-stable sync key |
|---|---|---|
| Run data (runs, jobs, tries, artifacts) | **UUID** | the UUID itself (stable by construction) |
| Natural-key entities (e.g. users) | **integer auto-increment / identity** (host-local) | the **natural unique column** (e.g. `username`; R7), `UNIQUE`-constrained; import/sync serialize on it, never the PK |
| DB/web-local (e.g. sessions) | local identity | none (not synced) |

Per-engine UUID storage (from `dbthoughts`, proven by the dbix_quickorm reference):
MySQL + Percona = binary `BINARY(16)`; MariaDB + PostgreSQL = native `uuid`; SQLite =
best-fit (BLOB). Where no native UUID type exists, add an auto-maintained
`*_uuid_string` (STORED GENERATED) mirror column for humans — but only on UUIDs humans
look up directly. App-side generation via `Test2::Util::UUID` (v7). *(Storage details
finalize in decision 3.)*

### 0.3 Canonical data path (settled)

The jsonl run-log is **no longer the canonical record**. Canonical = **artifact blobs**
(each collector's `events.jsonl.zst`, which already contains its transitions interleaved)
+ the **folded summary rows** (run/job/job_try) the logger derives from the transition
wire stream. **There is no separate transitions table** (R6). The per-job
`events.jsonl.zst` survives only as a **blob artifact**. The old whole-run jsonl log
becomes an optional render format (the "jsonl renderer", §10 side-track), not the import
source. Import logic is therefore all-new.

### 0.4 Work order (settled — user-specified)

1. Move the old DBIC DB+web layer to `reference/old_db/` (decision 1, below).
2. Define the **new schema, PostgreSQL-first** (most capable), then port to the other
   flavors.
3. Write the **DB logger / importer** process: subscribes to transitions (folds them into
   run/job/job_try rows),
   imports run-data + artifact blobs into a DB. **SQLite-first** for dev (schema ported
   to all flavors by then).
4. **DB→DB sync**: import a SQLite log into PostgreSQL / MariaDB / etc.
5. Port / implement the `reference/old_db` bits the **webapp** needs, on the new layer.

---

## 1. Decision 1 — move old DB/web layer to `reference/old_db/` — **RESOLVED**

**MERGE TARGET:** new TODO chunk (see §B, "Chunk DB-1"). Supersedes part of chunk 8b.

The move (all DB-free from the runner's view):

- `lib/App/Yath2/Schema/` (~210 files: `Schema.pm`, `ResultBase`, `ResultSet`,
  `Result/`, per-flavor `MySQL`/`MariaDB`/`Percona`/`PostgreSQL`/`SQLite` dirs,
  `Overlay/`, `Importer`, `RunProcessor`, `Queries`, `Sweeper`, `Sync`, `Util`)
- `lib/App/Yath2/Server/` + `lib/App/Yath2/Server.pm` (~36 files: web UI + controllers)
- `lib/App/Yath2/Renderer/DB.pm`, `lib/App/Yath2/Renderer/Server.pm`
- `lib/App/Yath2/Command/{db.pm, db/*, server.pm, recent.pm}`
- `lib/App/Yath2/Options/DB.pm`, `lib/App/Yath2/Plugin/DB.pm`
- `share/schema/*.sql` + `author_tools/regen_schema.pl` (codegen dies under
  no-table-classes; kept as historical reference)
- web assets (templates / JS / CSS — locate at execution time)

Resolved choices:

- **(a) Worktree:** created at execution time, off `2.0d`, branch `2.0d-db-rewrite`.
- **(b) Target dir:** `reference/old_db/`, preserving relative paths
  (`reference/old_db/lib/App/Yath2/Schema/…`, `reference/old_db/share/schema/…`).
  `reference/dbix_quickorm/` remains the *target*-schema template; `old_db` is the *old*
  layer being retired.
- **(c) Move, not copy:** `git mv` (preserve history; avoid a live drifting copy).
- **(d) Gap behaviour:** the `db` / `server` / `recent` commands (+ DB renderer/plugin)
  become **stubs that error if used**; their tests become **`SKIP_ALL`** until the
  rewrite lands. (Not silent removal — keep the command surface visible but inert.)
- **(e) Codegen + DDL:** `regen_schema.pl` and current `share/schema/*.sql` move to
  `reference/old_db/`. New schema starts fresh (decision 4), reflected by QuickORM.

Verification note: `dist.ini [GatherDir]` has **no `^reference` exclude** and **3744
`reference/` files already ship** in the tarball (no `MANIFEST.SKIP` either). **Fix in
DB-1:** add `exclude_match = ^reference` to `dist.ini [GatherDir]` (R15) — before the
`git mv` into `reference/old_db`.

---

## 2. Decision 2 — QuickORM usage model + schema authoring — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE new DB section; informs chunks DB-1..DB-7.

- **(a) Tooling:** **QuickORM** = the live ORM via `autofill` (introspects schema from
  the live DB on first connect; `autotype JSON/UUID/DateTime`). **QuickDB** = spinning
  ephemeral / test databases: test fixtures *and* an ephemeral PostgreSQL stood up for
  logging + webapp during a run.
- **(b) Dumb DB objects (DCI / modules-as-actions).** Row objects are dumb. Custom row
  classes only for **simple** mutators / readers when needed. Any **algorithm** lives in
  a function; if it is complex enough to outlive a function, it lives in a **module
  (object) that acts on rows** — algorithm fragments are **not** sprinkled into row
  classes. Complex logic (import, sync, queries) → dedicated modules + controllers under
  the DB namespace. *This rule applies to the DB layer only* — not retroactively to the
  CLI or backend harness layers.
- **(c) Placement: all DB code + the logger under `App::Yath2`; backend touches no DB.**
  **Verified:** `lib/Test2/` has **zero** DB access today. The only grep hits are false
  positives — the `Importer` CPAN exporter module (`use Importer Importer => …` in
  Util/UUID/IPC/FdPass/etc.), a POD doc-link `L<App::Yath2::Renderer::DB>` in
  `Renderer/Base.pm:62`, and the word "database" as a generic resource example in
  `Runner/Resource.pm` comments. So this is adoptable with **no backend changes**.
  Backend→App coupling stays one-way and DB-free: the backend emits **transitions** (read
  by the App-side `Client` over `runner.socket`) and produces **artifact files**
  (`events.jsonl.zst`, located by `Monitor`, read by path); the App-side logger consumes
  those — the backend never reaches into a DB.
- **(d) DDL:** hand-write per-flavor `share/schema/<Flavor>.sql`, PostgreSQL-first then
  port. **No `regen_schema.pl`** — QuickORM builds its internal schema by reading the DB,
  so there is no Perl db-code to keep in sync with the DDL.
- **(e) Versioning:** stamp the **yath version** into each log/DB (a `schema_meta` /
  version row). **No migrations** beyond that for now.

New namespace: `App::Yath2::Schema` (rebuilt, the old one moved to `reference/old_db`),
`App::Yath2::Schema::Row::*` (autorow + optional simple custom), `App::Yath2::DB::Flavor`,
plus logger / importer / sync / controllers under `App::Yath2`.

## 3. Decision 3 — serialization-key + per-engine UUID storage — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE DB section; chunks DB-2/DB-3 (DDL).

- **(a) NOT verbatim — hybrid (see §0 Hybrid principle).** Take the *mechanics* from
  `reference/dbix_quickorm` and the *accurate columns* from the current-branch DBIC.
  **Run-data table set for the new schema:**
  - `runs`, `jobs`, `job_tries`, `artifacts`, *(no `transitions` table — R6)*
  - `machine_users` — the OS user who **ran** the run (per-machine; R7), and `users` — the
    app user who **submitted** it (may differ; captured at import time),
  - `sessions` — **deferred** until the UX layer needs it.
  - **Drop** the reference's `collector` table (and likely others — settled per-table in
    decision 4). Use current-branch names (`job_tries`, not the reference's `try`).
- **(b) `*_uuid_string` mirror scope:** **`run` + `job`** only (the two IDs a human
  pastes from CI output). Tries/artifacts/etc. are reached relationally.
- **(c) Lowercase canonical UUID everywhere.** The reference is inconsistent
  (MySQL/Percona `LOWER(...)`, but SQLite `hex()` returns uppercase). Standardize to
  lowercase: wrap SQLite's generated mirror in `lower(...)`. Per the known gotcha
  (`project_quickorm_uuid_case`): `gen_uuid()` is uppercase, QuickORM canonical is
  lowercase — **normalized centrally at the boundary (R9)**, not via scattered `lc()`
  calls. **Record this so the rebuild does not reintroduce it.**
- **(d) v7 generation in Perl** via `Test2::Util::UUID`; QuickORM UUID autotype
  packs/unpacks canonical-string ↔ 16-byte blob.
- **(e)** Carry the reference's column-ordering convention (fixed-width → variable →
  generated-last; PG prefers alignment-descending).

Per-engine storage mechanism (lowercase-fixed): pg/mariadb = native `uuid` PK, no mirror
(**MariaDB 10.7+ required** — R8);
mysql/percona = `BINARY(16)` PK; sqlite = `BLOB(16)` PK; on mysql/percona/sqlite the
`run` + `job` tables get a STORED generated **lowercase** string mirror + index.

Key strategy per table class (mechanics; per-table assignment finalized in decision 4):
run-data (runs/jobs/job_tries/artifacts) → UUID PK (host-stable sync key);
`users` → integer/identity PK + `UNIQUE(username)`, sync on **username** (R7);
`machine_users` → integer PK + `UNIQUE(host, username)`, sync on (host, username) (R7);
`sessions` → local, not synced.

### 3.1 Derived UUID scheme (v7-preserving) — DEFINITIVE (R4)

Some run-data UUIDs are **derived** from a base UUID so they are reproducible on every
logger/DB with **no coordination** (required for sync idempotency). Every implementation
**MUST** use exactly this algorithm or sync keys + facet-rewrites diverge.

`derive(base_uuid, offset)` — `base_uuid` is a backend-minted **v7** UUID, `offset` an
integer `≥ 0`:

1. Interpret `base_uuid` as a 128-bit big-endian unsigned integer.
2. Bit layout (MSB→LSB):
   `[48b unix_ts_ms][4b version=0111][12b rand_a][2b variant=10][62b rand_b]`.
   `rand_b` = the **low 62 bits** (bits 61..0).
3. `new_rand_b = (rand_b + offset) mod 2^62` — **add-with-wrap**. The carry **never leaves
   `rand_b`**, so timestamp / version / `rand_a` / variant are preserved byte-for-byte.
4. Result = `base_uuid` with its low 62 bits replaced by `new_rand_b`. It is still a
   **valid v7 UUID** (sortable; version=7 kept).

Properties: deterministic (same base+offset → same result everywhere); `offset ≥ 1` ⇒
result ≠ base (no self-collision); distinct offsets in `[0, 2^62)` ⇒ distinct results per
base; cross-base collisions carry the *same negligible* probability as any random UUID
(bases are independent random v7s). **Wrap rule (the bit you asked to nail):** if
`rand_b + offset ≥ 2^62`, it wraps within the 62-bit field (mod) — it does **not** flip
the variant/version/timestamp bits above it.

**Applications** — each derivation uses a base whose offset-space is **disjoint** from any
sibling space:
- **`job_try_uuid = derive(job_uuid, try_ord)`** — `try_ord` is **≥ 1**, guaranteed **at
  the source**: the producer (backend) is changed to start `try_ord`/`is_try` at **1, never
  0** (R10) — so wire == db, no translation. Tries of a job occupy `job_uuid + [1..maxtry]`.
- **`artifact_uuid = derive(collector_uuid, artifact_index)`** — base is the artifact's
  **source collector** (each try runs under its own collector, so this space is per-try and
  disjoint from the `job_uuid`-derived try space). **Events blob = offset 0** (so the
  events-artifact uuid `==` its `collector_uuid`); **extracted binaries = offsets 1, 2, …**
  in extraction (stream) order. *(Binaries deliberately derive from `collector_uuid`, NOT
  `job_try_uuid` — the latter would collide with sibling tries.)*

## 4. Decision 4 — core entity schema — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE DB section; chunk DB-2 (PostgreSQL DDL).

Disposition of the 29 current-branch tables:

- **KEEP — core run-data:** `runs`, `jobs`, `job_tries`, `users`, `machine_users`,
  `projects`, `test_files`, `hosts`.
- **NEW:** `artifacts` (d5), `schema_meta` (= live `versions`; the yath/schema version
  stamp from d2e). *(No `transitions` table — R6; transitions fold into run/job/job_try
  rows + live in blobs.)*
- **Fold into JSON, drop the table:** `run_fields` → a JSON column on `runs`;
  `job_try_fields` → a JSON column on `job_tries`.
- **DROP — replaced by artifacts:** `events`, `binaries`, `log_files`.
- **DROP — reference-only:** `collector`.
- **DROP:** the `mode` enum/column (it drove *which events get rows*; with events in an
  opaque blob there are no event rows to prune).
- **DEFER — UX/auth layer:** `config`, `email`, `primary_email`,
  `email_verification_codes`, `sessions`, `session_hosts`, `api_keys`, `permissions`.
- **DEFER — later feature chunks:** coverage (`coverage`, `coverage_manager`,
  `source_files`, `source_subs`), resource telemetry (`resources`, `resource_types`),
  `reporting` (chart rollups — derivable), `sweeps` (retention — needs rework for the new
  model).

Core columns (accurate set lifted from current-branch DBIC, adjusted):

- **`runs`**: `run_uuid` PK · `project` ref · `host` ref · **`ran_by`** (FK →
  `machine_users` — the OS user on the test machine; R7) · **`submitted_by`** (nullable FK
  → `users`, the account user who uploaded; R7) · counters
  (passed/failed/to_retry/retried — **aggregated over the run's resolved jobs**; survey #3,
  R17) · concurrency_j/x · status enum
  (pending/running/complete/broken/canceled) · canon/pinned · has_coverage/has_resources
  · `parameters` JSONB · **`fields` JSON** (folded `run_fields`) · duration · **version
  stamp** (d2e). **Dropped:** `log_file_id`, `mode`. `worker_id` (import-claim) shape
  TBD under d7.
- **`jobs`**: `job_uuid` PK (= the existing backend `job_id`, already a `gen_uuid()`;
  d6c) · `run` ref · `test_file` ref · `is_harness_out` (job0 = harness internal log) ·
  **`passed`** (folded "any try passed" once resolved — survey #3) · **`failed`**
  (resolved && !passed — survey #3). *(No `should_retry` column — runtime-only, R17.)*
- **`job_tries`**: PK **`job_try_uuid`** — a *single derived* uuid = `job_uuid` with
  `try_ord` **added (mod 2⁶²) into the low `rand_b` bits** (§3.1/d6c; keeps the existing
  try-uuid URLs, deterministic
  across loggers) · `job_uuid` ref · `try_ord` (1-based, ≥1 never 0, R10) ·
  **`result`** (tri-state verdict: null = in-flight / true = pass / false = fail — the
  top-line "did this try pass", distinct from the counts; survey #5) ·
  `assertion_count` · `pass_count` · `fail_count` (assertion counts) ·
  `subtests` (top-level count) · **`subtests_passed`** · **`subtests_failed`** (the
  split, derived from the auditor's `subtests[]`; survey #5) ·
  `status` enum · `exit_code` · started/finished timestamps (+ `duration`) ·
  `parameters` JSONB · **`fields` JSON** (folded `job_try_fields`, directives #1).
  **Dropped:** the `stdout`/`stderr` text columns — read on demand from the artifact
  blob (R6 follow-on, now final; survey #5). *(Counts are `pass_count`/`fail_count`,
  NOT old4's `passed`/`failed` — those collide with the `result` verdict bool.)*
- **`hosts`**: kept small (host identity) so runs can be listed per host to spot a broken
  host. `runs.host` references it.
- **`projects` / `test_files`**: kept (a run needs its project; a job references its test
  file).

### 4.1 Retry-recording + verdict-fold rules (RECORD-ONLY — survey #3/#5, R17)

Retry is **record-only**: the **runner owns *when* to retry** (in-memory `Runner/State.pm`,
DB-free per d2c); the **logger only records outcomes**. The schema therefore stores results,
never scheduler state.

- **One `job_tries` row per `is_try`.** The logger writes a row per try (keyed by `try_ord`
  = the runner's `is_try`, **1-based** per R10); `result`/counts/subtest-split are folded
  from the auditor's `final_state` (survey #5).
- **`should_retry` is runtime-only — NOT a persisted column.** `retry_limit` is **input** and
  lives in the job's **params JSON** (`parameters`), not a dedicated column.
- **`jobs.passed` = folded "any try passed"** (true once the job's tries are resolved);
  **`jobs.failed` = resolved && !passed** (survey #3).
- **`runs.passed`/`failed`/`retried` aggregate over the run's resolved jobs** (the run
  counters above).

## 5. Decision 5 — artifacts table — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE DB section; chunk DB-2 (DDL) + DB-4 (importer) + DB-6
(controller). Absorbs the dropped `events`, `binaries`, `log_files` tables.

Final table:

```
artifacts:                       # plural, per current-branch naming (R12)
  artifact_uuid  UUID PK         # DETERMINISTIC (R2/R4): derive(collector_uuid, idx) — events=0, binaries=1,2,…; v7-preserving §3.1
  run_uuid       FK -> runs        NOT NULL    # denormalized: purge a run's artifacts without chasing FKs
  job_try_uuid   FK -> job_tries   NULL        # null = run/process-level artifact (single derived uuid, d6c)
  filename       TEXT  (NOT unique; 'events.jsonl.zst', '<service_name>.json.zst', 'screenshot.png')
  local_path     TEXT
  data           BLOB  (nullable)
```

- **`data` vs `local_path`:** if `data` is populated it is **canon**; if missing, read
  `local_path`. `local_path` is **host-local** — **not** copied on import or DB→DB sync,
  **never cleared** by the logger; it points into the workdir and dies when the workdir
  is deleted. (No two-phase null-ing — simpler than the reference.) *Operational risk:* a
  `data`-null artifact whose workdir is deleted before import is dangling — the logger
  must import before workdir cleanup (feeds d7).
- **`filename` carries the kind** — no `type`/`kind` column. Events blob vs binary is
  told by the filename (+ `job_try_uuid` presence). DCI-simple.
- **No `binaries` table.** A binary attachment is just an artifact row (its own
  `filename`, `data`). The live `binaries` table's three roles are subsumed:
  addressability → `artifact_uuid` + the controller; MIME → filename extension;
  event→binary linkage → the event facet stores the binary's `artifact_uuid`.

**Import behavior (binary extraction)** — the importer reads the `.jsonl`; any
artifact/event-stream containing embedded binary data (e.g. images) gets that binary
**extracted into its own binary artifact row**. The event **stays in the stream** but
with the binary bytes **removed** and its facet **rewritten to point at the new binary
artifact's `artifact_uuid`**. (Schema-adjacent; the mechanism lands in d7.)

**Download controller (capture as a ticket):** `GET /artifact/<uuid>.<ext>` — strip
`.ext`, look up the artifact by uuid, **verify** the stored `filename`'s extension
matches `.ext` (rejects forged/mismatched requests), then stream `data` with
`Content-Type` derived from the extension and **`Content-Disposition: attachment;
filename="<stored filename>"`** (or `inline` to render images in-page). Serves any
artifact — events blob download or image. → see §B for the ticket stub.

## 6. Decision 6 — job-try identity + transitions handling (**NO transitions table** — see R6) — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE DB section; chunk DB-4 (logger).

> **R6 reframe (2026-06-22):** there is **no `transitions` table**. Transitions are already
> written into every collector's `events.jsonl.zst` (`record_transitions=1`) → the artifact
> blobs, so a table would store them twice. Instead the **logger folds wire transitions into
> run/job/job_try ROW STATE** (the queryable folded summary), seeded by the subscribe-time
> snapshot; the full transition detail lives in the blobs. The original table design
> (append-only log, per-run ordinal, `entity_type`, `(run_uuid, ordinal)` PK) is **withdrawn**.
> Only part **(c)** below — the `job_try_uuid` identity — survives (it's about `job_tries`,
> not transitions).

- **(a)/(b)/(d)/(e) WITHDRAWN** (the transitions table). Replacements: transitions fold into
  run/job/job_try rows via the Monitor's folded state (d7); durable detail in blobs;
  `system_load` rides into the sampler's blob (R6 (b)); stage lifecycle stays in the stage's
  blob (deferred wire-emission). No `ordinal`, no runner-`seq`, no per-frame Subscriber tap.
- **(c) Identity model — derived single `job_try_uuid` (this SURVIVES — `job_tries` table).**
  `job_id` is **already a UUID** (verified `lib/App/Yath2/TestFile.pm:454`
  `job_id => gen_uuid()`; `Job.pm:819` documents `$uuid = $job->job_id`) — so
  **`job_uuid := job_id`, no backend fix**. `job_tries` PK is a **single derived
  `job_try_uuid`** = the `job_uuid` (a v7 uuid) with `try_ord` **added (mod 2⁶²) into the
  low `rand_b` bits** (the v7-preserving scheme defined in §3.1). It is **deterministic** —
  every logger/DB computes the same value, so
  sync matches on one column — AND it preserves the existing **try-uuid URLs** (which we
  keep; this is why we chose single over compound). `try_ord` remains a column (it is the
  derivation input + ordering/display). Downstream (the `artifacts` table)
  references a try by the single `job_try_uuid`. The backend already mints + emits
  `run_uuid` and `job_id`(uuid), so all run-data UUIDs are globally stable with no backend
  identity changes.
  - **Derivation rules:** see the definitive **§3.1** —
    `job_try_uuid = derive(job_uuid, try_ord)` via `(rand_b + try_ord) mod 2^62`
    (v7-preserving add-with-wrap, R4). Centralize in **one well-tested function**.
    **`try_ord` is ≥ 1 at the source** — the producer is changed to start try ordinals at 1
    (R10) — so the first try's uuid ≠ the job uuid → see §B ticket.
  - **OPTIONAL feature (only if easy):** overwrite the derived uuid's high-48-bit
    timestamp with the **try's start time** (the first collector transition's `stamp`,
    which is on the wire) so try uuids are time-sortable by actual try start instead of
    inheriting the job's creation time. Reproducibility holds *iff* the Monitor's
    initial-state snapshot preserves the original transition stamp (verify) — a
    late-joining logger must see the same start stamp. Not required; depends on effort.
**Row-state seeding (survives from old (d)):** the logger seeds run/job/job_try state from
the Monitor **subscribe snapshot** (initial state), then folds subsequent transitions into
the rows as it polls. The early-start sequence — **start harness → start logger → queue
run** (d7) — ensures it attaches before most transitions occur.

## 7. Decision 7 — logger / importer process — **RESOLVED**

**MERGE TARGET:** new ARCHITECTURE §"DB logger process"; chunk DB-4. Largest net-new
component. All DB-side; backend stays DB-free (d2c).

- **(a) Own subscription per logger** — each logger is an independent App-side process
  owning its own `App::Yath2::Client` + `Subscriber` to `runner.socket` (run-scoped via
  `connect_subscriber(run_id)`). N loggers → N DBs; runner stays the sole hub. Exit on
  socket-close (transient) or `run_done`/`harness_run_end` (persistent).
- **(b) Fold-into-rows + blob import (R6).** The logger (i) **folds wire transitions into
  run/job/job_try ROW STATE** via the Monitor's folded state — **no `transitions` table**
  (R6); and (ii) stores each collector's `events.jsonl.zst` **whole** as an artifact blob
  (the blob already contains the full transition detail; **no per-event rows** — 1.0's
  per-event rows were the "major db issue", `reference/notes/fresh_start`).
  Binary-extraction (d5) happens here.
- **(c) Spawn** — `test`/`run` fork+exec's the logger **early** (harness → logger → queue
  run, d6d), handing `workdir` + `run_id` + DB config via a temp-JSON settings file
  (`Renderer::DB._start_process` pattern; reuse the plumbing, not the per-event ingestion).
- **(d) Row-state from the Monitor fold + incremental blob import (R6).** The logger reads
  the **Monitor's folded state** (seeded by the subscribe snapshot, updated each `poll()`)
  and upserts the run/job/job_try summary rows — it does **not** need a per-frame
  Subscriber tap (GPT-2 dissolved with the table). The fold also yields each collector's
  `events_file` path. Import each blob **as that collector finalizes** (`wait_terminal`
  handles the completed-before-final-state gap), not batched at run-end — shrinks the
  cleanup race.
- **(e) Workdir-cleanup race — runner waits for subscribers.** The persistent runner
  **defers shutdown + workdir cleanup until all subscribers disconnect**; loggers are
  subscribers, so they stay subscribed until their imports finish, then disconnect → the
  runner cleans. The default **local sqlite logger is the durability anchor**;
  additional/remote loggers are best-effort and recover anything missed via **sync (d8)**
  — they never gate cleanup. If a logger/command detects the **workdir vanished early**
  (runner crash / force-kill), report the error to the terminal and mark the log
  **incomplete and possibly corrupt**. *Existing:* `Runner.pm:1316` handles
  workdir-removed-out-from-under. *New requirement (ticket):* the runner must defer
  cleanup until subscribers disconnect.
- **(f) Defaults + naming.** The default sqlite DB reuses the **current logger's naming
  machinery** (the `log_file_format` strftime + `%!` escapes, dir + temp-dir fallback,
  and the `lastlog` symlink — `test.pm:707-720`) **with a DB extension** instead of
  `.jsonl`; lives in the **temp dir by default**, overridable location/name; symlinks
  `lastlog` to the current dir **when asked**. **No compression** (it's a DB; artifact
  blobs are already zst). The enable option is **`-L` / `--logger`** (R16): **repeatable**,
  value-polymorphic — bare = default sqlite, `=path` = sqlite file, `=$DSN` = remote DB;
  each `-L` forks one logger process (N loggers → N DBs). **Logging is opt-in (default OFF,
  R11)** — sqlite is only the default *target* once you enable it; DB modules are optional
  and lazily required with an actionable error. See the option audit below (§7.1).
- **(g)** The jsonl **renderer** (writes a file) and the DB **logger** (a process) are
  **fully separate** concerns. Confirmed.

**Tickets (→ §B):** (1) runner defers workdir cleanup until all subscribers disconnect;
(2) logger/command detects workdir-vanished-early → terminal error + "log incomplete /
possibly corrupt."

### 7.1 Current logger option audit (your "adopt what applies")

Current `App::Yath2::Options::Logging` group → split between the new DB **logger** (d7)
and the jsonl **renderer** (d10), dropping short forms and `log` from names (per earlier
decisions). **Resolved mapping (R16):**

| Current option | jsonl renderer (d10) | DB logger (d7) | notes |
|---|---|---|---|
| `log` / `-L` | renderer enabled by adding it to the renderer list | **`-L` / `--logger`** = enable DB logging (opt-in, default OFF); **repeatable** (N loggers→N DBs); value-polymorphic: bare=default sqlite, `=path`=sqlite file, **`=$DSN`=remote DB** | **`-L` repurposed to the DB logger** (R16); never auto-on (R11) |
| `log_dir` | `--jsonl-dir` (temp fallback) | DB dir (temp fallback) | shared dir+temp-fallback machinery |
| `log_file` / `-F` | `--jsonl-file` (no short) | DB target via `-L=<path\|DSN>` (R16) | **`-F` short freed** |
| `log_file_format` / `--lff` | jsonl format (`.jsonl` ext) | DB-name format (DB ext) | **shared format/`%!`-expansion helper**, different default ext |
| `bzip2` / `-B`, `gzip` / `-G` | **KEPT** (long-form `--bzip2`/`--gzip`; shorts dropped) | ✗ not for a DB | renderer keeps compression; **`-B`/`-G` shorts freed** |
| lastlog symlink (`test.pm:707`) | renderer `lastlog` | DB `lastlog` (when asked) | shared symlink helper |

**Resolved:** the jsonl renderer **keeps** compression (long-form `--bzip2`/`--gzip`,
shorts dropped); the DB logger has none.

## 8. Decision 8 — DB→DB sync — **RESOLVED**

**MERGE TARGET:** new ARCHITECTURE §"DB sync"; chunk DB-5. Old `Schema/Sync.pm` +
`Command/db/sync.pm` → `reference/old_db` (reference only).

- **(a) From scratch on QuickORM.** Enough differs (uuid-stable keys, no int-remap, new
  table set, QuickORM marshalling) that porting the raw-SQL `Sync.pm` would drag in
  inapplicable machinery. New module under the DB namespace (DCI; reusable by the command).
  Old `Sync.pm` informs only the *algorithm* (run_delta, per-run dump/load,
  get_or_create, datetime normalize).
- **(b) Command-driven.** `yath db sync` (from-DB → to-DB; a `run_uuid` list or a
  `run_delta`-style "runs in A not in B"). **No** auto-push / server-pull in scope now.
- **(c) Per-run granularity, uuid-upsert idempotency.** Selector = `run_uuid`; a run +
  all its jobs/tries/artifacts move as a unit (transition detail rides in the artifact
  blobs, R6; runs are immutable once
  complete — no intra-run incrementality). Re-sync is an idempotent upsert keyed on the
  globally-stable uuids; conflicts impossible (distinct runs → distinct uuids).
- **(d) Marshalling.** Run-data **UUID PKs** copy verbatim (no surrogate-PK remap). But
  run-data **FK columns to natural-key entities are host-local integers and MUST be
  remapped** (R5): resolve the entity on the destination via `find_or_create` on its
  natural key (`users`→**username**, `machine_users`→**(host, username)**, `projects`→name,
  `hosts`→hostname, `test_files`→path; PK host-local, d3; R7), then rewrite the FK before
  writing. Note `submitted_by` honors the R7 attribution flag. Artifacts:
  copy the `data` blob, **skip `local_path`** (host-local, d5). QuickORM autotypes handle
  per-engine UUID storage + datetime. Not synced: sessions/auth/config (local).
- **New table set:** `runs, jobs, job_tries, artifacts` + `users, machine_users, projects,
  test_files, hosts`. **No `transitions` table** (R6) — transition detail rides **inside the artifact
  blobs**, so it syncs automatically when artifacts sync. (Dropped from old list: `events,
  binaries, run_fields, job_try_fields, reporting, coverage` — folded or deferred.)
- **Plus a simple `import` command** — imports the **single run** contained in one sqlite
  **log file** into another database, **auto-selecting the only run** (no `run_uuid`
  needed). A convenience wrapper over the sync engine; it replaces the old
  `db-publish`/upload role for the sqlite-log → DB path. → §B ticket.

## 9. Decision 9 — webapp port — **DEFERRED to a separate future spec**

**Not part of this DB-work effort.** The webapp (`App::Yath2::Server` + controllers) moves
to `reference/old_db` with the rest (d1) and **stays broken** while the DB work lands
(`server` command stubbed, d1d). After the DB changes land, a **separate UX-migration
spec** will be written from the user's ideas. No webapp decisions are made now.

**Parked research (input for that future UX spec, NOT decisions):**
- Read-path: decode artifact blobs on demand, **Perl-first** streaming filter (events are
  already in `event_idx/sdx` file order in the blob); per-request TEMP events table only
  for pathologically large overlapping tries. No permanent events table.
- The **only** cross-job query is **Interactions** = phase-1 `job_tries` timing query
  (kept columns launch/start/ended) + phase-2 per-try blob decode within a stamp window.
  Every other event view (Events `load_subtests`, Files top-level subtests, Stream live)
  is single-try → one blob. Source: `reference/old_db/.../Server/Controller/*` (+
  `reference/pre_ai_2.0/.../Interactions.pm`).
- **Render-on-read** (no event rows to hold a pre-rendered column; reuse `line_data`/
  painter on decoded events; cache later if needed).
- **Point-at-any-DB**: `yath server` connects to any one DB (sqlite or server) via
  QuickORM, read-only; default sqlite.
- Preserve the `line_data()` output contract + numeric-epoch stamps so the front-end JS
  ports with minimal change.
- The **`/artifact/<uuid>.ext`** download controller (d5) lands with this future webapp
  spec.

## 10. Decision 10 — side-track: jsonl renderer + renderer-owned options + junit — **RESOLVED**

**MERGE TARGET:** ARCHITECTURE renderer/options sections; chunk DB-Jsonl (in this effort).
The jsonl-renderer conversion + renderer-owned options are **part of this effort** — the
new DB logger takes over the "logger" concept, so the old jsonl logger **must** become a
plain renderer to make room (land this **before** the DB-logger chunk). **junit is its
OWN separate effort** (deferred — not part of this effort).

- **(a) jsonl renderer = CONVERT the current logger** (it already speaks our event
  shape), **not** a port of old3 (which had a very different producer). Wrap the existing
  logger logic — `test.pm::logger()` FH construction + the `dispatch_to_sinks` `as_json`
  write + `Options/Logging` — into a proper renderer: `render_event` writes
  `as_json`; `start` opens the FH (+ compression); `finish` writes the `null` terminator
  + close + `lastlog` symlink + "Wrote log file". Own `option_group` (the §7.1 audited
  options: `--jsonl-file/dir/format` + `--bzip2/--gzip`, no `log`, no shorts). **Promote
  into the renderers list; delete the inline `logger` sink** in
  `Renderer::Base::dispatch_to_sinks`. **Rewire implicit-enable** (the old `Logging`
  post_process + the YathUI force-enable) to inject the renderer instead of setting
  `logging->log`.
- **(b) Renderer/plugin option auto-loading — model on pre_ai_2.0.** Use
  **`mod_adds_options => 1`** on the `renderers` option (`Display.pm`) so each named
  renderer's `option_group` auto-loads — exactly what pre_ai_2.0 did
  (`Options/Renderer.pm:82`), and pervasively across pluggable sources
  (Runner/Yath/Scheduler/Resource/Finder). Live already does this for **Finder**
  (`Options/Finder.pm:580`) but **not renderers**. Audit the other pluggable sources and
  bring them all up to the pre_ai standard so renderers/plugins/etc. contribute options
  automatically. *(Supersedes the earlier manual-guarded-include lean.)* **Verify** live
  `Getopt::Yath` `mod_adds_options` works on the **renderers Map** option (pre_ai's
  renderers was map-ish and used it; live migrated the Getopt::Yath machinery in chunk 2)
  — small fix if the Map case differs from the List case. Add a test that
  `--renderers +My::Renderer` with a renderer-defined flag parses.
- **(c) junit import — its OWN separate effort (deferred).** When done: **old3** base
  (matches the live `harness_job_start`/`abs_file`/`rel_file` event shape + ships a test).
  Re-base onto `Test2::Harness2::Renderer`; swap `Object::HashBase` →
  `Test2::Harness2::Util::HashBase`; drop `desired_filters` (no Filter machinery live) +
  its test subtest. `JUNIT_TEST_FILE`/`ALLOW_PASSING_TODOS` env-first (option group
  later). **`XML::Generator` = OPTIONAL dependency** — the junit renderer **refuses to run
  with a clear error if `XML::Generator` is missing**. (Benefits from (b)'s renderer-owned
  options if its env vars become proper options, but does not block on it.)

**Tickets (→ §B):** (1) convert current logger → jsonl renderer (+ promote, delete inline
sink, rewire implicit-enable); (2) renderer-owned options via `mod_adds_options`
(pre_ai model) + audit all pluggable sources + verify Map support + test; (3) junit
renderer import (old3 base) + optional `XML::Generator` guard.

## Decision tracker (final)

Discussed one at a time. Each fills in here as resolved. Leanings shown are from
research, **not** decisions.

| # | Decision | Status |
|---|---|---|
| 1 | Move old layer → `reference/old_db` | **RESOLVED** (§1) |
| 2 | QuickORM usage model; placement under App::Yath2; DCI dumb-objects; `.sql` source of truth; version stamp | **RESOLVED** (§2) |
| 3 | Serialization-key + per-engine UUID storage; hybrid principle; table set | **RESOLVED** (§3) |
| 4 | Core entity schema — table disposition + core columns; fields→JSON; drop mode | **RESOLVED** (§4) |
| 5 | Artifacts table — final shape; data/local_path canon rule; no binaries table; import binary-extraction; download controller | **RESOLVED** (§5) |
| 6 | **No transitions table** (R6) — transitions fold into run/job/job_try rows + live in blobs; derived single `job_try_uuid` (§3.1) survives | **RESOLVED** (§6, R6) |
| 7 | Logger/importer process — own subscription; **folds transitions into run/job/job_try rows** (Monitor fold; no transitions table, R6) + whole-blob artifact import; early spawn; runner waits for subscribers; sqlite default; option audit | **RESOLVED** (§7, R6) |
| 8 | DB→DB sync — from-scratch QuickORM module; `yath db sync` command; per-run uuid-upsert; get_or_create for natural keys; blob copied/local_path skipped; + simple `import` command | **RESOLVED** (§8) |
| 9 | Webapp port — **DEFERRED to a separate future UX-migration spec** (built from user's ideas after DB lands); webapp stays broken meanwhile | **DEFERRED** (§9) |
| 10 | jsonl renderer + renderer-owned options **in this effort** (frees "logger" for DB-4); junit = **its own separate effort** | **RESOLVED** (§10) |

*(Detailed resolutions appended below as each is decided.)*

---

## R. Review-driven revisions (2026-06-22 — gemini + gpt reviews)

Resolutions to `db_review_gemini.md` / `db_review_gpt.md`, discussed one at a time.
These **amend** the decisions above; where they contradict earlier text, these win.

- **R1 — ~~transitions `ordinal` is RUNNER-assigned~~ SUPERSEDED by R6.** *(Moot: the
  `transitions` table is dropped in R6, so there is no `ordinal`/`(run_uuid, ordinal)` key
  to make stable. No runner-`seq` change needed.)*
- **R2 — artifact identity is DETERMINISTIC (GPT-3).** `artifact_uuid` is **derived from
  stable inputs**, never an independent `gen_uuid()`, so the same run logged into two DBs
  produces identical artifact UUIDs *and* identical binary-extraction facet-rewrites
  (portable blobs). **events-artifact** = derive(`collector_uuid`, 0); **binary-artifact** =
  derive(`collector_uuid`, `index≥1`) — NOT from `job_try_uuid` (would collide with sibling
  tries; R4/§3.1); no content-hash dedup (clean per-try
  ownership). Per **R4**, both derive via the v7-preserving scheme from **`collector_uuid`**
  (events blob = offset 0, binaries = offsets 1,2,… — disjoint from the `job_uuid`-derived
  try space; see §3.1). Logger-computed; **no backend change**. → §B ticket.
- **R3 — ~~global frames duplicate per-run, incl. `system_load`~~ SUPERSEDED by R6.**
  *(Moot: no transitions table. Global lifecycle frames remain durable in their own
  collectors' blobs. `system_load` is handled by R6 option (b): the sampler emits its load
  into its own events stream so it rides into `sampler-events.jsonl.zst`.)*
- **R4 — derived UUIDs keep v7 via add-with-wrap (Gemini-1, user scheme).** Derived UUIDs
  (`job_try_uuid`, `artifact_uuid`) are **not** v8 and **not** "replace low bits"; they use
  the user's **`(rand_b + offset) mod 2^62`** scheme that preserves v7 (version/variant/
  timestamp untouched, wraps within `rand_b`). Defined definitively in **§3.1**.
  `job_try_uuid = derive(job_uuid, try_ord≥1)`; `artifact_uuid = derive(collector_uuid,
  index)`. This **supersedes** the earlier v8 mention in R2.
- **R5 — sync remaps natural-key FKs (Gemini-4).** Run-data UUID PKs copy verbatim, but
  run-data **FK columns pointing at natural-key entities** (`runs.project`, `runs.host`,
  `runs.ran_by`/`submitted_by`→users, `jobs.test_file`) are host-local integers. The sync
  engine resolves each on the **destination** via `find_or_create` on its natural key
  (project→name, user→username, host→hostname, test_file→path), then **rewrites the FK**
  in the run-data row before writing. (Amends d8d.)
- **R6 — DROP the transitions table (major; supersedes d6 table, R1, R3).** Transitions are
  **already duplicated into the collectors' `events.jsonl.zst`** (`record_transitions=1`
  everywhere — `Job.pm:237-242`, `Runner.pm:878/953/960`, `Preloader.pm:247`,
  `Plugin.pm:59`), which become artifact blobs. A separate `transitions` table just stored
  them twice. So:
  - **No `transitions` table.** Full transition detail (run/job/try/collector/stage)
    lives durably **inside the artifact blobs**.
  - **The logger folds wire transitions into run/job/job_try ROW STATE** — it upserts the
    summary rows (status, counts, exit, timestamps, verdict) from the **Monitor's folded
    state**, seeded by the subscribe-time **snapshot** (initial state), updated as it
    polls. The rows are the queryable folded summary; the blobs are the full record.
  - **GPT-2 (Subscriber frame-tap) DISSOLVES** — the logger reads the Monitor's folded
    state (which `poll()` already maintains), not each individual frame, so **no new
    Subscriber frame-exposing API is needed**. (Item 6's original ask is moot.)
  - **`system_load` → option (b):** the sampler **emits its load into its own events
    stream** so it rides into `sampler-events.jsonl.zst` (a blob) like everything else —
    small sampler change; no metrics table. → §B ticket.
  - **R1 runner-`seq` change: not needed** (no ordinal key to stabilize).
  - **Sync:** `transitions` leaves the synced table set (d8); transition detail travels
    **inside the artifact blobs** automatically when artifacts sync.
  - **Stage lifecycle:** still emitted into the stage's blob (deferred wire-emission, d6e);
    no dedicated rows.
  - **`job_try_uuid` identity (d6c) + §3.1 are UNAFFECTED** — `job_tries` still exists.
  - Row-column trim follow-on (**now final — R17/survey #5**): the detailed
    `job_tries.stdout/stderr` columns are **dropped**; that output is read on demand from the
    artifact blob; rows keep the folded summary only.
- **R7 — TWO distinct user tables (GPT-7).**
  - **(1) machine-user (ran-by)** = the OS user on the test machine → its **own table
    `machine_users`**: `machine_user_id` (host-local int PK), `host` FK **NOT NULL**,
    `username` TEXT, **`UNIQUE(host, username)`**. `runs.ran_by` → FK `machine_users`.
    Natural/sync key = **(host, username)** — resolved by host (hostname) then username.
  - **(2) app-user (submitted-by)** = the account user who uploaded → the **`users`** table,
    natural key **`username`** (email/auth deferred). `runs.submitted_by` nullable FK →
    `users` (null = unknown).
  - **Import/sync attribution for `submitted_by`** (flag): **(a) carry-original** —
    `find_or_create` by username on the destination; **(b) override** — attribute to the
    user performing the import/sync (common cross-DB case; don't sync foreign accounts).
    *Proposed default:* **carry-original**, `--as-user`/`--override-user` forces (b).
  - Both `machine_users` and `users` are natural-key entities → **FK-remapped on sync**
    (R5): `machine_users` by (host, username), `users` by username. (Amends d4 + d8.)
- **R8 — require MariaDB 10.7+ (Gemini-5).** Native `uuid` is MariaDB 10.7+ only (10.5/10.6
  LTS lack it). Declare **MariaDB 10.7+ a hard minimum** and keep the native `uuid` column
  (no binary fallback). Document it (cpanfile/Makefile note + Flavor/DDL comment).
- **R9 — centralize UUID lowercasing at the boundary (Gemini-6).** No more "`lc()` before
  every compare". A central `App::Yath2::Util::UUID` exports a **`gen_uuid()` returning
  lowercase** and **normalizes wire UUIDs to lowercase on ingest** into the DB layer
  (backend still mints uppercase via `Test2::Util::UUID`, d2c). §3.1 derive math works on
  the 128-bit integer (case-irrelevant); only stored/compared string form is normalized.
  (Supersedes the "`lc()` at comparison" guidance in §3c.)
- **R10 — producer emits 1-based try ordinals (GPT-8).** Instead of mapping `wire 0 → db 1`
  at ingest, change the **producer** (backend) so `try_ord`/`is_try` starts at **1, never
  0** — wire == db, no translation; satisfies §3.1's `try_ord ≥ 1` at the source. **Backend
  blast radius (ticket):** `Job.pm` `is_try` default/init + retry increment, `job_dir`
  naming (`job_id+is_try`, `Job.pm:508`), any `is_try == 0` "first try" checks, the wire
  `try` field, and the POD that says it starts at 0. Audit all `is_try` uses.
- **R11 — DB layer is OPTIONAL; deps are Suggests/Recommends, not Requires (GPT-9 + user).**
  Core `yath test` **without logging** must need **zero** DB modules. So:
  - **No DB module is a hard runtime prereq** — `DBIx::QuickORM`, `DBIx::QuickDB`,
    `DBD::SQLite` (incl. the default sqlite backend), `DBD::Pg`/`DBD::mysql`/`DBD::MariaDB`
    all move to **RuntimeRecommends/Suggests**. (Currently `DBD::SQLite` is a *hard* prereq
    — `dist.ini:132` — it gets demoted.)
  - **Remove the `DBIx::Class*` prereqs** (`dist.ini:123-130`) after DB-1 moves DBIC to
    `reference/old_db` (reference isn't loaded/shipped).
  - **Logging is OPT-IN** (default OFF; `yath test` does nothing DB unless asked). When you
    *do* opt in, the **default target is sqlite** — corrects the earlier "enabled by
    default" wording in §7.1/§7f.
  - **Lazy-load + actionable error:** every DB-touching entry point (logger, `db`/`server`
    commands, sync, import) **runtime-`require`s** its modules and throws a clear
    "install `DBIx::QuickORM` + `DBD::<engine>` to use logging/the web UI" exception if
    absent. Nothing always-loaded may `use` a DB module at compile time.
- **R12 — table names plural, current-branch convention (GPT-10).** All tables plural:
  `runs, jobs, job_tries, artifacts, users, machine_users, projects, test_files, hosts,
  schema_meta`. Fixed decision-5's artifact table name to `artifacts`. (§0.2 key-table
  already corrected when the transitions table was dropped.)
- **R13 — ARCH §2.4 wording explicitly replaced (GPT-5).** §A now mandates replacing
  §2.4's "schema-as-Perl, **not** hand-written DDL" with "hand-written per-flavor DDL +
  QuickORM autofill", as a **prerequisite for chunk DB-2**.
- **R14 — execution proceeds as approved; amend AGENTS.md (GPT-6).** Worktree + `git mv`
  into `reference/old_db` are approved. The AGENTS.md "never modify `reference/`" rule is
  about **not mutating existing reference content** — **adding a new `reference/old_db`
  dir is fine** (it's a retirement destination, never edited afterward). **Proposed
  AGENTS.md amendments** (apply at execution, in the worktree): (1) clarify the
  `reference/` rule — "do not modify existing reference content; adding a new reference
  subdir as a retirement destination is allowed"; (2) **lift/scope the foundations
  override** for this DB effort to permit the worktree (justified by the concurrent agent
  in this repo). *(AGENTS.md was not in the "other agent owns it" list, but treat it as a
  shared doc edited at execution.)*
- **R15 — exclude `reference/` from the dist, in DB-1 (GPT-6).** `dist.ini [GatherDir]` has
  no `^reference` exclude and **3744 `reference/` files already ship** in the tarball
  (pre-existing bloat). Add **`exclude_match = ^reference`** to `dist.ini [GatherDir]` as
  part of **DB-1** (before/with the `git mv` of ~210 DBIC files into `reference/old_db`).
  Fixes the existing bloat + the new addition. (Supersedes §1's "pre-release" note.)
- **R16 — hard-drop 2.0 backcompat; repurpose `-L` for the DB logger (Gemini-7 + user).**
  No deprecated aliases (2.0 may break CLI compat). **`-L` is NOT dropped — it's repurposed
  to the new DB logger** (≡ `--logger`), a **repeatable, value-polymorphic** option (one
  `-L` per logger → N loggers/N DBs):
  - bare **`-L`** = enable DB logging at the **default sqlite** location,
  - **`-L=path/to/log`** = sqlite at that **path** (filename override),
  - **`-L=$DSN`** = connect to **another database** (postgres/mariadb/… via DSN),
  - **repeatable** — multiple `-L` start multiple loggers to multiple DBs.

  The old `-F`/`-B`/`-G` short letters are **freed** for reuse. The **jsonl renderer uses
  long opts only** (`--jsonl-file`/`--bzip2`/`--gzip`, no shorts). (Amends §7.1 + §7f +
  d7f's `--logger`, + d10a.)
- **R17 — `job_tries` verdict columns + retry recording folded in (survey #3/#5).** The
  reference-port survey items **#3 (retry recording)** and **#5 (job_try verdict columns)**
  fold into this DB schema (no stand-alone tickets). Amends d4 §"core columns" + adds §4.1:
  - **`job_tries` verdict columns (survey #5):** add **`result`** (tri-state: null=in-flight
    / true=pass / false=fail), `assertion_count`/`pass_count`/`fail_count`, `subtests`
    (top-level count) + **`subtests_passed`**/**`subtests_failed`** (split, derived from the
    auditor's `subtests[]`). Naming `parameters` (not `params`); counts are
    `pass_count`/`fail_count` (not old4's `passed`/`failed`, which collide with `result`).
  - **DROP `stdout`/`stderr` text columns** — read on demand from the artifact blob (was the
    R6 follow-on; now **final**). No duplicating large output already in the blob.
  - **Retry recording (survey #3, record-only):** retry stays runner-owned (in-memory,
    DB-free, d2c); the **logger only records** — one `job_tries` row per `is_try` (1-based,
    R10). **`jobs.passed` = any-try-passed** (folded once resolved); **`jobs.failed` =
    resolved && !passed**; **`runs.passed`/`failed`/`retried` aggregate over resolved jobs.**
    **`should_retry` is runtime-only — NOT a column**; `retry_limit` lives in job params.

## A. Proposed `ARCHITECTURE.md` changes (running list, for the merge agent)

- Reframe **§2.4 / §4.6** (the DB/QuickORM sections referenced by the current chunk 8b):
  from "migrate interim DBIC → QuickORM" to "from-scratch QuickORM DB layer, reflect-
  from-DB, no table classes; canonical record = **artifact blobs + folded summary rows**
  (no transitions table)."
  - **EXPLICITLY replace** §2.4's current sentence *"schema is defined with DBIx::QuickORM
    (schema-as-Perl), **not** hand-written DDL files"* — the new model is **hand-written
    per-flavor DDL + QuickORM `autofill`** (reflect-from-DB), with a one-line rationale (the
    reference branch proves DDL+autofill end-to-end; no Perl schema/codegen to keep in
    sync). This ARCH edit is a **prerequisite for chunk DB-2** (R13/GPT-5).
- State explicitly: **all DB code + the logger live under `App::Yath2`; the backend
  `Test2::Harness2` layer accesses no DB in either direction** (one-way coupling: backend
  emits transitions + artifact files, App consumes). QuickORM = ORM, QuickDB = ephemeral
  DBs. DB layer follows DCI dumb-row-objects (algorithms in functions/modules acting on
  rows, not in row classes). Version-stamp each log/DB; no migrations yet.
- New subsection: **serialization-key strategy** (§0.2 table) — PK vs host-stable sync
  key.
- New subsection: **DB logger process** (the §7 design) — its own process, subscribes to
  transitions via the client, **folds them into run/job/job_try summary rows** and **stores
  each collector's `events.jsonl.zst` as an artifact blob** (transition detail lives in the
  blobs; **no transitions table**, R6); N loggers → N DBs; default SQLite.
- New subsection: **multi-DB sync** (§8) — serialize on the host-stable key; per-run
  uuid-upsert; natural-key FK remap (R5); `yath db sync` + `import` commands.
- **Schema** (§4–6): runs/jobs/job_tries/artifacts + users/projects/test_files/
  hosts (**no transitions table**, R6); per-engine UUID storage (native pg/mariadb; binary
  mysql/percona; blob sqlite; lowercase `run`+`job` string mirror); derived single
  `job_try_uuid` (§3.1, v7-preserving); artifacts = blob source-of-truth + host-local
  `local_path`.
- **Renderers/options** (§ renderer + Getopt::Yath): the jsonl log becomes a **renderer**
  (converted from the current logger), not a command-level concept; renderers/plugins/etc.
  **auto-contribute options** via `mod_adds_options` (pre_ai_2.0 model). Note the old
  inline `Renderer::Base` `logger` sink is removed.
- **Deferred to separate specs/efforts** (note in ARCH so they're tracked): the **webapp
  UX migration** (§9) and the **junit renderer** (§10c).
- *(Numbering/anchors finalized at merge time; §2.4/§4.6 are the current DB anchors.)*

## B. Proposed `TODO_STEPS.md` / `TODO_TASKS.md` changes (running list)

- **Supersede Chunk 8b ("QuickORM conversion").** Replace its one-line scope with a
  chunk set for the from-scratch rewrite:
  - **Chunk DB-1** — move old DB/web layer to `reference/old_db` (`git mv`); command
    stubs error; tests `SKIP_ALL` (§1).
  - **Chunk DB-2** — new schema, PostgreSQL-first (decision 4/5/6).
  - **Chunk DB-3** — port schema to SQLite/MySQL/MariaDB/Percona (decision 3 storage).
  - **Chunk DB-Jsonl** — convert the current logger → jsonl **renderer** + renderer-owned
    options (decision 10 a/b). **Lands before DB-4** — frees the "logger" concept for the
    new DB logger.
  - **Chunk DB-4** — transition-listener / DB **logger** process, SQLite-first
    (decision 7).
  - **Chunk DB-5** — DB→DB sync + `import` command (decision 8).
  - ~~Chunk — webapp port~~ → **DEFERRED to a separate future UX-migration spec**
    (decision 9); not part of this effort. Webapp stays broken; `server` command stubbed.
  - ~~Chunk — junit renderer~~ → **its OWN separate effort** (decision 10c); not part of
    this effort.
  - *(Final chunk numbering chosen at merge time to fit the existing sequence.)*
- **Dependency tasks (R11) — DB layer OPTIONAL:** DB-1 removes the `DBIx::Class*` hard
  prereqs (`dist.ini:123-130`) + **demotes `DBD::SQLite` from Requires** to Suggests; DB-2
  adds `DBIx::QuickORM` + `DBIx::QuickDB` to **RuntimeRecommends/Suggests** (never Requires),
  keeps `DBD::Pg`/`DBD::mysql`/`DBD::MariaDB` in Suggests. Every DB entry point
  runtime-`require`s its modules with an actionable "install X" error; nothing
  always-loaded `use`s a DB module at compile time. Core `yath test` (no logging) installs
  + runs with zero DB modules.
- New TODO_TASKS tickets per chunk — numbers assigned at merge time. Ticket stubs so far:
  - **Ticket (artifact download controller)** — `GET /artifact/<uuid>.<ext>`: strip ext,
    fetch by uuid, verify ext matches the stored filename ext, stream `data` with
    `Content-Type` (from ext) + `Content-Disposition` (stored filename). **Deferred to the
    future UX-migration spec** with the rest of the webapp (d9); self-contained when built.
    (§5)
  - **Ticket (import binary-extraction)** — importer splits embedded binary facets into
    binary artifact rows and rewrites the source event's facet to reference the new
    `artifact_uuid` (binary bytes removed from the stream, event retained). Part of chunk
    DB-4. (§5)
  - **Ticket (artifact identity derivation)** — deterministic `artifact_uuid`:
    events=derive(`collector_uuid`, 0), binary=derive(`collector_uuid`, `index≥1`),
    **v7-preserving §3.1** (not v8); two independent imports of a run produce identical
    artifact UUIDs + identical facet-rewrites (test it). Gates DB-4. (R2/R4)
  - **Ticket (derived-UUID function)** — one centralized, well-tested
    `derive(base, offset)` per **§3.1** (`(rand_b + offset) mod 2^62`, v7-preserving);
    used for `job_try_uuid = derive(job_uuid, try_ord)` and
    `artifact_uuid = derive(collector_uuid, idx)`. Tests: wrap at `rand_b` max, no
    self-collision for offset≥1, two independent imports identical. Part of chunk DB-4.
    (§3.1)
  - **Ticket (producer 1-based try ordinals)** — change the backend so `try_ord`/`is_try`
    starts at **1, never 0** (R10): `Job.pm` init + retry increment, `job_dir` naming
    (`Job.pm:508`), `is_try == 0` checks, wire `try`, POD. Audit all `is_try` uses; tests
    for first try / first retry. Backend change. (R10/§6c)
  - **Ticket (OPTIONAL — try-uuid start-stamp)** — overwrite the derived `job_try_uuid`'s
    high-48-bit timestamp with the try's start time (first collector transition `stamp`)
    for time-sortability; only if cheap, and only if the Monitor initial-snapshot
    preserves original stamps (verify). Nice-to-have, not required. (§6c)
  - **Ticket (runner defers workdir cleanup)** — the persistent runner must wait for all
    subscribers to disconnect before shutdown + workdir cleanup (loggers disconnect once
    imports finish). Verify current behavior; likely new. Part of chunk DB-4. (§7e)
  - **Ticket (workdir-vanished-early detection)** — logger/command detects the workdir
    disappeared before import completed (runner crash / force-kill) and reports a terminal
    error marking the log incomplete/possibly corrupt. (§7e)
  - **Ticket (`yath db sync` command)** — from-scratch QuickORM sync: per-run uuid-upsert,
    run_delta gap-fill, natural-key FK remap (R5), blob copied / local_path skipped, and the
    **`submitted_by` attribution flag** (`--as-user`/`--override-user`: carry-original vs
    override; R7). Chunk DB-5. (§8)
  - **Ticket (`import` command)** — import the single run in a sqlite log file into another
    DB, auto-selecting the only run; convenience wrapper over the sync engine; supports the
    same `submitted_by` attribution flag (R7). Chunk DB-5. (§8)
  - **Ticket (sampler emits load into its events stream)** — the sampler additionally
    emits each `system_load` snapshot into its own collector events stream so it rides into
    `sampler-events.jsonl.zst` (a blob); small `Service::Sampler` change. (R6 (b))
  - **Ticket (logger folds transitions → run/job/job_try rows)** — the logger upserts the
    summary rows from the Monitor's folded state (snapshot-seeded), NOT a transitions table.
    Chunk DB-4. (R6)
- *(Refined as decisions resolve.)*

## C. References (porting sources)

- Target schema template: `reference/dbix_quickorm/share/schema/*.sql`,
  `reference/dbix_quickorm/lib/Test2/Harness2/Schema.pm`.
- Old layer (post-move): `reference/old_db/…` — behaviour to port for the webapp.
- Sync prior art: `reference/old_db/lib/App/Yath2/Schema/Sync.pm`,
  `reference/old_db/lib/App/Yath2/Command/db/sync.pm`.
- jsonl-renderer / renderer-options / junit prior art: `reference/old3/` renderers,
  `reference/pre_ai_2.0/` (junit cross-check).
