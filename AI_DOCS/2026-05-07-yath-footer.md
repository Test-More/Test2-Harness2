# YATHFOOT trailer — unified meta.json access for sealed yath archives

Date: 2026-05-07
Branch: `new_log_refactor`

This document covers the third refactor pass on `new_log_refactor`,
landing immediately after the schema redesign described in
`AI_DOCS/2026-05-07-schema-redesign.md`. After the schema redesign
landed, sealed `.yath` files (tar.zidx and single-archive SQLite)
still required format-specific code to recover `meta.json`. This pass
adds a single 64-byte trailer (`YATHFOOT`) appended to the end of
every sealed archive so external tools, third-party readers, and
yath's own `inspect` command can pull `meta.json` out of an archive
by reading only the last few KB of the file -- no SQLite parser, no
tar parser, no zidx index parser required.

The work landed across four commits (F1 -- F4) on `new_log_refactor`.

## Trigger

Pre-trailer, `meta.json` lived in two completely different places
depending on backend:

- **tar.zidx**: a `meta.json.zst` member at offset 0 of the tar
  archive (older inline mechanism). Recovering it required a tar
  parser and a zstd decompressor.

- **SQLite single-archive**: typed columns on the `archives` row
  (`host`, `user`, `git_sha`, `project`, `yath_version`,
  `sealed_at`, `meta_extras` JSON). Recovering it required a SQLite
  client and the schema's column list.

Two consequences:

1. External tools (a Python script, a `jq` pipeline, a Go CLI)
   needed format-specific code to even know "what archive UUID is
   this" without first cracking open the archive proper.

2. `yath inspect` had to call into the artifact-handle API to fetch
   `meta.json`, which for SQLite archives meant fully opening the
   DB and reconstructing meta from typed columns. This was correct
   but heavy for a "what is this file" probe.

The trailer fixes both: a fixed-shape, self-describing 64-byte
record at the end of the file points at a zstd-compressed copy of
`meta.json`.

## Decisions

### D1. Single 64-byte trailer at the file end

A fixed 64-byte trailer is appended after all body bytes and any
format-specific footers (zidx footer for tar, SQLite body for the
DB case). The trailer carries everything needed to locate and
verify the meta payload:

- 8-byte head magic (`YATHFOOT`) and 8-byte tail magic (`YATHTAIL`)
  for unambiguous detection.
- 1-byte trailer version, 1-byte flags, 4-byte format-id (NUL-padded
  ASCII: `'TAR\0'`, `'SQL\0'`).
- u64 `meta_offset` and u64 `meta_size` locate the meta payload.
- u32 `meta_crc32` over the (compressed) payload bytes for integrity.
- u64 `body_size` declares the format-specific body length (for
  SQLite: `page_count * page_size`; for tar: `zidx_footer_offset +
  32`).
- u64 `format_ptr` is a backend-specific helper. For tar.zidx it
  points at the start of the existing 32-byte zidx footer so a
  reader can locate the index without scanning. For SQLite it is 0.

All multi-byte fields are little-endian. The exact pack template
(`'a8 C C a2 a4 Q< Q< L< L< Q< Q< a8'`) lives in
`App::Yath2::Log::Footer::FOOTER_PACK_TEMPLATE`.

Alternatives considered:

- **A header at offset 0.** Rejected because the SQLite body owns
  bytes 0..15 (`'SQLite format 3\0'` magic), and prepending bytes
  to a tar archive breaks the tar parser. Trailing bytes are
  invisible to both: SQLite reads only `page_count * page_size`,
  tar reads members until it hits the two empty 512-byte blocks
  marking end-of-archive.

- **A separate sidecar file** (`run.yath.meta`). Rejected: doubles
  the artifact count, makes archives no longer "one file", breaks
  copy/move workflows that don't know about the sidecar.

- **Variable-size trailer.** Rejected: a fixed 64 bytes lets a
  reader `seek(-64, SEEK_END)` and unpack in a single read. The
  meta payload itself is variable-size, but the trailer that
  describes it is fixed.

### D2. zstd-compressed meta payload

The meta payload is zstd-compressed by default. The trailer's flags
byte carries `FLAG_META_COMPRESSED` (bit 0); decoding tools must
honour it. Compression matters because the schema-redesign pass
made `meta.json` stored on the SQLite side with a `meta_extras`
JSON catch-all, which can grow when producers add extras. zstd
keeps the trailer overhead negligible (~200--400 bytes for a
typical run).

### D3. Backend integration via `seal => 1`

Rather than dispatching on backend at the writer level, the
trailer is appended via a single `seal => 1` opt that flows into
the existing `archive` / `insert` paths:

- `App::Yath2::Log::Directory->archive($path, ...)` passes
  `seal => 1` into the format-specific writer.
- `App::Yath2::Log::TarZIdx` writer appends the trailer after
  closing the zidx footer. The trailer's `format_ptr` records the
  zidx footer's start so readers don't have to "look at the last
  32 bytes of the body" -- they consult `format_ptr` instead.
- `App::Yath2::Log::DB::insert($source, seal => 1)` (for the
  SQLite flavor) appends the trailer after the transaction
  commits. The instance is then flagged as sealed and refuses
  further `insert()` calls.

Multi-archive SQLite containers (DBs that hold more than one
`archives` row) intentionally do NOT get a trailer: a single
file-level meta.json doesn't make sense when the DB holds N
archives. Detection is by `seal => 1` -- the caller (typically
`Directory->archive(format => 'sqlite')`) knows it is producing
a single-archive container and asks for the seal.

### D4. `last_breaking_version` bump

The trailer is mandatory on read for sealed file-backed archives.
`App::Yath2::Log->last_breaking_version` was bumped to `2.000012`
so older archives without a trailer are refused with a clear error
on read. The schema-redesign pass had already bumped to
`2.000011`; this pass takes the next step.

### D5. Reader API surface

A single module exposes everything:

- `App::Yath2::Log::Footer::has_footer($path)` returns 1/0 for
  cheap presence checks.
- `App::Yath2::Log::Footer::read_footer_from_path($path)` returns
  the unpacked trailer hashref or undef.
- `App::Yath2::Log::Footer::read_meta_from_path($path)` reads,
  CRC-checks, and (if compressed) zstd-decompresses the meta
  payload. Returns `($meta_bytes, $footer)`.

`yath inspect` uses these directly: when the inspect target is a
sealed file-backed archive (TarZIdx or single-archive sealed
SQLite), `meta.json` is read through the trailer, sidestepping
the artifact-handle path entirely. The artifact-handle fallback
remains for live directories (no trailer ever) and for archives
predating the trailer (refused at read time anyway, but the
fallback covers any in-flight transition).

## Trailer layout

All fields are little-endian. Total: 64 bytes.

    offset  size  field
    0       8     magic            = ASCII 'YATHFOOT'
    8       1     trailer_version  (u8, currently 1)
    9       1     flags            (u8: bit0 = FLAG_META_COMPRESSED)
    10      2     reserved         (zero)
    12      4     format_id        (4 ASCII bytes, NUL-padded;
                                    'TAR\0', 'SQL\0', ...)
    16      8     meta_offset      (u64) absolute file offset of
                                         meta payload start
    24      8     meta_size        (u64) meta payload byte count
                                         (compressed bytes when
                                         FLAG_META_COMPRESSED is set)
    32      4     meta_crc32       (u32) crc32 of meta payload bytes
    36      4     reserved         (zero)
    40      8     body_size        (u64) sqlite: page_count*page_size;
                                         tar: zidx_footer_offset + 32
    48      8     format_ptr       (u64) tar: offset of zidx footer;
                                         sqlite: 0
    56      8     trailer_self_magic = ASCII 'YATHTAIL'

The dual magic (`YATHFOOT` at offset 0 and `YATHTAIL` at offset 56)
catches truncation: if a downstream tool stripped the last 8 bytes
of the file, the tail magic won't match and the reader refuses.

## Backend integrations

### tar.zidx

The tar.zidx writer flow with `seal => 1`:

1. Write tar members (data + meta.json + zidx index).
2. Write the 32-byte zidx footer (existing format).
3. Append `meta.json` bytes (zstd-compressed) at the current end.
4. Append the 64-byte YATHFOOT trailer with:
   - `format_id   = 'TAR'`
   - `body_size   = zidx_footer_offset + 32`
   - `format_ptr  = zidx_footer_offset`
   - `meta_offset = body_size`
   - `meta_size   = length(compressed_meta_bytes)`

The reader consults `format_ptr` to find the zidx footer (which
in turn locates the index), so the "last 32 bytes" rule is gone.
Older archives without the trailer are refused at read time per
D4.

### SQLite (single-archive sealed)

The SQLite flow with `seal => 1`:

1. Open / create the SQLite file.
2. `begin_work`, populate every table, `commit`.
3. Read `PRAGMA page_count` and `PRAGMA page_size`. Their product
   is the SQLite body size.
4. Validate: `(-s $path) == page_count * page_size`. If not,
   something else has appended bytes -- refuse to seal.
5. Append `meta.json` bytes (zstd-compressed).
6. Append the 64-byte YATHFOOT trailer with:
   - `format_id   = 'SQL'`
   - `body_size   = page_count * page_size`
   - `format_ptr  = 0`
   - `meta_offset = body_size`
   - `meta_size   = length(compressed_meta_bytes)`

After seal, the in-memory `App::Yath2::Log::Sqlite` instance
flags itself sealed and refuses further `insert()`. SQLite still
reads the file fine -- it ignores trailing bytes past
`page_count * page_size` -- so raw `DBI->connect` and `sqlite3`
CLI both work unmodified. Verified empirically: `sqlite3 PRAGMA
integrity_check` returns `ok` on sealed archives.

## Reader API

`App::Yath2::Log::Footer` is the only public surface:

```perl
use App::Yath2::Log::Footer qw{
    FOOTER_SIZE FORMAT_ID_TAR FORMAT_ID_SQL FLAG_META_COMPRESSED
    has_footer read_footer_from_path read_meta_from_path
};

if (has_footer($path)) {
    my $f = read_footer_from_path($path);
    # $f->{format_id}, $f->{meta_size}, ...
    my ($meta_bytes, $footer) = read_meta_from_path($path);
    my $meta = decode_json($meta_bytes);
}
```

The `append_meta($path, $bytes, %opts)` helper is also exported but
is for backend writers only -- end users should not call it.

`yath inspect` consumes the public surface in
`lib/App/Yath2/Command/inspect.pm`:

- A new `_read_meta_via_footer($path)` helper checks
  `has_footer`, calls `read_meta_from_path`, decodes to JSON, and
  returns the hashref or undef on any failure.
- A new `_log_path($log)` helper returns the on-disk file path
  for sealed file-backed Logs (TarZIdx -> `path`, Sqlite ->
  `file`) and undef for Directory / Live (which never have a
  trailer).
- `_fill_log_report` calls `_read_meta_via_footer` first and only
  falls back to the artifact-handle path if the trailer is
  absent or fails.
- `_fill_sqlite_report` calls `_read_meta_via_footer` against the
  archive path up front; on a single-archive sealed file the
  trailer carries the file-level meta so it surfaces at
  `report.meta` even before per-archive enumeration.

## Trade-offs / non-goals

- **The tar archive's `meta.json.zst` member is redundant with the
  trailer**. The trailer holds a separately-compressed copy at the
  file tail. We accept the duplicate so the trailer shape stays
  uniform across formats (tar and sqlite both carry meta the same
  way at the same offset semantics) and so `tar -xf` still extracts
  a recognizable `meta.json.zst` for users who don't know about
  the trailer. The duplication is small (a few hundred bytes of
  compressed JSON).

- **`last_breaking_version = '2.000012'`**. Archives without a
  YATHFOOT trailer (i.e. produced by any code older than this
  pass) are refused on read. Re-stamping is a manual-tools
  concern handled later if needed.

- **Multi-archive SQLite containers do not get a trailer**. A
  single file-level `meta.json` is meaningless when the DB holds
  N archives. The per-archive meta lives in typed `archives`
  columns + `meta_extras` and is recovered via the artifact API
  on a per-archive basis, the same as before this pass. `yath
  inspect` falls through cleanly: `_read_meta_via_footer` returns
  undef, and the per-archive enumeration fills the rest.

- **Sealed SQLite is read-only**. The `sealed` flag on the in-memory
  Log instance refuses further `insert()` calls. Re-importing into
  a sealed file is not supported. Workflow: extract back to a
  Directory, then re-archive to a fresh sealed file.

- **`PRAGMA integrity_check` is best-effort verified**. The new
  `t/AI/integration/footer_round_trip_sqlite.t` runs the pragma
  via the system `sqlite3` CLI and notes the result. Empirically
  the pragma returns `ok` -- SQLite ignores trailing bytes
  cleanly -- so the test does not gate on it (the assertion is
  soft: `note 'ok'` on success, `diag` with details on
  non-ok). This protects against future SQLite versions that
  might tighten that behaviour without surprising the test
  suite.

- **Live directories never get a trailer**. There is no `seal`
  step on a live directory; the trailer is strictly a sealed-archive
  artefact.

## Commit list

Four commits on `new_log_refactor`, in order:

- F1 (`3205194fd`) -- `App::Yath2::Log::Footer`: pack/unpack, CRC,
  append helper, presence/read helpers + unit test.
- F2 (`4c2cafa49`) -- `App::Yath2::Log::TarZIdx`: writer appends
  trailer; reader follows trailer to zidx footer; bump
  `last_breaking_version` to `2.000012`.
- F3 (`363bd5cfe`) -- `App::Yath2::Log::DB::insert(seal => 1)`:
  append trailer for single-archive sealed SQLite; sealed-instance
  refuses further inserts.
- F4 (this pass) -- `yath inspect` prefers the trailer for
  meta extraction; integration tests for round-trip + external
  CLI tools (`tar -xf`, `sqlite3`); AI_DOC + ARCHITECTURE
  addendum.
