# MIGRATION.md

Living status tracker for the **yath 1.0 → 2.0** transition.

yath 2.0 is built by **evolving the 1.0 codebase in small, reviewable chunks**
(not a ground-up rewrite). This document is the single source of truth for
*where that transition stands*. Any agent doing transition work reads this
first to learn the current state, then updates it after landing a chunk.

This file tracks **status**; it is deliberately short and current. The *target
architecture* lives in `ARCHITECTURE.md`; the *how-to-work* rules live in
`AGENTS.md`. Do not duplicate those here — point at them.

## How to use this document

- **Before starting transition work:** read this file top to bottom, then read
  the section of `ARCHITECTURE.md` for the subsystem you are touching.
- **After landing a chunk:** flip its status below, record the commit
  reference(s), and update "Current state". Keep entries terse — status, not
  narrative. Move detail into commit messages or an `AI_DOCS/` entry when one
  is warranted (see `AGENTS.md` "AI task documentation").
- **Keep it honest:** if a chunk is partially done, say so and note what
  remains. A new agent must be able to trust this file.

## Key documents

- **`ARCHITECTURE.md`** — authoritative aspirational target-state spec.
  §1.1 holds the migration order; each subsystem section carries a status tag
  (`[1.0]` / `[migrating]` / `[target]`).
- **`AGENTS.md`** — per-repo workflow, pre-review checks, dependency rules,
  commit/worktree policy, testing instructions.
- **`STYLE_GUIDE.md`** + **`STYLE_GUIDE_AGENT_CHECKLIST.md`** — code style and
  the self-audit checklist walked before handing work back.
- **`new_plan`** — the original transition brief (broad strokes).
- **`reference/`** — read-only prior iterations (immutable; copy out to reuse).
  Beyond `legacy`/`old2`/`old3`/`old4`/`botched`, the abandoned 2.0 feature
  branches are snapshotted as the best reference for their subsystems:
  `2.0b` (collector swap + Monitor + harness-service MVP),
  `harness_service` (Role::Service, scheduler, system-load service),
  `dbix_quickorm` (DBIx::QuickORM layer), `painter` (renderer),
  `io_events` (in-tree formatter IO-events). `reference/notes/` holds
  working notes from that abandoned-branch era.

## Ground rules (current)

- **Branch:** `2.0d` (cut from `1.0`). Commit **directly** to it — the
  foundations override in `AGENTS.md`/project policy means no worktrees or
  feature branches until the user declares foundations done.
- **Testing:** `prove -Ilib -j16 -r t/`. The `-Ilib` is **mandatory** — it is
  what makes the suite exercise this repo's `lib/` instead of any installed
  1.0 (`Test2::Formatter::*` / `Test2::Tools::*` collide by name with the
  installed dist; `-Ilib` wins). Not self-hosting yet, so `yath test` is not
  used to run our own suite.
- **`Test2-Collector`** is a hard dependency and must be installed (declared
  in `dist.ini`).
- Each chunk stays small and keeps the suite green.
- **Do not rename** (decided): `Test2::Formatter::*` and `Test2::Tools::*`
  (much becomes obsolete with the collector swap), and the `App::Yath::Script`
  namespace itself (only its `V#` handler is ours).

## Migration chunks

Order mirrors `ARCHITECTURE.md` §1.1. Status: ✅ done · 🚧 in progress · ⬜ not started.

| # | Chunk | Status | Refs |
|---|-------|--------|------|
| 1 | Mechanical renames + version bump | ✅ | `2ea678e`, `aa6e5eb` |
| 2 | Argument processing → `Getopt::Yath` | ✅ | `3270b30`..`213b5bd` + this task's deletion/POD/docs commits |
| 3 | Collector swap → `Test2-Collector` (yath collector reads `.jsonl.zst`) | ✅ | `fa49f2b65` (merge) |
| 4 | Collectors wrap every yath-started process | 🚧 | — |
| 5 | Transition-only pipelining + Monitor-style state sync | ⬜ | — |
| 6 | Renderer rewrite (base finds `.jsonl.zst`) | ⬜ | — |
| 7 | System-load service (gate concurrency on cpu/mem) | ⬜ | — |
| 8a | Database + UI inline (DBIx::Class, SQLite logs) | ✅ | `2d09d348a` (merge) |
| 8b | Convert inlined UI schema `DBIx::Class` → `DBIx::QuickORM` | ⬜ (deferred) | — |

## Done so far

**Foundations** (pre-chunk):
- Agent governance docs landed and reconciled to the evolve-from-1.0 plan
  (`ARCHITECTURE.md` rewritten aspirational — `1cd766f`; `AGENTS.md` +
  checklist — `8d002ca`).
- `reference/` rebuilt: curated base + abandoned-feature-branch snapshots
  (`e704dd7`, `f9d0f16`).

**Chunk 1 — mechanical renames + version bump** (`2ea678e`, `aa6e5eb`):
- `App::Yath` → `App::Yath2`, `Test2::Harness` → `Test2::Harness2`.
- `App::Yath::Script::V1` → `::V2` (`App::Yath::Script` namespace + external
  dispatcher dependency unchanged).
- All `$VERSION` `1.000173` → `2.000000`.
- Distribution `Test2-Harness` → `Test2-Harness2` (dist.ini, Makefile.PL) — so
  an installed 2.0 co-exists with an installed 1.0.
- Test-fixture modules and unit-test dir layout moved to the `*2` paths.
- Verified the suite runs against `lib/`, not installed 1.0.
- Suite green: `Files=67, Result: PASS`.

**Chunk 2 — argument processing → `Getopt::Yath`** (`3270b30`..`213b5bd` +
this task):
- All option, command, and plugin declarations converted to `Getopt::Yath`.
- `App::Yath2` parse flow swapped to `Getopt::Yath` two-stage processing;
  `Test2::Harness2` consumes `Getopt::Yath::Settings` throughout.
- The 1.0 option machinery (`App::Yath2::Options`, `App::Yath2::Option`,
  `Test2::Harness2::Settings`, `…::Settings::Prefix`) deleted.
- Release POD generators rewritten for the `Getopt::Yath::Instance` API;
  option/command/plugin POD regenerated.
- Suite green: `Files=63, Result: PASS`.

## Current state

- **Namespaces/versions:** fully on the 2.0 names (`App::Yath2`,
  `Test2::Harness2`, dist `Test2-Harness2`, versions `2.000000`).
- **Option handling:** now `Getopt::Yath`. The settings object is
  `Getopt::Yath::Settings` (the 1.0 `App::Yath2::Options` / `App::Yath2::Option`
  / `Test2::Harness2::Settings` machinery is deleted).
- **Collector pipeline:** swapped to `Test2-Collector` (chunk 3, merged
  `fa49f2b65`). Each test job runs under its own collector and writes
  `events.jsonl.zst`; the yath-side gatherer (`Test2::Harness2::Collector` via
  `JobReader`) reads those files and re-attaches run/job/event UUIDs. No harness
  service, transition channel, or system-load service yet — those are `[target]`
  in `ARCHITECTURE.md`.
- **Web UI:** inlined (chunk 8a, merged `2d09d348a`) under `App::Yath2::Server*`
  / `App::Yath2::Schema*` (+ `Command::{server,db/*,client/*}`,
  `Options::{DB,WebServer,Server,WebClient,Publish,Yath}`, `Plugin::DB`,
  `Renderer::{DB,Server}`), following the pre_ai_2.0 layout, on **DBIx::Class**
  (5 drivers; SQLite default for ephemeral/tests). Assets in `share/`, samples in
  `demo/`. Tests: Perl unit + HTTP smoke (`t/AI/integration/ui_server.t`) +
  Playwright (`js-tests/`, run from `t/playwright.t`). The QuickORM conversion is
  **chunk 8b (deferred)**.
- **Logic:** otherwise still 1.0 for the not-yet-migrated chunks (4-7).
- **Not renamed (intentional):** `Test2::Formatter::*`, `Test2::Tools::*`,
  `App::Yath::Script`.

## Next

**Chunk 4 — collectors everywhere** (`ARCHITECTURE.md` §4.1/§4.2).
Wrap every yath-started process in a `Test2::Collector`, not just test jobs
(the runner and other helper processes), extending the chunk-3 collector swap.
Reference: `reference/2.0b` and the unmerged `harness_service` worktree work.
