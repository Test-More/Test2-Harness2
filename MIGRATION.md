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
- **`Test2-Collector`** is unreleased; loaded via the `t2clib` symlink at the
  repo root (gitignored). Tests that load `Test2::Collector*` need
  `use lib 't2clib';`.
- Each chunk stays small and keeps the suite green.
- **Do not rename** (decided): `Test2::Formatter::*` and `Test2::Tools::*`
  (much becomes obsolete with the collector swap), and the `App::Yath::Script`
  namespace itself (only its `V#` handler is ours).

## Migration chunks

Order mirrors `ARCHITECTURE.md` §1.1. Status: ✅ done · 🚧 in progress · ⬜ not started.

| # | Chunk | Status | Refs |
|---|-------|--------|------|
| 1 | Mechanical renames + version bump | ✅ | `2ea678e`, `aa6e5eb` |
| 2 | Argument processing → `Getopt::Yath` | ⬜ | — |
| 3 | Collector swap → `Test2-Collector` (yath collector reads `.jsonl.zst`) | ⬜ | — |
| 4 | Collectors wrap every yath-started process | ⬜ | — |
| 5 | Transition-only pipelining + Monitor-style state sync | ⬜ | — |
| 6 | Renderer rewrite (base finds `.jsonl.zst`) | ⬜ | — |
| 7 | System-load service (gate concurrency on cpu/mem) | ⬜ | — |
| 8 | Database + UI inline (`DBIx::QuickORM`, sqlite logs) | ⬜ | — |

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

## Current state

- **Namespaces/versions:** fully on the 2.0 names (`App::Yath2`,
  `Test2::Harness2`, dist `Test2-Harness2`, versions `2.000000`).
- **Logic:** otherwise still 1.0. The collector pipeline is still the in-tree
  1.0 implementation (not yet `Test2-Collector`). Option handling is still
  1.0's `App::Yath2::Options` (not yet `Getopt::Yath`). No harness service,
  transition channel, system-load service, or QuickORM DB layer yet — those
  are `[target]` in `ARCHITECTURE.md`.
- **Not renamed (intentional):** `Test2::Formatter::*`, `Test2::Tools::*`,
  `App::Yath::Script`.

## Next

**Chunk 2 — migrate argument processing to `Getopt::Yath`** (`ARCHITECTURE.md`
§2.3). Reference: the abandoned 2.0 attempts under `reference/old2`–`old4`
already use `Getopt::Yath`.
