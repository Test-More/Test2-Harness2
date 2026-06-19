# Chunk 19 — Extract the preload root out of the runner

## Task

Make the runner a pure orchestrator. Before this chunk the runner process loaded
the user's preload library, held the preloaded interpreter state, forked the
preload stages directly out of itself, and ran in `BEGIN` so the
`Long::Jump`/goto-file test-launch path worked in-process. Chunk 19 moves all of
that into a **separate preload-root process**, leaving the runner holding no
preloaded state. Prerequisite: chunk 14 (the state-only `TestFile` split). Spec:
`19_spec.md`. Commit range: `925d82d75`..`0b604f4a1` on `2.0d`.

## Achieved design

Process tree (when preloads are configured and not below `preload_threshold`):

```
runner (scheduler-only)
  └─ [collector] preload-root            perl -MTest2::Harness2::Preload=launch,<runner.socket> -e 1;
        ├─ in-process base/default/NOPRELOAD stage   (dials runner.socket as preload-<base>)
        └─ fork → [collector] stage-<name>           (dials runner.socket as preload-<name>)
              └─ fork → [collector] test job          (longjump + goto-file via JobLauncher)
```

- **`Test2::Harness2::Preload`** is the `-M…=launch` bootstrap. Its `import`
  establishes the `Long::Jump`/goto-file host in `BEGIN`, then `run_driver` dials
  `runner.socket` as `preload-root`, handshakes (`get_preload_list` →
  preload specs + the real runner pid + `monitor_preloads`; `set_stage_data` → the
  stage map built from the merged `Test2::Harness2::Runner::Preload` meta), answers
  `resolve_file_stages`, sends `preload_warnings`, and drives a stage-host Runner.
- **Stage-host Runner = an ordinary `Test2::Harness2::Runner` with `rootpid` set to
  the real runner's pid.** Because `rootpid != $$`, `run_stage` treats every stage
  as a socket service (dials the real runner, binds `preload-<name>.socket`) rather
  than the scheduler root; the base/default/NOPRELOAD stage runs in-process and the
  named stages fork as children. One Runner class thus serves **both** roles —
  real orchestrator and stage host — selected purely by `rootpid`.
- **`Runner::run_scheduler_only`** is the real runner's loop when a preload-root
  hosts the stages (`_preload_root_hosts_stages` / `PRELOAD_ROOT_HOSTS`): it loads
  no preloads, hosts no stage, services `runner.socket`, ticks the scheduler, and
  dispatches each task over the channel the hosting stage opened. Stage resolution
  comes from the reported map (eager fan-out rebuilt from `can_run`) +
  `resolve_file_stages` (only the preload-root has the `file_stage` callbacks). The
  no-preload / below-threshold paths are unchanged (the runner forks the test-job
  collector directly).
- **`Test2::Harness2::Runner::JobLauncher`** holds the goto-file job launch
  (collector wrap + `Long::Jump` unwind + post-`goto::file` child setup + the
  `YATH_INTERACTIVE` filter), extracted from `App::Yath2::Command::runner` so
  `Test2::Harness2` loads no `App::Yath2*` (the one-way dependency rule).

## Key decisions

- **Per-stage and per-test collectors retained — no shared-collector deviation.**
  An earlier draft of the plan (and `19_plan`) assumed stages were not yet
  collector-wrapped and proposed one collector for the whole preload tree;
  investigation showed stages already each had their own collector, which is the
  better shape, so the §4.1 "every yath-started process is its own collector"
  invariant is **unchanged** (no ARCHITECTURE addendum). Only a stage's *parent*
  changed (preload-root, not runner).
- **`rootpid` injection** lets one Runner class be both the scheduler-only
  orchestrator and the stage host, avoiding a parallel implementation.
- **Broken preload is transient-fatal but persistent-tolerant**, reusing the
  existing `monitor_preloads` semantics (pre-19 "persistent mode ignores broken
  preloads"): the runner conveys `monitor_preloads` to the preload-root via
  `get_preload_list`; warnings ride a `preload_warnings` channel and are re-emitted
  at each `queue_run` so a `yath run` client sees them (the persistent stage host
  never exits, so they cannot ride `stage_host_exited`).
- **Reaping / leak fix (19.4d).** `spawn_collector` returns the *collector parent*
  pid; the preload-root is the `-e` child it exec'd. The original `stop_preload_root`
  force path `TERM`/`KILL`ed the collector parent, which destroyed its `ChildMonitor`
  (the very thing that kills the preload-root tree when the runner vanishes) and
  **orphaned** the `-e` child — leaking idle daemons that, accumulated across runs,
  bogged the machine. Fix: send the graceful socket `stop`, reap over a generous
  window, and if it does not land, **leave the collector parent alone** — the runner
  exits moments later and the `ChildMonitor` reaps the whole tree. The preload-root
  pid is tracked **outside** the runner's `{+PROCS}` so it never trips
  `IPC::_bring_out_yer_dead`'s `waitpid(-1)`. (Drove `AGENTS.md`'s new "never block
  on a stuck test run" ceiling — a long run is a hung test or a leak, not slowness.)
- **`resolve_file_stages`** exists because the scheduler-only runner has no loaded
  preloader and so cannot run `file_stage` itself; it round-trips the file list to
  the preload-root, which does.

## Residuals (deferred)

- The explicit stage lifecycle-state enum `starting`/`up`/`restarting`/`down` +
  generation counter (§6.8 / chunk 10). The behavior — stage-owned in-place reload,
  exit, and preload-root respawn — works (`reload.t` green); the explicit enum is
  unbuilt.
- The 19.5 refinements: retiring/reshaping the `yath runner` command's goto-file
  host (still used by the no-preload path), the §6.12 HUP-protocol redesign, and the
  §6.10 "preload-root dies but the runner lives → respawn + stale-stage cleanup"
  case.
- The §6.1 verdict-mirroring `spawn_collector` nuance for the preload-root (it
  currently uses `spawn_collector`, collector-health exit; matters only once the
  runner makes restart decisions on the preload-root's exit status).

## Spec deviations flagged

None material. The chunk implements `19_spec.md`; the only revision from the
original `19_plan` is keeping per-stage collectors (the plan's "only the preload
root needs a collector" was based on the wrong premise — see Key decisions). The
substeps landed in a different shape than `19_spec.md` §12 enumerated (the atomic
stage-hosting flip could not be split into independently-green pieces), but the end
state matches the spec.
