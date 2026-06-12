# Fresh start: orchestration model + collector extraction

## What and why

The user wrote `fresh_start` (repo root) capturing the direction for
this rewrite, and extracted the collector pipeline into a standalone
`Test2-Collector` distribution (`~/projects/Test2/Test2-Collector`).
This task updated `ARCHITECTURE.md` and `AGENTS.md` to reflect both.
No code changed.

## Decisions recorded

1. **The collector is external.** `Test2-Collector`
   (`Test2::Collector` namespace) owns the collector pipeline; its
   own `ARCHITECTURE.md` is the authoritative collector spec. This
   repo keeps only the boundary description and the Monitor
   (`Test2::Harness2::Collector::Monitor`), which was deliberately
   not extracted. Recorded as `ARCHITECTURE.md` §2.7 and a rewritten
   §4.1.

2. **Replacement pending, not done.** `Test2-Collector` is under
   review — not released, not installed. The in-tree
   `Test2::Harness2::Collector*` modules (minus Monitor) and
   `Test2::Formatter::Stream2*` are pre-extraction copies that keep
   working until the swap; new code must not build against their
   internals or load `Test2::Collector*` yet. After the swap the
   build-out of the harness proper begins.

3. **Orchestration model** (from `fresh_start`), recorded as
   `ARCHITECTURE.md` §4.2:
   - One collector per collected process; full events to a per-collector
     `jsonl.zst` file; only transitions to the harness.
   - Every harness-started process — including the main harness
     process — is a (non-test) collector: one wire format everywhere.
   - Completion comes from transition messages, never reaping
     (collectors may not be direct children).
   - Transitions (plus harness-added events) are the shared state
     forwarded to consumers; nothing rebroadcasts the full stream.
   - Consumers (renderers etc.) read a collector's events file on
     demand; the `starting` transition carries its path.
   - `Getopt::Yath` for command-line parsing (App::Yath2 side).

4. **Extraction differences** that make the in-tree copies stale as
   spec (recorded in §4.1 and a §5.2 addendum): unified sinks (one
   `Recorder::*` abstraction for both the event stream and the
   transitions stream; facet-based routing moved into the collector),
   the `{type => "transition", payload => ...}` envelope removed
   (transitions are plain events stamped with a `harness_collector`
   facet; optional `transition_frame` wrapper), the test pipeline
   (`Assembler` → `Auditor`) auto-wired for `is_test`, and the
   formatter renamed `Test2::Formatter::Collector`. The in-tree
   recorder/Monitor still speak the envelope; they change together
   when the swap lands.

## Alternatives considered

- Doing the code swap now, against the sibling checkout: rejected —
  the dist is still under the user's review and is not installed, so
  the harness cannot depend on it yet. **Superseded the same day**:
  the user directed the swap to proceed against the sibling checkout
  via a gitignored `t2clib` symlink (see "Swap landed" below).
- Leaving §4.1's deep pipeline description in place with an addendum:
  rejected — two authoritative collector specs would drift; the
  external dist's `ARCHITECTURE.md` owns the contract, §4.1 keeps the
  boundary, status, differences, and the Monitor.

## Swap landed (same day)

The user directed the replacement to proceed before the dist is
installed, loading it from a gitignored `t2clib` symlink at the repo
root (`ln -s ../Test2-Collector/lib t2clib`); no worktree/branch by
explicit instruction (foundational work happens directly on `2.0b`
until foundations are declared in place).

What changed:

- **Deleted** the pre-extraction copies: `Test2::Harness2::Collector`
  (engine), `Assembler`, `Auditor` (+`TimeTracker`), `Parser::*`,
  `Recorder` (+`::Test`), `Role::*`, `Test2::Formatter::Stream2*`,
  and `Test2::Harness2::Event` — plus their tests and the orphaned
  helper scripts. `Test2-Collector`'s own suite covers all of it.
- **Kept** all `Test2::Harness2::Util::*` modules — **superseded the
  same day** (see "Util unification" below): the user directed
  switching to the collector's utils, and the whole harness Util
  tree was deleted.
- **Ported the Monitor** to the extracted transition shape: frames
  decode to plain events (`{facet_data => ...}`) stamped with a
  `harness_collector` facet — no `{type, payload}` envelope. Added
  handling for the `exited` transition plain (non-test) collectors
  emit: it marks the collector complete (feeds `new_completed`, not
  `new_test_exits`).
- **Ported `scripts/t2h2_collector`**: `Test2::Collector`'s
  `spawn_collector` with `recorder => Recorder::Zstd` (events file)
  and `reporter => Recorder::Socket` (transitions to the Monitor's
  socket). Two behavior notes: the processor chain is auto-wired for
  `is_test` (still passed explicitly to set the Assembler's
  `emit_stray` under `-vv`), and the spawned collector's exit code
  now reports collector health (0/255), not the test verdict — the
  script derives its own 0/1 exit from the final state received over
  the socket, failing also on a non-zero collector exit.
- **Scripts self-load `t2clib`** when it exists
  (`use lib grep { -d $_ } "$RealBin/../t2clib", "$RealBin/../lib"`),
  so they run without `-I` flags and keep working unchanged after the
  dist is installed. `t/AI/integration/t2h2_paint.t` (the only test
  loading `Test2::Collector*` directly) carries `use lib 't2clib'`.

Suite after the swap: 8 files, 71 tests, all passing via
`prove -Ilib -j16 -r t/`.

## Util unification (same day, follow-up)

The user directed switching to the collector's utility modules
wherever possible. The entire `Test2::Harness2::Util*` tree is now
deleted; the Monitor, the `scripts/t2h2_*` drivers, and the tests use
`Test2::Collector::Util::{JSON, Socket, Zstd, Zstd::FrameBuffer}`.
Notes:

- `encode_pretty_json` / `json_true` / `json_false` and
  `open_zstd_writer` / `open_zstd_reader_fh` have no collector
  equivalent and no remaining consumers. The one pretty-JSON user
  (`scripts/t2h2_extract`, a human-facing dump) builds its own
  `Cpanel::JSON::XS` pretty/canonical/ascii encoder inline; the one
  zstd-writer user (`t2h2_extract.t`'s fixture) writes
  `compress_blob` frames directly.
- The Monitor's `feed_frame` uses `decompress_blob` instead of
  calling `Compress::Zstd::decompress` directly, dropping the
  Monitor's direct `Compress::Zstd` dependency (the collector util
  gates zstd behind `HAVE_ZSTD`).
- Future harness-only utilities may re-grow under
  `lib/Test2/Harness2/Util/`, but wire-format / IPC helpers must come
  from `Test2::Collector::Util::*` (recorded in `ARCHITECTURE.md` §3
  and the AGENTS.md reuse pass).

Suite after unification: 6 files, 63 tests, all passing (the two
in-tree util unit tests went with their modules; the collector dist
tests its own utils).
