# `new_log_refactor` branch — full summary

Date: 2026-05-07
Branch: `new_log_refactor` (merged into `2.0` at `e45acaa9b`)

Condensed roll-up of three sibling AI_DOCs:

- `2026-05-04-log-refactor.md` — collector pipeline + Log reader rewrite.
- `2026-05-07-schema-redesign.md` — DB schema overhaul across all four
  flavors.
- `2026-05-07-yath-footer.md` — YATHFOOT trailer for sealed `.yath` files.

Plus post-redesign followups not in any of those: `yath db` → `yath qdb`
rename, F26 timestamp normalization, multi-version DB-test discovery, and
the test-side fallout from those.

Read this first; the three sibling docs carry per-decision detail.

## Phase 1 — Collector pipeline + Log reader rewrite

### Trigger

Pre-rewrite: `LogArchive` reader had a baroque collector pipeline
(`Logger::JSONL` writer plugins, `Observer` chain, separate `TestObserver`
for IPC, `parent_io` machinery on every collector). Two bad assumptions:

1. Every collector might own state — so every collector had auditor /
   observer slots, IPC reflectors.
2. Reader assumed a coherent on-disk tree with one logger per collector
   and uniform paths.

Reality: tests *produce* state via events; runs and services *act on*
state in their own service process. Old design tried to put state-tracking
next to every collector. That forced `parent_io` for collectors with no
business tracking parent state and a `TestObserver` separate from the
test auditor purely because the auditor "didn't speak IPC".

### Rev-2 ownership rule (new ARCHITECTURE.md addendum)

- Tests produce state via events. Auditor reconstructs state next to the
  test-job collector. Auditor handles IPC.
- Runs and services act on state. State lives in the service process. The
  service emits its own state-transition events into its own outgoing
  events stream. The collector for those is a dumb pass-through.

### Decisions

- **Drop event UUIDs + identifier mirrors.** Events are identified by
  position on disk; the reader injects `harness.run_id` / `job_id` /
  `job_try` / `service_name` based on which file an event came from.
- **`LogArchive` → `Log`.** Old name implied "post-run sealed thing"; new
  name covers live workdirs, sealed dirs, tar.zidx, SQLite, and
  network-DB backends uniformly.
- **Single Collector class, no Logger / Observer plugins.** Type-driven
  behavior: `type => 'Job' | 'Run' | 'Service'` plus an `id`. Job
  collectors carry an `Auditor::Test` that absorbed `TestObserver`'s IPC
  duties. Run / Service collectors are dumb pass-through. Pipeline:
  `parser -> [Auditor::Test on Job] -> write_phase`.
- **`collector_start` / `collector_end` IPC** reflected into parent
  service's events stream as `harness_collector_start` /
  `harness_collector_end`. The depth-first reader iterator descends into
  child collectors on `_start` and pops on the matching `_end`.
- **Attachments at write phase.** `harness_attachment` facets carry
  base64 blobs; the collector decodes during write phase and stores
  under `<base>/attachments/<filename>`, replacing the in-event payload
  with a `path` reference.
- **Drop `collector_artifacts` IPC + `artifacts.json`.** With start/end
  facets reflected and a uniform on-disk layout, artifacts metadata is
  implicit — walk the directory.
- **Run / harness service emit own transitions.** `run_failing`,
  `run_completed` (with `collector_report` aggregating per-job
  pass/fail), and the analogous harness lifecycle transitions.
- **`logs/LIVE` sentinel.** Created at start, removed on clean shutdown.
  Reader uses presence to disambiguate live-workdir-expecting-more-bytes
  from sealed-workdir-clean-EOF. `extract` and `archive` skip it.
- **`Log` reader as dispatcher.** `Log->new(...)` picks backend by arg
  shape: `live => $dir` → `Log::Live`, `dir => $dir` → `Log::Directory`,
  `file => $f` → `Log::TarZIdx` or `Log::Sqlite` (auto-detected via
  magic), `dbh|dsn => ...` → `Log::Sqlite` or sibling DB backends.
- **Identical surface across all backends.** Listing
  (`services` / `runs` / `jobs` / `tries` / `last_try` / `has_*`),
  artifacts handle factory (`artifacts(...)` returns a `Log::Artifact`),
  depth-first event iterator (`event($timeout)` / `events()` / `EOE` /
  `reset`), path-aware identifier injection.
- **DB backends — SQLite, Postgres, MariaDB, MySQL.** `Log::DB` abstract
  base; per-flavor classes cover DSN, schema bootstrap from
  `share/schema/<flavor>.sql`, UUID/JSON codecs, payload bind hooks.
  Multi-archive is the universal model: every DB holds N archive rows;
  even a single-archive sqlite `.yath` is N=1.
- **Test command rewired.** `test` subscribes to harness IPC bus, spawns
  a renderer child that opens `Log->new(live => $dir)` and iterates
  events. `Streamer::Live` is gone. `replay`, `failed`, `archive`,
  `extract`, `times`, `speedtag` rewired likewise.
- **`yath inspect <path>`.** Detects log type, validates harness
  service, prints summary; `--json` for machine-readable. SQLite
  multi-archive: lists every archive row + per-archive run count.
- **`runs` / `exclude_runs` filters on extract / archive.** Per-run
  partial extracts. Globals (services-without-a-run-id, archive-root
  files) always included.
- **ord ints replace UUIDs for run/job ids.** UUIDs survive only as
  logical archive identifiers in DB rows. Run / job ids are sequential
  ord ints scoped to their archive.

## Phase 2 — DB schema redesign

### Trigger

Post-Phase-1 the schema still carried pre-rev-2 choices:

1. Two version columns of unclear distinction (`format_version` +
   `schema_version`).
2. BLOB duplication of spec / report bytes in entity rows AND in
   `artifacts.payload` rows. Two copies, no integrity guarantee.
3. No multi-archive aggregation surface — couldn't answer "every run of
   `t/foo.t` across these 50 archives" without parsing spec BLOBs.
4. `services` was single-row per service — restarts couldn't be
   represented.
5. `meta.json` lived as an `arbitrary` artifact row — no typed columns.
6. No transaction wrap on insert.
7. No protection against re-import.

### Decisions

- **D1. `service_lifetimes`.** Services restart. New child table holds
  per-restart spec/report data. `services` reduces to identity (`name`,
  `role`, `run_id`).
- **D2. `*_extras` JSON catch-alls.** Every entity table that previously
  stored full spec/report row JSON gains `spec_extras` and/or
  `state_extras` BLOB. Insert splits incoming row → typed cols + extras.
  Reconstruct merges (typed wins on collision). Aggregated children
  (`subtests`, run-level `jobs[]`) are NOT in extras — rebuilt via JOIN.
- **D3. No producer-side spec nesting.** `TestFile` slots flatten into
  the spec row root at write time. No `test_file => {...}` wrapper.
  Producer JSON keys match column names exactly; insert and reconstruct
  use schema-derived column lists, no rename map.
- **D4. `archive_version` single field.** Replaces `format_version` +
  `schema_version`. Carries `$App::Yath2::Log::VERSION` at write.
  `App::Yath2::Log->last_breaking_version` (initially `'2.000011'`,
  later raised to `'2.000012'` by Phase 3) is the read-time refusal
  floor. No auto-migration.
- **D5. `sealed_at`** = source archive's live→sealed timestamp
  (`meta.created_at`). Carried over on insert; not stamped at insert
  end.
- **D6. Atomic insert.** `DB->insert($source)` wraps in `begin_work` /
  `commit` / `rollback`. Pre-flight `archive_uuid` uniqueness check
  rejects re-imports with a clean
  `"archive already exists; not re-imported"` error before opening
  the transaction.
- **D7. Project + test_file breakout.** `projects(project_id, name
  UNIQUE)`. `runs.project_id` FK. `test_files(test_file_id, project_id,
  file)` UNIQUE(project_id, file). `job_specs` (per-job snapshot of
  TestFile content) UNIQUE(job_id) — preserves per-run snapshot when the
  test file is edited between runs. `jobs.test_file_id` NOT NULL FK.
- **D8. Drop spec/report artifact rows.** `artifacts.artifact_kind`
  CHECK narrows from
  `('events','state','spec','report','attachment','arbitrary')` to
  `('events','attachment','arbitrary')`. Content lives entirely in
  typed columns + extras. `Artifact->spec_iter` / `->report_iter`
  reconstruct JSONL on demand.
- **D9. Promote meta.json fields.** `archives` gains `host`, `"user"`,
  `git_sha`, `project`, `yath_version`, `meta_extras BLOB`. `meta.json`
  arbitrary artifact write at insert is dropped.
- **D10. All four flavors in lockstep.** Each DDL change lands across
  `share/schema/{sqlite,mariadb,mysql,postgres}.sql` simultaneously.

### Reconstruction model

For DB backends: `spec.jsonl`, `report.jsonl`, `meta.json` are
reconstructed on demand from typed columns + JSON catch-alls. The reader
API surface is unchanged. Tar / Directory / Live backends still store
those as on-disk artifact files — only DB-backed switched to typed-column
storage. Aggregated children (`subtests`, run-level `jobs[]`) rebuild via
JOIN. Byte-level round-trip of spec/report JSON is explicitly not
required; key/value content matches but ordering / whitespace may
differ.

### Per-table outline (post-redesign)

- `archives`: `archive_id PK`, `archive_uuid UNIQUE`, `archive_version`,
  `sealed_at`, `host`, `"user"`, `git_sha`, `project`, `yath_version`,
  `meta_extras BLOB`.
- `projects` (new): `project_id PK`, `name UNIQUE`.
- `runs`: as before + `project_id FK`, `spec_extras`, `state_extras`;
  drops the `spec` / `state` BLOBs.
- `test_files` (new): `test_file_id PK`, `project_id FK`, `file`,
  `UNIQUE(project_id, file)`.
- `jobs`: `archive_id FK`, `run_id FK`, `test_file_id FK NOT NULL`,
  `job_ord`, `pass`, `status`, `retry_count`. Drops `file`, `spec`, all
  TestFile-derived columns.
- `job_specs` (new): per-job snapshot of TestFile (`category`,
  `duration`, `stage`, `features`, `switches`, retry/isolation/binary
  flags, timeouts, slot bounds, `ch_dir`, `extras` BLOB).
  `UNIQUE(job_id)`.
- `job_tries`: typed columns for queued/started/ended timestamps,
  pass/fail/assertion counts, plan / halt / times / child_times /
  child_wall, plus `spec_extras` / `state_extras`. Drops `spec` /
  `state` BLOBs.
- `services`: identity only — `archive_id`, `run_id NULL`, `name`,
  `role`. Drops `status`, `spec`, `state`.
- `service_lifetimes` (new): one row per restart. `lifetime_ord`,
  `status`, `type`, `id`, `service_name`, `stage_name`, started/ended
  timestamps, `"exit"`, `exit_decoded`, `times`, `child_times`,
  `child_wall`, `spec_extras`, `state_extras`.
  `UNIQUE(service_id, lifetime_ord)`.
- `subtests`: unchanged.
- `artifacts`: `artifact_kind` CHECK narrowed. Indexes unchanged.

## Phase 3 — YATHFOOT trailer

### Trigger

Pre-trailer, sealed `.yath` files stored `meta.json` two different ways:

- **tar.zidx**: `meta.json.zst` member at offset 0 of the tar archive.
  Recovery needed a tar parser + zstd.
- **SQLite single-archive**: typed columns on `archives`. Recovery
  needed a SQLite client + the schema's column list.

External tools and `yath inspect` had to use format-specific code to
even know "what archive is this?" without fully cracking the file.

### Decisions

- **D1. Single 64-byte trailer.** Appended after all body bytes and
  format-specific footers. Self-describing: 8-byte head magic
  (`YATHFOOT`), 8-byte tail magic (`YATHTAIL`), 1-byte version, 1-byte
  flags, 4-byte format-id (`'TAR\0'`, `'SQL\0'`), u64 `meta_offset`,
  u64 `meta_size`, u32 `meta_crc32`, u64 `body_size`, u64 `format_ptr`.
  Pack template: `'a8 C C a2 a4 Q< Q< L< L< Q< Q< a8'`. All
  multi-byte fields little-endian. Total 64 bytes.

  Alternatives rejected:
  - **Header at offset 0** — SQLite owns bytes 0..15 (`'SQLite format
    3\0'`); prepending breaks tar.
  - **Sidecar file** — doubles artifact count, breaks copy/move
    workflows.
  - **Variable-size trailer** — fixed 64 bytes lets a reader
    `seek(-64, SEEK_END)` and unpack in a single read.

- **D2. zstd-compressed meta payload.** `FLAG_META_COMPRESSED` (bit 0
  of flags). Negligible overhead (~200–400 bytes for a typical run);
  matters because schema redesign made `meta_extras` JSON growable.
- **D3. `seal => 1` opt** flows through existing `archive` / `insert`
  paths. `App::Yath2::Log::Directory->archive($path, ...)` passes it
  to format-specific writers. `TarZIdx` appends after the zidx footer
  (with `format_ptr = zidx_footer_offset` so the reader doesn't need
  the "last 32 bytes" rule). `DB::insert($source, seal => 1)` for
  SQLite appends after commit; sealed instance refuses further
  inserts. **Multi-archive SQLite containers do NOT get a trailer** —
  a file-level `meta.json` is meaningless when the DB holds N
  archives.
- **D4. `last_breaking_version` → `'2.000012'`.** Trailer mandatory on
  read for sealed file-backed archives. Older archives refused on
  read.
- **D5. Reader API.** `App::Yath2::Log::Footer` exposes `has_footer`,
  `read_footer_from_path`, `read_meta_from_path` (returns
  `($meta_bytes, $footer)`, CRC-checked, zstd-decoded). `yath inspect`
  uses these directly when the target is sealed file-backed; falls
  back to artifact-handle path only for Directory / Live / unsealed.

### Trailer layout

    offset  size  field
    0       8     magic            = 'YATHFOOT'
    8       1     trailer_version  (currently 1)
    9       1     flags            (bit0 = FLAG_META_COMPRESSED)
    10      2     reserved
    12      4     format_id        ('TAR\0', 'SQL\0', ...)
    16      8     meta_offset
    24      8     meta_size        (compressed bytes when flagged)
    32      4     meta_crc32
    36      4     reserved
    40      8     body_size        (sqlite: page_count*page_size;
                                    tar:    zidx_footer_offset + 32)
    48      8     format_ptr       (tar: offset of zidx footer;
                                    sqlite: 0)
    56      8     trailer_self_magic = 'YATHTAIL'

Dual magic catches truncation: if the last 8 bytes were stripped, the
tail magic mismatches and the reader refuses.

### SQLite seal flow specifics

1. `begin_work`, populate, `commit`.
2. Read `PRAGMA page_count` * `PRAGMA page_size` → SQLite body size.
3. Validate `(-s $path) == body_size`. If not, refuse to seal.
4. Append zstd-compressed `meta.json` bytes.
5. Append the 64-byte YATHFOOT trailer.

After seal, raw `DBI->connect` and `sqlite3` CLI both still work;
SQLite ignores trailing bytes past `page_count * page_size`. Verified
empirically — `PRAGMA integrity_check` returns `ok` on sealed
archives. The integration test asserts via the system `sqlite3`
binary as a soft check.

### Trade-offs

- The tar archive's `meta.json.zst` member duplicates the trailer
  payload. Accepted so `tar -xf` still extracts a recognizable
  `meta.json.zst` and the trailer shape stays uniform across formats.
- Sealed SQLite is read-only. Re-importing into a sealed file is not
  supported. Workflow: extract → re-archive.
- Live directories never get a trailer.

## Phase 4 — Followups (post-merge polish)

These weren't a planned phase; they're the in-flight fixes between merge
and final review.

### F26 — DateTime normalization across flavors

Producer (`Test2::Harness2::Collector`) emits epoch-seconds time numbers
and ISO-8601 strings inconsistently. MariaDB / MySQL `DATETIME(6)`
columns reject ISO with `T` / `Z` separators and reject bare epochs.

Fix funnels every producer-side timestamp through DateTime objects with
per-flavor parse/format overrides:

- `Log::DB` base: `_to_datetime`, `_format_datetime`,
  `_normalize_timestamp`, `_db_datetime_to_iso`. `_update_row` binds
  via `bind_param` with per-column type hints from
  `_param_type_for_col`. Producer-side bind sites call
  `_normalize_timestamp`; reconstruction emit sites call
  `_db_datetime_to_iso`.
- `Log::Postgres`: overrides `_format_datetime` /
  `_to_datetime` to use `DateTime::Format::Pg`.
- `Log::MariaDB` + `Log::MySQL`: same pattern with
  `DateTime::Format::MySQL`.
- `Log::Sqlite`: `_format_datetime` uses
  `$dt->strftime('%Y-%m-%dT%H:%M:%S.%3NZ')` — `DateTime::Format::SQLite`
  truncates fractional seconds.
- `_db_datetime_to_iso` uses strftime conditional on nanosecond presence
  to preserve fractional output where present.

Per-column type hint mechanism: `_param_type_for_col($table, $col)`
returns an optional DBI type. `MySQL` / `MariaDB` use it to bind
`*_uuid` columns as `SQL_BINARY` for `BINARY(16)` storage. Without the
hint, `_update_row` was sending raw 16 bytes as TEXT, triggering "Data
too long for column 'run_uuid'" on `yath qdb mysql`.

New deps in `cpanfile`, `dist.ini`, `Makefile.PL`:
`DateTime::Format::ISO8601`, `DateTime::Format::MySQL`,
`DateTime::Format::Pg`, `DateTime::Format::SQLite`.

### `yath db` → `yath qdb`

The new "open archive in temp DB + drop into flavor shell" command was
mistakenly named `db`, overwriting the existing (broken, dependent on
the unwritten `App::Yath2UI`) `yath db` command. Rename to `qdb`,
restore the original broken `db.pm` content. Also: `_flavor_meta('mysql')`
returns `'MySQLCom'` driver instead of `'MySQL'`.

`DBIx::QuickDB::Driver::MySQL` is an ANY-style picker that prefers
MariaDB on PATH — a system `mariadbd` symlink shadowed `mysql-9.7`,
caused `archive_uuid_string` to come back NULL after a qdb mysql load.
`MySQLCom` is the Oracle/Community-specific driver and avoids the
shadow.

### Multi-version DB-test discovery

Tests now run per-version against installed DBs at `~/dbs/<prefix>-*`.
`Test2::Harness2::Test::DBVersions` exports `for_each_db_version` which
discovers versions and runs the body inside a forked `AsyncSubtest`
named after the version, with `$ENV{PATH}` localized so the version's
`bin` is first.

Forking is required because `DBIx::QuickDB` and its drivers cache
resolved binary paths at the package level (`%PROVIDER_CACHE` for
MySQL, `BEGIN`-time `$INITDB` / `$POSTGRES` for PostgreSQL), which
would otherwise pin the first-found version for the rest of the
process. Each fork starts with fresh package state.

Body is called as `$body->($name, $bin, $prefix)`. Prefix
disambiguates flavor sub-variants (mysql vs percona) so the body can
pick `'MySQLCom'` or `'Percona'` driver.

When no versions found in `~/dbs`, falls back to a single
`('system', undef, undef)` call in the parent process — preserves
prior single-version behavior.

### Test fixes

- All `t/AI/unit/Log/MySQL/*.t` switched to prefix-based driver
  selection (`MySQLCom` for `mysql`, `Percona` for `percona`).
- `service_lifetimes.t`: MySQL 8/9 `information_schema` returns
  uppercase column names; MariaDB returns lowercase. Lower-case the
  hash keys before checking.
- New `t/AI/unit/Log/Postgres/preprocess_schema.t` covers
  `_preprocess_schema_sql` (zstd / lz4 / strip / case-insensitive /
  pglz pass-through paths). Stubs `_server_compression` via
  `local *App::Yath2::Log::DB::Postgres::_server_compression` so no real
  postgres needed. The `//=` cache miss for an `undef` value would
  otherwise fall through to the dbh probe.
- Sqlite test assertions updated to compare timestamps via
  `$db->_db_datetime_to_iso($row->{...})` because raw column shape is
  now flavor-canonical.

## Status

Merged into `2.0` at commit `e45acaa9b` with `--no-ff`. 73 commits total
on the branch. Suite at merge: 216/216 passing under
`AUTHOR_TESTING=1 yath -D test t`.

Code on `2.0` is provisional pending end-to-end "AI slop" review before
a stable release. Yath 2.0 is unreleased and under rapid prototyping;
the merge is acceptable in that posture, with the explicit understanding
that the entire codebase will be reviewed before stable.
