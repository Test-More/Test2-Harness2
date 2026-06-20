# Migration Chunk 2: App::Yath2::Options → Getopt::Yath

**Date:** 2026-06-12
**Branch:** `2.0d` (foundations override active — commit directly, no worktree)
**Status:** Approved design

## Goal

Replace the in-tree 1.0 option-processing machinery (`App::Yath2::Options`,
`App::Yath2::Option`, `Test2::Harness2::Settings`) with the external
**`Getopt::Yath`** distribution (installed, 2.000008). This is chunk 2 of the
1.0 → 2.0 migration (`TODO_STEPS.md`, `ARCHITECTURE.md` §1.1, §2.3).

## Decisions (user-approved)

1. **Wholesale swap, staged commits.** No coexistence shim, no parallel
   implementation. The machinery is replaced entirely in one chunk, landed as
   reviewable commits. The suite must be green at the end of the sequence;
   intermediate commits need not be runnable.
2. **`Getopt::Yath::Settings` replaces `Test2::Harness2::Settings`.**
   `Test2::Harness2::Settings` and `Settings::Prefix` are deleted. The access
   idiom (`$settings->group->field`) is the same, so read-side consumers
   mostly do not change.
3. **CLI surface: adopt old3 definitions where they improved.** Where
   `reference/old3` restructured an option that exists in the live tree
   (name, alias, normalize, env-var hooks, type), take old3's shape.
   Integration tests are edited only where a flag intentionally changed;
   every such edit is called out in its commit message.

## Donor material

- **`reference/old3/lib/App/Yath2.pm`** — already Getopt::Yath-based; donor
  for the parse flow (config files, two-stage parse, cli_help, dev-libs
  re-exec trigger).
- **`reference/old3/lib/App/Yath2/Options/*.pm`** (22 modules) — donor for
  option *definitions*, but only for options that exist in the live tree.
  The unit of adoption is the **option**, not the old3 module: an old3
  module like `Yath.pm` or `Harness.pm` may donate the improved definition
  of an option the live tree keeps in `PreCommand` or `Debug`. Whole option
  groups for not-yet-migrated subsystems (DB, Server, WebServer, Scheduler,
  the rewritten Renderer, Reloader, IPC/IPCAll, Publish, Recent, Resource)
  do **not** come over — they arrive with chunks 3–8.
- `reference/old2` — secondary reference where old3 is unclear.
- Reference trees are immutable: copy out, adapt the copy.

## Scope

### Rewritten in Getopt::Yath DSL (same file paths)

The 10 live option-group modules under `lib/App/Yath2/Options/`:
Collector, Debug, Display, Finder, Logging, Persist, PreCommand, Run,
Runner, Workspace.

Type map from the 1.0 single-letter types:

| 1.0 | Getopt::Yath |
|-----|--------------|
| `s` | Scalar |
| `b` | Bool |
| `c` | Count |
| `m` | List |
| `h` | Map |
| `D` | AutoPathList (or PathList/Auto as the option's semantics dictate) |
| autofill scalars | Auto |

`option_group {group => ..., category => ...}` wraps each module's options;
`option_post_process` replaces 1.0 `post` callbacks (weight semantics
preserved); `applicable` guards carry over.

### Rewritten consumers

- **`lib/App/Yath2.pm`** — port old3 flow: load config files
  (`.yath.rc` / `.yath.user.rc`), stage-1 global parse
  (`skip_posts`, `stop_at_non_opts`, `skip_invalid_opts`), resolve command,
  include command options, stage-2 parse (`skip_non_opts`, invalid-opt
  callback), apply state modules/env. `cli_help` built on
  `$options->docs('cli')` with `category_sort_map`.
- **`lib/App/Yath2/Command.pm`** + all 24 commands under
  `lib/App/Yath2/Command/` — option declarations in the new DSL
  (`include_options` for shared groups, `option_group` for command-specific
  options). `write_settings_to` uses `Getopt::Yath::Settings->TO_JSON`.
- **`lib/Test2/Harness2/Run.pm`, `Runner.pm`, `Finder.pm`,
  `Runner/State.pm`** — consume `Getopt::Yath::Settings`;
  `settings.json` reads via `FROM_JSON_FILE`.
- **Plugins** `lib/App/Yath2/Plugin/{Git,Cover,YathUI,Notify}.pm`,
  `lib/App/Yath2/Plugin.pm` base, and the `t/lib`, `t2/` fixtures — plugin
  options declared with the same DSL; `-p` / `--plugin` uses
  `mod_adds_options => 1` so loading a plugin pulls in its options
  (old3 pattern).
- **`release-scripts/generate_options_pod.pl`** and
  **`generate_command_pod.pl`** — regenerate POD via `docs('pod')`.

### Deleted (last commit of the sequence)

- `lib/App/Yath2/Options.pm` (935 lines)
- `lib/App/Yath2/Option.pm` (1157 lines)
- `lib/Test2/Harness2/Settings.pm` + `lib/Test2/Harness2/Settings/Prefix.pm`
- `t/unit/App/Yath2/Option.t`, `t/unit/App/Yath2/Options.t` — the machinery
  they test now lives upstream in the Getopt-Yath dist and is tested there.

### Settings serialization

`settings.json` keeps the group→field→value JSON shape. Writer
(`Command.pm`) and all readers swap inside this chunk, so no cross-format
compatibility window exists. Persist-mode (`yath start` workdirs) written by
an old binary is not supported across this boundary — acceptable pre-release.

## Out of scope

- New option groups for chunks 3–8 subsystems.
- Renaming option groups beyond what old3 did to equivalent options.
- `Getopt::Yath` feature work (anything missing upstream gets flagged, not
  forked).

## Style

Rewritten modules count as migrated: `use v5.38;` (ARCHITECTURE §2.6),
`Object::HashBase` where stateful, STYLE_GUIDE eval patterns, POD layout per
STYLE_GUIDE. Pre-review: both `agent_scripts/audit-*` scripts + `podchecker`
on every touched `.pm` (AGENTS.md).

## Testing

- `prove -Ilib -j16 -r t/` green at sequence end (67 files, 984 tests
  baseline).
- `t/unit/App/Yath2/Options/Runner.t` rewritten against the new DSL; other
  unit tests updated as their subjects change.
- Integration tests are the behavioral spec: edits only for intentional
  old3-shape changes, each named in its commit message.

## Commit staging

1. Option-group modules rewritten in Getopt::Yath DSL.
2. `App::Yath2.pm` + `Command.pm` core parse-flow swap, commands migrated.
3. Harness-side consumers (`Test2::Harness2::*`) + settings swap.
4. Plugins, fixtures, unit tests.
5. Delete old machinery; migrate release-scripts; TODO_STEPS.md chunk 2 → ✅.

(Boundaries may shift as work demands; the sequence stays small and ordered.)
