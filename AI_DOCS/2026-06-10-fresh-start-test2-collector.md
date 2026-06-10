# Fresh start: orchestration model + collector extraction

## What and why

The user wrote `fresh_start` (repo root) capturing the direction for
this rewrite, and extracted the collector pipeline into a standalone
`Test2-Collector` distribution (`~/projects/Test2/Test2-Collector`).
This task updated `ARCHITECTURE.md` and `AGENTS.md` to reflect both.
No code changed.

## Decisions recorded

1. **The collector is external.** `Test2-Collector`
   (`Test2::Collector` namespace) owns the collector pipeline; its
   own `ARCHITECTURE.md` is the authoritative collector spec. This
   repo keeps only the boundary description and the Monitor
   (`Test2::Harness2::Collector::Monitor`), which was deliberately
   not extracted. Recorded as `ARCHITECTURE.md` §2.7 and a rewritten
   §4.1.

2. **Replacement pending, not done.** `Test2-Collector` is under
   review — not released, not installed. The in-tree
   `Test2::Harness2::Collector*` modules (minus Monitor) and
   `Test2::Formatter::Stream2*` are pre-extraction copies that keep
   working until the swap; new code must not build against their
   internals or load `Test2::Collector*` yet. After the swap the
   build-out of the harness proper begins.

3. **Orchestration model** (from `fresh_start`), recorded as
   `ARCHITECTURE.md` §4.2:
   - One collector per collected process; full events to a per-collector
     `jsonl.zst` file; only transitions to the harness.
   - Every harness-started process — including the main harness
     process — is a (non-test) collector: one wire format everywhere.
   - Completion comes from transition messages, never reaping
     (collectors may not be direct children).
   - Transitions (plus harness-added events) are the shared state
     forwarded to consumers; nothing rebroadcasts the full stream.
   - Consumers (renderers etc.) read a collector's events file on
     demand; the `starting` transition carries its path.
   - `Getopt::Yath` for command-line parsing (App::Yath2 side).

4. **Extraction differences** that make the in-tree copies stale as
   spec (recorded in §4.1 and a §5.2 addendum): unified sinks (one
   `Recorder::*` abstraction for both the event stream and the
   transitions stream; facet-based routing moved into the collector),
   the `{type => "transition", payload => ...}` envelope removed
   (transitions are plain events stamped with a `harness_collector`
   facet; optional `transition_frame` wrapper), the test pipeline
   (`Assembler` → `Auditor`) auto-wired for `is_test`, and the
   formatter renamed `Test2::Formatter::Collector`. The in-tree
   recorder/Monitor still speak the envelope; they change together
   when the swap lands.

## Alternatives considered

- Doing the code swap now, against the sibling checkout: rejected —
  the dist is still under the user's review and is not installed, so
  the harness cannot depend on it yet.
- Leaving §4.1's deep pipeline description in place with an addendum:
  rejected — two authoritative collector specs would drift; the
  external dist's `ARCHITECTURE.md` owns the contract, §4.1 keeps the
  boundary, status, differences, and the Monitor.
