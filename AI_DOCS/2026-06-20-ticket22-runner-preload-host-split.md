# Ticket TODO-22 — Untangle the runner from the preload-root (two independent classes)

## Task

Chunk 19 (`AI_DOCS/2026-06-18-chunk19-preload-root-extraction.md`) moved preloaded
interpreter state out of the runner into a separate **preload-root** process, but
it did so by having that process build an *ordinary*
`Test2::Harness2::Runner` with `rootpid` set to the real runner's pid. Because
`rootpid != $$`, the same Runner class behaved as a **stage host** instead of the
scheduler — selected throughout `Runner.pm` by ~16 `ROOTPID == $$` guards. One
class served two opposite roles.

Ticket TODO-22 (owner directive, 2026-06-20) ends that entanglement: the **runner**
(scheduler + primary server) and the **preload-root stage host** (preload +
launch tests, no scheduler) become **two fully independent classes**. Neither
inherits from the other; there is **no shared base class or role designed just for
them**. They share only `Test2::Harness2::Role::Service` (both have a listen
socket + manage connections — a legitimate, pre-existing shared role).

## Achieved design

- **`Test2::Harness2::Preload::Host`** (new) is the stage host. It composes
  `Role::Service` and `parent Test2::Harness2::IPC`; it does **not** compose the
  runner's `Runner::Role::Scheduler` or `Runner::Role::Service::Handlers`. It owns
  the stage-host machinery that used to be the `rootpid != $$` projection of the
  runner: `process` / `run_tests` / `run_stage` / `run_job` / `set_proc_exit` /
  `reset_stage` (preload via `Runner::Preloader`, fork/host named stages, the
  goto-file job launch on dispatch, the stage-relaunch-on-reload longjump). Its
  `state` is always the lightweight in-stage `Runner::Stage` delegate (it holds no
  canonical run State). It carries its **own** stage request handlers —
  `run_task`, `resolve_file_stages`, `reload` — the only commands a stage serves.
  Its `rootpid` is a required attribute (the real runner's pid), conveyed down as
  `watch_parent_pid` so every stage/job collector watches the runner (§4.1).

- **`Test2::Harness2::Preload::_run_stage_host`** now constructs a
  `Preload::Host`, not a `Runner`.

- **`Test2::Harness2::Runner`** is now ALWAYS the root scheduler. The
  stage-host-only code and the `ROOTPID == $$` role guards are gone:
  - removed `service_name` / `is_stage_service` (the runner is always the 'runner'
    service; `Role::Service`'s default `service_name == name` suffices),
    `stage_delegate` + the delegate branch of `state`, `_connect_runner`,
    `stop_stages`, the `Runner::Stage` import, the `stage_delegate` slot;
  - `run_stage` is now only the no-preload **'default'** stage (the runner forks
    each test job itself); its stage-service binding/dial/restart branches are
    gone;
  - `run_job` always records the job pid directly; `set_proc_exit` lost its
    `Preloader::Stage` relaunch branch (the runner forks no preload stages);
  - the always-true `ROOTPID == $$` guards were dropped in `process`, `init` (HUP
    handler), `setup_plugins`/`teardown_plugins`, `_preload_root_wanted`,
    `stop_preload_root`, `dispatch_pending`.
  - The runner keeps the scheduler-only preload path (`run_scheduler_only`,
    `dispatch_pending`, `spawn_preload_root` / `stop_preload_root`,
    `_handle_dead_preload_root`, stage-map + `resolve_file_stage` resolution) and
    the no-preload fork+exec path — both unchanged in behavior.

This matches `ARCHITECTURE.md` §4.2 (the runner is scheduler-only when a
preload-root hosts the stages) and §4.7 (preload stage services). No
ARCHITECTURE addendum is needed — the target spec already described this split;
only the implementation caught up to it.

## Key decisions / gotchas

- **The host needs stage request handlers.** The first cut of `Preload::Host`
  composed only `Role::Service` and so had no `request_handler_run_task` /
  `request_handler_resolve_file_stages`. `Role::Service::handle_request` then
  answered the runner's dispatches with `{ok=>0, error=>'invalid command'}` (the
  runner's dispatch is one-way, so the task silently vanished). The visible
  symptom was `t/integration/preload.t` hanging: the SLOW stage's preload blocks
  until `slow.tx` runs in the eager FAST stage, but with `run_task` dropped no
  test ever ran, so the trigger file was never written and SLOW timed out
  ("did not exit cleanly"). The fix: `Preload::Host` carries its own
  `run_task` / `resolve_file_stages` / `reload` handlers (the originals lived in
  the runner's `Service::Handlers` role, which the host deliberately does not
  compose).

- **`resolve_file_stages` on the host** uses `$self->preloader->staged` exactly as
  the runner-as-host did — equivalent behavior, no semantic change.

- **Supersedes** the chunk-19 "rootpid injection lets one Runner class be both the
  scheduler-only orchestrator and the stage host" decision. There is no longer a
  dual-role Runner; the two roles are two classes.

## Follow-ups (not done here)

- The runner's `Runner::Role::Scheduler` and `Runner::Role::Service::Handlers`
  still carry `rootpid == $$` predicates internally (now always true). They are
  harmless (correct, not dead branches), left for a tidy-up pass.
- The runner's `run_tests` still wraps the no-preload `run_stage('default')` in a
  `setjump "Stage-Runner"` loop, but nothing longjumps that label in the runner
  anymore (the stage-relaunch that did was removed). It runs once; the loop could
  be flattened.
- `_preload_root_hosts_stages` / `PRELOAD_ROOT_HOSTS` still distinguishes the
  preload vs no-preload run inside the runner. The directive's ideal end state
  (`run_scheduler_only` as the runner's *only* run path, collapsing the no-preload
  fork path into it) is a larger change deferred to a follow-up.
