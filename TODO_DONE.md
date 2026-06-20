# TODO_DONE.md — Completed tickets

Tickets from `TODO_TASKS.md` that have landed, with review notes. Each entry: what
was done, commit(s), test result, and anything the implementer flagged for review.

Newest first.

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
