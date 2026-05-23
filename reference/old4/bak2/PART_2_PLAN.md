# PART 2 PLAN — App::Yath2 (scaffold)

**Status: scaffold.** The Part-2 work — the `yath` command, the
options layer, the output / renderer pipeline, the persistent-daemon
command set, and the optional database / web-UI back-ends — will be
specced out in detail once `PART_1_PLAN.md` is complete. This file
exists so that Part-1 work has a place to drop deferred notes as it
goes.

## When to update this file

Append a bullet to the appropriate section below whenever Part-1
work surfaces something that belongs to Part 2:

- A CLI flag or option the user mentioned in passing.
- A renderer / output-pipeline concern.
- A discovery, project-detection, or `.t2h2` consumer hook.
- Anything that depends on the `App::Yath2*` namespace and so
  cannot be implemented in Part 1.
- An open design question that we deliberately deferred so we
  could keep moving on Part 1.

Keep the note tight: one or two sentences naming the thing and the
context. Detail goes in the eventual Part-2 design doc; this file
just makes sure nothing gets lost.

When Part 1 ships, this file is the starting raw material for the
real Part-2 spec.

---

## Scope (target shape, subject to revision)

Per `ARCHITECTURE.md` §16, Part 2 covers everything `Test2::Harness2`
deliberately does not:

- The `yath` command (single binary, dispatches per sub-command).
- The options layer (`App::Yath::Script`, `Getopt::Yath`).
- The persistent-daemon command set: `yath start`, `yath run`,
  `yath stop`, `yath kill`, `yath status`, `yath list`.
- The non-daemon commands: `yath test`, `yath spawn`, `yath archive`,
  `yath extract`, `yath inspect`.
- The output pipeline: ArtifactLayer, OutputManager, filters,
  renderers.
- Read-side tooling on top of the database — querying past runs,
  rendering archived logs, exporting subsets, browsing job history.
  All the data already lives in the database from Part 1; Part 2 is
  what surfaces it to users.
- Project auto-detection (walking up looking for `.git`,
  `dist.ini`, `META.json`, `Makefile.PL`, etc.).
- The `--no-resource=<Name>` family of CLI flags (notably
  `--no-resource=TempDir`).

Out of scope for the foreseeable future (intentionally **not** Part 2):

- A separate `App::Yath2::DB` namespace. The harness already owns
  the database — there is no separate "log database" layer to wrap.
- A web UI. Was previously sketched as `App::Yath2::UI`; deferred
  indefinitely until someone explicitly wants it.

---

## Standing notes carried over from `new_plan`

These notes were captured in the original `new_plan` and apply
directly to Part 2; they are recorded here so we don't lose them
once `new_plan` is consumed.

- **`yath spawn`.** Built on the preload-launcher spawn socket
  (Part 1 §11 / `ARCHITECTURE.md` §7.3). Behaves "just like running
  the command" except the child inherits the preload's loaded-module
  state. The launcher emulates a normal foreground process: child
  stdout/stderr go to requester stdout/stderr, requester stdin goes
  to the child, signals are forwarded, the child's exit code becomes
  the requester's exit code.
- **`yath start` / `yath run`.** Built on the Part-1 persistent
  runner. Discovery via the `.t2h2` files written by the harness
  handle. `yath run` queues a run against the discovered runner and
  exits with the run's pass/fail status.
- **`yath stop` / `yath kill`.** Discover a runner via its `.t2h2`
  file, send it the right shutdown sequence. `stop` is graceful;
  `kill` is escalation.
- **Discovery cleanup.** Whichever Part-2 command does discovery is
  also responsible for cleaning up stale `.t2h2` files whose pids no
  longer exist. (Part 1's discovery helper, when one exists, can do
  the same; Part 2 just needs to know it's a shared responsibility.)
- **Default resources opt-out.** `Test2::Harness2::Resource::TempDir`
  is enabled by default in Part 1. Part 2 needs a `--no-resource=Name`
  flag to opt out.
- **Project auto-detection.** Part 1 accepts an explicit project
  string (and uses `t2h2` in development). Part 2 walks up from
  cwd for `.git`, `dist.ini`, `META.json`, `META.yml`,
  `Makefile.PL`, etc. to infer it.

---

## Deferred during Part 1

> Append bullets here as Part-1 work uncovers Part-2-shaped items.
> Format: `- **<short label>.** <one or two sentence note.>`

*(empty — fill in as Part 1 progresses)*

---

## Open questions to revisit when speccing Part 2

> Append bullets here when a Part-1 stage hits a design question
> that we punted on because it's really a Part-2 concern.

*(empty — fill in as Part 1 progresses)*

---

## References

When Part 2 starts, the existing implementations are the obvious
starting point:

- `reference/old3/lib/App/Yath2/**` — most recent attempt at the
  Part-2 surface. The OutputManager / filter / renderer split and
  the persistent-daemon command set all have working code here.
  Drop everything that depends on `IPC::Manager`. Also drop the
  `App::Yath2::Log` / `App::Yath2::DB` / `App::Yath2::UI` trees:
  the new design folds everything those provided into Part 1's
  single canonical database, so there is nothing here to port —
  only the renderer, options, and command surfaces are reusable.
- `reference/old2/lib/App/Yath2/**` — earlier attempt; less complete
  but sometimes simpler.
- `reference/legacy/lib/App/Yath/**` — yath 1.0. Reference for
  historical command shapes and option names.

Treat all of these the same way Part 1 treats `reference/` —
copy out, modify the copy, never edit in place.
