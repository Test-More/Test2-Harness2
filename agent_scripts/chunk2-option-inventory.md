# Chunk 2: Option Inventory (live lib/App/Yath2 vs reference/old3)

Generated 2026-06-12 from /home/exodist/projects/Test2/Test2-Harness.

Legend for option lines:
`- <name> | type=<x> | <attr>=<val> ... | desc: <short>`
Only attributes actually passed to option() are listed. `CODE` = coderef (named sub noted where applicable). `POST weight=<n>` = post() callback registered in the same group.

## Section 1: DSL exports

`lib/App/Yath2/Options.pm` (`App::Yath2::Options`) installs its DSL via a custom `import()`. On `use App::Yath2::Options;` it croaks if the caller already defines `options`, then installs **five subs into the caller's package** (closures over a lazily-created per-package `App::Yath2::Options` instance):

- `options()` — returns (vivifying on first use) the package-level Options instance.
- `option(TITLE => %FIELDS)` / `option("title=type")` / `option(title, type)` — creates an `App::Yath2::Option` (with `trace => [caller()]`, merged with the innermost option_group common fields) and adds it via `include_option`. Caller-context parsing (`_parse_option_caller`) derives `prefix`/`from_command`/`from_plugin`: commands and `App::Yath2` are "top-level"; `App::Yath2::Plugin::X` callers get plugin prefix defaulting and name gets `PREFIX-` prepended.
- `option_group(\%COMMON, sub{...})` — pushes %COMMON (merged with any enclosing group) onto a stack for the duration of the sub; if common contains `builds => $class` the class is required immediately.
- `post([$weight,] [$applicable,] sub{...})` — registers a post-processing callback `[$weight // 0, $applicable // group's applicable, $cb]`; run sorted by ascending weight in `process_option_post_actions`.
- `include_options(@CLASSES)` (`include_from`) — requires each class, calls its `options()` and merges all options + post_list into this instance; tracks in `included` hash.

Other key Options instance machinery: `set_command_class` (also `include_from($cmd_class)`), `grab_pre_command_opts` (stop_at_non_opt + passthrough), `grab_command_opts`, `process_*_opts`, `populate_pre_defaults`/`populate_cmd_defaults`, `clear_env`, `pre_docs`/`cmd_docs` ('cli'/'pod'), `set_by_cli` tracking, `used_plugins`. `--no-X` long args route to `handle_negation`. Pre-command options are also re-offered to commands (`_command_options` = cmd_list + pre_list, filtered by `applicable`).

### App::Yath2::Option attribute keys (HashBase slots)

From `lib/App/Yath2/Option.pm`:

```
title, field, name, type, trace, ignore_for_build,
prefix, short, alt,
pre_command, from_plugin, from_command,
pre_process, adds_options,
default, normalize, action, negate, autofill,
env_vars, clear_env_vars,
applicable (private slot + applicable() method),
builds, category, description, short_examples, long_examples
```

Validation in `init()`:
- Requires `title` OR both `field` and `name`; `prefix` is required; `alt` must be arrayref.
- `field` derived from title with `-`→`_`; `name` with `_`→`-` (plugin options get `prefix-` prepended to name).
- `builds` class must `can($field)` unless `ignore_for_build`.
- `type` defaults to `'b'`; long aliases canonicalized (bool/boolean→b, count/counter/counting→c, scalar/string/number→s, multi/multiple/list/array→m, default/def→d, multi-def/multiple-default/list-default/array-default→D, hash→h, hash-list→H). Valid types: `b c s m d D h H`.
- `autofill` defaults to 1 for d/D; fatal for other types.
- `default` must be scalar or coderef; `normalize`/`action` must be coderefs.
- `trace` defaults to caller(1); `category` defaults to 'NO CATEGORY - FIX ME'; `description` defaults to 'NO DESCRIPTION - FIX ME'.
- Any hash key without a matching uppercase constant is fatal ("not a valid option attribute").

Type behavior: requires_arg: s,m,h,H; allows_arg additionally d,D. Defaults when unset: b/c→0, m/D→[], h/H→{}, else undef; env_vars consulted first (leading `!` negates). h/H handlers maintain insertion-order key list under `'@'`.

## Section 2: Option groups

### lib/App/Yath2/Options/Collector.pm — prefix `collector`, category "Collector Options"
- max_open_jobs | type=s | long_examples=[' 18'] | short_examples=[' 18'] | desc: max jobs collector processes concurrently
- max_poll_events | type=s | default=1000 | long_examples=[' 1000'] | short_examples=[' 1000'] | desc: max events polled per job
- POST weight=0 (`\&collector_post`: defaults max_open_jobs to 2 * runner job_count)

### lib/App/Yath2/Options/Debug.pm — prefix `debug`, category "Help and Debugging"
- POST weight=99999 (`_post_process_show_opts`: print settings JSON, exit)
- POST weight=99998 (`_post_process_interactive`: fifo + fork stdin forwarder, forces quiet=0/verbose>=1/qvf=0, sets YATH_INTERACTIVE)
- POST weight=0 (`_post_process_version`: print version table, exit)
- POST weight=0 (`_post_process_help`: print cli help via IO::Pager, exit)
- dummy | type=b(default) | short=d | env=T2_HARNESS_DUMMY | clear_env_vars=1 | default=0 | desc: dummy run, execute nothing
- procname_prefix | type=s | default='' | desc: prefix for ps proc names
- keep_dirs | type=b | short=k | alt=[keep_dir] | default=0 | desc: do not delete work dirs
- show-opts | type=b | pre_command=1 | desc: exit showing parsed options
- version | type=b | short=V | pre_command=1 | desc: exit showing version info
- help | type=b | short=h | desc: exit showing help
- interactive | type=b | short=i | desc: interactive mode, stdin forwarded
- summary | type=d | long_examples=['', '=/path/to/summary.json'] | normalize=CODE(normalize_summary) | action=CODE(summary_action) | applicable=CODE(true only if Options::Run included) | desc: write summary json file

### lib/App/Yath2/Options/Display.pm — prefix `display`, category "Display Options"
- color | type=b | default=CODE(-t STDOUT) | desc: turn color on
- quiet | type=c | short=q | default=0 | desc: be very quiet
- verbose | type=c | short=v | default=0 | desc: be more verbose
- no_wrap | type=b | default=0 | desc: disable fancy text-wrapping
- no_final_table | type=b | default=0 | desc: no table for final results
- show_times | type=b | short=T | desc: show per-job timing data
- hide_runner_output | type=b | default=0 | desc: hide runner output
- truncate_runner_output | type=b | default=0 | desc: only show post-command runner output
- term_width | type=s | alt=[term-size] | long_examples=[' 80', ' 200'] | action=CODE(sets $ENV{TABLE_TERM_SIZE}) | desc: override terminal width detection
- progress | type=b | default=CODE(-t STDOUT) | desc: toggle progress indicators
- renderers | type=H | alt=[renderer] | long_examples/short_examples=[' +My::Renderer', ' Renderer=arg1,arg2,...'] | action=CODE(prepends Test2::Harness2::Renderer::, requires module, handler) | desc: specify renderer classes
- POST weight=100 (quiet/verbose conflict check; quiet drops Formatter renderer; otherwise injects Test2::Harness2::Renderer::Formatter with args from formatter+display settings)

Second group in same file — prefix `formatter`, category "Formatter Options":
- formatter | type=s | desc: formatter class (no description attr; default category text)
- qvf | type=b | desc: quiet but verbose-on-failure
- show_job_end | type=b | default=1 | desc: show output at job end
- show_job_info | type=b | default=0 | desc: show job config at start
- show_job_launch | type=b | default=0 | desc: show job launch output
- show_run_info | type=b | default=0 | desc: show run config at start
- POST weight=90 (formatter defaults to QVF/Test2 from qvf; -v sets show_job_launch, -vv sets show_job_info+show_run_info)

### lib/App/Yath2/Options/Finder.pm — prefix `finder`, category "Finder Options", builds `Test2::Harness2::Finder`
- finder | type=s | default='Test2::Harness2::Finder' | long_examples=[' MyFinder', ' +Test2::Harness2::Finder::MyFinder'] | pre_command=1 | adds_options=1 | pre_process=CODE(finder_pre_process: load class, include its options) | action=CODE(finder_action: normalize class, populate defaults, munge_settings) | builds=undef | desc: Finder subclass to use
- extension | type=m | field=extensions | alt=[ext] | desc: valid test filename extensions
- search | type=m | desc: tests/dirs to search (positional equivalent)
- no_long | type=b | desc: skip LONG duration tests
- only_long | type=b | desc: only LONG duration tests
- show_changed_files | type=b | applicable=CODE(changes_applicable: false for projects command) | desc: print changed files list
- changed_only | type=b | applicable=CODE(changes_applicable) | desc: only tests for changed files
- rerun | type=d | long_examples=['', '=path/to/log.jsonl', '=plugin_specific_string'] | desc: re-run tests from log
- rerun_plugin | type=m | long_examples=[' Foo', ' +App::Yath2::Plugin::Foo'] | desc: plugin priority for rerun
- rerun_modes | type=m | alt=[rerun-mode] | long_examples=[' failed,missed,...', ' all', ' failed', ' missed', ' passed', ' retried'] | desc: which test categories to rerun
- rerun_all | type=d | long_examples=['', '=path/to/log.jsonl', '=plugin_specific_string'] | ignore_for_build=1 | desc: rerun all from log (generated loop)
- rerun_failed | type=d | (same attrs as rerun_all) | desc: rerun failed tests
- rerun_retried | type=d | (same attrs) | desc: rerun retried tests
- rerun_passed | type=d | (same attrs) | desc: rerun passed tests
- rerun_missed | type=d | (same attrs) | desc: rerun missed tests
  (the five rerun_* opts are generated in a `for my $mode (keys %RERUN_MODES)` loop)
- changed | type=m | long_examples=[' path/to/file'] | applicable=CODE(changes_applicable) | desc: mark files as changed
- changes_exclude_file | type=m | long_examples=[' path/to/file'] | applicable=CODE | desc: files to ignore for changes
- changes_exclude_pattern | type=m | long_examples=[" '(apple|pear|orange)'"] | applicable=CODE | desc: regex ignore for changes
- changes_filter_file | type=m | long_examples=[' path/to/file'] | applicable=CODE | desc: only check these files
- changes_filter_pattern | type=m | long_examples=[" '(apple|pear|orange)'"] | applicable=CODE | desc: regex filter for change checks
- changes_diff | type=s | long_examples=[' path/to/diff.diff'] | applicable=CODE | desc: diff file for changed-files
- changes_plugin | type=s | long_examples=[' Git', ' +App::Yath2::Plugin::Git'] | applicable=CODE | desc: plugin to detect changes
- changes_include_whitespace | type=b | default=0 | applicable=CODE | desc: include whitespace-only changed lines
- changes_exclude_nonsub | type=b | default=0 | applicable=CODE | desc: exclude changes outside subs
- changes_exclude_loads | type=b | default=0 | applicable=CODE | desc: exclude load-only coverage tests
- changes_exclude_opens | type=b | default=0 | applicable=CODE | desc: exclude open()-only coverage tests
- durations | type=s | long_examples/short_examples=[' file.json', ' http://example.com/durations.json'] | desc: durations json file/url (fatal on failure)
- maybe_durations | type=s | long_examples/short_examples=[' file.json', ' http://example.com/durations.json'] | desc: durations json, non-fatal
- durations_threshold | type=s | alt=[Dt] | default=undef | desc: min test count to fetch durations
- exclude_file | type=m | field=exclude_files | long_examples/short_examples=[' t/nope.t'] | desc: exclude a file
- exclude_pattern | type=m | field=exclude_patterns | long_examples/short_examples=[' t/nope.t'] | desc: exclude regex pattern
- exclude_list | type=m | field=exclude_lists | long_examples/short_examples=[' file.txt', ' http://example.com/exclusions.txt'] | desc: file/url of exclusions
- default_search | type=m | desc: default search paths (t, t2, test.pl)
- default_at_search | type=m | desc: default AUTHOR_TESTING search (xt)
- POST weight=0 (`_post_process`: folds rerun_* fields into rerun + rerun_modes, validates modes, defaults durations_threshold to job_count+1, default_search ['./t','./t2','test.pl'], default_at_search ['./xt'], extensions ('t','t2'), strips leading dots)

### lib/App/Yath2/Options/Logging.pm — prefix `logging`, category "Logging Options"
- log | type=b | short=L | desc: turn on logging
- log_file_format | type=s | alt=[lff] | env=YATH_LOG_FILE_FORMAT,TEST2_HARNESS_LOG_FORMAT | default=CODE('%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl') | desc: strftime-ish log filename format
- bzip2 | type=b | short=B | alt=[bz2, bzip2_log] | desc: bzip2-compress the log
- gzip | type=b | short=G | alt=[gz, gzip_log] | desc: gzip-compress the log
- log_dir | type=s | normalize=CODE(\&clean_path) | desc: log directory
- log_file | type=s | short=F | normalize=CODE(\&clean_path) | desc: log file name
- POST weight=0 (`post_process`: bzip2+gzip conflict fatal; implies log=1; builds log_file from format/dir; fixes .jsonl/.bz2/.gz extensions)

### lib/App/Yath2/Options/Persist.pm — prefix `runner`, category "Runner Options"
- daemon | type=b | default=1 | desc: start runner as daemon

### lib/App/Yath2/Options/PreCommand.pm — prefix `harness`, **pre_command=1 for whole group** (per-option categories)
- plugins | type=m | short=p | alt=[plugin] | category=Plugins | long_examples=[' PLUGIN', ' +App::Yath2::Plugin::PLUGIN', ' PLUGIN=arg1,arg2,...'] | short_examples=['PLUGIN'] | action=CODE(plugin_action: load class, include its options, instantiate if can new) | desc: load a yath plugin
- no_scan_plugins | type=b | category=Plugins | desc: disable plugin module scanning
- project | type=s | alt=[project-name] | category=Environment | desc: project/codebase label
- persist_dir | type=s | category=Environment | normalize=CODE(\&clean_path) | desc: where persistence files live
- persist_file | type=s | category=Environment | alt=[pfile] | normalize=CODE(\&clean_path) | desc: persistence file path
- dev_libs | type=D | short=D | name=dev-lib | category=Developer | long_examples=['', '=lib'] | short_examples=['', '=lib', 'lib'] | normalize=CODE(normalize_dev_libs) | action=CODE(dev_libs_action: dedupe, unshift @INC, warn late-add) | desc: add paths to @INC early
- POST weight=0 (`post_process`: default persist_file via find_pfile(vivify, no_checks))

### lib/App/Yath2/Options/Run.pm — prefix `run`, category "Run Options", builds `Test2::Harness2::Run`
- POST weight=0 (`post_process`: author_testing sets env var; dbi_profiling loads/injects Test2::Plugin::DBIProfile into load_import)
- link | type=m | field=links | long_examples=[3 url examples] | desc: links shown for this run
- test_args | type=m | desc: @ARGV for all tests
- input | type=s | desc: stdin string for all tests
- input_file | type=s | action=CODE(validates -f, clears run->input with warning, handler) | desc: stdin file for all tests
- dbi_profiling | type=b | desc: use Test2::Plugin::DBIProfile
- author_testing | type=b | short=A | desc: set AUTHOR_TESTING env
- use_stream | type=b | name=stream | default=1 | desc: use stream formatter
- tap | type=b | field=use_stream | alt=[TAP, --no-stream] | normalize=CODE($_[0] ? 0 : 1) | desc: legacy TAP instead of stream
- fields | type=m | short=f | long_examples/short_examples=[' name:details', ' JSON_STRING'] | action=CODE(fields_action: parse json or name:details) | desc: add custom run data
- env_var | type=h | field=env_vars | short=E | long_examples=[' VAR=VAL'] | short_examples=['VAR=VAL', ' VAR=VAL'] | desc: env vars for each test
- run_id | type=b(default-type, used as value) | alt=[id] | default=CODE(\&gen_uuid) | desc: set specific run-id
- load | type=m | short=m | alt=[load-module] | desc: load module in each test (no import)
- load_import | type=H | short=M | alt=[loadim] | long_examples/short_examples=[' Module', ' Module=import_arg1,arg2,...'] | desc: load module with import
- event_uuids | type=b | default=1 | alt=[uuids] | desc: Test2::Plugin::UUID in tests
- mem_usage | type=b | default=1 | desc: Test2::Plugin::MemUsage in tests
- io_events | type=b | default=0 | desc: Test2::Plugin::IOEvents in tests
- retry | type=s | default=0 | short=r | desc: retry failed jobs N times
- retry_isolated | type=b | default=0 | alt=[retry-iso] | desc: retries run isolated (-j1)

### lib/App/Yath2/Options/Runner.pm — prefix `runner`, category "Runner Options"
- use_fork | type=b | alt=[fork] | env=!T2_NO_FORK,T2_HARNESS_FORK,!T2_HARNESS_NO_FORK,YATH_FORK,!YATH_NO_FORK | default=CODE(0 on win32 else 1) | desc: run tests via fork
- abort_on_bail | type=b | default=1 | desc: abort all on bail-out
- use_timeout | type=b | alt=[timeout] | default=1 | desc: enable/disable timeouts
- shared_jobs_config | type=s | default='.sharedjobslots.yml' | long_examples=[3 path examples] | desc: shared slot config file
- POST weight=0 (`jobs_post_process`: fix_job_resources, sets T2_HARNESS_MY_JOB_COUNT / T2_HARNESS_MY_MAX_JOB_CONCURRENCY env)
- job_count | type=s | short=j | alt=[jobs] | env=YATH_JOB_COUNT,T2_HARNESS_JOB_COUNT,HARNESS_JOB_COUNT | clear_env_vars=1 | long_examples=[' 4', ' 8:2'] | short_examples=['4', '8:2'] | action=CODE(split j:x, set slots_per_job, fix_job_resources) | desc: concurrent job count
- slots_per_job | type=s | short=x | env=T2_HARNESS_JOB_CONCURRENCY | clear_env_vars=1 | long_examples=[' 2'] | short_examples=['2'] | desc: slots each job uses
- dump_depmap | type=b | default=0 | desc: dump staged-preload depmap json
- includes | type=m | name=include | short=I | desc: add dir to include paths
- resources | type=m | name=resource | short=R | long_examples=[' Port', ' +Test2::Harness2::Runner::Resource::Port'] | short_examples=[' Port'] | normalize=CODE(prepend Test2::Harness2::Runner::Resource:: unless +) | desc: resource modules for assignments
- tlib | type=b | default=0 | action=CODE(push t/lib to includes) | desc: include t/lib
- lib | type=b | short=l | default=1 | action=CODE(push lib, zero lib/blib flags) | desc: include lib
- blib | type=b | short=b | default=1 | action=CODE(push blib/lib+blib/arch, zero flags) | desc: include blib paths
- unsafe_inc | type=b | env=PERL_USE_UNSAFE_INC | default=0 | desc: keep '.' in @INC
- preloads | type=m | alt=[preload] | short=P | desc: preload module before tests
- preload_threshold | type=s | short=W | alt=[Pt] | default=0 | desc: min jobs before preload
- nytprof | type=b | long_examples=[''] | desc: Devel::NYTProf on tests
- POST weight=0 (`cover_post_process`: honors $ENV{T2_DEVEL_COVER}, sets T2_NO_FORK, use_fork=0, injects Devel::Cover into run->load_import)
- cover | type=d | long_examples=['', '=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl'] | action=CODE(default args if bare) | desc: Devel::Cover coverage
- switch | type=m | field=switches | short=S | desc: perl switch per test
- fail_on_resource_skip | type=b | default=0 | long_examples=[''] | desc: resource-skips become failures
- resource_timeout | type=s | alt=[rt] | default=0 | long_examples/short_examples=[' SECONDS'] | desc: abort if no tests can start
- event_timeout | type=s | alt=[et] | default=60 | long_examples/short_examples=[' SECONDS'] | desc: kill test on output timeout
- post_exit_timeout | type=s | alt=[pet] | default=15 | long_examples/short_examples=[' SECONDS'] | desc: stop waiting post-exit
- runner_id | type=s | default=CODE(gen_uuid()) | desc: runner ID uuid

### lib/App/Yath2/Options/Workspace.pm — prefix `workspace`, category "Workspace Options"
- tmp_dir | type=s | short=t | alt=[tmpdir] | env=T2_HARNESS_TEMP_DIR,YATH_TEMP_DIR,TMPDIR,TEMPDIR,TMP_DIR,TEMP_DIR | default=CODE(File::Spec->tmpdir) | desc: specific temp directory
- workdir | type=s | short=w | env=T2_WORKDIR,YATH_WORKDIR | clear_env_vars=1 | normalize=CODE(\&clean_path) | desc: set the work directory
- clear | type=b | short=C | desc: clear non-empty workdir
- POST weight=0 (anon sub: create/clear workdir or tempdir(yath-$$-XXXXXX) honoring debug->keep_dirs and command->always_keep_dir)

## Section 3: Commands

Base class `lib/App/Yath2/Command.pm` provides: `only_cmd_opts` => 0, `munge_opts` => no-op, `handle_invalid_option` => 0, `internal_only` 0, `always_keep_dir` 0. It does `use App::Yath2::Options();` (no import) so the **base class itself has no `options()` method and declares no options**. A subclass gets an options instance only when it (or an ancestor) does `use App::Yath2::Options;`; `Options->set_command_class` calls `include_from($class)` which uses `$class->can('options')`, so subclasses inherit the nearest ancestor's options instance.

No command in lib/ overrides `only_cmd_opts` or `munge_opts`. Only `runner` defines `generate_run_sub`.

### test (lib/App/Yath2/Command/test.pm)
- include: Debug, Display, Finder, Logging, PreCommand, Run, Runner, Workspace, Collector
- own options: none
- generate_run_sub: no | only_cmd_opts: inherited 0 | munge_opts: inherited no-op

### run (lib/App/Yath2/Command/run.pm) — parent: test (own options instance)
- include: Debug, Display, Finder, Logging, PreCommand, Run
- own options (option_group prefix `run`, no category):
  - check_reload_state | type=b | default=1 | desc: abort/confirm on reload errors
- generate_run_sub: no | only_cmd_opts: no | munge_opts: no

### projects (lib/App/Yath2/Command/projects.pm) — parent: test
- include: inherits test's options (no own `use App::Yath2::Options`)
- own options: none. Note: Finder's changes_* options are `applicable=0` for this command.
- generate_run_sub/only_cmd_opts/munge_opts: no

### start (lib/App/Yath2/Command/start.pm) — parent: Command
- include: Debug, PreCommand, Runner, Workspace, Persist, Collector
- own options (option_group prefix `runner`, category "Persistent Runner Options"):
  - reload | type=b | short=r | default=0 | desc: reload modified modules in-place
  - restrict_reload | type=D | long_examples=['', '=path'] | short_examples=['', '=path'] | normalize=CODE(clean_path unless '1') | action=CODE(restrict_action: default to rc-file dir/cwd) | desc: restrict reload to path
  - quiet | type=c | short=q | default=0 | desc: be very quiet
- generate_run_sub/only_cmd_opts/munge_opts: no

### spawn (lib/App/Yath2/Command/spawn.pm) — parent: run (own options instance)
- include: none declared (fresh instance; does NOT include run's sets)
- own options (option_group prefix `spawn`, category "spawn options"):
  - stage | type=s | short=s | default='default' | long_examples/short_examples=[' foo'] | desc: stage for launching script
  - copy_env | type=m | short=e | long_examples/short_examples=[' HOME', ' SHELL', ' /PERL_.*/i'] | desc: copy env vars (regex ok)
  - env_var | type=h | field=env_vars | short=E | long_examples=[' VAR=VAL'] | short_examples=['VAR=VAL', ' VAR=VAL'] | desc: env vars for spawn
- generate_run_sub/only_cmd_opts/munge_opts: no

### failed (lib/App/Yath2/Command/failed.pm) — parent: Command
- include: none (own instance via `use App::Yath2::Options`)
- own options (standalone option, explicit prefix):
  - brief | type=b | prefix=display | category="Display Options" | desc: show only failed file names
- generate_run_sub/only_cmd_opts/munge_opts: no

### replay (lib/App/Yath2/Command/replay.pm) — parent: Command
- include: Debug, Display, PreCommand
- own options: none
- generate_run_sub/only_cmd_opts/munge_opts: no

### resources (lib/App/Yath2/Command/resources.pm) — parent: Command
- include: Debug, Runner
- own options: none
- generate_run_sub/only_cmd_opts/munge_opts: no

### speedtag (lib/App/Yath2/Command/speedtag.pm) — parent: Command
- include: Debug
- own options (option_group prefix `speedtag`, category "speedtag options"):
  - generate_durations_file | type=d | alt=[durations, duration] | long_examples=['', '=/path/to/durations.json'] | normalize=CODE(normalize_duration) | action=CODE(duration_action: default durations.json) | desc: write duration json file
  - pretty | type=b | default=0 | desc: pretty durations.json output
- generate_run_sub/only_cmd_opts/munge_opts: no

### times (lib/App/Yath2/Command/times.pm) — parent: Command
- include: Debug
- own options: none
- generate_run_sub/only_cmd_opts/munge_opts: no

### status (lib/App/Yath2/Command/status.pm) — parent: run
- include: inherits run's options (no own use)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### abort (lib/App/Yath2/Command/abort.pm) — parent: status (→ run options)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### kill (lib/App/Yath2/Command/kill.pm) — parent: abort (→ run options)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### ps (lib/App/Yath2/Command/ps.pm) — parent: status (→ run options)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### stop (lib/App/Yath2/Command/stop.pm) — parent: run (→ run options)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### help (lib/App/Yath2/Command/help.pm) — parent: Command
- `sub options {};` — explicitly empty options (suppresses inheritance/instance)
- own options: none | generate_run_sub/only_cmd_opts/munge_opts: no

### do (lib/App/Yath2/Command/do.pm) — parent: Command
- stub command (dispatches to run/test); no options | no special subs

### init (lib/App/Yath2/Command/init.pm) — parent: Command
- no options | no special subs

### reload (lib/App/Yath2/Command/reload.pm) — parent: Command
- no options | no special subs

### watch (lib/App/Yath2/Command/watch.pm) — parent: Command
- no options | no special subs

### which (lib/App/Yath2/Command/which.pm) — parent: Command
- no options | no special subs

### auditor (lib/App/Yath2/Command/auditor.pm) — parent: Command, internal_only=1
- no options | no special subs

### collector (lib/App/Yath2/Command/collector.pm) — parent: Command, internal_only=1
- no options | no special subs

### runner (lib/App/Yath2/Command/runner.pm) — parent: Command, internal_only=1
- no options
- **defines `generate_run_sub`** (class method; builds runner from settings.json in workdir, scrubs/restores %SIG, Long::Jump based exec) | only_cmd_opts/munge_opts: no

## Section 4: Plugins + fixtures

### lib/App/Yath2/Plugin.pm
- Base class (parent Test2::Harness2::Plugin). Declares NO options; provides finish()/finalize() stubs and documented optional hooks (handle_event, sort_files, sort_files_2).

### lib/App/Yath2/Plugin/Git.pm — option_group prefix `git`, category "Git Options"
- change_base | type=s | long_examples=[" master", " HEAD^", " df22abe4"] | desc: change-base for changed files

### lib/App/Yath2/Plugin/Cover.pm — option_group prefix `cover`, category "Cover Options"
- POST weight=0 (`post_process`: injects cover class into run->load_import when files/write/metrics)
- types | type=m | alt=[cover-type] | default=CODE([qw/pl pm/]) | desc: coverage file types
- dirs | type=m | alt=[cover-dir] | default=CODE(['lib']) | action=CODE(glob expand) | desc: coverage dirs
- exclude_private | type=b | default=0 | description='' | desc: exclude private subs
- files | type=b | desc: Test2::Plugin::Cover file coverage
- metrics | type=b | description='' | desc: coverage metrics
- write | type=d | normalize=CODE(\&clean_path) | long_examples=['', '=coverage.jsonl', '=coverage.json'] | action=CODE(default coverage.jsonl) | desc: write coverage data file
- aggregator | type=s | alt=[cover-agg] | long_examples=[' ByTest', ' ByRun', ' +Custom::Aggregator'] | normalize=CODE(prepend Test2::Harness2::Log::CoverageAggregator::) | desc: custom aggregator subclass
- class | type=s | default='Test2::Plugin::Cover' | desc: Test2::Plugin::Cover subclass
- manager | type=s | long_examples=[' My::Coverage::Manager'] | applicable=CODE(changes_applicable: false for projects cmd) | desc: coverage 'from' manager
- from_type | type=s | long_examples=[' json', ' jsonl', ' log'] | desc: coverage source file type
- maybe_from_type | type=s | long_examples=[' json', ' jsonl', ' log'] | desc: from_type for maybe_from
- from | type=s | long_examples=[' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.jsonl'] | desc: coverage source (fatal if invalid)
- maybe_from | type=s | long_examples=[same as from] | desc: coverage source, non-fatal

### lib/App/Yath2/Plugin/YathUI.pm — option_group prefix `yathui`, category "YathUI Options"
- url | type=s | alt=[uri] | long_examples=[" http://my-yath-ui.com/..."] | desc: Yath-UI url
- api_key | type=s | desc: Yath-UI API key
- project | type=s | desc: Yath-UI project name
- mode | type=s | default='qvfd' | long_examples=[' summary', ' qvf', ' qvfd', ' complete'] | desc: upload mode
- retry | type=c | default=0 | desc: retries before giving up
- grace | type=b | default=0 | desc: fail gracefully on connect error
- durations | type=b | default=0 | applicable=CODE(can_finder: Options::Finder included) | desc: poll durations from Yath-UI
- coverage | type=b | default=0 | applicable=CODE(can_finder) | desc: poll coverage from Yath-UI
- medium_duration | type=s | default=5 | long_examples=[' 5'] | desc: SHORT→MEDIUM threshold seconds
- long_duration | type=s | default=10 | long_examples=[' 10'] | desc: MEDIUM→LONG threshold seconds
- upload | type=b | default=0 | applicable=CODE(can_log: Options::Logging included) | desc: upload log to Yath-UI
- POST weight=-1 (validates url/project, forces log+bzip2 on upload, wires cover->from / finder->durations URLs)
(commented-out: median_durations)

### lib/App/Yath2/Plugin/Notify.pm — option_group prefix `notify`, category "Notification Options", **group applicable=CODE(\&applicable: Options::Run included)** (applies to every option + the post)
- slack | type=m | long_examples=[" '#foo'", " '\@bar'"] | desc: slack results channel/user
- slack_fail | type=m | long_examples=[" '#foo'", " '\@bar'"] | desc: slack failures channel/user
- slack_url | type=s | long_examples=[" https://hooks.slack.com/..."] | desc: slack webhook endpoint
- slack_owner | type=b | default=0 | desc: notify test-meta slack owners
- no_batch_slack | type=b | default=0 | desc: send slack per-failure not batch
- email_from | type=s | long_examples=[' foo@example.com'] | default=CODE(user@hostname) | desc: from address for email
- email | type=m | long_examples=[' foo@example.com'] | desc: email results to addresses
- email_fail | type=m | long_examples=[' foo@example.com'] | desc: email failures to addresses
- email_owner | type=b | default=0 | desc: email owner of broken tests
- no_batch_email | type=b | default=0 | desc: send email per-failure not batch
- text | type=s | alt=[message, msg] | desc: custom text snippet
- text_module | type=s | alt=[message_module] | desc: module to generate messages
- POST weight=0 (validates Email::Stuffer/HTTP::Tiny+SSL, defaults email_owner/slack_owner unless set_by_cli, registers plugin instance in harness->plugins)

(lib/App/Yath2/Plugin/SysInfo.pm declares no options — not in scope list but verified.)

### t/lib/App/Yath2/Plugin/Options.pm (test fixture)
- foobar | type=b | prefix=testplugin (explicit; from_plugin would otherwise force `options` prefix) | desc: fixture bool option

### t/lib/App/Yath2/Command/fake.pm (test fixture) — parent Command, option_group prefix `fake`
- x | type=b(default) | short=x | desc: fixture short opt
- y | type=b(default) | short=y | desc: fixture short opt
- z | type=b(default) | short=z | desc: fixture short opt
  (generated via `option($_, short => $_) for qw/x y z/`)
- POST weight=0 (prints "AAAA", increments $main::POST_HOOK)

### t2/ fixtures
- grep of t2/ for `option(` found **no fixtures declaring options** (t2/ contains only .t test scripts, lib/, non_perl/; none use App::Yath2::Options).

## Section 5: old3 equivalents (reference/old3/lib/App/Yath2/Options/*.pm)

old3 uses Getopt::Yath (`group` instead of `prefix`, long type names, from_env_vars/set_env_vars/clear_env_vars arrays, trigger/initialize/autofill, option_post_process). "same" below = same option name+semantics (modulo type-name spelling).

### Collector.pm (live) → old3: NO equivalent file
| live option | old3 |
|---|---|
| max_open_jobs | absent-in-old3 |
| max_poll_events | absent-in-old3 |
(old3 IPC.pm/IPCAll.pm cover IPC discovery — ipc-dir, ipc-dir-order, ipc-protocol, ipc-file, ipc-allow-non-daemon — a different concern; no collector tuning options.)

### Debug.pm (live) → old3 Harness.pm + Yath.pm (+ Workspace.pm, Run.pm)
| live (debug.*) | old3 |
|---|---|
| dummy | same — Harness.pm harness.dummy |
| procname_prefix | same name — Harness.pm harness.procname_prefix (restructured: default 'yath', set_env_vars, trigger) |
| keep_dirs | moved — Workspace.pm workspace.keep_dirs |
| show-opts | same name — Yath.pm yath.show-opts (restructured: Auto type w/ =group arg) |
| version | same — Yath.pm yath.version |
| help | same — Yath.pm yath.help (restructured: Auto w/ =Group) |
| interactive | moved — Run.pm run.interactive (Bool, set/from YATH_INTERACTIVE) |
| summary | absent-in-old3 |

### Display.pm (live) → old3 Term.pm + Renderer.pm
| live | old3 |
|---|---|
| display.color | same — Term.pm term.color (adds YATH_COLOR/CLICOLOR_FORCE env) |
| display.quiet | moved — Renderer.pm renderer.quiet |
| display.verbose | moved — Renderer.pm renderer.verbose (Count, set_env_vars) |
| display.no_wrap | restructured — Renderer.pm renderer.wrap (inverted Bool, default 1) |
| display.no_final_table | absent-in-old3 |
| display.show_times | moved — Renderer.pm renderer.show_times |
| display.hide_runner_output | moved — Renderer.pm same name |
| display.truncate_runner_output | moved — Renderer.pm same name |
| display.term_width | same — Term.pm term.term_width (field=width, set/from TABLE_TERM_SIZE) |
| display.progress | same — Term.pm term.progress |
| display.renderers | renamed-to renderer.classes — Renderer.pm (Map, name 'renderers', App::Yath2::Renderer:: namespace) |
| formatter.formatter | absent-in-old3 (formatter model replaced by renderers/themes; closest renderer.theme/qvf) |
| formatter.qvf | moved — Renderer.pm renderer.qvf (theme-swap semantics) |
| formatter.show_job_end | moved — Renderer.pm renderer.show_job_end |
| formatter.show_job_info | moved — Renderer.pm renderer.show_job_info (default from verbose) |
| formatter.show_job_launch | moved — Renderer.pm renderer.show_job_launch (default from verbose) |
| formatter.show_run_info | moved — Renderer.pm renderer.show_run_info (default from verbose) |
(old3-only additions: renderer.theme, renderer.show_run_fields, renderer.server, term color env wiring.)

### Finder.pm (live) → old3 Finder.pm
| live (finder.*) | old3 |
|---|---|
| finder | renamed-to class (name stays 'finder', field=class, default App::Yath2::Finder) |
| extension (field extensions) | renamed-to extensions (alt ext/extension, split_on ',', default t,t2) |
| search | absent-in-old3 |
| no_long / only_long | same |
| show_changed_files / changed_only | same (no applicable callback in old3) |
| rerun | same (Auto + lastlog autofill) |
| rerun_plugin | renamed-to rerun_plugins (alt rerun-plugin) |
| rerun_modes | restructured — BoolMap w/ pattern qr/rerun-($modes)(=.+)?/ + custom_matches + trigger |
| rerun_all/failed/retried/passed/missed | restructured — folded into rerun_modes BoolMap pattern (no separate options) |
| changed | same (PathList) |
| changes_exclude_file | renamed-to changes_exclude_files (alt singular) |
| changes_exclude_pattern | renamed-to changes_exclude_patterns (alt singular) |
| changes_filter_file | renamed-to changes_filter_files (alt singular) |
| changes_filter_pattern | renamed-to changes_filter_patterns (alt singular) |
| changes_diff / changes_plugin | same |
| changes_include_whitespace / changes_exclude_nonsub / changes_exclude_loads / changes_exclude_opens | same |
| durations / maybe_durations | same |
| durations_threshold | same (default 0 instead of undef→j+1) |
| exclude_file | renamed-to exclude_files (alt singular) |
| exclude_pattern | renamed-to exclude_patterns (alt singular) |
| exclude_list | renamed-to exclude_lists (alt singular) |
| default_search / default_at_search | same (defaults inline instead of post) |

### Logging.pm (live) → old3 Log.pm (group `log`)
| live (logging.*) | old3 |
|---|---|
| log | same — log.log |
| log_file_format | absent-in-old3 (fixed ${project}-${user}-${stamp}-${pid}.yath convention) |
| bzip2 | restructured/absent — replaced by log.compress (zstd Bool, default 1) |
| gzip | restructured/absent — replaced by log.compress |
| log_dir | renamed-to dir — log.dir |
| log_file | renamed-to file — log.file (short F kept) |
(old3-only: log.format tar|sqlite, log.compress.)

### Persist.pm (live runner.daemon) → old3
| live | old3 |
|---|---|
| runner.daemon | absent-in-old3 (Server.pm has an unrelated `daemon` for the web server; persistent-runner daemonization not an option) |

### PreCommand.pm (live, prefix harness) → old3 Yath.pm + IPC.pm
| live (harness.*) | old3 |
|---|---|
| plugins | same name — Yath.pm yath.plugins (Map, mod_adds_options, fqmod normalize) |
| no_scan_plugins | restructured — Yath.pm yath.scan_options (BoolMap pattern scan-(.+)) |
| project | same — Yath.pm yath.project (+ post fallback chain) |
| persist_dir | restructured — IPC.pm ipc.dir (name ipc-dir) + ipc.dir_order |
| persist_file | restructured — IPC.pm ipc.file (name ipc-file) |
| dev_libs | same — Yath.pm yath.dev_libs (AutoPathList, re-exec trigger, + dev_libs_verbose) |
(old3-only: yath.user, yath.base_dir, yath.dev_libs_verbose, ipc.protocol, IPCAll ipc.allow_non_daemon.)

### Run.pm (live, prefix run) → old3 Run.pm + Tests.pm (group `tests`)
| live (run.*) | old3 |
|---|---|
| link (field links) | same — Run.pm run.links (name links, alt link) |
| test_args | renamed-to tests.test_args field `args` (alt test-arg) |
| input | moved — Tests.pm tests.input |
| input_file | moved — Tests.pm tests.input_file (trigger replaces action) |
| dbi_profiling | same — Run.pm run.dbi_profiling (trigger) |
| author_testing | same — Run.pm run.author_testing (set/from AUTHOR_TESTING, trigger) |
| use_stream (name stream) | moved — Tests.pm tests.stream (alt use-stream) |
| tap (field use_stream) | restructured — Tests.pm tests.stream `alt_no => ['TAP']` |
| fields | same — Run.pm run.fields (alt field, normalize json/name=details) |
| env_var (field env_vars) | moved — Tests.pm tests.env_vars (Map, short E) |
| run_id | same — Run.pm run.run_id (initialize gen_uuid) |
| load | moved — Tests.pm tests.load |
| load_import | moved — Tests.pm tests.load_import (Map + trigger) |
| event_uuids | moved — Tests.pm tests.event_uuids (no default, maybe-group) |
| mem_usage | moved — Tests.pm tests.mem_usage |
| io_events | absent-in-old3 (feature moved to external Test2-Collector dist) |
| retry | moved — Tests.pm tests.retry (+ old3-only allow_retry) |
| retry_isolated | moved — Tests.pm tests.retry_isolated |
(old3 Run.pm additions: abort_on_bail (from live runner), nytprof (from live runner), interactive (from live debug), run_auditor.)

### Runner.pm (live, prefix runner) → old3 Runner.pm + Tests.pm + Resource.pm + Preload.pm
| live (runner.*) | old3 |
|---|---|
| use_fork | moved — Tests.pm tests.use_fork (same alt/env list) |
| abort_on_bail | moved — Run.pm run.abort_on_bail |
| use_timeout | moved — Tests.pm tests.use_timeout |
| shared_jobs_config | absent-in-old3 (utilize/throttle resource model instead) |
| job_count | renamed-to resource.slots — Resource.pm (short j, alt jobs/job-count, j:x trigger) |
| slots_per_job | renamed-to resource.job_slots — Resource.pm (short x, alt slots-per-job) |
| dump_depmap | same — Runner.pm runner.dump_depmap |
| includes (name include) | moved — Tests.pm tests.includes (PathList) |
| resources (name resource) | renamed-to resource.classes — Resource.pm (Map, short R, name resources) |
| tlib / lib / blib | moved — Tests.pm same names (no actions; resolved later) |
| unsafe_inc | moved — Tests.pm tests.unsafe_inc (set_env_vars added) |
| preloads (alt preload) | renamed-to preload.modules — Preload.pm (option modules, group preload) |
| preload_threshold | absent-in-old3 |
| nytprof | moved — Run.pm run.nytprof |
| cover | moved — Tests.pm tests.cover (Auto + autofill, set/from T2_DEVEL_COVER) |
| switch (field switches) | moved — Tests.pm tests.switches (alt switch) |
| fail_on_resource_skip | absent-in-old3 |
| resource_timeout | absent-in-old3 |
| event_timeout | moved — Tests.pm tests.event_timeout |
| post_exit_timeout | moved — Tests.pm tests.post_exit_timeout |
| runner_id | absent-in-old3 |
(old3-only: runner.class, scheduler.class (Scheduler.pm), resource.utilize, reloader.backend (Reloader.pm), tests.chdir, tests.set_hash_seed, tests.allow_retry.)

### Workspace.pm (live, prefix workspace) → old3 Workspace.pm
| live | old3 |
|---|---|
| tmp_dir (alt tmpdir) | renamed-to tmpdir (alt tmp-dir; restructured: defaults under workdir, sets TMPDIR-family env instead of reading TMP_DIR/TEMP_DIR) |
| workdir | same (restructured default: $TMPDIR/yath-$instance_uuid; trigger mkdir) |
| clear | same |
(old3 Workspace also hosts keep_dirs, which lives in live Debug.)

old3 modules with NO live Section-2 counterpart (new/other concerns): DB.pm, Publish.pm, Recent.pm, Server.pm, WebClient.pm, WebServer.pm, Scheduler.pm, Resource.pm (beyond job-count mapping), Preload.pm, Reloader.pm, IPC.pm/IPCAll.pm (beyond persist-file mapping), Yath.pm extras (user, base_dir, dev_libs_verbose, scan_options).

## Tallies
- Section 2 group modules: 10 — option() declarations: 118 (Collector 2, Debug 8, Display 17, Finder 34, Logging 6, Persist 1, PreCommand 6, Run 18, Runner 23, Workspace 3) + 13 post callbacks.
- Section 3 commands: 24 files — command-declared options: 10 (run 1, spawn 3, start 3, failed 1, speedtag 2).
- Section 4 plugins + fixtures: options: 41 (Git 1, Cover 13, YathUI 11, Notify 12, t/Plugin/Options 1, t/Command/fake 3) + 4 post callbacks; t2/ has none.
- Grand total option() declarations inventoried: 169.
