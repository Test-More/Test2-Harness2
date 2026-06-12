# 2026-04-23: Per-test JSONL was getting interleaved writes

## Symptom

Failing tests under `yath test` produced JSONL files with malformed
lines: 2-3 JSON event objects concatenated end-to-end with no
separating newlines, the first object truncated mid-value (e.g.
ending at `"pid":212931` with no closing `}`). Passing tests were
sometimes clean, sometimes corrupt -- it depended on the relative
timing of run-service state broadcasts.

## Root cause

The harness was spawning **two collectors per test job**, both of
which independently `open '>'`-ed the same JSONL path. Two
processes truncating the same file and then writing to it from
independent file offsets is exactly the byte-level interleave
pattern observed.

The double-spawn came from a stale-state race between the harness
scheduler and the run service:

1. `Test2::Harness2::_try_launch_next_pending` iterated
   `$run->pending` and called `_launch_job` for each entry it
   could place. `_launch_job` then called `$run->mark_running`
   on the same Run object to remove the job from `pending`.

2. The run service does NOT consider a job "running" in its own
   Run mirror until it has seen `test_job_started` come back
   from the collector. Until that arrives, its mirror still
   shows the job as pending.

3. Between launch and `test_job_started` the run service
   periodically broadcasts its full Run state
   (`pending` / `running` / `done` arrays) back to the harness via
   `run_state_update`.

4. `_handle_run_state_update` then **overwrote** the harness's
   own Run object from the broadcast:

   ```perl
   for my $slot (qw/pending running done/) {
       my $list = $data->{$slot};
       next unless ref($list) eq 'ARRAY';
       $run->{$slot} = [@$list];
   }
   ```

   When the broadcast arrived before `test_job_started`, the run
   service's `pending` still contained the just-launched job, and
   that overwrite resurrected it in the harness's local `pending`.

5. `_try_launch_next_pending` ran again, saw the resurrected
   `pending`, and called `_launch_job` for the same job a second
   time. Second launch -> second collector spawn -> second
   `Logger::JSONL::startup` -> second `open '>'` on the same path
   -> two processes writing the same file with independent
   seek positions.

The corruption was strongly correlated with failing tests because
the failure path emits a denser burst of events at job exit time,
which made the interleave likely to happen mid-event.

## Fix shipped

The harness scheduler now keeps its **own** per-run pending /
running view in `$self->{+SCHEDULER}`, populated once at queue
time from the initial Run job list and mutated only by the
harness's own scheduling decisions. It never reads or writes the
Run object's `pending` / `running` / `done` arrays after queue
time, so a stale broadcast cannot resurrect a launched job.

New helpers in `lib/Test2/Harness2.pm`:

- `_scheduler_queue_run`        -- populate at queue time
- `_scheduler_pending_for_run`  -- ordered list of jobs not yet
                                   attempted
- `_scheduler_mark_running`     -- called from `_launch_job` on
                                   success
- `_scheduler_mark_done`        -- called from `_handle_job_release`
                                   and from the orphan-test fallback
                                   in `handle_subreaped_pid_exit`
- `_scheduler_skip`             -- called from the resource-skip
                                   and broken-resource-skip paths
- `_scheduler_drop_run`         -- called from
                                   `_finalize_run_if_complete`
- `_scheduler_run_complete`     -- "the scheduler has nothing left
                                   to do for this run"
- `_scheduler_started`          -- "this run has had at least one
                                   job launched or skipped"

Call-site changes:

- `_try_launch_next_pending` iterates
  `$self->_scheduler_pending_for_run($run_id)`, not `$run->pending`.
- `_launch_job` calls `_scheduler_mark_running` instead of
  `$run->mark_running`.
- The resource-skip and broken-resource paths call
  `_scheduler_skip` instead of `$run->mark_skipped`.
- The orphan-test fallback calls `_scheduler_mark_done` instead
  of `$run->mark_done`.
- The "first launch -> emit run_started" check uses
  `_scheduler_started` instead of `!@{$run->running} && !@{$run->done}`.

The Run object's `pending` / `running` / `done` arrays are still
mirrored from `run_state_update` broadcasts. The mirror remains
the source for `request_handler_status` (informational query) and
for `_snapshot_run_results` (final pass/fail accounting at
finalization time). What changed is that the **scheduler** no
longer trusts or touches them.

Finalization (`_finalize_run_if_complete`) is still gated by the
Run mirror's `is_complete`: that is the run service's
authoritative "all jobs done with these results" signal. The
scheduler's own done-ness is necessary but not sufficient to
finalize -- the scheduler can reach empty before the mirror has
the results we need to snapshot. A `COMPLETED_RUNS->{$run_id}`
guard makes finalization idempotent so repeat triggers do nothing.

## Follow-up: serial run ordering

While auditing the scheduler I noticed that
`_try_launch_next_pending` would fall through to the next queued
run whenever the head run had no launchable jobs at this instant
(every job deferred on resources etc.), letting a later run jump
ahead. The intent is that runs are processed strictly in queue
order, one at a time -- later runs do not get a chance to launch
until the head run has fully drained. The follow-up commit picks
the first non-complete entry of `+QUEUE` as the head run for the
tick and only schedules from that run.

Ordering integrity:

- `$self->{+QUEUE}` is an arrayref, so run order is preserved at
  insert time and iterated in that order.
- `$self->{+SCHEDULER}->{$run_id}->{pending}` is an arrayref, so
  per-run job order is preserved.
- The `+SCHEDULER` hash itself is never iterated for ordering --
  only `+QUEUE` is -- so unordered hash keys do not affect run
  selection.

## How it was found

Per-event debug `syswrite` to a fixed file (`/tmp/jsonl-dbg.log`)
inside `Logger::JSONL::log_event`, capturing `$$`, `fileno($fh)`,
the path, and the calling sub. That immediately showed two
distinct PIDs writing to the same per-test path with two distinct
fds (i.e. two `open '>'` calls from two separate `startup`s).
Adding the same syswrite to `Logger::JSONL::startup` plus
`getppid()` and a `caller()` stack confirmed two `Collector::Test
-> spawn -> _spawn_collector -> _run_collector` invocations per
test job. Walking back through the stack (instrumenting
`_launch_job` and `request_handler_launch_job` the same way)
showed `_try_launch_next_pending` firing twice for each job and
landed on the resurrected-pending broadcast as the trigger.

## Earlier symptom-mask (reverted)

A first attempt at fixing the corruption switched
`Logger::JSONL::startup` to `'>>'` (O_APPEND) and made the
`log_event` `print` write `body . "\n"` as a single string so that
each individual write was at least atomic. That hid the symptom
without addressing the cause -- two collectors per job is wrong
even when their writes are individually atomic. Once the real
cause was understood, the JSONL change was reverted to plain `'>'`
mode: the file has one writer again, which is what `'>'` is
correct for and matches the rest of the project's conventions.
