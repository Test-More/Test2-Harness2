# 2026-04-23: Log Archive

## Task

Land `App::Yath2::LogArchive` (reader + writer) plus the two harness-side
`artifacts.json` manifests (global + per-run) needed to make the archive
contents self-describing. Triggered by spec
`docs/superpowers/specs/2026-04-23-log-archive-design.md` and plan
`docs/superpowers/plans/2026-04-23-log-archive.md`.

## Result

- New module tree under `lib/App/Yath2/LogArchive/`:
  - `Format.pm` — magic-byte detection plus reader/writer dispatch tables.
  - `Role/Source.pm`, `Role/Writer.pm` — backend role contracts.
  - `Directory.pm` — on-disk directory backend.
  - `Tar/{External,PP}.pm`, `TarGz/{External,PP}.pm`, `TarBz2/{External,PP}.pm`.
  - `Zip/{External,PP}.pm`, `SevenZip/{External,PP}.pm`.
  - `Writer/Tar.pm` — single class for all three tar flavours.
  - `Writer/Zip/{External,PP}.pm`, `Writer/SevenZip.pm`.
- `LogArchive.pm` itself is the dispatcher and the high-level API base
  (`artifacts`, `runs`, `services`, `rogue_files`).
- Harness service (`lib/Test2/Harness2.pm`) now seeds `%artifacts` from
  its loggers on startup and merges any global `collector_artifacts`
  messages, writing `logs/artifacts.json` atomically on every change.
- Run service (`lib/Test2/Harness2/RunService.pm`) accumulates
  `%artifacts` from `collector_artifacts` and writes
  `logs/runs/<run_id>/artifacts.json` atomically.
- Unit + integration tests under `t/AI/unit/LogArchive/` and
  `t/AI/integration/log_archive.t`. The integration test runs a real
  harness, archives the workdir as `tar.bz2`, and asserts that the
  reader API returns identical results from the directory and the
  archive.

## Decisions

- **Dispatcher class also serves as base class.** `App::Yath2::LogArchive`
  doubles as the entry point (`new`, `create`) and the parent class for
  every read backend (so backends inherit `artifacts` / `runs` /
  `services` / `rogue_files` for free). The constructor branches on
  `$class eq __PACKAGE__`: if invoked on the dispatcher it picks a
  backend by format; otherwise it falls through to a HashBase-style
  bless+init. This was discovered the hard way — without the branch,
  `Directory->new` resolves to the parent dispatcher and re-enters
  itself, which OOM-killed the host (123 GB RSS) before producing a
  Perl deep-recursion warning.
  - *Alternative considered:* keep the dispatcher in a separate class
    (`App::Yath2::LogArchive::Dispatcher` or similar). Rejected because
    every caller already wants `App::Yath2::LogArchive->new(path => ...)`
    to "just work" and a second class is more surface area for the same
    behaviour.
- **External-first backend selection.** `Format::reader_class_for`
  prefers the `External` subclass of each format and only falls back to
  `PP` if the binary is unavailable. Faster on large archives and
  avoids slurping every member through Perl space.
  - *Alternative:* PP-first. Rejected — speed/memory matter most for the
    real workload (multi-GB log archives produced by long runs).
- **Magic-byte detection over file extension.** Users rename archives,
  CI pipelines hand us files without an extension, and our writer can
  produce extensionless output. Magic bytes are authoritative; the only
  exception is `directory`, which is decided by `-d $path` first.
- **`artifacts.json` owned by the emitting service.** Harness service
  writes the global manifest, each run service writes its own
  per-run manifest. A single central manifest written by the harness
  was rejected because run scope would leak across concurrent runs and
  the harness would need to learn every run's logger output paths.
- **Duplicate-key policy: warn-and-skip.** A logger reporting a path
  that another logger already claimed gets a warning and is dropped
  from the manifest. Failing the run was rejected — a routing bug in
  one logger should not sink an entire run.
- **`runs(include_empty => 1)` is backend-specific.** Archives don't
  store empty directories, so empty runs cannot exist there. Directory
  backend overrides `runs()` to scan the on-disk `runs/` directory in
  addition to the manifest-driven enumeration. The base class only
  knows about runs that have an `artifacts.json`.
- **Tar entries normalise to clean names.** `tar -cf out -C dir .`
  prefixes every member with `./`. Both `Tar::External` and `Tar::PP`
  build a name map keyed by the cleaned path so callers look up
  entries with the natural relative form. The map preserves the stored
  name for the actual extract.

## Architectural touches

- Narrowed the `collector_artifacts` drop-filter at
  `lib/Test2/Harness2.pm` so global messages (no `run_id`) flow into
  the new `_handle_global_collector_artifacts`. Run-scoped messages
  still bypass the harness handler.
- Added `%artifacts` state plus `_seed_artifacts_from_loggers`,
  `_merge_artifacts`, `_write_artifacts_manifest` to the harness
  service.
- Mirrored the same helpers in `RunService` (sans the seed step;
  collectors are the only sources for run-scoped artifacts).
- `App::Yath2::LogArchive` is the new reader/writer façade. Backends
  load lazily via `require module_path($class)` so an installation
  missing `Archive::SevenZip` (etc.) still loads fine until that
  format is actually requested.

## Process notes

The implementation host crashed twice during this work due to running
the test suite at `-j24` while parallel subagents were also active —
combined RAM use peaked at 120 GB and tripped the kernel OOM killer.
The third (successful) run dropped to single-threaded test execution
under `ulimit -v` caps, which made the dispatcher recursion bug fail
fast with a Perl-level deep-recursion warning instead of locking the
machine. Future work in this branch should keep parallelism modest
until any new backend is fully exercised.

## Deviations from `ARCHITECTURE.md`

None. The new modules live entirely in the `App::Yath2` namespace
called out in the architecture's module map; the harness changes
slot into the existing collector_artifacts protocol. No addendum
required.
