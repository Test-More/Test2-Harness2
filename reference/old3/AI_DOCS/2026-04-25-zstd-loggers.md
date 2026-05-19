# AI_DOC: zstd-compressed log artifacts

Date: 2026-04-25
Branch: `zstd-loggers`
Spec: `docs/superpowers/plans/2026-04-25-zstd-loggers-spec.md` (gitignored locally)

## What changed

Every text file the harness, run service, resource service, or
collector logger writes under `workdir/logs/` is now zstd-compressed.
JSON snapshots become `.json.zst`; JSONL event streams become
`.jsonl.zst`; the `artifacts.json` manifests at harness scope and
per-run scope become `artifacts.json.zst`.

A pre-trained shared dictionary is shipped with the dist at
`share/other/zstd.dict`. At run start the harness copies the dict
into `$logdir/zstd-dict.bin`, and `yath archive` bundles that copy
into the resulting `tar.zidx` so extracts and replays do not depend
on the recipient's install having a matching dict.

The multi-format archive support (`tar`, `tar.gz`, `tar.bz2`, `zip`,
`7z`) was deleted along the way -- `tar.zidx` is now the single
in-tree archive format yath produces or reads. The `tar.zidx` family
of modules collapsed from four files into one consolidated module.

`yath extract` decompresses entries on the fly by default and strips
the `.zst` suffix from output filenames, so the extracted tree is
directly human-readable. A `--no-decompress` flag preserves the
byte-for-byte form for debugging or training-input pipelines.

## Why

1. **Smaller logs.** zstd at level 3 with a small jsonl-shaped
   dictionary gives ~3.8x compression on per-line frames vs ~2.1x
   without the dict. Whole-file compression (the json snapshots and
   manifests) gets ~7x. See spec section 9 for the benchmark.
2. **Tail-safe.** Each line in a `.jsonl.zst` is a self-contained
   zstd frame. Concurrent writers can append independently as long
   as a frame fits in `PIPE_BUF`. Readers tail the file by walking
   frames as they land.
3. **Self-contained archives.** Frames carry a 4-byte dictID, not the
   dict itself. Bundling the dict inside each archive means an
   archive moved between machines decodes cleanly even if their
   `share/other/zstd.dict` differs.
4. **Simpler codebase.** Multi-format archive support (tar / tar.gz /
   tar.bz2 / zip / 7z) existed only to give users a familiar tool to
   reach archive contents. That made sense when the harness produced
   uncompressed files. Now it compresses everything anyway and
   bundles its own dict, so the recipient running `yath extract`
   gets plaintext for free. Dropping the alternates removes ~1000
   lines of code, several optional dependencies, and a maintenance
   burden.

## Decisions and alternatives considered

### Compression always on; no opt-out

Spec section 7. The architectural mandate is "every text file under
`workdir/logs/` is zstd-compressed." There is no `--no-compression`
yath option. If a user wants uncompressed logs, they run
`yath extract --no-decompress` post-hoc.

### Compression level 3 (zstd default), not tunable

Bench numbers showed level 3 hits a good ratio/CPU sweet spot at our
data scale. Tunable later if profiling justifies it.

### `Compress::Zstd` is a hard prereq; no binary fallback

Earlier draft kept the `zstd`/`unzstd` CLI as a runtime fallback for
compress/decompress. Benchmarks showed the binary path is 5-30x
slower than in-process module calls (process spawn dominates), and
the dual-path complexity had no ratio benefit. The `zstd` binary is
still required for `author/train_zstd_dict` since `Compress::Zstd`
exposes no `--train` API; that is the only place in the codebase
that spawns a zstd process.

### Single name `zstd-dict.bin` across all contexts

The dict copy in the live logdir, the entry in the `tar.zidx`
archive, and the file written by `yath extract` all use the exact
filename `zstd-dict.bin`. Earlier drafts used a defensive
`__zstd_dict__.bin` for the archive entry to avoid collisions with
user-named entries, but the archive simply bundles the contents of
`$logdir/`, so the entry naturally lands at the same path. Removing
the rename simplified writer / reader / extract.

### Per-line frame for jsonl (one zstd frame per line)

Each line in `.jsonl.zst` is one self-contained frame. With the
shared dict the per-frame overhead drops enough that the ratio is
comparable to streamed compression while preserving append/tail
safety. Without the dict the ratio is ~2x worse than streamed, but
streamed compression is incompatible with safe concurrent appends.

### Dictionary tracked in git, manual updates only

`share/other/zstd.dict` lives in the repo. Updating it is a
deliberate maintenance step the same way bumping a CHANGELOG entry
is. `author/train_zstd_dict` walks one or more existing yath
archives via `App::Yath2::Streamer::Static`, dumps the events as
training samples, runs `zstd --train`, and overwrites
`share/other/zstd.dict`. A `[Run::BeforeBuild / AssertZstdDict]`
hook in `dist.ini` makes dzil refuse to build if the file is
missing or empty.

### Subclasses for the file-reader split, not runtime detection

`Util::File::JSON::Zstd` subclasses `Util::File::JSON`;
`Util::File::JSONL::Zstd` subclasses `Util::File::JSONL`. The
plaintext base classes never see compressed bytes; the `::Zstd`
subclasses never see plaintext. Logger and streamer code picks
which to instantiate based on the file path's `.zst` suffix.

An earlier draft had a single class detect compressed vs plaintext
at runtime via the zstd frame magic. Cleaner contract with explicit
subclasses.

## Architectural changes

* `Test2::Harness2` gains a `dict_path` constructor attribute. At
  init time it copies the resolved dictionary into
  `$logdir/zstd-dict.bin`. Default-resolution uses
  `File::ShareDir::dist_file('Test2-Harness2', 'other/zstd.dict')`
  directly -- not `App::Yath2::Util::share_file` -- to honour the
  CLAUDE.md "no `App::Yath2` from `Test2::Harness2`" rule.

* `App::Yath2::Options::LogArchive` is a new options library
  declaring `--zstd-dict` and `--no-zstd-dict`. yath commands that
  spawn the harness pre-resolve the chosen dict path and thread it
  in through `dict_path`. No yath command is required to load this
  options library; the harness has a sensible default on its own.

* The `tar.zidx` index entry hash gains an `inner` field
  (`"zstd"` or `"none"`) that tells the reader whether the entry's
  payload is itself zstd-compressed (legacy default) or stored
  verbatim. Already-`.zst` source files and the bundled dict are
  stored verbatim with `inner => "none"`; everything else gets an
  inner zstd frame and `inner => "zstd"`.

* `App::Yath2::LogArchive::Format`'s multi-format dispatch tables
  collapse to `directory` and `tar.zidx`. `detect_format` croaks
  with a plain "unknown archive format" message on anything else --
  there are no users with archives in deleted formats to migrate
  from.

## Files added

* `lib/Test2/Harness2/Util/Zstd.pm`
* `lib/Test2/Harness2/Util/File/JSON/Zstd.pm`
* `lib/Test2/Harness2/Util/File/JSONL/Zstd.pm`
* `lib/App/Yath2/Options/LogArchive.pm`
* `lib/App/Yath2/LogArchive/TarZIdx.pm` (consolidated; replaces four files)
* `share/other/zstd.dict`
* `author/train_zstd_dict`
* `xt/author/zstd-dict.t`
* `t/AI/unit/Util/Zstd.t`
* `t/AI/unit/Util/File/JSON_Zstd.t`
* `t/AI/unit/Util/File/JSONL_Zstd.t`
* `t/AI/unit/Options/LogArchive.t`
* `t/AI/unit/Harness2/zstd_dict.t`
* `t/AI/integration/extract_zstd.t`
* `t/AI/integration/logdir_all_zstd.t`

## Files deleted

* `lib/App/Yath2/LogArchive/Tar/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/TarGz/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/TarBz2/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/Zip/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/SevenZip/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/Writer/{Tar,SevenZip}.pm`
* `lib/App/Yath2/LogArchive/Writer/Zip/{External,PP}.pm`
* `lib/App/Yath2/LogArchive/TarZIdx/{External,PP,Util}.pm`
* `lib/App/Yath2/LogArchive/Writer/TarZIdx.pm`
* Their tests under `t/AI/unit/LogArchive/`.

## Migration

There is no migration path for legacy multi-format yath archives.
The 2.0 rewrite has no users with such archives. `detect_format`
simply croaks `"unknown archive format"` on anything that is not
`directory` or `tar.zidx`.

For the live logdir shape: pre-spec logdirs (with `.json` /
`.jsonl` plaintext) cannot be read by the new code -- it expects
the `.json.zst` / `.jsonl.zst` extensions and the bundled
`zstd-dict.bin`. This is also a clean cutover for the rewrite.
