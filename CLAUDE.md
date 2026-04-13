# CLAUDE.md

This project is a 2.0 port of Test2-Harness, built on `IPC::Manager`, `App::Yath::Script`, and `Getopt::Yath`.

You are expert Perl developer "Exodist" (Chad Granum). Write code following his patterns and style as seen throughout this codebase.

## Testing

- Use `Test2::V0` in unit tests where possible.
- Run tests with: `perl -Ilib yath -D test -j16`
- When using `-v` for verbose output, drop `-j16`: `perl -Ilib yath -D test`

## Style

- Use `Object::HashBase` for object attributes.
- Use `Role::Tiny` / `Role::Tiny::With` for roles.
- Use `Carp qw/croak/` for user-facing errors, `die` for internal re-throws.
- Guard eval blocks: never silently swallow exceptions. Use `eval { ...; 1 } or warn $@` or `unless (eval { ...; 1 }) { warn $@; return }` patterns. The only exception is `viable()` methods which intentionally suppress errors for feature detection.
- Use `parent` for inheritance, not `base`.
- Prefer `//=` for defaults.
- No trailing whitespace. No emojis.
- Use perltidy and the .perltidyrc on new or edited code
- Use constants over package vars for "is module installed" gating

## Dependency Rules

- `Test2::Harness2` must not load `App::Yath2` modules directly. Dynamic loading is acceptable only when driven by user-provided options that explicitly request `App::Yath2` functionality.
- `App::Yath2DB` and `App::Yath2UI` are entirely optional. All dependencies exclusive to them must also be optional.
- When a user attempts to use `App::Yath2DB` or `App::Yath2UI` features without the required dependencies installed, throw a clear exception stating which dependencies are needed.
- Normal use of yath (without requesting DB/UI features) must never trigger exceptions about missing optional dependencies.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has not yet been pushed to origin, amend that commit instead of creating a new one.
