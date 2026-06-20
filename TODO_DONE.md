# TODO_DONE.md — Completed tickets

Tickets from `TODO_TASKS.md` that have landed, with review notes. Each entry: what
was done, commit(s), test result, and anything the implementer flagged for review.

Newest first.

---

## Batch 2 (2026-06-19) — dedup + interface

Three parallel tickets, integrated onto 2.0d. Combined suite green: `prove` Files=106
Tests=1731 · `yath test` PASSED (both `AUTHOR_TESTING=1 -j16`).

### #24 — Resource base → Role::Tiny role (`requires available, assign`) — DONE (`38f6b00a9`, orig `0a979a4093`)
Converted `Runner::Resource` to a **Role::Tiny role that `use`s Object::HashBase**
(`use Role::Tiny;` before `use Object::HashBase;` so HashBase suppresses `new` for the
role; then `requires 'available','assign'`). Consumers compose via the `&` prefix
(`use Object::HashBase qw/&Test2::Harness2::Runner::Resource .../`); `JobCount`
predeclares `sub new;` to keep its own `new`. Removed dead `scope_global/host/run` and
the `available`/`assign` no-op defaults; kept the optional no-op hooks (+
`sort_weight`/`job_limiter*`/`discharge` — called on every resource). Converted the 4
integration-test resources to `&`-composition; POD → composition.
**Review notes:** (1) `requires` enforcement is a **load-time WARN, not a hard die**
(HashBase's role-applier `warn`s on a missing required method) — JobCount + all test
resources satisfy it, so moot in practice; flag if fatal enforcement was wanted.
(2) no-op defaults got explicit invokants (`my $self = shift; return`) to satisfy the
methods-not-functions audit now that the file `use`s Object::HashBase. (3) kept the
existing `strict/warnings` headers (v5.38 is for new modules only).

### #16 — `run_ord` → rename `run_id` (keep the seam) — DONE (`212aca276`, orig `9369a5f22`)
Renamed the dormant socket-naming seam everywhere (`Role/Service.pm` `->can`/POD/
`service_socket_path`, `Runner.pm` seam comment, and the `Role_Service.t` consumer
test). `grep run_ord lib/ t/` → zero hits. Fixed the doc ("per-run numeric subdir" →
"the run's run_id (UUID) subdir"). Seam intact, behavior identical (no consumer defines
the hook). The unrelated real `run_id` run-identifier API was untouched.

### #9 — Factor collector-reporter boilerplate → `Util::socket_reporter` — DONE (`fca4f3e42`, orig `beb44ecd5`)
Added exportable `Test2::Harness2::Util::socket_reporter($identity, $socket)` (returns
undef unless `-S $socket`; builds `Recorder::Socket` with `no_reply`, `drain_input`,
**`pid => $$`** — the #1 handshake pid; eval-guarded). Swapped the 4 sites (Runner.pm
preload-root, Job.pm, Preloader.pm, Plugin.pm), identity strings preserved. **Review
note:** Job.pm/Preloader.pm previously `warn`ed on connect failure; the helper swallows
the error + returns undef (the file recorder still produces a complete stream), so those
two warns are gone — the one behavioral delta beyond the dedup. Flag if the warn should
be restored (e.g. socket-reporter failure now goes silent).

---

## Batch 1 (2026-06-19) — behavior-preserving deletes

Four independent tickets, each implemented by a fresh agent in an isolated worktree,
integrated onto 2.0d. Combined suite green: `prove` Files=106 Tests=1731 · `yath test`
PASSED 107 files / 1737 assertions (both `AUTHOR_TESTING=1 -j16`).

### #5 — Delete SharedJobSlots — DONE (`6bd15d6b6`, orig `5a999eeae`)
Deleted the 3 modules + their unit tests/fixture, the `--shared-jobs-config` option +
`fix_job_resources` SharedJobSlots logic in `Options/Runner.pm` (kept JobCount
default-add + slot defaulting/clamp), the `resources.pm` `shared_resources` branch, and
all POD/comment mentions (`test.pm`/`projects.pm`/`start.pm`/`Runner.pm`/`Resource.pm`).
`JobCount` independent + kept. **Review notes:** left `t/AI/fixtures/ui/sample-run.jsonl`
(frozen serialized settings containing `shared_jobs_config` — test data, not a code ref)
and `Makefile.PL` (auto-generated; its stale `Test2/Harness/.../SharedJobSlots/*.t` globs
now match nothing) untouched — both intentional/out-of-scope. POD was surgically removed,
not regenerated (a future full POD regen is consistent either way).

### #6 — Delete dead `wait()` params (`cat`/`all_cat`/`block`) — DONE (`d6f3135fb`, orig `ed1317240`)
Removed the 3 dead params + POD from `IPC.pm::wait`, the `$cat_total` bookkeeping, the
`cat`-delta branch, and collapsed `_wait_done` to its 4 real cases (dropped its unused
`$found` arg). **Dropped `PROCS_BY_CAT` entirely** — verified `cat`/`all_cat` were its
sole consumers (all refs were inside IPC.pm). Kept the `category` method on
`IPC::Process`/`Job`/`Preloader::Stage` (public, used by Monitor/Renderer; #8 may revisit).
Behavior-preserving (no caller used the removed params).

### #7 — Misc dead lines (7a/7d/7e/7f) — DONE (`9b4a96252`,`0aed56cf3`,`662e073f3`,`88bf6e12a`)
- 7a: removed the duplicate `IN_MOVE_SELF` inotify-mask line in `Reloader.pm`.
- 7d: removed unused `use Atomic::Pipe` in `Renderer/DB.pm` (verified unused).
- 7e: kept `DepTracer::add_callback`; added a comment pointing at its consumer
  (`Preloader::_reload_cb_reload` via `$dtrace->callbacks`) so it isn't re-flagged dead.
- 7f: deleted Role::Service `run()`/`reap_children` + the `service_on_start/stop/reap`
  hooks + POD + the Runner no-op `reap_children` override (kept `service_tick`).
  **Review note:** the ticket said "zero callers" but `t/AI/unit/Runner_Subscriber.t:104`
  called `$hub->run` — the agent migrated that test to drive the loop inline via the
  public `service_io`/`service_tick`/`service_stopped`/`close_service` primitives
  (faithful to `run()`'s former body), consistent with the ticket's intent.

### #19 — Delete dead `Runner::Client` stage-report methods — DONE (`3d3e28d61`, orig `cce2eb191`)
Deleted the 6 dead stage-report methods (`stop_task`/`retry_task`/`reload`/`stage_ready`/
`stage_down`/`job_pid`) + POD from `Runner/Client.pm` (zero callers confirmed — only the
POD `=item`s referenced them; `reload_state` is distinct and kept). Fixed the stale
`stage_delegate` comment at `Runner.pm:~331` (it uses `service_send`, not a Client).

**Orchestration note:** every agent's worktree was created from a stale 1.0-era base
(`00ee6f7f3`); each adapted by advancing to `2.0d` (`31013c21d`) before working, so all
commits are based on 2.0d and cherry-picked cleanly. Worth fixing the worktree base for
future batches if possible.
