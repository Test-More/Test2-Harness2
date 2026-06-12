# Rendering / Formatter Rewrite — Design Discussion

**Date:** 2026-05-17
**Status:** Discussion only. No code written. No plan started. Resume here.

## Trigger

Exodist wants to redesign how rendering works in yath 2.0. Current system has a single push-stream model where every event flows through every renderer (via filter chains). Proposal: split into **formatters** (pure artifact-to-format conversion) and **renderers** (assemble + emit), with a pull-based model driven by log-watching.

## Current System (baseline)

(Reference: `ARCHITECTURE.md` §13; live code under `lib/App/Yath2/Renderer/`, `lib/App/Yath2/OutputManager.pm`, `lib/App/Yath2/Options/Renderer.pm`.)

- `yath test` forks a single renderer child running `App::Yath2::Renderer::Driver`.
- Driver tails on-disk log, synthesizes lifecycle facets (`harness_run`, `harness_job_start`, etc.) from raw transition events.
- Synthesized + raw events feed `OutputManager`, which groups renderers by identical `desired_filters` pipelines and dispatches each event through the chain.
- Renderers implement `render_event($event)` and lifecycle hooks (`start`, `finish`, `signal`, `end_of_events`).
- Built-ins: `Default` (TUI), `Summary` (JSON file), `JUnit`, `DB` (async, own process), `Logger`, `Notify`, `TAPHarness`, `ResetTerm`, `Server`.
- `Default` uses `Renderer/Default/Composer.pm` + `Theme.pm` for facet-to-line conversion.
- Filters are stateless per-event pass/drop (Verbose/Quiet). QVF (quiet-verbose-on-failure) handled via upstream buffering hack, not filter layer.

## Proposed Design

### Two-layer split

**Formatters** — pure converters keyed by output format name.

- Name == type: `html`, `tty`, `text`, `csv`, `jsonl`, etc.
- Each formatter declares an input artifact kind and produces a single output format.
- Receives the artifact plus a context struct (which run, which job, etc.).
- **Leaf-only conversion** (recommended; open question, see below): formatter does not recursively pull other artifacts. Renderer is responsible for composing multiple formatted pieces.
- Formatters may declare themselves **append-capable** (e.g., `jsonl`). Non-append-capable formatters cache only sealed artifacts.

**Renderers** — assemble formatted output and emit to a sink.

- `Terminal` (replaces `Default`) — uses `tty` formatter, ANSI escapes, theme colors.
- `Text` — uses `text` formatter, no ANSI.
- `Server` — uses `html` formatter, serves web UI.
- `Summary`, `JUnit`, `Logger`, `Notify` continue to exist, refactored against new contract.
- `DB` renderer **deleted** (was an event-stream sink; log layer already handles DB-backed logs).

### Pull, not push

- Renderers subscribe to **producer lifecycle notifications**, not the raw event stream.
- Notification kinds: `producer_started`, `producer_progress`, `producer_sealed`. Producers: services, runs, jobs, etc.
- On notification, renderer decides whether to fetch any artifacts (spec, report, events, stdout, stderr) and in which format.
- **Default behavior:** most renderers ignore `events.jsonl` until the producing process is sealed.
- **Opt-in tailing:** a renderer can declare it wants to tail a specific artifact early (e.g., verbose Terminal wants events as they arrive). Declarative `desired_tails` on the renderer class. Watcher only watches for new entries in files at least one renderer cares about.

### Notification source

- A new layer replaces `Driver`: a **log watcher** that reads the log and emits producer notifications.
- Live logs: tail-watch.
- Sealed logs (extracted dir, DB, tarball): finite iterate.
- Notifications are derived **entirely from reading the log**. No IPC from the harness for normal flow.
- Existing log-reading code in the repo already supports most of what's needed (per Exodist).

### Renderers run as their own processes

- Every renderer is its own process, implementing `IPC::Manager::Role::Service`.
- `yath test` (and similar commands) spawns each renderer service, hands over settings via IPC at spawn time.
- When the harness reports done, `yath test` sends an IPC shutdown message to each renderer, then waits for shutdown ack.
- Subscription registry is built at spawn time from each renderer's declared interests; static per-run, no dynamic re-subscribe.

### Replay parity

- Live and non-live runs use the same renderer/formatter/watcher code paths.
- Any log (live, extracted, tarball, DB) can be rendered.

### Caching

- Formatter outputs cached in the log:
  - **Live / extracted / DB logs:** cache writes allowed.
  - **Tarball logs:** read-only, no cache writes.
- Cache only **sealed** artifacts by default. Append-capable formatters (jsonl) may cache mid-flight with per-entry framing.
- Cache files **zstd compressed** by default. Append-capable formats use per-entry zstd frames (concatenated; `zstdcat` reads them natively). Sealed full-file = single zstd frame.
- Cache version tracked per-blob (inline-in-blob recommended; see open question). Meta artifact in log root holds the index of formatter versions in use.

### Filters

- Filter layer goes away. Renderer pulls only what it wants; no need to filter a firehose.
- Pipeline-sharing optimization replaced by **formatter-output memoization**: within a process and via on-disk cache, repeated requests for the same (artifact, formatter, version) tuple are deduplicated.

### QVF and verbosity

- Buffer hack disappears. QVF becomes a Terminal renderer pull policy: on `job_sealed`, if pass → one-line; if fail → fetch events in verbose form.
- Verbosity drives **which artifacts** a renderer requests and **at what format detail**, not a filter chain.

## Decisions Made

| # | Decision |
|---|----------|
| 1 | Default renderer behavior: ignore `events.jsonl` until producer sealed. Tail is opt-in via declarative `desired_tails`. |
| 2 | Watcher only watches new entries in files at least one renderer subscribes to. |
| 3 | Cache only sealed artifacts by default. Append-capable formatters (jsonl) may cache mid-flight. |
| 4 | Cache stored zstd-compressed. Sealed = single frame. Append-capable = per-entry frames. |
| 5 | Formatter versions tracked via meta artifact in log root. (Storage authority: see open Q.) |
| 6 | Formatter name == output type: `html`, `tty`, `text`, `csv`, `jsonl`. |
| 7 | Filter layer removed. Replaced by pull + formatter memoization. |
| 8 | DB renderer deleted entirely (not folded into log backend, just gone). |
| 9 | Ordering is best-effort, driven by log append order. |
| 10 | Existing log-reader infrastructure assumed sufficient for watcher backends. |
| 11 | Renderer iface: `start($log_handle, $settings)`, `on_producer($descriptor)`, `finish()`, `signal($sig)`. Renderer pulls via `$log_handle->fetch($artifact_ref, formatter => $name)`. |
| 12 | All renderers run as their own process (`IPC::Manager::Role::Service`). `yath test` sends IPC shutdown when harness done, then waits. |
| 13 | Migration plan / staging — **deferred**. Exodist wants to map renderers individually before discussing how to convert. |
| 14 | QVF becomes renderer pull policy, not buffered filter. |
| 15 | Server renderer fits the new model cleanly (HTTP handlers pull cached HTML via formatter). |

## Open Questions

1. **Formatter context scope.** Can a formatter call back into the log handle to fetch other artifacts (recursive), or strictly leaf conversion (input + ctx → bytes)? Leaning **leaf**: keeps formatters trivially cacheable and parallelizable; renderer composes. Exodist to confirm.
2. **Meta-artifact authority for cache versions.** Meta in log root authoritative (cache writes must update meta, mismatched cache invalid), or version embedded inline in each cached blob (meta is an index/summary)? Recommend **inline-in-blob**; meta acts as index.
3. **IPC shutdown mechanism.** Assumed to be `IPC::Manager` service messages over each renderer's service socket. Confirm.
4. **Subscription registry shape.** Built at spawn time, static for the run. Confirmed in principle — exact data shape TBD.
5. **Migration staging.** Whole approach deferred. Will need a renderer-by-renderer mapping before sequencing.

## Items to Cover Next Session

- Walk through each existing renderer (`Default`, `Summary`, `JUnit`, `DB`, `Logger`, `Notify`, `TAPHarness`, `ResetTerm`, `Server`) and decide: keep / rename / split / delete, and what formatter(s) each will use.
- Define the artifact kind registry (run_spec, run_report, job_spec, job_report, events, stdout, stderr, summary, ...).
- Decide formatter context scope (open Q #1).
- Decide cache version authority (open Q #2).
- Sketch the watcher's notification descriptor shape.
- Then a real plan with stages.

## Pointers

- Renderer code today: `lib/App/Yath2/Renderer/`, `lib/App/Yath2/Renderer.pm`, `lib/App/Yath2/Renderer/Driver.pm`.
- Output manager: `lib/App/Yath2/OutputManager.pm`.
- Options: `lib/App/Yath2/Options/Renderer.pm`.
- Theme + composer: `lib/App/Yath2/Theme.pm`, `lib/App/Yath2/Renderer/Default/Composer.pm`.
- Test command: `lib/App/Yath2/Command/test.pm`.
- Authoritative spec: `ARCHITECTURE.md` §13 (renderer contract, OutputManager, filters).
