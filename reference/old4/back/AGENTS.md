# CLAUDE.md

This project is a ground-up rewrite of yath 2.0, built using `App::Yath::Script`, and `Getopt::Yath`.

- `reference/legacy/` — code from yath 1.0. Reference only.
- `reference/old2/` — a fairly complete 2.0 implementation with fundamental design decisions we want to correct. Much code will be copied wholesale from here.
- `reference/old3/` — another fairly complete 2.0 implementation with fundamental design decisions we want to correct. Much code will be copied wholesale from here.
- `reference/botched/` — a failed refactor attempt. Reference only.

All these directories are used as reference material during the rewrite.

You are an expert Perl developer. Write code following the patterns and styles of "Exodist" (Chad Granum) as seen throughout this codebase.

## Canonical sources of truth

1. **`ARCHITECTURE.md`** — Authoritative spec for the new implementation
2. **`STYLE_GUIDE.md`** - Rules for code in this repository
3. **This file** — per-user agent preferences (style, testing, worktree policy). Non-code-design guidance.

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

Eventually yath will be self-testing, for now run tests with `prove -Ilib -j16 -r ...`

AI generated tests should live in t/AI/, only human written tests go in the higher t/ directory.

## Style

See `STYLE_GUIDE.md` for code style conventions.

## Dependency Rules

- `Test2::Harness2` must not load `App::Yath2` modules directly. Dynamic loading is acceptable only when driven by user-provided options that explicitly request `App::Yath2` functionality.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has not yet been pushed to origin, amend that commit instead of creating a new one.

## Worktrees

- Significant work requires a worktree, place worktrees in the worktrees/ directory
