# Bugfix/Cleanup Integration — RESUME & Handoff (2026-07-03)

Autonomous implementation of the 20 Fable/Opus-Decided specs **and** the full
TIER-8/9/10 cleanup+bug backlog. This doc is the pickup point: current state,
what's left undone, and the decisions still open.

---

## TL;DR

- **Branch:** `2.0d-bugfix` (integration worktree at `/home/exodist/projects/Test2/Test2-Harness-bugfix`), tip **`a4c2e0cd5`**, **102 commits ahead of `2.0d`** (+20.4k / −6.8k, 271 files).
- **Status:** full suite **GREEN** (`-j4`, idle machine). NOT merged to `2.0d` — awaiting review.
- **Done:** every ticket **TODO-64–TODO-162 except TODO-104** (deferred). All 20 Decided specs, all P0–P3 bugs, all TIER-8 cleanup.
- **Docs on `2.0d` already:** `b5a4e0264` (20 RESOLUTION specs), `3e2587b40` (TIER-10 latent findings TODO-157–TODO-162). This resume doc is the third.

## How to resume

```
INT=/home/exodist/projects/Test2/Test2-Harness-bugfix
git -C "$INT" log --oneline 2.0d..HEAD          # 102 commits, one fix(#N)/cleanup(#N) each
git -C "$INT" diff --stat 2.0d..HEAD
git -C "$INT" branch --list 'fix/*'             # per-ticket branches (all merged)
```
- Test cmd: `AUTHOR_TESTING=1 prove -Ilib -It2clib <files>`. Each worktree needs an **absolute** `t2clib` symlink → `/home/exodist/projects/Test2/Test2-Collector/lib`.
- Full gate: `AUTHOR_TESTING=1 prove -Ilib -It2clib -j4 -r t/` **on an idle machine** (see Known Issues). Re-run any failure isolated; isolated-pass ⇒ environmental.
- To ship: after review, `git checkout 2.0d && git merge --ff-only 2.0d-bugfix` (linear, bisectable).
- Per-ticket worktrees under `/home/exodist/projects/Test2/bugfix-wt/*` can be pruned (`git worktree remove …`) — all merged.

---

## Left UNDONE (deferred — pick up here)

### 1. TODO-104 — TODO status sync (only genuinely-skipped ticket)
Doc-only: flip `TODO_STEPS.md` DB-1..DB-5/DB-Jsonl/REF-PORT rows and `TODO_TASKS.md` TODO-45–TODO-62 to DONE (they're implemented/merged on 2.0d already). Skipped deliberately — low value, and it edits the same spec doc holding the RESOLUTION blocks. **Do when convenient**; risk-free once the branch is merged.

### 2. TODO-114-B — `yath reload` socket readback (the thorough half)
`TODO-114-A` (no-preload detection + honest exit codes) is **done**. `TODO-114-B` (reload becomes a socket request/response returning the reloaded-stage list) was deferred. Prereqs, per TODO-159's investigation:
- The reload-identity **cluster TODO-111/TODO-112/TODO-113 is done** (routing now via `service_peers->{'preload-root'}->peer_pid`), so B is unblocked.
- **Must use request name `trigger_reload`** — the name `reload` is already a one-way stage notification; a command-sent `reload` corrupts `reload_state` (autovivified key at `State.pm`).
- The runner can't block on the async respawn ack — B needs a two-phase dispatch-ack + command-side poll of the existing `status` query's `stage_lifecycle` stamps.

### 3. Web-parked sub-items (deferred to the §9 webapp port, per owner directive — parked, NOT deleted)
- **TODO-94 / TODO-98 step 2:** `Options/Collector.pm` is genuinely dead (nothing reads the `collector` settings group) but deleting it edits core command wiring exercised only by the full `yath test` suite — left for a full-suite-validated pass.
- **TODO-98 step 3:** trim `Options/Publish.pm` (flush_interval/buffer_size/retry/force/user) + `Options/WebClient.pm` (grace/request_retry) — needs DB-rewrite-worktree / §9 coordination.
- **TODO-100:** YathUI `median_durations` block → deferred to **TODO-55** (parked web layer).
- **TODO-102:** `Test2/Harness2/Log.pm` sub-item → deferred to DB-Jsonl **TODO-55/TODO-56**.
- `Options/Server.pm` + `Options/WebServer.pm` were **parked via `git mv` → `reference/old_db/…`** (not deleted).

### 4. FreeBSD/DragonFly SubReaper (TODO-154, item 42) — a small open call
Shipped: **FreeBSD `SYS_procctl` = 544** (was wrongly 548), DragonFly **dropped** from the OS match (reports "unsupported", no false-positive). The TODO-154 agent offered to *table DragonFly's real constants from a syscall table* instead of dropping it — declined for safety (can't test off-Linux). Revisit if DragonFly support is wanted; verification of FreeBSD needs a CPAN-testers FreeBSD run post-release.

---

## DECISIONS to make (implemented as the spec default — override if you disagree)

Each was resolved with a sensible default and marked in the ticket's RESOLUTION block. To change one, say which; it's a small follow-up.

| Ticket | Decision made (default) | Override option |
|---|---|---|
| **TODO-67** OWNER-CONFIRM | Hoisted shared process-mgmt (check_timeouts/stop/handle_sig) into common base `Test2::Harness2::IPC` | Keep duplicated / Role helper, honoring TODO-22 literally |
| **TODO-70** OWNER-CONFIRM | Split `Handlers.pm` → `Completion` + `TransitionHub` roles (seam names + `service_transition`/`monitor` under TransitionHub) | A different cut, or grant a 1000-line exception (no split) |
| **TODO-108** OWNER-OVERRIDABLE | `-L` DB loggers share the 16MiB per-conn outbound cap | Exempt loggers (unbounded queue) if lossless import > bounded memory |
| **TODO-118** OWNER-OVERRIDABLE | Unknown HARNESS-CATEGORY → fail that job (E1); durations coerce <15s short / <30s medium / else long | Lenient: unknown category → warn + `general`; different thresholds |
| **TODO-121** OWNER-OVERRIDABLE | `yath stop` never escalates to TERM on deadline (diagnostic + "use `yath kill`") | Allow stop→TERM, or add `yath kill --force` |
| **TODO-129** OWNER-OVERRIDABLE | Fork C (per-run dest txn + always-descend) | Pure fork A (no txns; partial run briefly reader-visible between syncs) |
| **TODO-131** OWNER-OVERRIDABLE | Aborted job → status `broken`, counted in `runs.failed` | Distinct `canceled` status for owner-initiated aborts (truncate/owner-drop) |
| **TODO-135** OWNER-OVERRIDABLE | Monitor run-end marker ring = 100 runs | Raise (longer late-subscribe window, more memory) or 0 (hang-on-late-subscribe restored) |
| **TODO-140** OWNER-OVERRIDABLE | Interactive STDIN security = **C+D** (scrub `$ENV{YATH_INTERACTIVE}` in `connect_stdin` + SO_PEERCRED log); nonce dropped | Upgrade to **A** (per-job nonce) — needs a scheduler→accept-loop nonce channel |
| **TODO-144** OWNER-OVERRIDABLE | Follow symlinked test dirs (`follow_fast`+realpath dedup) | Fallback B: no follow, only top-level `clean_path(@dirs)` (matches 1.x, symlinked subdirs stay skipped) |
| **TODO-145** OWNER-OVERRIDABLE | A `not_live/unknown` discovery link is never auto-aged-out | Add an explicit `yath list --clean-stale` |
| **TODO-154** OWNER-OVERRIDABLE | DragonFly dropped (see "Left Undone TODO-4") | Table its real SYS_procctl/REAP constants |

---

## Known issues / operating notes

- **Environmental test flake (NOT a code bug):** heavy spawn/persistent-runner e2e tests (`spawn_direct_to_stage.t`, `spawn_robustness.t`, `db_sync.t`, `preload.t`, `db_logger.t`) fail under high `-j` load with `BEGIN failed--compilation aborted at .../yath line 15` / "runner exited before serving" — `yath` fails to compile/start under machine saturation (worsened when many agents run concurrently). **They pass isolated every time.** Gate policy: `-j4` on an idle machine, re-run any failure isolated. `TODO-119` (spawn setpgrp) was briefly mis-blamed for this, reverted, then proven innocent and re-added.
- **Gate cadence:** full suite gated after each of the 14 waves; kept green throughout. `-j16` (the canonical cmd in memory) is too aggressive for the grown suite on this box.
- **`TODO-86` vs `TODO-151` dedup:** the ByTest:91 in-progress-record fix is owned by **TODO-86** (both were annotated); TODO-151 kept only its unique ByRun swapped-guard finding. `TODO_TASKS.md` TODO-151 has a dedup note.
- Minor pre-existing podchecker noise in `Util.pm` (`write_file_atomic`/`write_link_atomic` internal `L<>` links added by TODO-145) — cosmetic, unaddressed.

## New bugs found beyond the original 126-finding audit (all handled)

Filed as TIER-10 **TODO-157–TODO-162** (committed on 2.0d) and resolved: TODO-157 (bounded connect — the root cause behind TODO-145/TODO-121's backstops) DONE; TODO-158 (aborted-run drain) DONE; TODO-159 (TODO-113 premise re-audit) verdict recorded, cluster fixed; TODO-160 (hidden-output renderers) covered by TODO-141; TODO-161 (runner.pm unlink) already fixed by TODO-145 + regression added; TODO-162 (dead -f unlinks) superseded by TODO-145. Plus in-spec latent finds folded into their tickets (e.g. `use POSIX` missing in `Util/IPC.pm`, `run_delta` skipping partial runs, the truncate-abort phantom-try).

## Next steps

1. Review `git -C $INT log/diff 2.0d..HEAD`.
2. Resolve any DECISIONS above you want changed (each is a small follow-up).
3. `ff-merge 2.0d-bugfix → 2.0d`.
4. Optionally schedule the deferred items (TODO-104, TODO-114-B, the §9 web-parked sub-items) and prune the per-ticket worktrees.
