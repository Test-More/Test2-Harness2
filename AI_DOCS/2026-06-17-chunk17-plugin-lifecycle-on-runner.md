# Chunk 17 — Plugin setup/teardown on the runner; aux output via collectors

**Status:** done. **Commits:** `cddf20369` (implementation), the daemon test, this
docs commit. **Branch:** `2.0d`.

## The decision

`Test2::Harness2::Plugin` has two kinds of hooks:
- `setup`/`teardown` — **runner-environment** hooks (start/stop services the tests
  need, prepare/clean shared state).
- `finalize`/`finish` — **client/render-side** hooks (unchanged by this chunk).

Before chunk 17, `setup`/`teardown` ran in the **command** (`test`/`start`/`stop`/
`kill`), *before the runner — and its `runner.socket` — existed*. That is the root
cause of the flat `aux_logs/<name>-STD{OUT,ERR}.log` files: a plugin's `shellcall`
output had nowhere to report, so it was dumped to files the renderer tailed.

**User decision:** keep the single `setup`/`teardown` names, but **move their
invocation to the runner**, and document the divergence from 1.0.

`reference/pre_ai_2.0/` (last human-authored checkpoint) solved the same problem by
splitting into `client_*` (command) + `instance_*` (runner, `Test2/Harness/Instance.pm`)
hooks, with aux through the collector and **no `aux_logs`**. That split existed only
to keep the 1.0 `Test2::Harness`/`App::Yath` namespaces back-compatible — a
non-concern with the `*2` namespaces, so we keep one `setup`/`teardown` pair on the
runner instead of resurrecting the split.

## What moved / changed

1. **Invocation → runner.** `Runner::process` calls `setup_plugins` after
   `start_service` (socket bound) and `teardown_plugins` after `run_tests` (root
   only). Command-side calls removed from `test.pm`/`start.pm`/`stop.pm`/`kill.pm`.

2. **Plugin reconstruction in the runner.** Plugins serialize to bare class names
   (`Plugin::TO_JSON`), so `App::Yath2::_instantiate_plugins` stashes the resolved
   specs (`Class` or `Class=arg1,arg2`) into `harness->plugin_specs`; the runner
   rebuilds the same instances (`require` + `->new(@args)`). Loading
   `App::Yath2::Plugin::*` in the runner is **user-driven** (the `-p` the user
   passed), which the §2.8 dependency rule permits.

3. **Aux output → collector events.** `shellcall` (synchronous) →
   `Test2::Collector::collect(exec=>...)` + `collector_exit_code`. `run_collected`
   (non-blocking / daemon, replaces `fork`+`redirect_io`) → `spawn_collector(run=>$sub
   | exec=>\@cmd)` returning a pid. Both build a `Recorder::Socket` reporter
   (`collector:aux:<name>`, `no_reply`) to `runner.socket` + a file recorder, and pass
   `watch_parent_pid => $$` (the runner pid — these run in the runner). `redirect_io`
   and the `aux_logs` path are gone.

4. **Completion gating.** A `run_collected` daemon's pid goes in a **separate**
   `AUX_PIDS` list (the runner localizes `Test2::Harness2::Plugin::AUX_PIDS` around
   setup/teardown; `run_collected` pushes to it), **not** `{+PROCS}` — so it never
   blocks `wait(all=>1)`. `stop_aux` `TERM`→`KILL`s + reaps at teardown;
   `watch_parent_pid` is the backstop.

5. **Rendering tag.** Aux collectors are named `aux:<name>`; `RunnerReader` gained a
   `tag` attribute and `step_runner_output` tags their output with `<name>` (the
   historical `(NAME)` shape) instead of `INTERNAL`. `_step_aux_logs` / `AUX_HANDLES`
   / the `File::Stream` tail are deleted.

6. **`yath stop` renders shutdown output.** Because `teardown` now runs in the runner
   at stop, `stop` must surface its output. It **primes** a TAIL-mode `Renderer::Base`
   (cursor at the current end of `runner-events`) **before** sending the stop request,
   then **drains** until the runner-events terminal (`harness_process_exit`). This
   shows only the new teardown output (not the whole persistent runner's history,
   which `yath run` already rendered) and avoids two races:
   - **tail-skip race:** priming before the stop request means teardown (written only
     after) is never in the skipped prefix.
   - **cleanup race:** the wrapping collector outlives the inner runner pid by the
     moment it takes to flush the final events; draining to the *terminal* (not to
     inner-pid death) means teardown is read before `stop` removes the workdir.
   `RunnerReader` + `Renderer::Base` gained a `tail` mode for this.

## A consequence worth knowing

The runner now **loads plugin modules** (to run their lifecycle), so test children
forked from the runner inherit them in `%INC`. In 1.0 the runner was a fresh `exec`
with no plugins, so test children were clean. `t/integration/plugin/test.tx` was
updated to expect the plugin present. If strict test-child isolation from plugin code
is ever required, it would need setup/teardown to run in a short-lived runner
subprocess (losing instance state between setup and teardown) — not done here.

## Verification

- `t/integration/plugin.t` — `(TESTPLUG)` shellcall output + setup/teardown-once pass
  in BOTH the transient `yath test` and persistent `start`→`run`→`stop` paths.
- `t/integration/plugin_daemon.t` — a `run_collected` daemon: output captured as
  `(DAEMON)` events, run does not hang, daemon dies with the runner (no orphan).
- `perl agent_scripts/audit-collector-watch-parent lib` — green (aux collectors pass
  `watch_parent_pid`).
- No `aux_logs` directory is created anywhere.
