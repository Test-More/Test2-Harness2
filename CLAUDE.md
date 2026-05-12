# CLAUDE.md

This project is a ground-up rewrite of yath 2.0, built on `IPC::Manager`, `App::Yath::Script`, and `Getopt::Yath`.

- `reference/legacy/` — code from yath 1.0. Reference only.
- `reference/old2/` — a fairly complete 2.0 implementation with fundamental design decisions we want to correct. Much code will be copied wholesale from here.
- `reference/botched/` — a failed refactor attempt. Reference only.

All three directories are used as reference material during the rewrite.

You are an expert Perl developer. Write code following the patterns and styles of "Exodist" (Chad Granum) as seen throughout this codebase.

## Canonical sources of truth

1. **`ARCHITECTURE.md`** — the single authoritative spec. Part I (§1–§15) covers process topology, IPC identities, collector and service lifecycle, event framing, artifact routing, preload-as-resource model, and the renderer contract. Part II (§16–§26) covers the module map, on-disk layout, utilities, external deps, coding conventions, and the test suite. Anything in `PLAN` or this file that conflicts with `ARCHITECTURE.md` is outdated. (The former `IPC_AND_LOGGERS` has been merged into Part I.)
2. **`PLAN`** — stage-by-stage implementation backlog. References `ARCHITECTURE.md`. Stage scope and sequencing are authoritative here; protocol / topology / semantics are not — those live in `ARCHITECTURE.md`.
3. **This file** — per-user Claude Code preferences (style, testing, worktree policy). Non-code-design guidance.

If you're about to implement something that seems to conflict with `ARCHITECTURE.md`, stop and verify — it is very likely the other document is stale and you should follow `ARCHITECTURE.md` while flagging the inconsistency for a follow-up edit.

## AI task documentation

AI_DOCS are for durable context that the code and commit history cannot carry on their own. Default: **do not** write one. Only write an AI_DOC when the task falls into one of these categories:

- A new significant feature or a full PLAN stage.
- An architectural change (process topology, IPC, event framing, service lifecycle, renderer contract, etc.).
- A non-trivial refactor that changes module boundaries, public interfaces, or coding patterns across multiple files.

Do **not** write an AI_DOC for:

- Bug fixes. Instead, if the fix directly contradicts or extends what an existing AI_DOC or `ARCHITECTURE.md` section already says, update that document in place. Otherwise the commit message is the only record.
- Test-only work (adding tests, fixing flakes, test refactors, moving tests under `t/AI/`). Commit messages only.
- Trivial cleanups (typos, whitespace, perltidy passes, comment tweaks).

When an AI_DOC is warranted, it should describe:

- What the task was and what triggered it.
- Decisions made, including alternatives considered and why they were rejected.
- Any architectural changes introduced.

Filename convention: `AI_DOCS/<YYYY-MM-DD>-<short-slug>.md`.

Any decision to deviate from `ARCHITECTURE.md` must **also** be recorded as an addendum section appended to `ARCHITECTURE.md` itself, explaining and justifying the deviation. `ARCHITECTURE.md` remains the authoritative spec; addenda exist so anyone reading it sees the deviation and its reasoning in one place. This rule applies regardless of whether an AI_DOC is also written.

### Referencing AI docs from code

User-facing text — POD, command `description` / `summary` / help output, `die` / `warn` / `croak` / `print` strings, and any other diagnostic shown to users — must **never** reference AI docs or any `.md` document (including `ARCHITECTURE.md`, `SCHEMA.md`, AI_DOCS entries, planning files, etc.). If the rule or behavior matters to the user, restate it in plain prose; if it does not, drop the reference. Users cannot read AI docs and should not be pointed at them.

Regular `#` comments in code may reference an AI doc, but only when **both** of these hold:

1. The referenced document is tracked in git. Comments must not reference untracked or gitignored files (e.g. `NEW_LOG_REFACTOR_*.md`, `docs/superpowers/...`, scratch planning files). Untracked docs can be deleted, renamed, or moved at any time, leaving the comment dangling.
2. The reference is specific: full path (or the document's repository-relative name) **plus** the exact section identifier — e.g. `AI_DOCS/2026-05-07-schema-redesign.md §D6`, `share/schema/SCHEMA.md §8`, `ARCHITECTURE.md §14`. A bare token like `D6`, `F18`, `K3`, or `M2 step 4+5` is not acceptable on its own — without a document name and section anchor a future reader cannot tell which document it points to.

When neither condition can be met, drop the cryptic code and state the rule itself in the comment so the surrounding prose stands on its own.

## Testing

- Use `Test2::V0` in unit tests where possible.
- Run tests with: `perl -Ilib yath -D test`. The harness auto-injects a JobCount resource (half the CPU cores, fallback 2) when no `-R` is given, so passing `-j16` is no longer needed. Override with `-R JobCount=N` only when the default is wrong for the workload.
- For verbose output: `perl -Ilib yath -D test -v` (still concurrent unless you also pass `-j1`).
- Tests that are substantially AI- or Claude-generated go under `t/AI/`, preserving the relative path beneath that prefix (e.g. `t/AI/unit/Foo.t`, `t/AI/integration/bar.t`). Anything outside `t/AI/` is reserved for tests originally written by humans; AI may modify those later as long as they stay readable. Tests copied in from `reference/old2/t/` or `reference/legacy/t/` count as human-authored and do **not** move under `t/AI/`.
- The `App::Yath::Script` wrapper (which ships the `yath` binary) is a separate distribution. By default `cpanfile` pulls the released CPAN version; to test against the unreleased code on `origin/script`, run `perl author/install-yath-script` (idempotent, only reinstalls when the branch SHA changes). The `ubuntu-script-branch` CI job runs the suite against that unreleased version on every PR.
- **Running `yath` commands from this repo:** the installed `yath` binary works directly when `-D` is placed *between* `yath` and the command. Examples:
  - `yath -D test t/AI/...`
  - `yath -D replay /path/to/logs/`
  - `yath -D extract /path/to/run.yath /tmp/out`
  - `yath -D archive /path/to/logs /tmp/run.yath`

  The `-D` flag tells the wrapper to load this checkout's `lib/` ahead of the installed dist, so changes in this branch take effect without reinstalling. Without `-D` the installed dist runs whatever was on CPAN.
- **Always set `AUTHOR_TESTING=1` when running tests.** Some tests gate themselves behind `Test2::Require::AuthorTesting` (slow, flaky-by-design, or otherwise not safe to ship as default-CI). Skipping them silently hides regressions during local development. Examples:
  - `AUTHOR_TESTING=1 prove -j16 -Ilib -It/lib -r t/AI` (prove still needs `-j16`; it has no auto-concurrency)
  - `AUTHOR_TESTING=1 yath -D test t/AI/...`

  The one exception: when validating the `AUTHOR_TESTING` gate itself (e.g., confirming a test correctly skips when the env var is unset), run that test once without the env var set to verify the skip path, then resume normal `AUTHOR_TESTING=1` runs.

## Style

See `STYLE_GUIDE.md` for code style conventions.

## Dependency Rules

- `Test2::Harness2` must not load `App::Yath2` modules directly. Dynamic loading is acceptable only when driven by user-provided options that explicitly request `App::Yath2` functionality.
- `App::Yath2::DB` ships in this dist but is only loaded by code that explicitly opens a DB-backed log. `App::Yath2::UI` is a separate optional dist. Dependencies exclusive to them must be optional.
- When a user attempts to use `App::Yath2::DB` features (specifically the DBIC backend) or `App::Yath2::UI` features without the required dependencies installed, throw a clear exception stating which dependencies are needed.
- Normal use of yath (without requesting DB/UI features) must never trigger exceptions about missing optional dependencies.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has not yet been pushed to origin, amend that commit instead of creating a new one.

## Worktree Config Inheritance

Both `/.claude/` and `/CLAUDE.md` are gitignored, so a freshly created worktree has no `.claude/` directory and (once the gitignore reaches its branch) no `CLAUDE.md` either. Claude Code running in the worktree would lose the project's per-project config — permissions, hooks, custom commands, agents, skills allowlist, and these very instructions. Superpowers and other locally-configured behaviors appear to "stop working" in worktrees for this reason.

After `git worktree add <worktree-path> ...` succeeds, and before starting work in the worktree, mirror the primary repo's config into the new worktree using symlinks so that future updates to the primary config automatically flow through:

    primary=/home/exodist/projects/Test2/Test2-Harness
    wt=<worktree-path>
    mkdir -p "$wt/.claude"
    find "$primary/.claude" -mindepth 1 -maxdepth 1 -not -name worktrees -print0 \
        | while IFS= read -r -d '' entry; do
            name=$(basename "$entry")
            [ -e "$wt/.claude/$name" ] && continue
            ln -s "$entry" "$wt/.claude/$name"
        done
    [ -e "$wt/CLAUDE.md" ] || ln -s "$primary/CLAUDE.md" "$wt/CLAUDE.md"

Rules:

- Symlink, do not copy — updates to the primary `.claude/` and `CLAUDE.md` must reach existing worktrees without manual resync.
- Never link `worktrees/` itself (would create a loop).
- Skip any entry that already exists in the worktree (e.g. a `CLAUDE.md` still carried by a branch that predates the gitignore change).
- Do this for every new worktree, not just the first one.
- The symlinked `SessionStart` hook still fires inside a worktree, but its "if cwd is the primary repo" guard prevents recursive worktree creation — leave that guard in place.
