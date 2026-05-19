# Task Specification: Yath DB Schema Refactor & Fixes

**Context:** The `yath-db-schema` branch has replaced the legacy database implementation with a new `App::Yath2::DB` architecture. While functional, several gaps in the enumeration/extraction logic and code duplication across backends need resolution.

---

## 1. Virtual File Enumeration (`list_files`)
**Problem:** `App::Yath2::DB::list_files` only returns paths for rows physically present in the `artifacts` table. It misses "virtual" files (`spec.jsonl`, `report.jsonl`, `state.jsonl`) which are reconstructed on-the-fly from typed columns.
**Requirement:** 
- Update `list_files` to enumerate virtual files for every scope that contains them.
- A Run has: `spec.jsonl`, `report.jsonl`.
- A Service has: `spec.jsonl`, `report.jsonl`.
- A Job-Try has: `spec.jsonl`, `report.jsonl`, `state.jsonl`.
- Iterate through `run_rows`, `service_rows`, and `job_rows` (and their tries) to generate these paths.

## 2. Virtual File Materialization (`extract`)
**Problem:** `App::Yath2::DB::extract` only writes physical artifacts to the destination directory.
**Requirement:**
- Update `extract` to materialize the virtual files enumerated in Task 1.
- Use existing reconstruction methods: `_reconstruct_spec_records`, `_reconstruct_report_records`, etc.
- Ensure they are written as JSONL (optionally compressed if the `compressed` flag is passed to `extract`).

## 3. Memory Optimization (`artifact_iter_records`)
**Problem:** `artifact_iter_records` (and the underlying `_artifact_read`) materializes the entire artifact payload as a single string and then often decodes it into a large arrayref of hashes. For large logs, this causes significant memory spikes.
**Requirement:**
- Refactor `artifact_iter_records` to return a `Test2::Harness2::Util::JSONL::Reader` object (or similar iterator) instead of a full arrayref.
- Use `IO::Scalar` or `open(my $fh, '<', \$payload)` to provide a filehandle to the reader, avoiding unnecessary string copies.
- Update `App::Yath2::DB::Iterator` (the event walker) to consume this new streaming interface.

## 4. Logic Consolidation (`Role::DB::Backend`)
**Problem:** Duplicate logic exists in `App::Yath2::DB::SQL` and `App::Yath2::DB::DBIC`.
**Requirement:**
- Move the following methods to `App::Yath2::Role::DB::Backend` (with default implementations):
    - `_pg_server_compression`: Probing Postgres for zstd/lz4 support.
    - `_server_is_mariadb`: Distinguishing MariaDB from MySQL via `VERSION()`.
    - `_should_skip_schema_statement`: The logic to skip triggers on MariaDB.
    - `preprocess_schema_sql`: The Postgres compression rewrite logic.
- Ensure both `SQL.pm` and `DBIC.pm` consume these from the role.

## 5. DBIC Write Delegation
**Requirement:**
- Ensure `App::Yath2::DB::DBIC` delegates **all** write-primitive methods (`archive_create`, `artifact_create`, `ensure_*_row`, etc.) to its internal `_shared_sql_backend`.
- This ensures that complex bind logic (for UUIDs and BLOBs) is maintained in exactly one place (`SQL.pm`).

---

**Files to Modify:**
- `lib/App/Yath2/DB.pm` (Tasks 1, 2, 3)
- `lib/App/Yath2/DB/Iterator.pm` (Task 3)
- `lib/App/Yath2/Role/DB/Backend.pm` (Task 4)
- `lib/App/Yath2/DB/SQL.pm` (Task 4 - remove duplicates)
- `lib/App/Yath2/DB/DBIC.pm` (Task 4 - remove duplicates; Task 5)

**Verification:**
- Run `t/AI/unit/DB/read.t` and `t/AI/unit/DB/write.t`.
- Verify extraction via `yath extract` or a script calling `$db->extract`. The extracted directory must contain the virtual `.jsonl` files and match the structure of a standard `yath` log directory.
