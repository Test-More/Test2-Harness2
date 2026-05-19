# Output Pipeline Refactor

**Date:** 2026-04-24
**Branch:** renderers_and_filters

## What the task was

Refactor the output subsystem to enforce a clean boundary between event
filtering and event rendering. The original proof-of-concept renderers
(STDOUT, Log, SQLite) mixed filtering decisions with formatting logic and
were replaced with a properly layered pipeline.

## What was built

### Pipeline model

```
Event source (TBD — Chad's ArtifactLayer)
    │  (dispatches every event — no mode filtering)
    ▼
OutputManager
    ├─► [Filter chain A] ──► Renderer A
    │                   └──► Renderer B   ← same chain, one run
    └─► [Filter chain B] ──► Renderer C
```

Renderers that declare identical filter chains (all class-name strings,
same order) share one pipeline in the OutputManager. The filter chain runs
once per event and the surviving event is fanned out to all renderers in
that group. Renderers with distinct chains (or with pre-built filter
instances) get independent pipelines.

### `lib/App/Yath2/OutputManager.pm` (new — replaces RendererManager)

Manages a list of `{key, filters, renderers}` pipeline entries. At
`add_renderer` time it calls `$renderer->desired_filters`, builds the
filter chain, and either attaches the renderer to a matching existing
pipeline (same key) or creates a new one. `start()` is called on the
renderer immediately at registration. `dispatch($event)` runs each
pipeline's filter chain once and fans out to all renderers in it.

Lifecycle is tied to object lifetime: `finish()` is called on all
renderers when `OutputManager` goes out of scope (via `DESTROY`) or when
explicitly called. A guard prevents double-firing.

### `lib/App/Yath2/Filter.pm` (new — base class)

Interface: `filter_event($event)` → `$event | undef`. Returns the event
(possibly transformed) to pass it downstream, or `undef` to drop it.
Filters are stateless or near-stateless; stateful buffering belongs
upstream.

### `lib/App/Yath2/Filter/Verbose.pm` (new)

Passes events with at least one displayable facet (assert, info, errors,
plan, harness job/run summaries). Drops housekeeping events with no
user-visible content.

### `lib/App/Yath2/Filter/Quiet.pm` (new)

Passes only `test_job_completed` and `run_complete` harness facet
events. Everything else is dropped.

### `lib/App/Yath2/Renderer.pm` (updated)

Added `desired_filters()` — default returns `()`. Subclasses override to
declare their filter chain based on settings (log level, verbosity, etc.).
Removed the old Getopt-coupled attribute list; `<settings` is retained as
the single entry point for renderer configuration.

### Removed

- `lib/App/Yath2/Renderer/STDOUT.pm` — proof-of-concept
- `lib/App/Yath2/Renderer/Log.pm` — proof-of-concept
- `lib/App/Yath2/Renderer/SQLite.pm` — proof-of-concept
- `lib/App/Yath2/Renderer/Role/Async.pm` — no longer needed
- `lib/App/Yath2/RendererManager.pm` — replaced by OutputManager

## Design decisions

**QVF is not a filter.** QVF (quiet-verbose-on-failure) requires buffering
all of a job's events and flushing them only on failure. That requires
knowing when a job ends, which is information the event source (not the
filter chain) has. Doing it in the filter chain would need stateful buffers
keyed by job_id, which is awkward and inefficient. QVF belongs upstream.

**Shared pipelines, not global pre-filter.** A single global filter chain
that fans out to all renderers would prevent renderers from having
independent filtering behaviour. Instead, renderers that request identical
chains share a single chain run (efficiency), while renderers with
different chains remain independent (correctness).

**Lifecycle via DESTROY.** Renderer `start()` fires at `add_renderer`
time; `finish()` fires when the OutputManager is destroyed. Callers that
need early deterministic teardown can still call `finish()` explicitly —
it is idempotent.

**ArtifactLayer deferred.** The ArtifactLayer implementation (polling
`run_progress` IPC) was removed. Chad is implementing this component;
the OutputManager and filter/renderer infrastructure stands ready to
receive events from whatever event source he builds.
