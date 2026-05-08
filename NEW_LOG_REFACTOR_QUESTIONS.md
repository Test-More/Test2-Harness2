# New Log Refactor — Questions

Worktree: `.claude/worktrees/new_log_refactor` (branch `new_log_refactor`, off
`2.0` @ `37736e02e`).

Spec: `LOGGER_ARTIFACT_REFACTOR2` (in primary repo).

> **2026-05-04 revision (rev 1):** the original draft of this document used
> a `parent_io` Atomic::Pipe pair on every collector for child→parent event
> propagation. That has been **dropped**. We extend the existing IPC channel
> the current `TestObserver` already uses (collector→service via `send_ipc`,
> targets `ipc_parent` / `ipc_run` / `ipc_harness`) by adding new message
> kinds (`collector_start`, `collector_end`, plus run/job pass-fail flips).
> The Collector class no longer carries a `parent_io` slot; it carries the
> existing `ipc_parent` / `ipc_run` / `ipc_harness` slots only.
>
> Sections B4–B6, C5–C6, I1–I3, and H2 were rewritten in rev 1.
>
> **2026-05-04 revision (rev 2):** per the answer to C3, the Observer
> abstraction is **dropped entirely**. The new pipeline is:
>
>     parser → [Auditor for Jobs only] → write_phase
>
> Test jobs are state *producers* (the test process emits state through
> events) — their Auditor tracks state and sends transition IPC. Runs and
> services *act on* state — their collected service process holds and
> emits state itself; the collector for a run or service is dumb and
> simply writes whatever events the service emits. So:
>
> - `Auditor::Test` (renamed from today's class) takes over what
>   `TestObserver` does today (sending `test_job_*` IPC messages).
> - There is no `Auditor::Run`, no `Auditor::Service`. There is no
>   `Observer::*` of any kind.
> - `collector_start` / `collector_end` IPC messages are emitted directly
>   by the Collector itself at process boundary (not through the pipeline)
>   and are recorded by the **parent** service into the parent's own event
>   stream (so the start/end markers land in the parent's
>   `events.jsonl.zst`, not the started/ended collector's).
> - The on-disk `harness_collector_start` / `harness_collector_end` events
>   live in the parent collector's `events.jsonl.zst` only. A reader walks
>   from the harness's events.jsonl down through nested
>   `harness_collector_start` events to discover and open child
>   `events.jsonl.zst` files.
> - The receiver of `collector_start` / `collector_end` IPC is the parent
>   *service* (run service for jobs and run-scoped services; harness for
>   global services and the run service itself). The parent service emits
>   a synthetic event into its own outgoing event stream so its own
>   collector writes that event to disk.
> - `collector_artifacts` IPC is **dropped entirely**. The new Log
>   artifacts API replaces what it carried. There are no on-disk artifacts
>   metadata files in the new format.
>
> Sections C3, C5–C6, M2 were rewritten in rev 2. New sections C7–C9 added.
>
> Section answers above each rewrite are preserved verbatim.

Carried-forward decisions from abandoned worktrees (`logger-artifact-refactor`,
`log-archive-db`) where they do not conflict with the new spec — answers from
the older Q&A files are referenced as "carried" below where applicable.
Listed below are questions where the new spec supersedes/contradicts the old,
plus genuinely new questions opened by the new spec.

Answer inline below each question with `ANSWER:` lines. Skip with "no
preference" if you want me to choose. Where a question has my recommendation,
"sounds good" is enough.

---

## A. Worktree / scope

### A1. Worktree name confirmed

Created `new_log_refactor` (branch `new_log_refactor`, off `2.0` @
`37736e02e`). Confirm.

ANSWER: yes

### A2. Live behavior of Log::Live for files written by collectors in the same process

If a collector instance is writing to `$base/events.jsonl.zst` and a
`Log::Live` reader in the *same* process is iterating over it via
`$log->event()`, do you expect that to work, or is Log::Live always for
*another* process tailing? (Affects locking / fsync / flush cadence.)

ANSWER: Always another process tailing

### A3. AI_DOC location

Per spec the refactor warrants an AI_DOC. Filename
`AI_DOCS/2026-05-04-log-refactor.md`, untracked (in .gitignore for AI_DOCS or
just don't git-add)?

ANSWER: write it, but do not track it.

---

## B. Collector attributes

### B1. Distinct collector subclasses or one class with `type`

Spec lists `type` as one of `Service`, `Run`, `Job`. Do you want:

- **(A)** Single `Test2::Harness2::Collector` class that takes `type => 'Job'`
  and dispatches internally.
- **(B)** Three subclasses (`Collector::Service`, `Collector::Run`,
  `Collector::Job`) with `->type` returning a constant. (Today there are
  `Collector::Service` and `Collector::Test`; this would replace `Test` with
  `Job` and add `Run`.)

I lean (B) — matches existing code shape, makes auditor-only-on-Job,
state-shape-per-type, and Observer-subclass dispatch cleaner.

ANSWER: B is fine

Do not make subclasses if we do not need them after removing 'observer' and
tracking state/sending ipc from the correct places.

### B2. `id` field semantics

For `type => 'Job'`, what is `id`? Job UUID (one per job, stable across tries)
or per-try identifier? Tries get their own subdir below the job dir, so I
expect `id` = job_id (no try suffix), `job_try` = integer.

For `type => 'Run'`, `id` = run identifier (sequential numeric per spec, with
`run_uuid` separate metadata in `spec`).

For `type => 'Service'`, `id` = service name string.

For the harness itself: type='Service', id='harness'?

Confirm or correct.

ANSWER: Services have names, those are their identifiers, global services
each have a unique name, services under runs also have unique names, there
can be overlapping names between global and runs, but those are stored in
different paths so conflict is fine. run's should get sequential integer ids
starting with 0, jobs should also get sequential integer ids starting at 0,
tries as well. Note when importing to the databases these can be stored in
fields named 'ord' (short for ordinal). Runs will also have a UUID, but it
should not appear in the path, just meta-data (spec) and also indexed in the
database row for each run. In database there should be a unique(archive_uuid,
run_uuid) check. The same run can appear in multiple archives.

### B3. Run identifier scheme

Spec: "runs should also primarily have a sequential numerical id in the log
structure, the UUID should be additional meta-data (in the spec)".

- Sequential within a single Log/session, starting at 1? Or 0?
- Stored on disk as `runs/1/`, `runs/2/`, etc.?
- The numeric run id is allocated by the harness when a `yath run` is
  initiated (Stage `start`/`run` split)?
- The run UUID appears only in `runs/$N/spec.jsonl.zst`?

ANSWER: See answer for B2 which covers this. Start at 0, runs/0/ runs/1/,
within a session, it will be possible for archives to only have runs/2/
without 0 or 1 when logs are made from `yath run` against a persistent
runner. Allocated by harness correct, correct on uuid storage on disk.

### B4. Upward channel: existing IPC bus, no new pipes

Drop `parent_io`. Use the existing IPC channel `TestObserver` already uses.
Concretely, every collector keeps the existing slots:

- `ipc_parent`  — bus name of the immediate parent service (run service for
  jobs and run-scoped services; harness for global services)
- `ipc_run`     — bus name of the run service the collector belongs to (if
  any)
- `ipc_harness` — bus name of the main harness service

The Observer (any subclass) emits its upward events via
`$collector->send_ipc($target, \%content)` exactly as `TestObserver` does
today (lines 154/181/etc. in `Observer/TestObserver.pm`). New observer-emitted
messages join the existing list (`test_job_started`, `test_job_diagnosing`,
`test_job_failing`, `test_job_completed`, `job_release`,
`collector_artifacts`).

Confirm:

- Default routing for new `collector_start` / `collector_end` and run/job
  pass-fail-flip messages is `ipc_run` if defined, else `ipc_harness` (same
  fallback as `_send_logger_metadata` does today).
- Service-level messages go to `ipc_parent` if defined (for run-scoped
  services), else `ipc_harness` (for global services).
- The harness's *own* collector has no parent and no run, so its
  `collector_start` / `collector_end` go to `ipc_harness` (its own bus). The
  harness service can listen for these on its own bus, the same way it already
  receives `run_artifacts_update` from the run service.

ANSWER:

Confirm, but also 'collector_artifacts' is no longer needed. We no longer need to send artifacts via IPC, and we no longer need any artifacts files in the logs, they are obsolute with the new artifacts api on the logs.


### B4-followup. Preload services without a path back to the run

Per the original B4 follow-up answer: when we add preloading at the global
level, a preload service has no run-scoped parent because it predates any
particular run. With the IPC channel model that's fine — preload services
already have `ipc_harness` and use it the same way other global services do.

So: no follow-up FIFO mechanic needed; the existing IPC bus already works.
Confirm we can drop the FIFO note from earlier.

ANSWER: Yes, though test jobs started by a global preload should still have an IPC path to the run service that requested them, it is just not their parent in such cases, in non-preload cases it would be the parent as well. Since the run requests the preload start the job we will know what IPC target requested it and will know to set it as the run.

### B5. Frame format / message shape for new IPC kinds

Each new message is just an IPC RPC call (`send_ipc($target, \%content)`),
consistent with the existing `test_job_*` messages. Strawman content shapes:

```
collector_start => {
    type           => 'Job',                # or 'Run', 'Service'
    id             => $id,                  # ord int for run/job/try; name for service
    run_id         => $run_ord,             # undef for global services + harness
    job_id         => $job_ord,             # only for jobs
    job_try        => $try_ord,             # only for jobs
    service_name   => $name,                # only for services
    collector_pid  => $$,
    collected_pid  => $child_pid,
    started_at     => $stamp,
    spec           => \%spec_hash,          # snapshot of the just-written spec row
}

collector_end => {
    type           => 'Job',
    id             => ...,
    run_id, job_id, job_try, service_name => same as start,
    collector_pid  => $$,
    collected_pid  => $child_pid,
    exit           => $exit_status,         # raw waitstatus or undef on crash
    exit_decoded   => parse_exit($exit),
    state          => \%final_state,        # the full state hash from B8
    ended_at       => $stamp,
}

run_pass_fail_flip => {
    run_id     => $run_ord,
    pass       => 0,                        # always 0; flips only happen on first failure
    cause      => 'job_failed' | 'service_failed' | 'service_aborted' | ...,
    job_id     => $job_ord,                 # populated when cause = job_failed
    stamp      => $stamp,
}

job_pass_fail_flip => {
    run_id => ..., job_id => ..., job_try => ...,
    pass   => 0,
    stamp  => $stamp,
}
```

Confirm or amend the message shapes. In particular: do you want a
`harness_facet`-formatted version (so the receiver can drop these straight
into its on-disk events.jsonl.zst as harness facets) or the lightweight RPC
content above?

I lean: lightweight RPC content (matches existing `test_job_*` style); the
receiver synthesizes any on-disk event facet from the content if it wants.

ANSWER: Confirm

### B6. Channel directionality

The new messages are unidirectional, child→parent (collector→service), same
as today's `test_job_*`. No commands flow back over this channel. Confirm.

ANSWER: Correct

### B7. spec field

Spec says `spec` is a hashref of constructor args + collector pid. Question:
in restart case (services), is `spec` re-issued (new row in spec.jsonl.zst)
even when constructor args didn't change, or only when something changed?

I expect: every restart appends a new row, always. The collector pid changes
on every restart anyway, so spec rows are never byte-identical, and
restart-detection downstream simplifies if we just always append.

ANSWER: Always append a new row.

### B8. state field shape per type

- Service: `{exit => undef|int}` (initially), updated to actual exit on
  termination. Anything else (`pid`? `restarts`? `status`?)
- Run: `{exit => undef|int, pass => 1|0|undef, total_jobs => int,
  passed_jobs => int, failed_jobs => int, started_at => stamp,
  ended_at => stamp}` — confirm/extend.
- Job: `{exit => undef|int, pass => 1|0|undef, status => 'queued|running|...',
  assertion_count => int, fail_count => int, plan => N|undef,
  started_at => stamp, ended_at => stamp, subtests => [...top-level only]}`?

These match the projected-snapshot fields planned for the DB schemas
(`runs.spec/state`, `jobs.spec/state`, `job_tries.state`).

Confirm or amend.

ANSWER: Confirmed, but also add a decoded exit value (see parse_exit or
similarly named utility function)

The run service will also need to emit an event before it exits that provides a full updated state that the collector can then merge with the exit value and write to state.jsonl. Other services will likely need similar.

### B9. report.jsonl.zst — exactly what gets written

Spec: "Before any collector exits it should record its state to this file."
One row per exit (so usually 1 row, or N+1 rows after N restarts)?

Each row content = the `state` hash at the point of exit (so `state` is
captured atomically into report)?

Or include both `spec` + `state` in each report row for self-containedness?

I lean: just the `state` hash, since `spec` is in its own file at the same
sequence position.

ANSWER: Just state

### B10. collector_start / collector_end event shape (on-disk)

In addition to the IPC content shape from B5, the collector also writes
sentinel rows into its own `events.jsonl.zst`. These are the in-stream
markers a downstream reader uses to know where a collector started/ended.

Strawman:

```json
{"facet_data":{"harness_collector_start":{
  "collector_pid": 12345,
  "collected_pid": 12347,
  "type": "Job",
  "started_at": 1714875000.123
}}}
```

```json
{"facet_data":{"harness_collector_end":{
  "collector_pid": 12345,
  "collected_pid": 12347,
  "exit": 0,
  "exit_decoded": {...},
  "ended_at": 1714875042.987
}}}
```

(`run_id`, `job_id`, `job_try`, `service_name` are *not* in the facet — they
are inferred from the artifact's path at read time per the spec's "strip
identifiers" rule.)

OK or amend? Naming: per your earlier answer we use the `harness_` prefix.

ANSWER: These should go in the parent collectors events.jsonl, not the events.jsonl for the collector being started/stopped. This will be used to discover when a new source of events has appeared, we read one collectors events, and encounter this event to know we have another collector to read from.  So when the harness service starts a run, the collector start and stop for that run should appear in the events.jsonl for the harness.  When a run starts a job the collector start and stop should appear in the run's events.jsonl.

### B11. Restart detection on disk

Collector starts, sees `events.jsonl.zst` already exists ⇒ this is a
restart, append. Per the rev-2 model, the `harness_collector_start` /
`harness_collector_end` rows go in the PARENT's events.jsonl.zst (not the
restarting collector's). So a reader walking the parent's events.jsonl.zst
sees:

```
... parent events ...
harness_collector_start { collected_pid: 100, started_at: T1 }
... (during this time, child collector writes its events to its own events.jsonl) ...
harness_collector_end   { collected_pid: 100, exit: 0,    ended_at: T2 }
... parent events ...
harness_collector_start { collected_pid: 200, started_at: T3 }   # restart
... (more child events appended to same child events.jsonl) ...
harness_collector_end   { collected_pid: 200, exit: 0,    ended_at: T4 }
```

The child collector's own events.jsonl.zst contains *only* the events
emitted by the collected process (parsed by the parser, audited if
applicable, written by the write_phase). It does NOT contain
`harness_collector_*` rows.

Question: does the restart still append a new row to the child's own
spec.jsonl.zst unconditionally? My read of B7 is yes, always.

ANSWER: yes

---

## C. Pipeline + Observer

### C1. Observer comes after Auditor — confirmed

Order: parser → [auditor for Job] → Observer (single, base + subclass) →
write events.jsonl.zst.

For Service and Run collectors there is no Auditor. Pipeline becomes:
parser → Observer → write.

Confirm.

ANSWER: Confirm

### C2. Single observer + attachments at the write phase

LOGGER_ARTIFACT_REFACTOR2 §40-46 says "For now only support one Observer
that accepts events, then returns the original event, then optionally adds
more events on return, like auditor does."

Per your answer to the original C2: attachment extraction lives in the
*write phase*, **not** as an observer or filter. So the full pipeline is:

```
parser → [auditor for Job] → Observer → write_phase
                                          ├ extract attachments to base/attachments/$f
                                          ├ rewrite event facet to point at archive_path
                                          └ append serialized event to events.jsonl.zst
```

Confirm.

ANSWER: We are dropping Observer, otherwise Correct.

### C3. Observer subclass per type

- Observer base: handles collector_start / collector_end emission to the
  upward IPC channel (per B4/B5). No state mutation by default beyond
  setting `state.exit` / `state.exit_decoded` at end.
- Observer::Run: also tracks run-level state (per B8) and emits run
  pass-fail-flip messages to ipc_harness.
- Observer::Job: also tracks job-level state (per B8) and emits job
  pass-fail-flip messages to ipc_run (same channel TestObserver uses
  today).
- Observer::Service: just the base.

Confirm. (Note: the run service itself, not the run collector's Observer,
remains the authoritative aggregator of per-job pass/fail across the run —
see C6.)

ANSWER:

Observer managing a state was a reflection of the now-defunct parent_io feature.

The observer does not need to track any state beyond noticing transitions like from pass to fail.

We may not even need an observer class. We can probably bake the behaviors we need into the Collector and its subclasses.

Maybe we drop the Observer and replace it like this:

parser -> [auditor] -> write_phase

The collector start and collector stop ipc messages do not need the pipeline, they are both triggered internally, once at collector start and the other at collector end. And it is the parent that is supposed to record them in their event logs, so we need no related event in our own events.jsonl
The transition events can be generated by the Auditor which already tracks state
The run collector can gain a run auditor that serves a similar role to the one the test jobs use.
Services need no auditor still.

There is some confusion to deal with. For test jobs the state is managed and recorded in the Auditor in the test collector. But for services and runs the state is in the service being collected, not in the collector for the service/run. This confusion is what lead to the "parent_io" mistake. One of the main differences that cause this is that tests are state producers, but runs and services act on state. This should be documented more clearly in architecture so we catch similar mistakes in the future.

So the Test Jobs should be the only collectors with an Auditor, ipc events for transitions changes in tests are sent from the Auditor when transitions happen.
There will be no Auditor for the runs or services since their states are managed by the colelcted service, not the collector.
The run service itself should send the IPC messages for its transitions, its collector should not have anything to do with them.
No more Observer classes.

In short: Transition changes should trigger IPC messages where the state is tracked, which is the collector for test jobs, but the service itself for runs and other services. So the collectors for runs and services can both remain simple, and probably do not need subclasses, The test jobs may or may not need a subclass, insertion of the optional auditor which should send the IPC events may be sufficient without a subclass.


### C4. State write timing

When Observer mutates `state`, when does it get persisted?

- Live writeback to `report.jsonl.zst` on every state change? Heavy.
- Live writeback only on transitions (pass→fail flip, first diag, exit)?
- Only at collector_end? Then the in-memory state is the live source of
  truth and consumers wanting current state must read collector_end events.
- Hybrid: in-memory state mutated continuously; report.jsonl.zst written
  on transitions + at exit.

The carried answer for "when to update state" was: pass→fail, first diag,
final exit, subtest completion. That gives a moderate cadence.

Pick.

ANSWER: Only at exit in this branch, we do not need to be able to get a
constant state from the log, that can come via IPC requests if and when we
need it.

### C5. Test command pass/fail signal flow (rev 2)

The test command needs to know: final harness exit code, final per-run
pass/fail, and (optionally) final per-job pass/fail.

Per the rev-2 model:

1. The harness collector emits `collector_start` and `collector_end` IPC
   to `ipc_harness` (its own bus, since it has no parent service). The
   harness service receives, reflects each as a synthetic event into its
   own outgoing event stream — the harness collector then writes them to
   `services/harness/events.jsonl.zst`.
2. The run service's collector emits `collector_start` and `collector_end`
   IPC to `ipc_harness` (the run service's parent is the harness). The
   harness service receives and reflects into its own event stream — those
   events therefore land in `services/harness/events.jsonl.zst` (so a
   reader walking the harness events.jsonl finds the entry-point for each
   run's events.jsonl).
3. Job collectors emit `collector_start` and `collector_end` IPC to
   `ipc_run`. The run service receives and reflects into its own event
   stream so they land in `runs/$N/events.jsonl.zst`.
4. The Auditor::Test (replacing TestObserver) keeps emitting
   `test_job_started` / `failing` / `diagnosing` / `completed` to
   `ipc_run`. Run service aggregates into `Run::State` as today.
5. The run service emits transition events into its own outgoing event
   stream when its own state changes (e.g. first failing job → run state
   "failing"). Run collector writes those events to
   `runs/$N/events.jsonl.zst`. The run service ALSO broadcasts
   `run_state_update` IPC as today.

The test command, the process that started the harness, can either:

- **(A)** Subscribe to the harness service's IPC bus and listen for
  `run_state_update` and the new harness-side reflections of
  `collector_start` / `collector_end` for the run service and harness
  itself.
- **(B)** Read the on-disk Log (`Log->new(live => $dir)`) and derive
  pass/fail from the `harness_collector_end` events the iterator surfaces
  for the run service (and ultimately the harness).
- **(C)** Both — IPC for fast-path live transitions, Log for canonical
  post-run summary.

I lean (C) — IPC for "should I stop waiting?" decisions, Log for the
final summary.

Pick.

ANSWER: C.  The renderer pipeline should always use the log. But the test command itself should rely on IPC. We do not want to mix them and accidentally render duplicate things.

### C6. collector_end IPC payload — what `state` does it carry?

For Job collectors the Auditor holds the final state and can attach it to
the `collector_end` IPC content. For Run and Service collectors the
state lives in the *service process*, not in the collector — the
collector's only job is to write whatever events the service emits.

So the `collector_end` IPC payload differs by collector kind:

- **Job** (collector has Auditor): payload includes `exit`, `exit_decoded`,
  `ended_at`, AND `state => \%final_state` from the Auditor.
- **Run** / **Service** (collector has no Auditor): payload includes
  `exit`, `exit_decoded`, `ended_at` only. The "final state" of the run
  or service is conveyed separately, by the service itself, via its own
  outgoing event stream (e.g. a `run_completed` event the run service
  emits at shutdown, which the run collector writes to events.jsonl.zst).

The `report.jsonl.zst` file each collector writes at exit:

- **Job**: row containing the Auditor's final state hash.
- **Run** / **Service**: row containing just `{ exit => ..., exit_decoded
  => ..., ended_at => ... }` — same content as the IPC payload above. The
  service-emitted run/service state already lives in events.jsonl.zst.

Confirm or amend.

ANSWER: When a run/service ends it should emit an event with a 'collector_report' facet with data that should be merged into the report.jsonl.zst entry along with the exit code info the collector gathers.

### C7. How does the parent service ingest collector_start/end IPC into its events.jsonl?

The parent service receives the child collector's `collector_start` /
`collector_end` IPC. To make those land in the parent's own
`events.jsonl.zst`, the parent service must emit an event into its own
outgoing event stream so its own collector's pipeline (`parser → [auditor]
→ write_phase`) writes the event normally.

Two reasonable mechanisms:

- **(A)** The parent service's IPC handler converts the incoming RPC
  content into a `harness_collector_start` / `harness_collector_end` facet
  and emits it through whatever in-process event-emit path the service
  already has (e.g. the run service's existing local-event emitter that
  produces `seed_run_started`, `job_started` etc. into its event stream
  today).
- **(B)** The child collector both writes the start event into its OWN
  events.jsonl.zst as the first row AND sends the IPC. The parent's
  reader, when it sees the IPC reflected, knows the path of the child's
  events.jsonl.zst and opens it. The parent's events.jsonl.zst then never
  contains `harness_collector_start` rows.

The user's B10 answer reads as (A): "These should go in the parent
collectors events.jsonl, not the events.jsonl for the collector being
started/stopped." So:

- Confirm (A).
- Identify the existing local-event-emit path in `RunService.pm` and
  `Harness2.pm` that we hook into. (`RunService.pm` line ~530 emits
  `job_started`, `job_diagnosing`, `job_failing`, `job_completed` events
  into the run's own log via its existing event-emit infrastructure. We
  add `harness_collector_start` / `harness_collector_end` to that list.)

ANSWER: Correct, A

### C8. Drop TestObserver, fold into Auditor::Test

Today `Test2::Harness2::Collector::Observer::TestObserver` sends:

- `test_job_started` (in `startup`)
- `test_job_diagnosing` (on first diagnostic)
- `test_job_failing` (on first failure)
- `test_job_completed` (post-reap, on `harness_job_exit` facet)
- `job_release` (post-reap, to ipc_harness)

These move into `Test2::Harness2::Collector::Auditor::Test`:

- `test_job_started` becomes Auditor's `startup()` lifecycle.
- `test_job_diagnosing` / `test_job_failing` are emitted from
  `audit_event` when the relevant transitions are observed (the Auditor
  already tracks pass/fail counts, so it knows the moment of transition).
- `test_job_completed` and `job_release` move to Auditor's `shutdown()`
  lifecycle (the auditor sees `harness_job_exit` last).

The Observer/role/instances classes (`Role::Collector::Observer`,
`Observer::TestObserver`, the Collector's `observers` slot and the entire
observe-pipeline plumbing) are removed.

Confirm.

ANSWER: Confirm

### C9. Run service / harness service emit their own transition events

For runs and global services, transition events (run pass→fail,
service-aborted, run-completed, etc.) are emitted by the service itself
into its own outgoing event stream. The collector for that service
writes them to events.jsonl.zst via the standard pipeline.

Concretely:

- `RunService.pm` already emits `seed_run_started`, `job_started`,
  `job_diagnosing`, `job_failing`, `job_completed` into the run's event
  stream. We add: `run_failing` (first failing job), `run_completed`
  (final state, on shutdown).
- `Harness2.pm` already emits `run_artifacts_update` etc. We add: any
  harness-level transition event we want recorded (probably none beyond
  what's already there).
- The run service ALSO continues broadcasting `run_state_update` IPC for
  consumers (test command, etc.) that want fast-path notification.

Confirm.

ANSWER: Confirm

---

## D. Log class hierarchy

### D1. Log namespace

Two reasonable namespaces:

- **(A)** `App::Yath2::Log` (matches the LogArchive→Log rename in spec
  literally; lives under App::Yath2 because it's the user-facing artifact
  store consumed by replay/failed/etc.)
- **(B)** `Test2::Harness2::Log` (so Test2::Harness2 collectors don't
  cross the Test2::Harness2 → App::Yath2 boundary when constructing Log
  objects).

The Test2::Harness2 dependency rule says it must not load App::Yath2. The
Collector currently writes via Logger::JSONL and Logger::JSON — both in
Test2::Harness2 namespace. If we drop loggers and the collector writes
directly, the writer code is in Test2::Harness2.

But Log (the reader/dispatcher) need not live in the same namespace as the
writer. Replay/failed/etc. live in App::Yath2.

I lean: writer code in `Test2::Harness2::Collector` (the collector itself
writes the .jsonl.zst files), and the reader/dispatcher class is
`App::Yath2::Log`. Symmetric to today.

Pick.

ANSWER: Yes, writer code is in Test2::Harness2, reader code is in App::Yath2. The harness is the producer, yath is the consumer.

### D2. `file => $path` auto-detect order

Spec lists both:

```perl
my $log = Log->new(file => $log_file); # *.yath log file, indexed tar
my $log = Log->new(file => $log_file); # *.yath log file, sqlite database
```

Both with `file => $path`, distinguished by sniffing magic bytes. Confirm:
detection is automatic, both `.yath` extensions are valid, no need for the
caller to disambiguate. Order: SQLite magic check first, tar.zidx footer
second, error otherwise.

ANSWER: Correct. Also add `yath valid_log FILENAME` command that checks if a file is a valid log (has one or the other magic bytes), and tells us what type it is. Also verify it has the correct artifacts for the 'harness' service since that is the entry point. No deeper checking for now.

### D3. DB connection arg shape

Spec literal: `Log->new(dbh => $dbh, uuid => $uuid)`. The older
log-archive-db Q&A had `dsn => $DSN, user => ..., pass => ..., attrs => ...`.

I plan both:

```perl
Log->new(dbh => $dbh, uuid => $log_uuid);
Log->new(dsn => $dsn, user => $u, pass => $p, attrs => $a, uuid => $log_uuid);
```

Confirm.

ANSWER: confirm.

### D4. `uuid` arg = log uuid (= archive uuid in DB) — confirm

Single-archive-per-DB or many — the `uuid` arg picks one archive. For SQLite
backed by a `.yath` file with a single archive, the uuid in the file is
detected from the singleton row; specifying `uuid` is optional (if there's
only one archive). For multi-archive servers, `uuid` is required.

Confirm and tell me whether to throw if `uuid` is omitted on a multi-archive
server.

ANSWER: Always assume db can be multi-archive, even when just writing a single archive to sqlite. More simple to have one codepath, single-archive is a natural subcase of multi-archive, no special handling. In single-run case the archive entry can share the runs uuid, multi-run means it needs a generated uuid that does not match any specific run.

### D5. Decorator / format conversion out of scope this round

Per F7 carried, the older spec's format-conversion / write-back rule was:

- Live directory → never persist generated formats (decorator output).
- Tar → in-memory only.
- Extracted directory (sealed) → persist generated.
- DB → persist generated.

The new spec mostly drops decoration. Push decoration / format conversion /
`events.html` etc. to a follow-up worktree?

I lean: yes, push to follow-up. This worktree focuses on raw events / spec /
state / report / attachments only.

ANSWER:

The decorators functionality has moved to this interface dictated in my
LOGGER_ARTIFACT_REFACTOR2 document. We just do not cover decorators anymore,
eventually this save() functionality will be used to accomplish those goals.

    $log->artifacts(%params)->save($filename, $content, compress => $bool);

No need for a followup at this time, I have differnet plans, do not persue decorator concept, just provide save().

### D6. `log->reset` semantics

Spec: `$log->reset;  # Reset event iterator`.

Confirm: this rewinds the depth-first walk so the next `event()` starts at
the harness service's first event again. If a stack of nested iterators is
held, all of them are dropped.

ANSWER: Correct

Note that an item should be removed from the stack of nested iterators once it
hits EOE so we do not keep checking it. That is seperare from reset, but I just thought of it.

### D7. `log->EOE`

Confirm `$log->EOE` returns true once **all** known artifacts in the
depth-first walk are exhausted *and* the log itself is sealed (non-live), or
in live mode once every collector has emitted a `collector_end` event AND
every live `events.jsonl.zst` reader has hit the null sentinel terminator.

For a partially-running live log, EOE is false. For a freshly-loaded sealed
archive, EOE flips true once the iterator hits the end of the last reader.

ANSWER: Correct.

### D8. Service restart visible in iterator?

In the depth-first walk, if a service restarted, its events.jsonl.zst has
multiple collector_start blocks. The iterator surfaces them all in order.
Confirm.

ANSWER: Confirm.

### D9. Listing methods

Per spec:

```perl
my @services = $log->services();           # global
my @services = $log->services($run_id);    # run-scoped
my @runs     = $log->runs();
my @jobs     = $log->jobs($run_id);
my @tries    = $log->tries($run_id, $job_id);
```

Carried answer: throw on missing parent (`jobs($missing_run_id)` throws,
`tries($run, $missing_job)` throws). Listing of empty children returns
empty list.

`tries` ordering: highest first (carried).

`services` ordering: alphabetical?

`runs` ordering: by sequential numeric id ascending? Or descending?

`jobs` ordering: insertion order = order created on disk?

ANSWER: Numeric order lowest to highest for all numerical ones (yes change from carried answer to tries). Alphabetical for services.

Also add has_service, has_run, has_job, and has_try methods. Also add last_try() method to get the number of the last try for a job.

### D10. Throw shape on missing target

When `artifacts(run_id => $missing)` throws, exception type:

- Plain `croak "no such run: $missing"` (string)
- A named exception class

Today the codebase doesn't use exception classes much. I lean string croak.

ANSWER: Plain croak.

---

## E. Artifacts API

### E1. `artifacts(%kw)` selectors

Selectors:

- `service => $name`               → global service
- `service => $name, run_id => $r` → run-scoped service
- `run_id => $r`                   → run itself
- `run_id => $r, job_id => $j`     → highest try (per carried 4b)
- `run_id => $r, job_id => $j, job_try => $t` → specific try

Throw if combination doesn't make sense (e.g. `run_id` without anything
under it = run itself; that's fine, but `job_id` without `run_id` = throw).

Confirm.

ANSWER:

Lets simplify:

artifacts($service_name)
artifacts($run_id)
artifacts($run_id, $service_name);
artifacts($run_id, $job);
artifacts($run_id, $job, $try);

This only becomes ambiguous if a service has a purely numerical name, so disallow pure integer service names, in fact do not allow service names to start with a numerical digit.

Still allow named arg forms too by passing in a hashref:

artifacts({service => $name, ...});

For the hashref form your selectors above are acceptible.

### E2. Default try when omitted

Per carried 4b: highest try number. If a job has tries 0, 1, 2 → default to
2. If only try 0 → return try 0.

Confirm.

ANSWER: Yes.

### E3. Spec/report return shape

`->spec` → bytes of the entire spec.jsonl(.zst) file decoded (multi-row
jsonl as a string)?
`->spec_iter->first` → first parsed JSON object (the initial spec hash)?

I'd expect:

- `->spec` = uncompressed bytes of the .jsonl file (raw text, possibly
  multi-row)
- `->spec_zst` = compressed bytes
- `->spec_iter` = streaming iterator over decoded JSON rows

Same for events / report. Confirm.

ANSWER: Confirm, also add ->last on iterators to jump right to the final row.

### E4. `attachment($name)` return shape

Bytes? Filehandle? Both via separate methods?

Today loggers return bytes for small, fh for large. I lean: just bytes.

Also: does `attachment($name)` return the **uncompressed** content (handling
.zst transparently), or the compressed bytes (caller decompresses)?

I lean: uncompressed bytes. Add `attachment_zst($name)` if compressed bytes
are needed.

ANSWER: good catch. Default returns uncompressed bytes. Allow options: attachment($name, %options) where `compressed => 1` and `filehandle => 1` can be passed when we want to get compressed form instead, and also filehandle option if we want a handle instead of bytes.

### E5. `save($filename, $content, compress => $bool)` return value

Returns the new artifact path? Returns true/false? Returns the Artifact-like
handle for the saved file?

ANSWER: artifact path on success, throw exception of failure.

### E6. `save` overwrite semantics

If artifact already exists at `$filename`, does `save` overwrite, throw, or
take a `force => 1` flag?

I lean: overwrite by default (we already need this for state.json being
rewritten on transitions). Throw only if compression mode disagrees with
existing on-disk file.

ANSWER: state.json will be going away during this refactor, if you expected it to remain there is a flaw in understanding this refactor. Override by default, add a flag we can provide if we do not want to override.

### E7. `compress => $bool` default per backend

Spec: "Compressed by default except for non-live directory archives."

So:

- Live directory → compress on by default.
- Sealed/extracted directory → compress off by default.
- TarZIdx → can_add_artifacts is false, throws.
- DB → "use database internal compression where possible instead of our own
  zstd, but use zstd for sqlite or databases without compression." So for
  Postgres/MariaDB → compress = false (rely on DB), for SQLite/MySQL →
  compress = true (zstd by us).

Confirm.

ANSWER: Confirmed

### E8. `exists($filename)` and `get($filename)` for arbitrary files

These check/get any arbitrary file under the collector's base dir, including
files outside the standard events/spec/report/attachments. Examples?

The spec gives no example of *what* these arbitrary files look like.
Decorator output (`events.html`) is one example for a follow-up. Anything
else expected in this round, or is this just the open hook for future
features?

ANSWER: the events/spec/report/attachments can probably use this under the hood, they would be shortcuts to fill in parameters for this generic interface. Also open hook for future use.

---

## F. UUID strategy

### F1. What gets a UUID

Per spec + B2 answer:

- Log archive itself → UUID (generated when sealed/written; preserved on
  re-archive).
- Run → UUID (in spec metadata, not in path).
- Service → UUID? (The older log-archive-db Q&A had `services.uuid`. Carried.)
- Job → no UUID (sequential ord int per run).
- Try → no UUID (sequential ord int per job).
- Event → no UUID.

Confirm services do or don't get a UUID. If they do, where (spec only?)?

ANSWER: Services do not need a uuid.

### F2. Service uuid storage location

If services get a UUID, lives in: `services/$name/spec.jsonl.zst` only? Or
also indexed in DB row?

ANSWER: Not needed

### F3. Archive uuid sharing across re-archives

Per spec: "extracting and re-archiving a log should maintain the uuid". So
the live dir's uuid persists into archives. Confirm: the `log_uuid` is
generated on first creation of the live dir (or on first archive) and is
stored in `services/harness/spec.jsonl.zst`?

If the live dir hasn't been archived yet, where does its uuid live? In
`services/harness/state.jsonl.zst` (or harness's spec)?

ANSWER: The uuid should be generated (or copied from single-run) when the archive is sealed or turned into a non-live form. Live log dir never has a UUID.

Note: We need an API to create an archive that excludes some runs fromthe source. A persistent runner (`yath start`) will have a logs dir with multiple runs (one per `yath run`) but the archives `yath run` will produce should contain all the global stuff, but only stuff from the 1 run they care about, not other runs.

### F4. Multi-run archive uuid generation

Per spec: archives with multiple runs need a fresh archive uuid each
re-archive operation; archives with exactly one run can share that run's
uuid. Confirm: implemented as "if N runs == 1: archive_uuid = runs[0].uuid,
else: archive_uuid = gen_uuid()" at archive time.

ANSWER: Correct

### F5. Live-dir uuid before first archive

At what point in time does a live dir get a uuid?

- (A) At first collector_start of the harness service (= start of run/start
  of `yath start`).
- (B) Lazily, only when first archived.
- (C) Both: a "live uuid" generated at start, may or may not become the
  archive uuid.

I lean (A) — generated at harness collector init, written into harness
spec.jsonl.zst. Then re-archive uses that uuid as default unless multi-run
forces a new one.

ANSWER: A live dir never has a uuid, uuids only get assigned/generated when turned into non-live form.

---

## G. Stripped fields

### G1. Field-stripping at write vs at read

Spec says strip identifiers at *write* time (don't waste space) and inject
at *read* time from path.

So at write time, the events.jsonl.zst file has no run_id/job_id/job_try in
event rows. At read time, `$log->event` populates them in the harness
facet.

Two corollaries:

- Today's events have these in `facet_data.harness`. The collector pipeline
  must drop them (or never set them) before write.
- Today's events have `event_id` / `about.uuid` / various trace fields. Per
  spec event UUIDs are not needed at all.

Question: what *exactly* should be stripped on the way into events.jsonl.zst?

Strawman strip list (drop):

- top-level `event_id`, `stamp`, `pid`, `tid` (today's redundant mirrors —
  Stream2 already has these in `trace`/`about`)
- `facet_data.about.uuid` (event UUID)
- `facet_data.harness.event_id`
- `facet_data.harness.stamp`
- `facet_data.harness.run_id`
- `facet_data.harness.job_id`
- `facet_data.harness.job_try`
- `facet_data.harness.stream_id` (already useful — keep? today it
  distinguishes stdout vs stderr bursts)
- empty facets (where the hash/array is `{}`/`[]`)

Strawman keep:

- `facet_data.about.details`
- `facet_data.trace.frame`, `trace.stamp` (canonical home for stamp per
  earlier filter plan), `trace.pid`, `trace.tid`
- `facet_data.harness.assert_count`
- All test-output facets (assert/info/control/...)

Confirm and amend the lists.

ANSWER: This looks correct, Keep stream_id.

### G2. Where do `run_id` / `job_id` live in injected events on read

When the iterator surfaces an event from `runs/5/jobs/3/0/events.jsonl.zst`,
where do the injected fields go in the returned event hash?

- (A) `facet_data.harness.{run_id,job_id,job_try}` (canonical home)
- (B) Top-level `{run_id,job_id,job_try}` slots on the event (legacy)
- (C) Both

I lean (A). Renderers / consumers read from there.

ANSWER: A, the top-level should not exist after this refactor. blessed events should have shortcut methods to access them from canonical locations.

### G3. Stamp canonical home

Carried answer from old filter plan: `trace.stamp`. Stream2 generates
events with `trace.stamp` populated. So the strip list above keeps
`trace.stamp` and removes `harness.stamp`. Confirm.

ANSWER: Correct.

---

## H. Append-stream termination

### H1. Null-line sentinel still wanted? (rev 2)

The older spec had a `null\n` row written at the end of an append-only
jsonl stream as a "stream sealed" marker, used by the JSONL reader to
distinguish "sealed" from "more may come".

In the rev-2 model, the natural termination marker for a child's
events.jsonl.zst is the `harness_collector_end` event in the **parent's**
events.jsonl.zst — once a reader walking the parent's stream sees a
`harness_collector_end` for a child, the child's stream is complete and
the reader can stop tailing it.

Two options:

- **(A)** Drop the null-line sentinel; the child's events.jsonl.zst is
  considered terminated when the parent's events.jsonl.zst surfaces a
  `harness_collector_end` event referring to it.
- **(B)** Keep the null-line sentinel as a redundant tail-of-file marker
  written by the child on its own way out.

I lean (A). The parent's `harness_collector_end` is the canonical
"child stream done" signal.

ANSWER: There can be multiple harness_collector_end events if a service is restarted with a new collector. For a live dir we need to come back if a new start event happens, so we need to compare start and stop events and only stop when every start has a matching stop. When sealing a log into an archive/db/etc. In a non-live log we know the artifacts will not grow and that the last line is final, so no such check is needed. Also for live we probably need to also check for a collector that ended without writing its end event, so make sute the last collector end is the same pid and other data as the last collecotr start seen.

### H2. Crash detection (rev 2)

If a collector crashes (parent never sees `collector_end` IPC, so no
`harness_collector_end` lands in the parent's events.jsonl.zst), how does
a tailing reader of the child's events.jsonl.zst know?

Options:

- **(A)** Don't worry: the parent service is already responsible for
  detecting child-collector death via existing IPC peer-down detection
  (the `_wait_for_ipc_target` plumbing). When the parent service notices
  a peer-down, the parent service emits a synthetic
  `harness_collector_end` event into its own outgoing stream (with an
  appropriate `cause: "crashed"` marker on the payload) — same path as a
  graceful end, just synthesized by the parent rather than driven by an
  incoming IPC message. The child's events.jsonl.zst itself stays
  unterminated, but the parent's stream signals "child done".
- **(B)** Tailing reader times out after N seconds of no progress, treats
  the artifact as terminated.

I lean (A) — the parent service is the single source of truth for "child
alive or not", and (A) reuses the same write-path so consumers see one
consistent termination signal.

ANSWER: Use A, also use logic I outlined in H1 answer where needed, but prefer A.

---

## I. test command + IPC for pass/fail

### I1. test command listens on harness service bus (rev 2)

`yath test` already starts the harness service and connects to its IPC
bus — that's how it currently sends start/stop commands. Extend the
test command to also subscribe to:

- `run_state_update` (already broadcast by run service today on each
  transition)
- `collector_end` IPC for the harness-itself collector (the harness
  service receives that IPC on its own bus per C5 step 1; the test
  command sees it via the same subscription)
- `collector_end` IPC for run service collectors (the harness service
  receives those on its own bus per C5 step 2)

The test command's main loop:

1. Spawns harness, captures its bus name.
2. Subscribes to the bus.
3. Loops on:
   - IPC events (fast-path pass/fail / completion signals)
   - Log iterator (`Log->new(live => $dir)->event($timeout)`) for
     renderer input

Confirm or correct.

ANSWER: Correct

### I2. Renderer reads live log dir

Renderer is started by the test command. It iterates events via
`Log->new(live => $dir)->event($timeout)`. Renderer never directly
subscribes to the IPC bus — pass/fail decisions for *display* come from the
events the renderer sees in the on-disk log (the run service's
`events.jsonl.zst` carries `seed_run_started`, `job_started`, `job_failing`,
`run_completed`, etc.).

Test command and renderer share the main process; the test command
multiplexes IPC reads + Log iterator on the same loop.

Confirm.

ANSWER: Renderer can be its own child process with its own loop, parent monitors IPC and waits on renderer.

### I3. test command exit code (rev 2)

Test command exit code derived from:

- The harness collector's `collector_end` IPC `exit_decoded` payload (the
  harness's process exit status), AND
- For each run, the final run state event the run service emitted into
  its own event stream (`run_completed`) seen via the Log iterator. Exit
  nonzero if ANY run's `pass` field is 0.

Confirm.

ANSWER: Correct. If either log or ipc report something is wrong or a failure then there should be a failure.

### I4. Live polling vs INotify in Log::Live

Spec: "Avoid busy loop. Prefer Linux::INotify when available". Default poll
cadence when INotify unavailable: 100ms? 50ms?

ANSWER: 50ms

### I5. test command also reads Log to build summary?

After the run finishes, the test command produces a summary (per-job
results, total pass/fail). Does it derive this from:

- (A) Final state recorded in the run's report.jsonl.zst (read via Log
  artifacts).
- (B) Events seen during the run (kept in memory).
- (C) Both.

I lean (A) for canonical post-run summary; (B) for live during-run summary
(if any).

ANSWER: Log should be used for summary. But we also need to consider IPC, if log says all is good, but ipc says we have a problem, then we have a problem. Same in reverse, if IPC says all is good, but log says we have a problem, then we have a problem.

---

## J. replay / failed / archive / extract / start / run

### J1. replay command

Opens `Log->new(file => $log)` or `Log->new(dir => $dir)`. Iterates events
via `$log->event` (no polling — non-live, EOE flips true once done). Feeds
to renderers. Confirm.

ANSWER: Confirm

### J2. failed command

Opens Log. Walks runs/jobs/tries. For each try, reads
`report.jsonl.zst->report_iter->last` to get final state. Lists failures
(jobs whose final state has `pass => 0` or `exit != 0`).

Confirm. Anything else `failed` needs (subtest detail, run-summary)?

ANSWER: Confirm. Failed should also show which top-level subtests failed. If these are not in the report they should be, we should not have to walk all events to find pass/fail for top-level subtests when reviewing a log.

### J3. archive command

`Log->new(dir => $live_or_extracted)->archive($file)`. Default format:
TarZIdx. `--format=sqlite` for SQLite. Confirm.

ANSWER: correct.

### J4. extract command

`Log->new(file => $file)->extract($dir)`. `--no-decompress` keeps `.zst`
suffix; default decompresses. Confirm.

ANSWER: confirm.

### J5. start / run / kill / etc commands

The non-test commands that interact with the harness service over IPC don't
seem to need refactoring for this work — they don't read the log. Confirm
no work needed in those for this worktree.

ANSWER: These commands are currently not migrated from legacy, so ignore them for now.

---

## K. DB backends

### K1. Scope this round

Implement which backends in this worktree?

- (A) SQLite only (rest in follow-up worktrees).
- (B) SQLite + Postgres (most-used pair).
- (C) All four (SQLite, Postgres, MariaDB, MySQL).

The plan from `LOG_ARCHIVE_DB_QUESTIONS.md` already laid out all four. Doing
all four extends the scope significantly.

I lean (A) for this worktree (the file-based Log refactor is the critical
path); follow-up worktrees add Postgres / MariaDB / MySQL.

ANSWER: C, each in its own commit. Also note that in abandoned worktree you initially aliased a bunch of methods from SQLite into other backends, I had to tell you to move them to the DB base class. This time put common functionality in the base class from the start.

### K2. SQLite as `.yath` file detection

Per spec: detect tar vs sqlite by magic bytes. SQLite first 16 bytes ==
`"SQLite format 3\0"`; tar.zidx footer at offset (filesize-32). Confirm
this detection runs in `Log->new(file => $path)`.

ANSWER: Correct.

### K3. Multi-archive in single SQLite

A `.yath` file can hold one archive (the common case) or multiple archives
(rare; allowed). The `archives` table has one row when there's only one
archive; the `Log->new(file => ...)` call when no `uuid` is given returns
the singleton archive (or throws if multiple).

Confirm.

ANSWER: Correct.

### K4. Schema doc location

`share/log/schema/<flavor>/schema.sql` for each flavor. Plus a single
`docs/schema/SCHEMA.md` review doc combining all four with per-flavor
variations highlighted, for review before locking. Confirm.

ANSWER: share/schema/<flavor>.sql, confirm on doc.

### K5. UUID v7

Codebase uses Test2::Util::UUID. Confirm whether `gen_uuid()` returns v7
(time-ordered) or v4 (random). If v7, it sorts well in a B-tree index — no
issue. If v4, MySQL's UUID_TO_BIN swap_flag should be considered.

Will check implementation, but flag if you have a strong preference.

ANSWER: We use V7, no need to set swap_flag. In databases where uuids are stored as binary, also store them as strings in a _string companion field to help humans using the database, index these as well for human use.  For PostgreSQL, MariaDB, etc where native UUID is supported we do not need this field. No code should use the field apart from populating it (though a trigger might be better for that?) it is just for humans looking at the db manually.

### K6. DBIx::QuickDB usage

For tests requiring a real DB, use `DBIx::QuickDB` from `~/projects/DBIx-
QuickDB`. Skip test if binaries / driver missing. Confirm.

ANSWER: Correct

---

## L. Test plan

### L1. Test command

Per CLAUDE.md memory + carried answer: `AUTHOR_TESTING=1 yath -D test \`find
t xt -iname "*.t"\``. Use this for the worktree. Confirm.

ANSWER: confirm

### L2. Where new tests go

`t/AI/unit/Log/`, `t/AI/unit/Collector/`, `t/AI/integration/log_*.t`. New
tests under t/AI/. Existing tests under t/AI/ that break — update in same
commit as the breaking change. Existing tests outside t/AI/ — most don't
touch this layer; if any break I'll flag and we discuss.

Confirm.

ANSWER: Confirm

### L3. Round-trip integration test

A test that:

1. Spawns a harness writing to a live dir.
2. Asserts events arrive via `Log->new(live => $dir)->event`.
3. Archives the dir to tar.
4. Asserts `Log->new(file => $tar)->event` yields the same event sequence.
5. Extracts back to dir.
6. Asserts iteration matches.
7. (If SQLite scope) writes to SQLite, asserts iteration matches.

OK as a baseline integration test? Anything else you want covered?

ANSWER: This is good.

---

## M. Migration strategy / ordering

### M1. Mega-PR or staged

Per spec "no need for any backwards compatibility, we will not be processing
old logs", the work can land as one big diff. But CLAUDE.md says "Make a
distinct commit for each change". Reconcile:

- Plan a sequence of commits, each independently meaningful (event UUID
  strip; rename LogArchive→Log; rewrite collector base; new Observer; etc.),
  but the codebase is broken between commits until the chain completes.
- All commits land on the `new_log_refactor` branch; the branch becomes one
  PR; merge as a single squash or merge-commit at completion.

I lean: keep the staged commits (per CLAUDE.md), accept that the branch is
broken mid-stream, merge as a regular merge-commit (preserves commit
history) at the end.

ANSWER: Staged commits, merge commit at the end, breakage between commits is fine.

### M2. Order of work (rev 2)

Suggested order (dependencies forward-chained; Observer-references gone):

1. Strip event UUIDs / identifier mirrors from Stream2 / parser / auditor
   / emitter (small, mostly mechanical, doesn't break readers because
   nothing reads them today besides the tests we'll update).
2. Rename `App::Yath2::LogArchive*` → `App::Yath2::Log*` (mechanical;
   replace Logger/JSON/JSONL imports en route).
3. Drop `collector_artifacts` IPC + on-disk artifacts metadata files +
   `_send_logger_metadata` plumbing (per B4).
4. Rewrite Collector base for direct file writes (spec/events/report
   .jsonl.zst written by collector itself) + drop Logger machinery.
   Pipeline: parser → [auditor for jobs] → write_phase. Drop the
   Observer abstraction entirely.
5. Move `TestObserver` IPC duties (`test_job_started/diagnosing/failing/
   completed`, `job_release`) into `Auditor::Test`. Delete
   `Observer/TestObserver.pm`, `Role/Collector/Observer.pm`, and the
   collector's observer plumbing.
6. Add `collector_start` / `collector_end` IPC emissions, triggered
   directly by the Collector at process boundary (not via pipeline).
   Targets: `ipc_run` (jobs), `ipc_harness` (run service + global
   services + harness's own collector).
7. Write phase: extract attachments before write, rewrite event facet,
   append serialized event to events.jsonl.zst.
8. Add parent-service handlers for `collector_start` / `collector_end`
   IPC in `RunService.pm` and `Harness2.pm`. Reflect each as a
   `harness_collector_start` / `harness_collector_end` event into the
   service's own outgoing event stream so the parent's collector writes
   it to events.jsonl.zst.
9. Run service emits `run_failing` / `run_completed` transition events
   into its own outgoing stream (per C9).
10. Build Log dispatcher + Log::Live + Log::Directory. Get
    `$log->event`-based iteration working end-to-end. Depth-first walk
    descending through `harness_collector_start` events. Path-aware
    identifier injection on read.
11. Wire test command: subscribe to harness IPC bus for `collector_end`
    + `run_state_update`; iterate Log for renderer input. Drop the
    Streamer::Live abstraction.
12. Wire renderer to use Log iterator (drop Streamer::Static).
13. Build Log::TarZIdx (sealed-only).
14. Build Log::Sqlite (sealed-only) — only if K1 = (B) or higher.
15. Update replay/failed/archive/extract commands.
16. Tests + AI_DOC + ARCHITECTURE addendum + POD. The architecture
    addendum should include the rev-2 insight: **tests are state
    producers; runs and services act on state, so their state lives in
    the service process (not the collector) and transition events are
    emitted by the service itself**.

OK or amend?

ANSWER: Looks good

### M3. Sub-agent usage

Per F14 carried + the user's instruction in the new spec, use sub-agents
to avoid context exhaustion. Plan:

- Survey/exploration → sub-agent (already done once for this round).
- Mechanical rename pass → sub-agent (LogArchive → Log).
- Test refactors / sweeping fixes → sub-agent in chunks.
- Architectural changes (Collector rewrite, Observer, Log dispatcher) →
  main agent (judgment-heavy).

OK?

ANSWER: yes.

---

## N. Anything I missed

Spot for additional questions / requirements you want pinned before
implementation starts.

ANSWER: This looks good
