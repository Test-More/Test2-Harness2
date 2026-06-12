# Getopt::Yath Migration (Chunk 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `App::Yath2::Options` / `App::Yath2::Option` / `Test2::Harness2::Settings` with the installed external `Getopt::Yath` (2.000008) dist, per the approved spec `docs/superpowers/specs/2026-06-12-getopt-yath-migration-design.md`.

**Architecture:** Wholesale swap in staged commits. The 10 live option-group modules are rewritten in the Getopt::Yath DSL keeping their live group/prefix layout; old3 improvements adopted at the option level only. The live BEGIN-phase entry model (`App::Yath::Script::V2` + `generate_run_sub` + goto::file optimization) is KEPT; only the parsing machinery inside `App::Yath2.pm` is swapped to old3's two-stage Getopt::Yath flow. The suite must be green at the end of the sequence — intermediate commits may be red.

**Tech Stack:** Perl 5.38+ (`use v5.38;` in every rewritten module), Getopt::Yath 2.000008 (installed), Object::HashBase, prove.

**Key references (read before starting any task):**
- Spec: `docs/superpowers/specs/2026-06-12-getopt-yath-migration-design.md`
- Option inventory (EVERY option + attribute + old3 mapping): `agent_scripts/chunk2-option-inventory.md`
- Donor: `reference/old3/lib/App/Yath2.pm` (parse flow), `reference/old3/lib/App/Yath2/Options/*.pm` (option definitions). Immutable — copy out, adapt.
- Getopt::Yath docs: `perldoc Getopt::Yath`, and source at `/home/exodist/perl5/perlbrew/perls/main/lib/site_perl/5.42.2/Getopt/Yath*`

---

## Global conversion rules

Apply in every task. These are the contract between tasks — do not improvise alternatives.

### R1: Module skeleton

Every rewritten option-group module follows this shape (declaration order: package, use v5.38, our $VERSION, deps, DSL):

```perl
package App::Yath2::Options::Collector;
use v5.38;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'collector', category => "Collector Options"} => sub {
    option max_open_jobs => (
        type        => 'Scalar',
        long_examples  => [' 18'],
        short_examples => [' 18'],
        description => 'Maximum number of jobs the collector can process concurrently',
    );
    # ...
};

1;
```

POD layout per STYLE_GUIDE.md (NAME/DESCRIPTION/SYNOPSIS up top, SOURCE/MAINTAINERS/AUTHORS/COPYRIGHT under `__END__`) — preserve each live file's existing POD text, updated where option names changed.

### R2: Type map (1.0 letter → Getopt::Yath type)

| 1.0 | Getopt::Yath | Notes |
|-----|--------------|-------|
| `b` | `Bool` | |
| `c` | `Count` | |
| `s` | `Scalar` | |
| `m` | `List` | use `split_on => ','` only where old3 does |
| `d` | `Auto` | `autofill` required (Getopt::Yath croaks without it) |
| `D` | `AutoPathList` | for path-ish opts (dev_libs, restrict_reload); plain `AutoList` otherwise |
| `h` | `Map` | |
| `H` | `Map` | values become arrayrefs — follow old3 donor (`Tests.pm` `load_import`, `Renderer.pm` `classes`) for normalize shape |

### R3: Attribute map

| 1.0 attr | Getopt::Yath |
|----------|--------------|
| `prefix => 'x'` | `group => 'x'` on the option_group |
| `env_vars => [...]` | `from_env_vars => [...]` (leading `!` negation supported same way) |
| `clear_env_vars` | `clear_env_vars` (unchanged) |
| `action => sub` | `trigger => sub` — signature differs: `my ($opt, %params) = @_;` with `$params{action}` ('set'/'initialize'/'clear'), `$params{val}`, `$params{ref}`, `$params{settings}`, `$params{group}`, `$params{state}`, `$params{set_from}`. Port body; gate on `$params{action} eq 'set'` where 1.0 action ran on CLI-set only. See old3 `Options/Yath.pm` dev_libs trigger for the idiom. |
| `normalize => sub` | `normalize => sub` (unchanged semantics) |
| `default => sub/scalar` | `default` — but use `initialize` where old3 does (e.g. `run_id` uses `initialize => \&gen_uuid`) |
| `applicable => sub` | `applicable => sub` — signature `($opt, $options)`; port per old3 |
| `post => sub` / standalone `post($weight, $cb)` | `option_post_process $weight, \&cb;` (or `option_post_process $weight, [$applicable], \&cb`). Callback signature: `my ($options, $state) = @_;` settings at `$state->{settings}`. |
| `pre_command => 1` | **dropped** — "pre-command" is now structural: `App::Yath2->options()` includes Debug + PreCommand globally; stage-1 parse handles them before command resolution (Task 9) |
| `adds_options => 1` / `pre_process => sub` | `mod_adds_options => 1` (see old3 `Options/Finder.pm` `class` option and `Options/Yath.pm` `plugins`) |
| `builds => $class` / `ignore_for_build` | **dropped** — was load-time validation only; object construction now via R5 |
| `short_examples`/`long_examples`/`alt`/`short`/`name`/`field`/`category`/`description` | unchanged |

### R4: Settings API swap (consumers)

| Old (`Test2::Harness2::Settings`) | New (`Getopt::Yath::Settings`) |
|---|---|
| `Test2::Harness2::Settings->new($file)` | `Getopt::Yath::Settings->FROM_JSON_FILE($file)` |
| `Test2::Harness2::Settings->new(%groups)` | `Getopt::Yath::Settings->new(%groups)` |
| `$settings->check_prefix('x')` | `$settings->check_group('x')` |
| `$settings->prefix('x')` | `$settings->group('x')` |
| `$settings->define_prefix('x')` | `$settings->group('x', 1)` (vivify) |
| `$prefix->vivify_field('f')` | `$group->option_ref('f', 1)` |
| `$prefix->field('f')` / `$settings->x->f` | `$group->option('f')` / `$settings->x->f` (AUTOLOAD unchanged) |
| `$settings->build(x => $class, @args)` | `$class->new($settings->x->all, @args)` |
| `$settings->TO_JSON` | `$settings->TO_JSON` (unchanged) |

### R5: Group layout is FROZEN

Live groups stay: `collector`, `debug`, `display`, `formatter`, `finder`, `logging`, `runner`, `harness` (PreCommand), `run`, `workspace`. old3 moved options into `renderer`/`term`/`tests`/`resource`/`preload` groups — those moves belong to chunks 5–7 and are NOT adopted. Adopt old3 only at option level: types, normalize/trigger bodies, env-var hooks, plural renames with singular `alt` (e.g. `exclude_file` → `exclude_files` + `alt => ['exclude-file']`), Auto/BoolMap restructures within the same group.

### R6: Per-task verification

Every module task ends with `perl -Ilib -c <file>` clean (plus listed unit tests where they exist). Full-suite green is required only at Task 14. Commit after each task with the message given in the task.

---

## Task 0: Baseline

**Files:** none modified.

- [ ] **Step 0.1:** Run `git log --oneline -1` — record HEAD.
- [ ] **Step 0.2:** Run `prove -Ilib -j16 -r t/ 2>&1 | tail -3`. Expected: `Files=67, Tests=984 ... Result: PASS`. If not green, STOP and report.

## Task 1: Convert `Options/Collector.pm` (template task)

**Files:**
- Modify: `lib/App/Yath2/Options/Collector.pm` (rewrite)

This is the smallest module (2 options + 1 post) — its diff is the template every later group task follows.

- [ ] **Step 1.1:** Read live `lib/App/Yath2/Options/Collector.pm` fully. Inventory section: "Collector.pm". No old3 equivalent exists (inventory §5) — pure mechanical conversion.
- [ ] **Step 1.2:** Rewrite the file:

```perl
package App::Yath2::Options::Collector;
use v5.38;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'collector', category => "Collector Options"} => sub {
    option max_open_jobs => (
        type           => 'Scalar',
        long_examples  => [' 18'],
        short_examples => [' 18'],
        description    => "Maximum number of jobs a collector can process at a time, opening more than this will delay collection of jobs that exceed the limit.",
    );

    option max_poll_events => (
        type           => 'Scalar',
        default        => 1000,
        long_examples  => [' 1000'],
        short_examples => [' 1000'],
        description    => "Maximum number of events to poll from a job before jumping to the next job.",
    );
};

option_post_process 0 => sub {
    my ($options, $state) = @_;
    my $settings  = $state->{settings};
    my $collector = $settings->collector;

    return if defined $collector->max_open_jobs;

    my $max_open = 8;
    if ($settings->check_group('runner')) {
        my $job_count = $settings->runner->job_count // 1;
        $max_open = 2 * $job_count if 2 * $job_count > $max_open;
    }

    $collector->create_option(max_open_jobs => $max_open);
};

1;
```

**Port the real `collector_post` body from the live file** — the sub above shows the structure (settings access via `$state->{settings}`, `create_option` for defaulting); the live callback's exact logic and numbers win where they differ. Keep the live file's POD (NAME/DESCRIPTION + standard tail).

- [ ] **Step 1.3:** Run `perl -Ilib -c lib/App/Yath2/Options/Collector.pm`. Expected: syntax OK (Getopt::Yath is installed; no t2clib needed).
- [ ] **Step 1.4:** Run `perl -Ilib -e 'use App::Yath2::Options::Collector; my $i = App::Yath2::Options::Collector->options; print ref($i), "\n"'`. Expected: `Getopt::Yath::Instance`.
- [ ] **Step 1.5:** Commit:

```bash
git add lib/App/Yath2/Options/Collector.pm
git commit -m "refactor(options): convert Options::Collector to Getopt::Yath"
```

## Task 2: Convert `Workspace.pm`, `Persist.pm`, `Logging.pm`

**Files:**
- Modify: `lib/App/Yath2/Options/Workspace.pm`, `lib/App/Yath2/Options/Persist.pm`, `lib/App/Yath2/Options/Logging.pm`

- [ ] **Step 2.1:** For each file: read the live file, the inventory section, and the old3 donor (`reference/old3/lib/App/Yath2/Options/Workspace.pm`, `Log.pm`; Persist has no donor). Convert per R1–R5. Specifics:
  - **Workspace:** keep live group `workspace` and live `tmp_dir` env-var READ list (`from_env_vars`); adopt old3's `tmpdir` alt spelling. Keep live workdir post (create/clear dir honoring `debug->keep_dirs` + command `always_keep_dir`) — old3's instance-uuid workdir default depends on later-chunk architecture; do not adopt.
  - **Persist:** 1 option (`daemon`), no donor, mechanical.
  - **Logging:** keep live options incl. `log_file_format`, `bzip2`, `gzip` (old3 replaced them with zstd `compress` — that belongs to the collector swap, chunk 3); adopt nothing structural. Port the post (conflict check, log-implies, filename build) as `option_post_process 0`.
- [ ] **Step 2.2:** `perl -Ilib -c` each of the three files. Expected: syntax OK ×3.
- [ ] **Step 2.3:** Commit:

```bash
git add lib/App/Yath2/Options/Workspace.pm lib/App/Yath2/Options/Persist.pm lib/App/Yath2/Options/Logging.pm
git commit -m "refactor(options): convert Workspace, Persist, Logging option groups to Getopt::Yath"
```

## Task 3: Convert `Debug.pm`

**Files:**
- Modify: `lib/App/Yath2/Options/Debug.pm`

- [ ] **Step 3.1:** Read live file + inventory "Debug.pm" + old3 donors `Yath.pm` (show-opts, version, help) and `Harness.pm` (dummy, procname_prefix).
- [ ] **Step 3.2:** Convert per rules. Specifics:
  - Adopt old3's **Auto** type for `show-opts` (`--show-opts=group`) and `help` (`--help=Group`) — definition improvements within the live `debug` group. `version` stays Bool.
  - `summary` (1.0 `d`) → `Auto` with live normalize/action(→trigger); keep its `applicable` (true only when Options::Run is included — port the live check against `$options->included`; Getopt::Yath applicable signature `($opt, $options)`).
  - The four POSTs keep their weights exactly: 99999 show-opts, 99998 interactive, 0 version, 0 help. Port bodies as-is (print/exit side effects), settings access per R4.
  - `interactive` stays here (old3 moved it to run — group move, not adopted).
- [ ] **Step 3.3:** `perl -Ilib -c lib/App/Yath2/Options/Debug.pm`. Expected: syntax OK.
- [ ] **Step 3.4:** Commit: `git commit -am "refactor(options): convert Options::Debug to Getopt::Yath"`

## Task 4: Convert `Display.pm` (two groups)

**Files:**
- Modify: `lib/App/Yath2/Options/Display.pm`

- [ ] **Step 4.1:** Read live file + inventory "Display.pm". old3 donor `Term.pm` for color/term_width/progress idioms only (env wiring: adopt `from_env_vars`/`set_env_vars` for `term_width` ↔ `TABLE_TERM_SIZE` replacing the live action; adopt `YATH_COLOR` env read on `color`).
- [ ] **Step 4.2:** Convert both groups in the file — `display` and `formatter` — each its own `option_group` block. `renderers` (1.0 `H`) → `Map` following old3 `Renderer.pm` `classes` normalize shape, but KEEP live name `renderers`, alt `renderer`, group `display`, and the live trigger body (prepend `Test2::Harness2::Renderer::`, require module). Posts: weight 100 (renderer/quiet logic) and 90 (formatter defaults) — port bodies, same weights.
- [ ] **Step 4.3:** `perl -Ilib -c lib/App/Yath2/Options/Display.pm`. Expected: syntax OK.
- [ ] **Step 4.4:** Commit: `git commit -am "refactor(options): convert Options::Display to Getopt::Yath"`

## Task 5: Convert `PreCommand.pm`

**Files:**
- Modify: `lib/App/Yath2/Options/PreCommand.pm`

- [ ] **Step 5.1:** Read live file + inventory "PreCommand.pm" + old3 `Yath.pm` (plugins, dev_libs — the two hard options).
- [ ] **Step 5.2:** Convert; group stays `harness`. Specifics:
  - `plugins`: keep live type List(`m`)+short `p`+alt `plugin`; adopt old3's `mod_adds_options => 1` + normalize (`fqmod` to `App::Yath2::Plugin::`) replacing the live `plugin_action`. Plugin options then load via the module-add mechanism instead of inside an action.
  - `dev_libs`: type `AutoPathList`; port the LIVE action body as trigger (dedupe + unshift @INC + warn-late). Do NOT adopt old3's exec-self re-exec trigger — live `Script::V2` pre-parses `-D` in BEGIN, so re-exec is unnecessary (deviation from spec's "dev-libs re-exec trigger" wording; record in commit message).
  - `no_scan_plugins`: keep live Bool (old3's `scan_options` BoolMap covers later-chunk needs).
  - `pre_command => 1` attrs dropped per R3 (structural now).
- [ ] **Step 5.3:** `perl -Ilib -c lib/App/Yath2/Options/PreCommand.pm`. Expected: syntax OK.
- [ ] **Step 5.4:** Commit: `git commit -am "refactor(options): convert Options::PreCommand to Getopt::Yath"`

## Task 6: Convert `Run.pm`

**Files:**
- Modify: `lib/App/Yath2/Options/Run.pm`

- [ ] **Step 6.1:** Read live file + inventory "Run.pm" + old3 donors `Run.pm` and `Tests.pm` (for option-level definitions only — everything stays in live group `run`).
- [ ] **Step 6.2:** Convert. Specifics:
  - `run_id`: `initialize => \&gen_uuid` (old3 idiom) instead of `default`.
  - `tap`/`use_stream` pair: adopt old3's single option with `alt_no` if Getopt::Yath::Option supports it (check `perldoc Getopt::Yath::Option`; old3 `Tests.pm` uses `alt_no => ['TAP']`); else port the live two-option normalize trick verbatim.
  - `fields`: port live `fields_action` as trigger (JSON or name:details parse).
  - `load_import` (1.0 `H`) → `Map` per old3 `Tests.pm` `load_import` shape.
  - `env_var` field `env_vars` → `Map`, short `E`.
  - Posts: author_testing env + dbi_profiling injection, weight 0.
- [ ] **Step 6.3:** `perl -Ilib -c lib/App/Yath2/Options/Run.pm`. Expected: syntax OK.
- [ ] **Step 6.4:** Commit: `git commit -am "refactor(options): convert Options::Run to Getopt::Yath"`

## Task 7: Convert `Runner.pm`

**Files:**
- Modify: `lib/App/Yath2/Options/Runner.pm`

- [ ] **Step 7.1:** Read live file + inventory "Runner.pm" + old3 `Tests.pm`/`Resource.pm` for definition idioms (`use_fork` env list, `cover` Auto + `T2_DEVEL_COVER` env wiring, `job_count` j:x trigger).
- [ ] **Step 7.2:** Convert; all 23 options stay in group `runner`. Specifics:
  - `job_count`: keep short `j` + alt `jobs` + env list + `clear_env_vars`; port the j:x split action as trigger (sets `slots_per_job`, calls `fix_job_resources` helper — keep the helper sub in this module).
  - `cover` (1.0 `d`) → `Auto` with old3's autofill string + adopt `from_env_vars`/`set_env_vars` for `T2_DEVEL_COVER`; keep the live `cover_post_process` (weight 0) for the fork/load_import side effects.
  - `lib`/`blib`/`tlib` triggers port the live include-juggling actions.
  - `resources`: List + live normalize (prepend `Test2::Harness2::Runner::Resource::` unless `+`).
- [ ] **Step 7.3:** `perl -Ilib -c lib/App/Yath2/Options/Runner.pm`. Expected: syntax OK.
- [ ] **Step 7.4:** Commit: `git commit -am "refactor(options): convert Options::Runner to Getopt::Yath"`

## Task 8: Convert `Finder.pm` (largest, 34 options)

**Files:**
- Modify: `lib/App/Yath2/Options/Finder.pm`

- [ ] **Step 8.1:** Read live file + inventory "Finder.pm" + old3 `Finder.pm` (closest 1:1 donor of all groups).
- [ ] **Step 8.2:** Convert. Adoptions from old3 (all within group `finder`):
  - `finder` option: old3 shape — `name => 'finder', field => 'class'`... **NO.** Keep live field `finder` (live consumers call `$settings->finder->finder`; field rename would ripple — old3's `class` field is rejected). Keep `mod_adds_options => 1` + normalize `fqmod 'Test2::Harness2::Finder'`.
  - Plural renames WITH singular alts: `extension`→`extensions` (alt `ext`, `extension`), `exclude_file`→`exclude_files`, `exclude_pattern`→`exclude_patterns`, `exclude_list`→`exclude_lists`, `changes_exclude_file`→`changes_exclude_files`, `changes_exclude_pattern`→`changes_exclude_patterns`, `changes_filter_file`→`changes_filter_files`, `changes_filter_pattern`→`changes_filter_patterns`, `rerun_plugin`→`rerun_plugins`. Field = new plural name. **These are intentional CLI/settings changes — list each in the commit message; Task 13 fixes consumers/tests.**
  - `rerun_modes` + the five generated `rerun_all/failed/retried/passed/missed`: adopt old3's **BoolMap restructure** (pattern `qr/rerun-($modes)(=.+)?/` + `custom_matches` + trigger; see old3 Finder.pm) replacing six live options with one. `--rerun-failed[=log]` CLI surface is preserved by the pattern.
  - `extensions` gets `split_on => ','` + inline default `['t','t2']` per old3; trim the post accordingly.
  - Keep the live post (weight 0) for: rerun folding (now simpler — only `rerun` + `rerun_modes`), `durations_threshold` default (live j+1 semantics, not old3's 0), `default_search`/`default_at_search` defaults, leading-dot strip.
  - `changed`/`changes_*` keep live `applicable` (false for `projects` command) — port the check.
- [ ] **Step 8.3:** `perl -Ilib -c lib/App/Yath2/Options/Finder.pm`. Expected: syntax OK.
- [ ] **Step 8.4:** Commit:

```bash
git add lib/App/Yath2/Options/Finder.pm
git commit -m "refactor(options): convert Options::Finder to Getopt::Yath

Intentional CLI/settings renames (old3 adoptions, singular kept as alt):
extensions, exclude_files, exclude_patterns, exclude_lists,
changes_exclude_files, changes_exclude_patterns, changes_filter_files,
changes_filter_patterns, rerun_plugins. rerun_all/failed/retried/passed/
missed folded into the rerun-modes BoolMap (CLI flags unchanged)."
```

## Task 9: Core swap — `App::Yath2.pm`, `Script/V2.pm`, `Command.pm`

**Files:**
- Modify: `lib/App/Yath2.pm`, `lib/App/Yath/Script/V2.pm`, `lib/App/Yath2/Command.pm`

The hard task. Donor: `reference/old3/lib/App/Yath2.pm` lines 268-284 (options construction), 307-358 (stage parsing), 379-461 (load_command, process_args, config), 492-541 (_resolve_command). KEEP the live entry model: `Script::V2::do_begin` BEGIN-phase + `generate_run_sub` + goto::file. Old3's `run()`-method model and Role::Command are NOT adopted.

- [ ] **Step 9.1:** Read live `lib/App/Yath2.pm`, `lib/App/Yath/Script/V2.pm`, `lib/App/Yath2/Command.pm` fully, plus the old3 donor sections above.
- [ ] **Step 9.2:** Rewrite `App::Yath2.pm` internals:
  - `use Getopt::Yath();` + `use Getopt::Yath::Settings;`
  - `options()` — lazy `Getopt::Yath::Instance->new(category_sort_map => {...})` (port old3 lines 273-279, adjust categories to live names), then `$instance->include(App::Yath2::Options::Debug->options)` and `(App::Yath2::Options::PreCommand->options)` — these replace `load_options()`'s hardwired pre-command includes. Keep the plugin/resource module scan (live lines 126-150) — for each scanned module with `can('options')`, validate `ref($lib->options) eq 'Getopt::Yath::Instance'` and `$instance->include($lib->options)`.
  - `process_argv()` — replace grab/process calls with old3 two-stage flow:
    1. stage-1: `$options->process_args($argv, settings => $settings, skip_posts => 1, stop_at_non_opts => 1, skip_invalid_opts => 1, stops => ['--', '::'])` (old3 `_process_global_args`)
    2. command resolution: port live `_command_from_argv` semantics (`-h`/`--help`→help, `do` splice, `::` stop, registered-command check, file/dir→default, persistent-runner→run else test) against the stage-1 `stop`/`remains` state, old3 `_resolve_command` as structural guide
    3. `load_command($cmd)` → `$options->include($cmd_class->options)` when the class `can('options')` (old3 line 397)
    4. stage-2: config-file command-section args + remaining args through `$options->process_args(..., skip_non_opts => 1, invalid_opt_callback => sub { ... exit 255 })` (old3 `_process_command_args`), posts run here
    5. plugin accumulation: from the parse state's loaded-modules tracking (old3 `_apply_state_modules`, lines 572-586) into `$settings->harness->plugins`
  - Config files: keep live `%CONFIG` hash handoff from Script::V2 (BEGIN-phase parse stays); feed `config->{'~'}` args before stage-1 and `config->{$cmd}` args into stage-2, replacing the `grab_pre_command_opts(args => ...)` calls.
  - `init()` settings seeding (live lines 40-48): `define_prefix`/`vivify_field` → R4 equivalents on a `Getopt::Yath::Settings` instance.
- [ ] **Step 9.3:** Update `Script/V2.pm`: the `CREATE_APP` section builds `Getopt::Yath::Settings` (`create_group(harness => {...})` with the same seed fields, live lines 198-213). The TESTABLE-CODE markers in the file are extracted by `t/yath_script.t` — keep marker structure intact.
- [ ] **Step 9.4:** Update `Command.pm` base:
  - Remove `use App::Yath2::Options()`; class-method `options()` contract: commands that declare/include options get a Getopt::Yath instance via `use Getopt::Yath;` in their own package; base provides `sub options { undef }` fallback (help.pm's empty-options behavior becomes the base default).
  - `cli_help()`/`generate_pod()`: replace `pre_docs`/`cmd_docs` with `$options->docs('cli', settings => ..., color => ...)` / `$options->docs('pod', head => 3)`. Global (Debug/PreCommand) vs command options render via the instance's category grouping — port old3 `App::Yath2.pm` `cli_help` (lines 79-114 in the old3 file).
  - `write_settings_to()`: body becomes `Test2::Harness2::Util::File::JSON->new(name => $path)->write($settings->TO_JSON)` (shape unchanged).
- [ ] **Step 9.5:** Run `perl -Ilib -c lib/App/Yath2.pm && perl -Ilib -c lib/App/Yath/Script/V2.pm && perl -Ilib -c lib/App/Yath2/Command.pm`. Expected: syntax OK ×3 (commands themselves still unconverted — full run not expected to work yet).
- [ ] **Step 9.6:** Commit: `git commit -am "refactor(core): swap App::Yath2 parse flow to Getopt::Yath two-stage processing"`

## Task 10: Convert commands

**Files:**
- Modify: `lib/App/Yath2/Command/{test,run,spawn,start,failed,speedtag,replay,resources,times,status,help,projects,...}.pm` (all 24; only test/run/spawn/start/failed/speedtag/replay/resources/times declare or include options — inventory §3)

- [ ] **Step 10.1:** For each command with includes (inventory §3): replace `use App::Yath2::Options; include_options(...)` style with `use Getopt::Yath; include_options('App::Yath2::Options::Debug', ...)` — same module lists as inventory. Commands with own options convert them per R1–R3 keeping their live groups (`run`, `spawn`, `runner` for start, `display` for failed's brief, `speedtag`).
- [ ] **Step 10.2:** Inheritance-based option sharing (projects←test, status/stop/abort/kill/ps←run): Getopt::Yath instances are per-package. Give each child that relied on inheritance an explicit `use Getopt::Yath; include_options('App::Yath2::Command::test');` (instance include from parent command class — verify `include_options` accepts a command class re-exporting `options()`; it does, same mechanism as option modules).
  - `help.pm`: delete its `sub options {}` — base default now covers it.
- [ ] **Step 10.3:** Settings access sites inside commands: apply R4 (`check_prefix`→`check_group`, `$settings->build(run => 'Test2::Harness2::Run')` → `Test2::Harness2::Run->new($settings->run->all)`, `$settings->build(finder => ...)` likewise in `test.pm:494,540`).
- [ ] **Step 10.4:** `for f in lib/App/Yath2/Command/*.pm; do perl -Ilib -c $f || echo "FAIL $f"; done`. Expected: all syntax OK.
- [ ] **Step 10.5:** Smoke: `perl -Ilib scripts/yath help 2>&1 | head -20` (if `scripts/yath` absent, `perl -Ilib -MApp::Yath::Script::V2 -e1`). Expected: help output or clean load, no croak from option machinery.
- [ ] **Step 10.6:** Commit: `git commit -am "refactor(commands): convert command option declarations to Getopt::Yath"`

## Task 11: Harness-side consumers

**Files:**
- Modify: `lib/Test2/Harness2/Run.pm`, `Runner.pm`, `Finder.pm`, `Runner/State.pm`, `Runner/Job.pm`, `Runner/Resource.pm`, `Renderer.pm`, `Plugin.pm`, `Log/CoverageAggregator/{ByRun,ByTest}.pm`, `lib/App/Yath2/Util.pm`, `lib/App/Yath2/Command/{collector,runner}.pm`

- [ ] **Step 11.1:** `grep -rln 'Test2::Harness2::Settings\|check_prefix\|define_prefix\|->build(' lib/` — for every hit apply R4. Known sites: `Runner/State.pm:97` (`->new($file)` → `FROM_JSON_FILE`), `Plugin.pm:33,70`, `CoverageAggregator/{ByRun,ByTest}.pm`, `Finder.pm:578`, plus `use` lines.
- [ ] **Step 11.2:** Finder consumers of renamed fields (Task 8): `grep -rn 'extensions\?\|exclude_file\|exclude_pattern\|exclude_list\|rerun_plugin\|rerun_all\|rerun_failed\|rerun_missed\|rerun_passed\|rerun_retried' lib/Test2/Harness2/Finder.pm lib/App/Yath2/` — update field reads to the plural names and the folded rerun/rerun_modes shape.
- [ ] **Step 11.3:** `for f in $(grep -rln 'Getopt::Yath::Settings\|check_group' lib/); do perl -Ilib -c $f || echo "FAIL $f"; done`. Expected: all OK.
- [ ] **Step 11.4:** Commit: `git commit -am "refactor(harness): consume Getopt::Yath::Settings throughout Test2::Harness2"`

## Task 12: Plugins + fixtures

**Files:**
- Modify: `lib/App/Yath2/Plugin.pm` (POD only — option docs), `lib/App/Yath2/Plugin/{Git,Cover,YathUI,Notify}.pm`, `t/lib/App/Yath2/Plugin/Options.pm`, `t/lib/App/Yath2/Command/fake.pm`

- [ ] **Step 12.1:** Convert each per R1–R3 and inventory §4. Groups stay (`git`, `cover`, `yathui`, `notify`, `testplugin`, `fake`). Notify's group-level `applicable` goes on its option_group common hash + the post's applicable arg. YathUI weight -1 post, Notify weight 0 post, Cover weight 0 post — weights preserved. `applicable` checks against included option modules port to `$options->included` equivalents (`Getopt::Yath::Instance` tracks included modules — check `modules`/`included` in the Instance source; use what old3's `can_finder`-style subs use).
- [ ] **Step 12.2:** `perl -Ilib -c` each, plus `perl -Ilib -It/lib -c t/lib/App/Yath2/Plugin/Options.pm` and `.../fake.pm`. Expected: all OK.
- [ ] **Step 12.3:** Commit: `git commit -am "refactor(plugins): convert plugin option declarations to Getopt::Yath"`

## Task 13: Tests

**Files:**
- Delete: `t/unit/App/Yath2/Option.t`, `t/unit/App/Yath2/Options.t`, `t/unit/Test2/Harness2/Settings.t`, `t/unit/Test2/Harness2/Settings/Prefix.t`
- Modify: `t/unit/App/Yath2/Options/Runner.t`, `t/unit/App/Yath2.t`, `t/yath_script.t` (if seed-shape assertions changed), `t/unit/Test2/Harness2/Runner/Job.t`, `t/unit/App/Yath2/Plugin/Git.t`, `t/integration/*` as failures dictate

- [ ] **Step 13.1:** `git rm` the four machinery test files (their subjects now live upstream in Getopt-Yath / are deleted in Task 14).
- [ ] **Step 13.2:** Rewrite `t/unit/App/Yath2/Options/Runner.t` against the new DSL: build settings via `App::Yath2::Options::Runner->options->process_args([...], settings => Getopt::Yath::Settings->new)` and assert the same behavioral expectations the old test had (job_count j:x split, env defaults, includes juggling).
- [ ] **Step 13.3:** Run `prove -Ilib -j16 -r t/unit/ 2>&1 | tail -5`; fix failures (most will be settings-construction in test setup — apply R4). Then `prove -Ilib -j16 -r t/ 2>&1 | tail -5`; integration failures are either (a) bugs — fix the code, or (b) intentional Task-8 renames — update the test and record the test path in the commit message.
- [ ] **Step 13.4:** Commit: `git commit -am "test: update suite for Getopt::Yath machinery"` (list intentional-rename test edits in body).

## Task 14: Delete old machinery, release-scripts, docs, final verification

**Files:**
- Delete: `lib/App/Yath2/Options.pm`, `lib/App/Yath2/Option.pm`, `lib/Test2/Harness2/Settings.pm`, `lib/Test2/Harness2/Settings/Prefix.pm`
- Modify: `release-scripts/generate_options_pod.pl`, `release-scripts/generate_command_pod.pl`, `MIGRATION.md`, `ARCHITECTURE.md` (§2.3 tag)

- [ ] **Step 14.1:** `grep -rn 'App::Yath2::Options\b\|App::Yath2::Option\b\|Test2::Harness2::Settings' lib/ t/ t2/ release-scripts/` — expected: only the four to-be-deleted files + release-scripts. Fix any straggler first.
- [ ] **Step 14.2:** `git rm` the four modules.
- [ ] **Step 14.3:** Update release-scripts: `generate_options_pod.pl` `pre_docs('pod',3)`/`cmd_docs('pod',3)` → `$class->options->docs('pod', head => 3)`; `generate_command_pod.pl` keeps calling `$pkg->generate_pod()` (already swapped in Task 9). Run both against `./lib` and eyeball one regenerated POD block.
- [ ] **Step 14.4:** Full suite: `prove -Ilib -j16 -r t/ 2>&1 | tail -3`. Expected: PASS. Fix until green.
- [ ] **Step 14.5:** Pre-review gates (AGENTS.md): `perl agent_scripts/audit-methods-not-functions lib`, `perl agent_scripts/audit-readonly-attrs lib`, `podchecker` on every touched `.pm`. All hits are hard stops — resolve, re-run suite if code changed.
- [ ] **Step 14.6:** Docs: MIGRATION.md — chunk 2 → ✅ with commit refs, update "Current state" + "Next" (chunk 3); ARCHITECTURE.md §2.3 — `[target]` → done (drop the "until then" sentence, retag section, note Getopt::Yath live).
- [ ] **Step 14.7:** Commit: `git commit -am "refactor!: complete Getopt::Yath migration, remove 1.0 option machinery"`

---

## Self-review notes

- Spec coverage: groups (T1–T8), core flow (T9), commands (T10), harness consumers (T11), plugins (T12), tests (T13), deletion + release-scripts + MIGRATION/ARCHITECTURE flip (T14). Settings-serialization compat: R4 + T9.4 + T11.1. Out-of-scope guard: R5.
- Known judgment calls executors must respect: live entry model kept (T9 preamble); no old3 group moves (R5); finder field `finder` NOT renamed to `class` (T8.2); dev-libs re-exec not adopted (T5.2).
- `alt_no` (T6.2) flagged as verify-against-installed-Getopt::Yath; fallback given.
