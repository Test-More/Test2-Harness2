# Chunk 14 — Split `Test2::Harness2::TestFile`

## Task

Migration chunk 14 (`ARCHITECTURE.md` §1, `TODO_STEPS.md`): separate the
file-reading/decision half of `Test2::Harness2::TestFile` (a UI/input concern)
from the runner-side, file-free state half. Prerequisite for chunk 19 (the
preload-root extraction), which needs a clean serializable per-test state object
to ship to the preload process.

## What changed

- **`App::Yath2::TestFile`** (new) — the reader: file I/O in `init`, header/shbang
  scanning (`_scan`), per-file decisions (`check_category` / `check_duration` /
  `check_stage` / `check_feature` / `rank`), and `queue_item` (produces the task
  payload). This is the old `Test2::Harness2::TestFile` body, repackaged.
- **`App::Yath2::Finder`** (moved from `Test2::Harness2::Finder`) — file gathering.
  It constructs `App::Yath2::TestFile`, so the dependency rule (`Test2::Harness2`
  must not load `App::Yath2*`) requires it to live on the `App::Yath2` side.
- **`Test2::Harness2::TestFile`** (rewritten) — a **state-only** object: a typed,
  read-only view over the task payload (`from_task` / `field` / `TO_JSON` /
  `task_data` + per-field accessors). No file I/O, no scan.
- Consumers repointed: `App::Yath2::RunPlan` (already called `queue_item` on the
  reader), `App::Yath2::Plugin::Notify` (constructs the reader post-run), POD
  references in `App::Yath2::Plugin` / `Test2::Harness2::Plugin` / `Test2::Harness2::Log`,
  and the `--finder` option default/normalize/POD in `App::Yath2::Options::Finder`
  + the auto-generated `--finder` POD in the command modules.
- Tests: reader unit test moved `t/unit/Test2/Harness2/TestFile.t` →
  `t/unit/App/Yath2/TestFile.t`; new state-only unit test
  `t/unit/Test2/Harness2/TestFile.t`; new runner-boundary proof
  `t/AI/unit/runner_no_file_read.t`; `t/AI/unit/Options_Finder.t` and the
  `TestPlugin` fixture updated to the `App::Yath2::Finder` / `App::Yath2::TestFile`
  namespaces.

## Decisions and rejected alternatives

- **The runner keeps consuming the task-payload hash; it was NOT converted to hold
  blessed state objects.** Investigation showed the runner's `State` scheduler treats
  the task as **mutable working state** (`$task->{is_try}++`,
  `$task->{category}='isolation'`, `$task->{resource_skip}=...`, `$task->{stage}=...`,
  `push @{$task->{test_args}}`). Forcing an immutable blessed object into that hot
  path would be high-risk and fight the existing design for no functional gain — the
  runner already reads no test files (it only ever read the payload). So the
  state-only object is the typed, serializable representation at boundaries (and the
  object chunk 19 ships to the preload-root), not a replacement for the scheduler's
  internal hash.
- **`Finder` had to move (not optional).** Keeping `Test2::Harness2::Finder` while it
  constructs `App::Yath2::TestFile` would violate the one-way dependency rule. Moving
  it to `App::Yath2::Finder` is the correct resolution; the `--finder` auto-prefix
  changes from `Test2::Harness2::Finder::` to `App::Yath2::Finder::` as a result
  (a deliberate, user-visible namespace change in the 2.0 split).
- **POD regeneration was done by hand for the `--finder` blocks.** The release POD
  generators are unreliable here: `release-scripts/generate_command_pod.pl` dies on a
  pre-existing missing marker in `Command/do.pm`, and `generate_options_pod.pl`
  re-churns unrelated option POD across many `Options/*` modules. The `--finder` POD
  text is uniform, so it was corrected directly in the 8 command modules +
  `Options/Finder.pm` instead, keeping the chunk's diff scoped to finder changes.

## Architectural note

This does not deviate from `ARCHITECTURE.md` §1; it implements it. No addendum
required. The split is now: reading test files = `App::Yath2` (`Finder` +
`TestFile` reader); runner-side state = `Test2::Harness2::TestFile` (payload view),
consumed by `Test2::Harness2::Runner::Job` via the task payload.
