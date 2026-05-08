# Yath DB Rebuild — Plan and Spec

## 1. Goal

Replace the existing `App::Yath2::DB::Internal*` tree with a clean
two-layer architecture:

- A backend-agnostic data-access class (`App::Yath2::DB`) that owns
  every transformation, codec, reconstruction, and archive-shaped
  read/write operation.
- Per-strategy backends (`App::Yath2::DB::SQL`, `App::Yath2::DB::DBIC`)
  that expose only row-level primitives (find rows, fetch payload,
  insert/update rows). Backends hold flavor branches when needed but
  never own transformation logic.

Adopt `App::Yath2::Role::Log` as the formal contract for all Log
backends (`Live`, `Directory`, `TarZIdx`, `DB`).

Final merge commit must have a clean tree, full t/ suite green, and
no references to `App::Yath2::DB::Internal*`. Intermediate commits are
allowed to break tests and commands provided each commit is
self-coherent and the breakage is called out in the message.

## 2. Why

The current code emerged from a port of `reference/old2/`. The split
between `App::Yath2::DB::Internal` (raw SQL + transformations + codecs
+ insert orchestration) and `App::Yath2::DB::DBIC` (which delegates
~7 methods back to a lazy Internal helper bound to its own dbh) was
pragmatic but architecturally wrong:

- DBIC cannot stand alone — pulling out Internal breaks every Group-A
  read/write surface that delegates to it.
- Codec logic (UUID round-trip, JSON column shape, datetime parsing,
  bytea bind) is duplicated across per-flavor `Internal::*` subclasses
  and inaccessible to DBIC except through delegation.
- Reconstruction logic (spec/report jsonl from typed columns, meta.json
  from archives row + meta_extras) is glued to Internal's SQL helpers
  rather than living above the row layer.
- Adding a new backend (e.g. a remote-protocol future backend) means
  re-implementing every transformation again.
- The `App::Yath2::Log::Artifact` handle calls a private `_artifact_*`
  family back into its log; only Internal implements that family. DBIC
  works around it by handing the Artifact a borrowed Internal helper.

Rebuilding around `App::Yath2::DB` as the single transformation layer
fixes all of these in one shape change.

## 3. Target Architecture

### 3.1 Module map

```
App::Yath2::Role::Log                  -- Log API contract (NEW)
App::Yath2::Log                        -- dispatcher (existing)
App::Yath2::Log::Live                  -- consumes Role::Log
App::Yath2::Log::Directory             -- consumes Role::Log
App::Yath2::Log::TarZIdx               -- consumes Role::Log
App::Yath2::Log::DB                    -- consumes Role::Log; thin
                                          (db, uuid)

App::Yath2::DB                         -- backend-agnostic data access
                                          + transformations + codecs

App::Yath2::Role::DB::Backend          -- primitive contract
App::Yath2::DB::SQL                    -- single class, flavor-aware
                                          methods; replaces ::Internal*
App::Yath2::DB::DBIC                   -- single class; uses
                                          DBIx::Class storage
App::Yath2::DB::DBIC::Schema           -- unchanged
App::Yath2::DB::DBIC::Result::*        -- unchanged

App::Yath2::Log::Artifact              -- still file-shaped; delegates
                                          to its log via Role::Log
                                          read/write contract (no
                                          private _artifact_* family
                                          on Log::DB)
```

Removed at end: `App::Yath2::DB::Internal*` (every file under that
namespace).

### 3.2 Responsibilities

**`App::Yath2::Role::Log`** — public Log surface. Required methods:

```
# Listing
services runs jobs tries last_try
has_service has_run has_job has_try
list_files

# Iteration
event events end_of_events EOE reset
events_iter spec_iter report_iter   (provided via artifacts())

# File access (Artifact-backed)
artifacts                            (factory)

# Format / IO
extract archive insert
absolute_path                        (croaks on archive-only backends)

# Status
is_live static
```

Provides a small set of helpers shared across all consumers
(`_artifacts_root`, base path validation, attachment listing reduce).
The exact provide-vs-require split is settled during Phase 1.

**`App::Yath2::Log::DB`** — consumes `Role::Log`. Owns:

- `db` — `App::Yath2::DB` instance.
- `uuid` — archive UUID this Log targets.

Every Role::Log method is one or two lines that delegate to
`$self->db` with the cached `archive_id` resolved from `uuid`. No
SQL, no codecs, no reconstruction. Mirror of how
`App::Yath2::Log::Directory` is "thin wrapper over a path".

**`App::Yath2::DB`** — backend-agnostic data layer. Owns:

- DSN/dbh/file/backend selection (`new` factory).
- All codecs: UUID canonical-hex ↔ DB-native, JSON shape, datetime
  parsing/formatting, payload encoding, zstd compress/decompress.
- All transformations: typed-row → spec.jsonl bytes, typed-row →
  report.jsonl bytes, archives row + meta_extras → meta.json record.
- Archive-shaped methods: `archives`, `archive_count`, `has_archive`,
  `runs($archive)`, `jobs($archive, $run)`, `services($archive,
  ...)`, `artifacts($archive, ...)`, `event(...)`, `events(...)`,
  `extract(...)`, `archive(...)`, `insert(...)`, `list_files(...)`,
  etc.
- Helpers used by `Log::DB`: returns rows, bytes, paths, iterators in
  the shapes the Log API expects.

Explicitly does not own:
- Direct SQL.
- DBI handle pool management beyond storing one dbh.
- Per-flavor type binding.

**`App::Yath2::Role::DB::Backend`** — backend primitive contract.
Required methods (final list refined during Phase 2; initial sketch):

```
# Connection / introspection
dbh flavor

# Bootstrap
bootstrap_schema schema_file _is_bootstrapped
preprocess_schema_sql _should_skip_schema_statement

# Archive layer
archive_rows                      -> [{archive_id, archive_uuid (canonical hex),
                                       archive_version, sealed_at, host, user,
                                       git_sha, project, yath_version,
                                       meta_extras (decoded hash)}, ...]
archive_create($meta)             -> $archive_id
archive_for_uuid($uuid)           -> row or undef
archive_count                     -> integer

# Run / job / service / try layers (all archive-scoped)
run_rows($aid)                    -> [{run_id, run_ord, run_uuid, status,
                                       aborted, timed_out, project_id}, ...]
service_rows($aid, %filter)       -> [{service_id, name, run_id (or undef)}, ...]
job_rows($aid, $run_id)           -> [{job_id, job_ord, test_file_id}, ...]
try_rows($job_id)                 -> [{job_try_id, try_ord, ...}, ...]

# Existence checks (each backend short-circuits on COUNT)
run_exists($aid, $run_ord)        -> 0/1
job_exists($aid, $run_id, $job_ord)  -> 0/1
try_exists($job_id, $try_ord)     -> 0/1
service_exists($aid, $name, $run_id?) -> 0/1

# Lookup helpers (return DB ids)
run_id_for_ord($aid, $run_ord)
job_id_for_ord($aid, $run_id, $job_ord)
try_id_for_ord($job_id, $try_ord)
service_id_for_name($aid, $name, $run_id?)

# Find-or-create (writes; mint UUIDs at this layer with backend-specific bind)
ensure_run_row($aid, $run_ord, $project_id)
ensure_service_row($aid, $name, $run_id?)
ensure_job_row($aid, $run_id, $job_ord, $test_file_id)
ensure_job_try_row($job_id, $try_ord)
ensure_test_file_row($project_id, $relative)
ensure_project_row($name)

# Artifact rows
artifact_rows_for_archive($aid, %opts)
                                  -> [{artifact_id, scope FKs,
                                       artifact_kind, format, name,
                                       compressed, joined run_ord/
                                       service_name/job_ord/try_ord/
                                       j_run_ord/s_run_ord, optional payload}]
artifact_row_for_scope($aid, $scope_kind, $scope_id, $kind, $name?)
                                  -> row or undef
artifact_payload($artifact_id)    -> bytes (decoded; zstd still applied
                                    when compressed)
artifact_create(%row)             -> $artifact_id
artifact_update($artifact_id, %row)

# Spec/report data layer (backing for reconstruction)
job_spec_rows($job_id, $try_ord?)
service_lifetime_rows($service_id)
subtest_rows($job_try_id)

# Sealing
mark_sealed($archive_id, $when)
```

Each row hashref returned is canonical: UUIDs are 36-char hex strings,
JSON columns are decoded Perl hashes, datetime columns are
`DateTime` objects (or ISO-8601 strings if simpler), payloads are raw
bytes (zstd-encoded if `compressed=1`). Backends translate to/from
flavor-native shapes on bind and fetch.

**`App::Yath2::DB::SQL`** — single class. Implements the backend role
via `$self->dbh` and raw `selectrow_*` / `prepare` / `execute` calls.
Flavor branches inside individual methods where necessary (e.g.
`archive_create` UUID bind, MySQL `BIN_TO_UUID` triggers, Postgres
bytea, MariaDB-vs-MySQL detection via `SELECT VERSION()`). Stays
small — most methods are 5–20 lines; flavor branches are isolated
guards inside one method, not separate per-flavor subclasses.

**`App::Yath2::DB::DBIC`** — single class. Implements the same
backend role using `$schema->resultset(...)` everywhere. Same row
shape on output. Postgres bytea, JSON inflate, datetime inflate are
handled by Result class column_info; this class never has to touch
the codec directly.

### 3.3 Codec contract

Every backend method exchanges canonical Perl values with
`App::Yath2::DB`:

| Concept    | Canonical form                          | Backend job                      |
|------------|------------------------------------------|----------------------------------|
| UUID       | 36-char lowercase hex (e.g. `aaaa-...`)  | encode/decode for flavor binding |
| JSON cols  | decoded Perl hashref / arrayref          | encode/decode (text vs JSONB)    |
| datetimes  | ISO-8601 UTC string                      | format/parse per flavor          |
| payloads   | raw bytes (zstd-encoded if compressed=1) | bytea / blob bind                |
| booleans   | 0 / 1                                    | flavor-native bool bind          |

Backends never accept or return packed UUID bytes, native JSON
strings, or DateTime objects. `App::Yath2::DB` handles all
packing/unpacking before/after the backend call.

This is the single biggest semantic shift from `App::Yath2::DB::Internal`
where each flavor subclass owned codec + SQL together. Splitting them
makes both backends symmetric and lets `App::Yath2::DB` write
flavor-agnostic code against `Role::DB::Backend`.

### 3.4 App::Yath2::Log::Artifact private interface

The Artifact handle currently calls `_artifact_exists / _artifact_read
/ _artifact_save / _artifact_iter_records / _artifact_list_dir /
_artifact_open_fh / _decompress_jsonl_bytes / absolute_path` on its
`{log}` reference. Under the new design those methods are part of
`Role::Log` (provided by all Log subtypes); `Log::DB` implements them
by delegating to `App::Yath2::DB` with `archive_id = self->archive_id`.

No more borrowing an Internal helper. No more BEGIN-block forwarder
in DBIC.

## 4. Public APIs (frozen during this rebuild)

### 4.1 `App::Yath2::Log->new` shapes

Unchanged from current. Keeps `live / dir / file / dbh / dsn / auto`
plus `backend => 'sql' | 'dbic'` for SQLite-file shorthand. `internal`
backend value renamed to `sql`; accept `internal` as a deprecated alias
that warns once during the rebuild and is removed before merge.

### 4.2 `App::Yath2::DB->new` shapes

```
my $db = App::Yath2::DB->new(file => $path,    backend => 'sql' | 'dbic');
my $db = App::Yath2::DB->new(dsn  => $dsn, ..., backend => ...);
my $db = App::Yath2::DB->new(dbh  => $dbh,    backend => ...);
my $db = App::Yath2::DB->new(schema => $dbic_schema);  # implies dbic
```

Returns a doer of `App::Yath2::DB` (NOT a backend instance — the
backend is encapsulated behind `$db->backend`). Multi-archive capable.

### 4.3 `App::Yath2::Log::DB->new`

```
my $log = App::Yath2::Log::DB->new(db => $db, uuid => $uuid);
```

`db` is required; `uuid` is required (fail loudly if absent — single-
archive shorthand goes through `App::Yath2::Log->new(file=>)` which
picks the singleton uuid).

### 4.4 Archive-shaped methods on `App::Yath2::DB`

```
$db->archives                              # list of canonical UUIDs
$db->archive_count
$db->has_archive($uuid)
$db->meta($uuid)                           # decoded meta record
$db->runs($uuid)
$db->services($uuid, $run_ord?)
$db->jobs($uuid, $run_ord)
$db->tries($uuid, $run_ord, $job_ord)
$db->last_try($uuid, $run_ord, $job_ord)
$db->has_run / has_job / has_try / has_service ($uuid, ...)
$db->list_files($uuid)
$db->artifact($uuid, $scope_kind, $scope_id, $kind, $name?)
                                           # returns row hashref or undef
$db->artifact_bytes($uuid, $rel)           # decoded bytes, or
                                           # reconstructed for spec/report
$db->save_artifact($uuid, %opts)           # write
$db->event($uuid, $timeout?)               # walker
$db->reset($uuid)
$db->extract($uuid, $dir, %opts)
$db->archive_to($uuid, $out_path, %opts)
$db->insert($source_log, %opts)            # creates archive row, returns uuid
```

Argument shapes mirror current `Log::DB` so callers translate trivially.

## 5. Migration Strategy

In-place rewrite on the existing `yath-db-schema` branch. Tests and
commands are allowed to break between intermediate commits. The merge
commit must:
- Have full t/ suite green.
- Build a working `yath` CLI end-to-end (extract / archive / replay /
  inspect / qdb / test).
- Carry no references to `App::Yath2::DB::Internal*` anywhere.

Each phase produces a self-contained commit (or short series). Each
commit message must call out: phase number, what's in this commit,
and which tests/commands are temporarily broken (with the broken set
expected to shrink to zero by the merge commit).

Tests are not deleted as we go. Per-flavor tests under
`t/AI/unit/Log/DB/{Sqlite,MySQL,Postgres,MariaDB}/` are repointed to
the new shape during the relevant phase, not removed.

Phase 0 sets up the skeleton; phases 1–9 fill it in; phase 10 deletes
Internal.pm; phase 11 closes the docs and merges.

## 6. Phase Plan

### Phase 0 — Skeleton

- Create `lib/App/Yath2/Role/Log.pm` with the required-method list
  (no provided methods yet).
- Create `lib/App/Yath2/DB.pm` (replace current minimal factory). Stub
  methods that will be filled in by later phases. Keep current factory
  shape so existing callers still load.
- Create `lib/App/Yath2/DB/SQL.pm`, `lib/App/Yath2/DB/DBIC.pm`. Empty
  Role::DB::Backend doers; all required methods stubbed to croak.
- Move existing `App::Yath2::DB::DBIC.pm` contents aside as
  `App::Yath2::DB::DBIC.pm.OLD` reference (gitignored copy). Same for
  Internal.pm. (Both will be deleted in Phase 10.)
- Update `App::Yath2::Role::DB::Backend` requires-list to the new
  primitive contract.

State after Phase 0: tree compiles. No tests pass. Git tree has both
old + new namespaces.

### Phase 1 — Role::Log

- Define required methods on `App::Yath2::Role::Log`.
- Make `App::Yath2::Log::Directory`, `App::Yath2::Log::TarZIdx`,
  `App::Yath2::Log::Live` consume the role. Patch any missing methods
  (most are already present).
- Add `t/AI/unit/Log/role.t` asserting role consumption + required
  method coverage on every consumer.

State: Directory/TarZIdx/Live tests pass. DB tests still red.

### Phase 2 — Role::DB::Backend primitives, both backends

Implement read primitives on `App::Yath2::DB::SQL` and
`App::Yath2::DB::DBIC` simultaneously (each method dual-implemented
in the same commit so the parametric test pass works):

- `archive_rows`, `archive_for_uuid`, `archive_count`.
- `run_rows`, `service_rows`, `job_rows`, `try_rows`.
- Existence checks.
- Lookup helpers (id-for-ord).
- `artifact_rows_for_archive`, `artifact_row_for_scope`,
  `artifact_payload`.
- `job_spec_rows`, `service_lifetime_rows`, `subtest_rows`.

Add `t/AI/unit/DB/Backend/read_primitives.t` parametric over both
backends, using a fixture sqlite archive built once per subtest.

State: read primitives green on both backends. Higher-level methods
still red.

### Phase 3 — App::Yath2::DB read paths

Implement on `App::Yath2::DB`:

- Codec: `_uuid_canonicalize`, `_uuid_to_db`, `_uuid_from_db` (via
  backend-supplied bind helpers — see §3.3), JSON encode/decode,
  datetime parse/format, payload zstd handling.
- `archives`, `archive_count`, `has_archive`, `meta`.
- `runs`, `services`, `jobs`, `tries`, `last_try`, `has_*`.
- `list_files` (uses `artifact_rows_for_archive`).
- `artifact` (single-row lookup).
- `artifact_bytes` including reconstruction:
  - spec.jsonl from `job_spec_rows` joined into a single jsonl stream.
  - report.jsonl similar.
  - state.jsonl (if applicable).
  - meta.json from `archive_for_uuid` row + decoded `meta_extras`.

Add `t/AI/unit/DB/read.t` parametric, asserting cross-backend parity
on every method.

State: read API green. Write API still stubbed.

### Phase 4 — App::Yath2::Log::DB rewrite

Replace `lib/App/Yath2/Log/DB.pm` body. New shape (~80 LoC):

- `init` validates `db` + `uuid` + caches `archive_id`.
- Each Role::Log method is a one-liner delegating to `$self->db->$m($self->{uuid}, ...)`.
- The private `_artifact_*` family used by `App::Yath2::Log::Artifact`
  becomes part of `Role::Log` (provided defaults that delegate to
  `$self->db->...` for `Log::DB`; trivial filesystem implementations
  for `Directory`/`Live`; archive-index implementations for `TarZIdx`).

Reroute `App::Yath2::Log->new(file=>)` to `App::Yath2::DB->new(file=>)` +
`App::Yath2::Log::DB->new(db=>$db, uuid=>$picked)` exactly as today,
just against the new types.

Repoint per-flavor `t/AI/unit/Log/DB/*/listing.t`,
`t/AI/unit/Log/DB/*/archive_version.t`, etc. to the new constructor
shape. Tests still using `for_each_log_db_backend` carry over with
the updated backend names (`sql` / `dbic`).

State: full READ side green across all flavors and both backends.
Write API (Phases 5-7) still stubbed.

### Phase 5 — Backend write primitives

Add to both backends:
- `archive_create`, `mark_sealed`.
- `ensure_run_row`, `ensure_service_row`, `ensure_job_row`,
  `ensure_job_try_row`, `ensure_test_file_row`, `ensure_project_row`.
- `artifact_create`, `artifact_update`.
- Insert-side spec/report row writers (`job_spec_create`,
  `service_lifetime_create`, `subtest_create`).

State: backend write primitives covered by parametric tests; upper
write API still stubbed.

### Phase 6 — App::Yath2::DB write paths

- `save_artifact` (used by `Log::DB`'s save).
- `extract` (artifact iteration + payload write + meta.json write).
- `archive_to` (formats: tar.zidx via extract+repack; sqlite via
  a fresh ::SQL backend + insert).
- `insert` — the heaviest. Steps in order:
  - Resolve meta from source.
  - Pre-flight uniqueness check on archive_uuid.
  - Open transaction.
  - `archive_create`.
  - Walk source `list_files`:
    - parse path → scope.
    - resolve project / test_file / run / job / try as needed.
    - `artifact_create`.
  - Populate summary rows: `service_lifetime` from spec/report walks,
    `subtest` from spec/report, `job_spec` from spec, `service`
    list, `job` list.
  - Commit (or rollback + propagate exception).

State: full write API green. End-to-end archive→DB→archive round-trip
parity across both backends.

### Phase 7 — Event walker + iterators

- `event($uuid, $timeout)` / `events($uuid)` / `EOE` / `reset`.
- Depth-first walker over artifact rows plus events.jsonl payload
  decode. Lives entirely on `App::Yath2::DB` (uses backend's
  `artifact_payload` + `artifact_rows_for_archive(scoped)` primitives).

Add cross-backend parity test for the walker.

State: every Role::Log method on `App::Yath2::Log::DB` is implemented
end-to-end. All 225 historical tests should pass against the new
backends if their assertions held public-API contracts.

### Phase 8 — Cross-backend parity sweep

- Run full t/ under each backend.
- Triage failures. Most should be either (a) test calling a removed
  helper; (b) test asserting a specific bytes representation that
  changed; (c) genuine regression.
- Fix and re-run until 225/225 PASSED across all backends and all
  flavors.

State: green.

### Phase 9 — Internal removal

- Delete `lib/App/Yath2/DB/Internal.pm`, `lib/App/Yath2/DB/Internal/*`.
- Delete the BEGIN-block delegation forwarder in DBIC (already gone
  if Phases 4–7 retired it; otherwise drop now).
- Delete `t/AI/unit/DB/Internal/` (or rename remaining live tests
  under `t/AI/unit/DB/SQL/` if they're worth keeping).
- Run full t/ once more.

State: tree contains zero `App::Yath2::DB::Internal*` references.

### Phase 10 — Docs

Update `ARCHITECTURE.md`:

- §16 (Module map) — replace `App::Yath2::DB::Internal*` block with
  the new `App::Yath2::DB` / `App::Yath2::DB::SQL` / `App::Yath2::DB::DBIC`
  block.
- §17 (On-disk layout) — unchanged.
- §18 (Utilities) — note that `App::Yath2::Role::Log` now formalizes
  the Log API.
- §19 (External deps) — confirm `DBIx::Class` remains optional;
  `App::Yath2::DB::DBIC` requires it, `App::Yath2::DB::SQL` does not.
- §20 (Coding conventions) — add: codec lives at the data layer
  (`App::Yath2::DB`), backends speak canonical Perl values.
- Add a new top-level section "Architecture revision: DB rebuild"
  pointing at this AI_DOC for the full rationale.

Update `share/schema/SCHEMA.md` (if needed) — should not be needed;
schema is unchanged.

Delete or supersede `AI_DOCS/2026-05-08-yath-db-namespace.md` (the
prior namespace-split doc) — its decisions are absorbed into the new
shape. Add a one-line note in that file pointing at this rebuild plan.

Update `CLAUDE.md` if any new project rules emerged during the
rebuild (don't anticipate any).

Final commit: "DB rebuild merge" with the full diff against the
pre-rebuild baseline summarized.

## 7. Test Strategy

- `for_each_log_db_backend` extended to iterate `('sql', 'dbic')`
  instead of `('internal', 'dbic')`.
- Every Role::Log consumer gets a `t/AI/unit/Log/<Backend>/role.t`
  asserting role consumption + required-method coverage.
- Every `App::Yath2::DB` method gets a parametric cross-backend test
  asserting identical output on both backends for the same fixture
  archive.
- Per-flavor tests stay (Sqlite / MySQL / Postgres / MariaDB) and run
  under both backends via the existing helper.
- Author-only tests (`AUTHOR_TESTING=1`) still gate slow / flaky
  things; no change to that gate.
- New file: `t/AI/unit/DB/codec.t` covering UUID / datetime / JSON /
  payload round-trip across the four flavors via SQL backend (DBIC's
  codec is structurally identical because Result classes own it).

Acceptance criterion at merge: `AUTHOR_TESTING=1 yath -D test -j16 t/`
exits 0 with 225+ passing files (count grows as new tests land).

## 8. Salvage / Discard

### Salvage

| Item | Disposition |
|------|-------------|
| `App::Yath2::Role::DB::Backend.pm` | Replace required-method list; keep `bootstrap_schema`, `schema_file`, `_should_skip_schema_statement`, `_is_bootstrapped`, `preprocess_schema_sql` as provided defaults. |
| `_decompress_jsonl_bytes`, `_scope_where_clause`, `_scope_fk_values`, `_format_for_name`, `absolute_path` | Move from role to `App::Yath2::DB` (their natural home is the data layer, not the backend role). |
| `list_files` orchestration | Move from role to `App::Yath2::DB`. |
| `artifacts()` / `_artifacts_root` / `_make_artifact` / `_artifacts_from_args` | Move from role to `App::Yath2::DB`. |
| `App::Yath2::DB::DBIC::Schema` + `Result/*` | Unchanged. |
| `share/schema/*.sql` | Unchanged. |
| `App::Yath2::DB::internal_class_for_flavor` | Repurpose as `sql_class_for_flavor` if the SQL backend ends up needing per-flavor sub-modules; otherwise delete. |
| `for_each_log_db_backend` test helper | Update backend list; otherwise unchanged. |

### Salvage from Internal.pm specifically

These transformations are correct and worth porting body-for-body:

- `_decompress_jsonl_bytes` — already on role.
- `_artifact_read_reconstructed` — moves to `App::Yath2::DB`.
- `_reconstruct_meta_record` — moves to `App::Yath2::DB`.
- `_read_first_jsonl_row` / `_read_all_jsonl_rows` — move to
  `App::Yath2::DB`.
- The depth-first event walker (`event` + `_walk` state) — moves to
  `App::Yath2::DB`.
- `_resolve_archive` (uuid → archive_id, with version check) — moves
  to `App::Yath2::DB`; `_check_archive_version` moves with it.
- Schema bootstrap order quirks (MariaDB trigger skip, Postgres
  COMPRESSION strip) — already on role + per-flavor branches.

### Discard

- `App::Yath2::DB::Internal.pm` (whole file).
- `App::Yath2::DB::Internal/Sqlite.pm`, `Postgres.pm`, `MariaDB.pm`,
  `MySQL.pm` (whole files).
- Per-method delegation in `App::Yath2::DB::DBIC` (BEGIN-block
  forwarder + `_internal` lazy helper).
- `App::Yath2::DB::DBIC._internal_for_artifact` shim added in this
  branch.
- `_uuid_to_db` / `_uuid_from_db` per-flavor methods on Internal —
  recreated as canonical-codec helpers on `App::Yath2::DB`, with
  per-flavor bind primitives on `App::Yath2::DB::SQL`.
- `_param_type_for_col`, `_bind_payload`, `_payload_to_bytes`,
  `_payload_from_bytes` on Internal subclasses — replaced by
  backend bind primitives that the SQL backend uses internally;
  never visible to `App::Yath2::DB`.

## 9. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| MySQL `BINARY(16)` UUID round-trip regresses (subtle: bind type, UTF-8 mangling). | Codec on `App::Yath2::DB` always passes canonical hex; SQL backend's flavor-specific `archive_create` / `_bind_uuid` carry the exact `bind_param(..., DBI::SQL_BINARY())` pattern from current Internal::MySQL. Cross-backend parity test exercises this. |
| Postgres bytea bind regresses payloads. | DBIC: handled by Result `data_type => 'blob'`. SQL: identical bind logic to Internal::Postgres carried into the SQL backend's bytea branch. Test: round-trip a 1MB random payload. |
| MariaDB-vs-MySQL detection breaks (driver returns same `Driver{Name}`). | `_server_is_mariadb` helper carried into the SQL backend; called once and cached. DBIC's `flavor_override` plumbing carried through `App::Yath2::DB->new`. |
| Spec/report reconstruction byte-equivalence drifts. | Reconstruction has a precise contract today (per `AI_DOCS/2026-05-07-schema-redesign.md §D9`). Test cross-checks the reconstructed bytes against a Directory-shaped archive of the same logical content. |
| Insert path's transactional rollback regresses. | Insert wrapped in `eval` exactly as today; rollback path tested in `insert_atomic.t` (kept for both backends). |
| Test churn obscures real regressions. | Don't delete tests as you go. Each phase's commit message lists the broken-test set; the set must monotonically shrink phase over phase. |
| App::Yath2::UI / App::Yath2::Command::* break during phases. | Acceptable per the user's explicit OK. Final merge commit re-runs `yath -D test`, `yath -D extract`, `yath -D archive`, `yath -D replay`, `yath -D inspect`, `yath -D qdb` end-to-end against fixture archives. |
| MariaDB CI host runs old version that lacks BIN_TO_UUID. | Already handled by `_should_skip_schema_statement` returning 1 on MariaDB; carries through. |
| Preserved `flavor_override` path for DBD::MariaDB. | `App::Yath2::DB->new(flavor => 'mysql')` still accepted; passed through to backend. Test exists. |

## 10. ARCHITECTURE.md updates required at completion

Sections to revise:

- **§16 Module map** — replace the `App::Yath2::DB::Internal*` block
  with:
  ```
  App::Yath2::DB                       data access + transformations
  App::Yath2::Role::DB::Backend        backend primitive contract
  App::Yath2::DB::SQL                  raw-DBI backend (single class,
                                        flavor-aware methods)
  App::Yath2::DB::DBIC                 DBIx::Class backend
  App::Yath2::DB::DBIC::Schema         DBIC schema
  App::Yath2::DB::DBIC::Result::*      result classes
  App::Yath2::Role::Log                Log API role
  App::Yath2::Log                      dispatcher (unchanged)
  App::Yath2::Log::{Live,Directory,    Log::Role consumers
    TarZIdx,DB}
  App::Yath2::Log::Artifact            file-shaped handle (unchanged
                                        public surface)
  ```

- **§16 dependency notes** — `Test2::Harness2` still must not load
  `App::Yath2::*` directly; rule unchanged. `App::Yath2::DB::DBIC`'s
  dependency on `DBIx::Class` is optional; `App::Yath2::DB::SQL`'s
  `DBI` dependency is required.

- **§17 On-disk layout** — unchanged.

- **§18 Utilities** — add a paragraph: codec helpers
  (`_uuid_*`, `_decompress_jsonl_bytes`, `_format_for_name`, etc.) live
  on `App::Yath2::DB`; backends speak canonical Perl values.

- **§19 External deps** — confirm: `DBI` required (always), `DBD::*`
  per flavor (lazy loaded), `DBIx::Class` optional (lazy loaded by
  `App::Yath2::DB::DBIC`), `Compress::Zstd` required.

- **§20 Coding conventions** — add: "Backends own SQL or ResultSet
  calls. Codecs and transformations live on App::Yath2::DB. Backends
  see canonical values only."

- **§14 Renderer contract** — unchanged.

- **§15 Preload-as-resource** — unchanged.

- **Top-level section: "Architecture revision: DB rebuild (2026-05)"**
  — short paragraph pointing at `AI_DOCS/2026-05-08-yath-db-rebuild.md`
  for the full rationale, with a one-line summary: "Codec and
  transformation logic moved out of per-flavor SQL subclasses into a
  single backend-agnostic data class. Backends are now skinny row-level
  primitives."

Sections that stay untouched: §1–§13 (process topology, IPC, collector
lifecycle, event framing, artifact routing, preload-as-resource, the
renderer contract). The DB rebuild is below the IPC waterline.

`AI_DOCS/2026-05-08-yath-db-namespace.md` (the prior namespace-split
doc) is superseded; add a stub at the top: "Superseded by
`AI_DOCS/2026-05-08-yath-db-rebuild.md`. Decisions in this doc are
historical."

`AI_DOCS/2026-05-07-schema-redesign.md` stays — it's the schema-level
contract that this rebuild operates on top of.

## 11. Done criteria

Merge commit must satisfy:

1. `AUTHOR_TESTING=1 yath -D test -j16 t/` passes.
2. `git grep 'App::Yath2::DB::Internal'` returns nothing.
3. `git grep 'BEGIN-block forwarder'` (or any artifact of the DBIC
   delegation pattern) returns nothing.
4. `App::Yath2::Role::Log` is consumed by `Log::Live`, `Log::Directory`,
   `Log::TarZIdx`, `Log::DB` (one assertion each).
5. `App::Yath2::Role::DB::Backend` is consumed by `App::Yath2::DB::SQL`
   and `App::Yath2::DB::DBIC` (one assertion each).
6. `yath` end-to-end smoke: `extract`, `archive`, `replay`, `inspect`
   all run against a fixture archive on both backends without
   exceptions.
7. ARCHITECTURE.md updated per §10 of this doc.
8. AI_DOCS prior namespace-split doc carries the supersession stub.

## 12. Out of scope

- Any change to `share/schema/*.sql` content (schema is the contract;
  rebuild is below it).
- Any change to `App::Yath2::DB::DBIC::Schema` or `Result/*` classes.
- Any change to IPC, collector, renderer, or harness layers.
- Any change to the `yath` CLI surface or `App::Yath2::Command::*`
  argument contracts (their internals may shift to follow the new
  data API; the CLI surface stays).
- A v3 backend (e.g. remote-protocol). The new shape makes one easy
  later, but isn't built here.
