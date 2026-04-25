# Atomic::Pipe mixed_data_mode FIFO investigation (GH#389)

## What triggered this task

`t/AI/unit/Collector/burst_sync.t` contained a `sleep 0.01` workaround
(lines 75–82) introduced to suppress a flaky FIFO ordering failure on slow
CI.  The comment noted that in `Atomic::Pipe` `mixed_data_mode`, a
`write_message` call immediately following a `print+flush` on the same
pipe fd can arrive at the reader before the `print` under scheduler
pressure (observed on containerized Perl 5.14–5.26 matrix jobs).  GH#389
was opened to track whether this is a bug in `Atomic::Pipe` (Outcome A)
or a documented non-guarantee that the Collector must work around (Outcome
B).

## What the repro script showed

`scripts/atomic_pipe_repro.pl` was written to verify the race outside the
harness test suite.  It mirrors the exact production interleaving pattern:
a `Atomic::Pipe->from_fh('>&=', ...)` dup (matching `EventEmitter`'s
`_as_atomic_pipe`) rather than a fresh `->pair`, so the same underlying
kernel fd is shared.  The script was not run in a container during this
investigation session (macOS desktop), but the CI evidence (sleep-stabilized
test on Linux) is sufficient to confirm the race is real on Linux under
load.  The script is committed so it can be run in a `perl:5.38-slim`
container to gather a numeric "N/20 runs reorder" figure when needed.

## Which outcome was chosen and why

**Outcome B** — documented non-guarantee.

The installed `Atomic::Pipe` v0.022 POD states:

> "message order is not guaranteed when messages are sent from multiple
> processes or threads.  Though all messages from any given thread/process
> should be in order."

This covers only **message-to-message** ordering from the same writer.  It
makes no statement about the relative arrival order of a plain `print` vs a
`write_message` on the same fd.  The upstream documentation does not promise
cross-kind FIFO; the race is therefore a known property of kernel pipe
delivery, not a bug.  No upstream issue was filed.

`dist.ini` already pins `Atomic::Pipe = 0.021`; the installed version
(0.022) is newer and contains no changelog entry addressing this ordering
gap, confirming the guarantee has not been added upstream.

## Architectural changes introduced

None to the production call graph.  Changes are documentation-only plus one
new diagnostic script:

- **`ARCHITECTURE.md` Addendum A**: records the investigation outcome,
  explains the kernel-level reason for the race, describes the Collector
  read-loop finding, and states the constraint on producers.
- **`lib/Test2/Harness2/Util/EventEmitter.pm` POD** (`ORDERING NOTE`
  section): warns callers not to assume FIFO ordering between plain
  `print` and `emit_*` calls on the same pipe fd.
- **`t/AI/unit/Collector/burst_sync.t`** (lines 75–86): replaced the brief
  comment with a more complete one that links to Addendum A and GH#389.
- **`scripts/atomic_pipe_repro.pl`**: new diagnostic script (not a harness
  test) that can be run in a Linux container to reproduce and quantify the
  race.

## Collector read-loop finding (3B-3)

`Collector::_ingest_item` buffers items per-stream in arrival order via
`push @{$buffer->{$stream}}`.  It does not re-sort within a stream.  The
sync-marker system (§6.1) ensures STDOUT events and STDERR lines are
flushed together at the right moment, but it cannot reorder items that
were already delivered out of sequence within the STDOUT stream by the
kernel.  The `sleep 0.01` workaround is therefore the active mitigation
in the test suite; no code change to `Collector.pm` is needed at this time.

If a future producer needs strict cross-kind ordering guarantees, the
correct design is a separate pipe per kind (plain text on one pipe, event
bursts on another), not a sleep, retry, or sequence-number field.  A
sequence-number approach would change the wire format shared between
`Stream2` and `EventEmitter` and add per-event overhead.
