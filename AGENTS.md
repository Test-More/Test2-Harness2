# AGENTS.md

This project is a ground-up rewrite of yath 2.0. It is divided into two parts:

- **Part 1 — `Test2::Harness2`.** Library only. The database, schema,
  scheduler, collectors, launchers, resources, preloads, recorders. No
  CLI. See `PART_1_PLAN.md` for the staged backlog.
- **Part 2 — `App::Yath2`.** User-facing `yath` command, options layer,
  output pipeline, persistent daemons, and read-side tooling on top of
  the harness's own database (querying past runs, rendering archived
  logs, etc.). The harness database from Part 1 *is* the archive —
  there is no separate log-archive or DB-backend layer. See
  `PART_2_PLAN.md` (scaffold; will be filled in once Part 1 is
  complete).

The new architecture **does not use `IPC::Manager`**. Every previous
attempt under `reference/` built on `IPC::Manager`, which turned out
to be bulky and complicated. The new design routes every cross-process
communication through the runner's database. If a doc, design note, or
piece of reference code says to use `IPC::Manager`, treat that as
outdated and follow `ARCHITECTURE.md` instead.

## Reference trees

- `reference/legacy/` — yath 1.0. Reference only.
- `reference/old2/` — earlier 2.0 attempt. Reference only. The
  collector implementation here is simpler than `old3`'s.
- `reference/old3/` — most recent attempt; based on `IPC::Manager`.
  Reference only. Most utility code (parsers, auditor, resources,
  directives, JSON / Zstd / EventEmitter helpers, TestFile, schema
  SQL) is intended to be copied (or copied-and-adapted) from here.
- `reference/botched/` — failed refactor attempt. Reference only.

**Never modify anything under `reference/`.** Copy out, modify the
copy. The reference trees are immutable history we read against.

Always check `reference/old3` first when answering a "how did this
used to work?" question. If `old3`'s answer conflicts with
`ARCHITECTURE.md` or `STYLE_GUIDE.md`, follow the current docs and
**stop and ask** if the conflict is non-trivial.

You are an expert Perl developer. Write code following the patterns
and styles of "Exodist" (Chad Granum) as seen throughout this
codebase.

## Canonical sources of truth

1. **`ARCHITECTURE.md`** — Authoritative spec for the new
   `Test2::Harness2` implementation (Part 1).
2. **`STYLE_GUIDE.md`** — Rules for code in this repository.
3. **`PART_1_PLAN.md`** — Stage-by-stage Part-1 backlog. Stages are
   sequential; each stage starts with you asking the user clarifying
   questions, then implementing, then asking the user to review.
4. **`PART_2_PLAN.md`** — Scaffold + notes for Part 2 (the
   `App::Yath2` rewrite). Append notes here whenever Part-1 work
   surfaces something that affects Part 2.
5. **This file** — Per-repository agent / contributor preferences.

`new_plan` (untracked, repository root) is the original chartering
document this rewrite was built from. Its content has been consumed
into the four canonical docs above; treat it as **historical input
only**, not as authoritative. If it conflicts with the canonical
docs, the canonical docs win. Do not cite it from code or
documentation going forward.

If you are about to implement something that seems to conflict with
`ARCHITECTURE.md`, stop and verify. The most common cause is that
the other document is stale — follow `ARCHITECTURE.md` and flag the
inconsistency.

## Working in stages

`PART_1_PLAN.md` is structured as numbered stages. Each stage:

1. Starts with the agent **asking clarifying questions** about what
   the user wants out of the stage before writing code.
2. Implements the stage.
3. Asks the user to review before moving on to the next stage.

Do not jump stages without explicit direction.

If during a Part-1 stage you encounter something that should be
deferred to Part 2 (e.g. a CLI option, a renderer concern, a
discovery / project-detection question), **add a note to
`PART_2_PLAN.md`** rather than expanding the Part-1 stage. Cross-cutting
notes belong with the document that owns the work.

### Pre-review checks

Before handing a stage / worktree / branch to the human for review
or merge, run the following passes against B<every file the branch
touched> (typically `git diff --name-only $base...HEAD`). Resolve
anything they turn up, then re-run the test suite.

1. **Style-guide pass.** Read `STYLE_GUIDE.md` and verify each
   touched file conforms. Common slips: `eval` patterns (always
   check the return value, never raw `$@`), `croak` vs `die`,
   `//=` for defaults, `Time::HiRes::sleep` for sub-second waits,
   `Object::HashBase` slot ordering, no trailing whitespace, and
   the "named subs in object modules must be methods, not
   functions" rule (see STYLE_GUIDE.md "Naming and structure"
   — `_flavor_from_dsn` style functions inside `use
   Object::HashBase` / `with '...'` modules are violations).
   Run `perl scripts/audit-methods-not-functions lib` and resolve
   every reported hit. Fix everything you find.

2. **POD pass.** Verify the file follows the POD layout in
   `STYLE_GUIDE.md` ("POD" section): `NAME` / `DESCRIPTION` /
   `SYNOPSIS` (plus `ATTRIBUTES` for HashBase-style classes) at
   the top of the file, `EXPORTS` / `PUBLIC METHODS` / `PRIVATE
   METHODS` inline above each sub, `SOURCE` / `MAINTAINERS` /
   `AUTHORS` / `COPYRIGHT` under `__END__`. Run `podchecker` on
   every `.pm` touched; resolve every error and warning.

3. **Util / role / base-class reuse pass.** Re-scan touched files
   for logic that already exists as a utility. The relevant
   homes are `Test2::Harness2::Util`, `Test2::Harness2::Util::*`,
   `Test2::Harness2::Role::*`, and the matching DB row classes.
   If the file open-codes something a util / role / base class
   already provides, switch to using it. If you see the same
   logic appearing in three or more places across the touched
   files, extract it to a util / role / base class instead of
   leaving the duplication.

These three passes are mandatory, not optional. Land their fixups
either as cleanup commits at the end of the stage or by amending
the relevant feature commits. Only after they pass should you
announce the stage as ready for review.

## AI task documentation

`AI_DOCS/` is for durable context that the code and commit history
cannot carry on their own. Default: **do not** write one. Only write
an AI_DOC when the task falls into one of these categories:

- A new significant feature or full PLAN stage completion.
- An architectural change (process topology, schema layout, service
  lifecycle, collector contract, recorder contract, preload
  mechanism, etc.).
- A non-trivial refactor that changes module boundaries, public
  interfaces, or coding patterns across multiple files.

Do **not** write an AI_DOC for:

- Bug fixes. Instead, if the fix directly contradicts or extends
  what an existing AI_DOC or `ARCHITECTURE.md` section already says,
  update that document in place. Otherwise the commit message is
  the only record.
- Test-only work (adding tests, fixing flakes, test refactors).
  Commit messages only.
- Trivial cleanups (typos, whitespace, perltidy passes, comment
  tweaks).

When an AI_DOC is warranted, it should describe:

- What the task was and what triggered it.
- Decisions made, including alternatives considered and why they
  were rejected.
- Any architectural changes introduced.

Filename convention: `AI_DOCS/<YYYY-MM-DD>-<short-slug>.md`.

Any decision to deviate from `ARCHITECTURE.md` must **also** be
recorded as an addendum section appended to `ARCHITECTURE.md`
itself, explaining and justifying the deviation. `ARCHITECTURE.md`
remains the authoritative spec; addenda exist so anyone reading it
sees the deviation and its reasoning in one place. This rule
applies regardless of whether an AI_DOC is also written.

### Referencing AI docs from code

User-facing text — POD, command `description` / `summary` / help
output, `die` / `warn` / `croak` / `print` strings, and any other
diagnostic shown to users — must **never** reference any `.md`
document (including `ARCHITECTURE.md`, `PART_1_PLAN.md`,
`PART_2_PLAN.md`, `STYLE_GUIDE.md`, `SCHEMA.md`, `AI_DOCS/*`,
etc.). If the rule or behavior matters to the user, restate it
in plain prose; if it does not, drop the reference. Users cannot
read internal documentation and should not be pointed at it. POD
is user-facing — see `STYLE_GUIDE.md` "POD style".

Regular `#` comments in code may reference `ARCHITECTURE.md` or
`STYLE_GUIDE.md` (both tracked, both authoritative). References to
`AI_DOCS/*` or other markdown files are **discouraged** and should
only appear when the comment cannot stand on its own without one.
When a reference is included, it must be specific: full path plus
a section identifier. A bare token like `D6` or `M2 step 4+5` is
not acceptable.

When in doubt, restate the rule itself in the comment and skip the
reference.

## Testing

For Part 1 (no `yath` command yet), tests run via:

```
prove -Ilib -j16 -r t/
```

Eventually yath will be self-hosting and the runner moves to:

```
perl -Ilib scripts/yath test -D -j24 [files...]
```

Test layout:

- `t/` — human-authored tests.
- `t/AI/` — AI-generated tests. Mirror whatever subdirectory layout
  `t/` uses (e.g. `t/unit/Collector.t` ↔ `t/AI/unit/Collector.t`).
- Tests copied from `reference/` count as human-authored even when
  the copy is done by AI.

It is OK to add helper scripts under `t/scripts/` for tests to
invoke (`t/scripts/collector` is the canonical development driver
for the collector — see `ARCHITECTURE.md` §5.9).

It is also OK to add throwaway scripts under `scripts/` to verify
in-progress functionality during a stage. Such scripts are not part
of the shipped distribution.

## Style

See `STYLE_GUIDE.md`. Pay particular attention to the `eval`
patterns — agents frequently get them wrong.

## Dependency rules

- `Test2::Harness2` must not load `App::Yath2*` modules directly.
  Dynamic loading is acceptable only when driven by user-provided
  options that explicitly request `App::Yath2*` functionality.
- Hard-required CPAN deps for `Test2::Harness2` / `Test2::Formatter::Stream2`
  are fine. Non-default database drivers (Postgres, MySQL, MariaDB,
  Percona) are loaded only when the caller points the harness at a
  matching DSN, so their `DBD::*` modules must be Suggests /
  Recommends in `dist.ini`, not hard requirements.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has
  not yet been pushed to origin, amend that commit instead of
  creating a new one.

## Worktrees

- Significant work requires a worktree. Place worktrees in
  `worktrees/`.
- Documentation-only work (editing `ARCHITECTURE.md`,
  `PART_1_PLAN.md`, `PART_2_PLAN.md`, this file, etc.) does not
  require a worktree.

## Architecture quick-reference

The full spec lives in `ARCHITECTURE.md`. The headlines an agent
must internalise before writing any code:

- **No `IPC::Manager`.** Cross-process state is the database.
- **`Test2::Harness2` is a library handle**, not a daemon. The
  `Test2::Harness2` object lives in the caller's process.
- **The scheduler is the only "harness-wide" service.** There is no
  separate harness service and no run service.
- **Every collected process gets exactly one collector.** Spawns
  (`yath spawn`-style detached processes) do **not** get a
  collector.
- **Collectors are direct children of the service that started
  them.** Regular (`ForkExec` / `Win32` / `Default`) launchers
  are in-process objects owned by the scheduler, so those
  collectors are children of the scheduler. Preload launchers
  proxy to their preload service over a Unix socket, so those
  collectors are children of the preload service. No double-fork,
  no detachment.
- **`Object::HashBase` for objects; `Role::Tiny` for roles.** They
  compose — `Object::HashBase` may be used inside roles and used by
  consumers of roles that use it.
- **`Test2::Util::UUID` for UUIDs** (v7; generated in Perl, not in
  the database).
- **`DBIx::QuickDB` for ephemeral database setups in tests and for
  spinning up non-SQLite databases on the fly.** Never used for
  the default SQLite path — that uses `DBD::SQLite` directly.
- **No `DBIx::Class`** for the harness's row layer. SQL via DBI
  (optionally aided by `SQL::Abstract`).
- **`Atomic::Pipe`** in mixed-data mode is the wire between
  collected process and collector. zstd is first-class; the
  recorder may write compressed bursts through to disk without
  recompressing. See `~/projects/Atomic-Pipe` for the source if
  you need to understand the framing or zstd handling.
