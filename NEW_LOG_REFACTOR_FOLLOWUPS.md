# New Log Refactor — Followups

Followup questions raised by answers in `NEW_LOG_REFACTOR_QUESTIONS.md`. Answer
inline below each.

---

## F1. Single Collector class vs subclasses

B1 was answered "B is fine" (subclasses) and then amended: "Do not make
subclasses if we do not need them after removing 'observer' and tracking
state/sending ipc from the correct places."

After all the rev-2 changes, the only behavioral differences across types are:

- **Job**: pipeline includes `Auditor::Test`; collector_end IPC payload
  includes Auditor's final state; collector_start/end IPC routes to `ipc_run`.
- **Run / Service**: no Auditor; collector_end IPC payload only carries exit
  info; collector_start/end IPC routes to `ipc_harness` (or `ipc_parent`).

These differences are config-driven, not class-driven. I lean: **single
`Test2::Harness2::Collector` class** with:

- `type => 'Job' | 'Run' | 'Service'` enum slot
- optional `auditor` slot (only set when type == Job, populated with
  `Auditor::Test`)
- type-driven IPC routing logic in the start/end emission code

No subclasses. Today's `Collector::Test` and `Collector::Service` collapse
into the single class.

Confirm.

ANSWER: Confirm

---

## F2. report.jsonl.zst naming — B8 said "state.jsonl"

Your B8 amendment says: "The run service will also need to emit an event
before it exits that provides a full updated state that the collector can
then merge with the exit value and write to **state.jsonl**."

Everywhere else the spec calls this file `report.jsonl.zst` (per
LOGGER_ARTIFACT_REFACTOR2 §28-32) and your E6 confirms `state.json` (the
old separate snapshot file) is going away.

I'm reading "state.jsonl" in B8 as a slip — the merge target is
`report.jsonl.zst`. Confirm, or correct.

ANSWER: Correct, report.jsonl.zst

---

## F3. collector_report facet — exact data shape + lifecycle

Per C6 amendment: "When a run/service ends it should emit an event with a
'collector_report' facet with data that should be merged into the
report.jsonl.zst entry along with the exit code info the collector gathers."

Concretely:

- The service emits one final event into its outgoing event stream just
  before clean shutdown.
- That event has a `collector_report` facet whose contents are the
  service-side state the collector wouldn't otherwise know (final
  pass/fail aggregate, totals, etc.).
- The collector's pipeline writes the event normally to events.jsonl.zst
  (so the collector_report facet ends up in events.jsonl.zst too).
- The collector ALSO captures the collector_report facet content,
  merges it with the exit info it gathers (`exit`, `exit_decoded`,
  `ended_at`, `collector_pid`, `collected_pid`), and writes ONE row to
  report.jsonl.zst with the merged content.

So the report.jsonl.zst row content for a Run/Service is:

```
{
  ...all keys from the service's collector_report facet...
  exit          => $exit_status,
  exit_decoded  => parse_exit($exit),
  ended_at      => $stamp,
  collector_pid => $$,
  collected_pid => $child_pid,
}
```

For a Job (auditor source instead of service-emitted facet):

```
{
  ...all keys from Auditor::Test's final state hash...
  exit          => $exit_status,
  exit_decoded  => parse_exit($exit),
  ended_at      => $stamp,
  collector_pid => $$,
  collected_pid => $child_pid,
}
```

Confirm.

ANSWER: Mostly correct, however for a run there should also be the state the run tracks about what test jobs passed and failed, what top-level subtests passed and failed, etc. That state should be emitted and included for runs.

---

## F4. collector_report facet vs run_completed event

C9 says the run service emits `run_completed` (final state) into its event
stream. C6 says it emits an event with a `collector_report` facet.

Is this:

- **(A)** One event carrying both `run_completed` (or similarly named
  harness facet describing the run completion) AND `collector_report`
  (collector-merge data). Single event, two facets.
- **(B)** Two separate events: `run_completed` (event-stream announcement
  that the run finished) and a separate `collector_report` (data the
  collector merges into report.jsonl.zst).

I lean (A) — one event with both facets, simpler. Same event for both
the on-disk announcement and the collector-merge data. Same pattern for
global services that need to emit at shutdown.

Confirm.

ANSWER: A.

---

## F5. Archive scoping API for persistent runner

Per F3 user note: "We need an API to create an archive that excludes some
runs from the source. A persistent runner (`yath start`) will have a logs
dir with multiple runs (one per `yath run`) but the archives `yath run`
will produce should contain all the global stuff, but only stuff from the
1 run they care about, not other runs."

Strawman API:

```perl
# Default: archive the whole log
$log->archive($file);

# Archive only specific runs (always include globals)
$log->archive($file, runs => [0, 2]);     # only runs 0 and 2
$log->archive($file, runs => [0]);         # only run 0

# Exclude runs (always include globals)
$log->archive($file, exclude_runs => [1]); # all except run 1
```

Mutually exclusive: passing both `runs` and `exclude_runs` throws.

Same options on `extract` and `archive_to_db` (the converter):

```perl
$log->extract($dir, runs => [0]);
$log->archive($file, format => 'sqlite', runs => [0]);
```

Confirm or amend.

ANSWER: Confirm

---

## F6. Harness collector's own collector_start/end

The harness collector has no parent. Its collector_start/end IPC must go
somewhere. Two options:

- **(A)** Send IPC to `ipc_harness` (its own bus). Harness service
  receives, reflects as event into its own outgoing stream, harness
  collector writes to `services/harness/events.jsonl.zst`. Recursive but
  works since the IPC message arrives after the harness service is
  running and the collector is consuming events.
- **(B)** Harness collector writes its `harness_collector_start`/`_end`
  events directly to `services/harness/events.jsonl.zst` at process
  boundary, bypassing the IPC round-trip. No parent service, no IPC.
- **(C)** Harness has a special "self" handler that synthesizes the
  event into its own pipeline without IPC.

(A) has bootstrap problems: the harness collector emits collector_start
*before* the harness service has registered handlers for it (or before
the collector loop is running to consume the resulting reflected event).

(B) is simplest but breaks the "events come through the pipeline"
invariant slightly.

(C) is (B) dressed up.

I lean (B). The harness's own start/end events are special and the
collector writes them directly. Document the exception.

Confirm or pick another.

ANSWER: These events and ipc calls are not needed at all for the harness since they serve to tell us when more data is available from a new collector, if we are already reading the events we do not need to know that same event stream is now available. If a service has no parent it just skips the collector start and end reporting that would nomally go to a parent. The harness artifacts are the entry point that are always expected to be there, so we do not need the discovery. This can be a generic mechanism for any collector that has no parent.

---

## F7. Preload-spawned job IPC plumbing

Per B4-followup amendment: jobs started by a global preload service have
the preload as parent, but the run service that requested the job is set
as `ipc_run`. So `ipc_parent != ipc_run`.

Today's code derives `bus_id` from `ipc_parent` for run-scoped collectors
(Service.pm). With ipc_parent != ipc_run, a job collector spawned by a
preload would derive `bus_id` from preload (its parent) but log to the
run.

Plumbing:

- `ipc_parent`  → preload service bus
- `ipc_run`     → requesting run service bus
- `ipc_harness` → harness bus (as today)

The collector's bus_id derives from job_id + run_id (its addressable
identity, run-scoped). The IPC routing per kind:

- `test_job_started` / `failing` / `diagnosing` / `completed` → `ipc_run`
  (not ipc_parent — the run service tracks job state, not preload)
- `job_release` → `ipc_harness`
- `collector_start` / `collector_end` → `ipc_run` (per B4 confirm)

So `ipc_parent` (preload) gets nothing from a preload-spawned job. The
preload is the spawn-time parent only; runtime IPC routes around it.

Confirm.

ANSWER: Confirm

---

## F8. Attachment filename collision strategy (no event UUIDs)

Old carried answer 10e: collision uses event UUID as prefix. But events no
longer have UUIDs (per spec).

Replacement options:

- **(A)** Stamp + sequence index from event position in stream:
  `1714875042.123-0007-foo.png`
- **(B)** sha256-content-hash prefix: `<hash>-foo.png` (auto-deduplicates
  identical content)
- **(C)** Just stream-position sequence: `0007-foo.png`
- **(D)** A per-collector counter: `0001-foo.png`, `0002-foo.png`

I lean (D) — simplest, deterministic, no collisions within a collector,
no need to compute hashes.

ANSWER: D

---

## F9. Subtests shape in Job state (in report.jsonl.zst)

Per B8 + J2 answer: report.jsonl.zst job state must include top-level
subtests so `failed` command doesn't have to walk all events.

Strawman shape:

```perl
subtests => [
    { name => 'foo subtest', pass => 1, count_pass => 5, count_fail => 0 },
    { name => 'bar subtest', pass => 0, count_pass => 3, count_fail => 1 },
],
```

Order: as seen in the test stream (insertion order).

Confirm or amend.

ANSWER: Thats fine

---

## F10. Live log identification — no UUID

Per F5 amendment: live dir never has a UUID; UUID only assigned at
archive seal.

Implication: while a run is live, no `log_uuid` exists. The test command
talks to its harness over IPC by bus name. The renderer points at the
live dir by path. Nothing identifies a live dir by uuid.

Are there places we need a "live identifier" (e.g. when multiple
yath start instances coexist on a host)? My read: no — IPC bus names
already disambiguate. Live dir is identified by its filesystem path and
the harness bus name. UUID gets minted on first archive.

Confirm.

ANSWER: That would probably be fine, but go ahead and throw a 'LIVE' file in the logs/ root with a value of "1\n". in case anything does need to disambiguate later, do not include it in tar archives, and no equivelent in databases, file is missing in non-live dir extracts.

---

## F11. SQLite-as-`.yath` opening without uuid

Per D4 amendment: always assume DB can be multi-archive. SQLite is no
exception.

When `Log->new(file => '/path/to/run.yath')` is called and the file is a
SQLite database:

- If 1 archive in DB → use that one (no `uuid` arg needed).
- If N > 1 archives in DB → throw "ambiguous; specify uuid => ..." (the
  caller must pass `Log->new(file => $path, uuid => $u)`).

Confirm.

ANSWER: Correct

Follow up for after current batch of work is done, do not implement yet:

Will also need another object LogDB which can take an SQLite db, or other database (dsn + args, dbh, etc) which can be used to list archives, runs, etc and we can get ::Log objects out of it:

    my $ldb = LogDB->new(...);
    my @archives = $ldb->archives();

    my $log = $ldb->log($uuid); # Returns an App::Yath2::Log object.

    For now @archives can just be a list of uuids. Eventually we will attach meta-data to logs, but not now.

## F12. Naming: IPC messages vs on-disk facets

To keep IPC and on-disk-facet naming distinct (per the IPC = lightweight
RPC, on-disk = harness facet pattern):

| Direction       | IPC message kind         | On-disk facet name        |
|-----------------|--------------------------|---------------------------|
| Collector→Service | `collector_start`     | `harness_collector_start` |
| Collector→Service | `collector_end`       | `harness_collector_end`   |
| Service→stream    | (n/a)                 | `run_failing`             |
| Service→stream    | (n/a)                 | `run_completed`           |
| Service→stream    | (n/a)                 | `collector_report`        |

So IPC kinds are bare; on-disk facets carry the `harness_`/`run_` prefix
that matches today's existing run-service event facet names
(`seed_run_started`, `job_started`, etc.).

Confirm or amend.

ANSWER: Correct

---

## F13. UUID `_string` companion field — populate via trigger or app code?

Per K5 amendment: native UUID where supported; binary-stored UUIDs
(MySQL/Percona) get a `_string` companion field for human readability,
indexed.

Population options:

- **(A)** App code (Perl) writes both binary and string columns on
  every INSERT/UPDATE.
- **(B)** DB trigger on the binary column converts to string.

You said "(though a trigger might be better for that?)". I lean **(B)**
for portability — triggers are ugly per-flavor SQL but the app stays
clean. Define the trigger in the schema SQL.

Confirm.

ANSWER: Confirm.

---

## F14. `valid_log` command scope

Per D2 amendment: add `yath valid_log FILENAME` that:

- Checks magic bytes (sqlite or tar.zidx).
- Tells you which type.
- Verifies the log has artifacts for the 'harness' service entry point.

Specifically, "correct artifacts for harness" means:

- `services/harness/spec.jsonl.zst` exists and has at least one parseable
  row.
- `services/harness/events.jsonl.zst` exists.

No deeper checking (no validating that all harness_collector_start events
have matching collector_ends, no validating run/job structure).

Confirm.

ANSWER: Confirm

Also command should be named `yath inspect LOGFILE`

---

## F15. Test command and renderer process model

Per I2 amendment: "Renderer can be its own child process with its own
loop, parent monitors IPC and waits on renderer."

Concretely:

- Test command process: spawns harness (separate process), spawns renderer
  child (separate process), then loops on IPC events from harness bus.
- Renderer child: opens `Log->new(live => $dir)`, iterates events,
  produces output.
- Test command waits on renderer to exit; combines IPC results + renderer
  exit + Log final summary into the test command's exit code.

Question: what causes the renderer child to exit cleanly?

- (A) Renderer iterates until `$log->EOE` returns true, then exits.
- (B) Test command sends a signal/IPC to renderer telling it to wrap up
  once the harness has exited.
- (C) Renderer watches for the harness's `harness_collector_end` event in
  the log and exits after it arrives.

I lean (A) — the iterator's EOE is the correct termination condition. The
test command waits for renderer to exit.

Confirm or pick.

ANSWER: A. However also have it check, if the harness pid goes away, we are getting no events, and EOE stays false, timeout after 10 seconds, and report an error that there is a problem with the EOE logic that we need to fix. We want to detect and EOE problem and report, not silently wait forever.

---

## F16. Anything I missed in this followup pass

ANSWER:

Follow ups, not for this batch of work, but before we close the branch:

 - Metadata for archives, project, user, git sha, etc.
  - The 'inspect; command will provide this metadata
  - stored as meta.json in archive root.
 - LogDB object for working with multi-archive databases and sqlite .yath files.

---

# Round 2 followups (raised by F1-F16 amendments)

---

## F17. Run service `collector_report` facet shape — exact aggregate

Per F3 amendment: "for a run there should also be the state the run
tracks about what test jobs passed and failed, what top-level subtests
passed and failed, etc. That state should be emitted and included for
runs."

Strawman shape for the run's `collector_report` facet:

```perl
{
    pass         => 0|1,           # overall run pass/fail
    started_at   => $stamp,
    ended_at     => $stamp,
    total_jobs   => $int,
    passed_jobs  => $int,
    failed_jobs  => $int,
    aborted_jobs => $int,           # if useful
    jobs         => [
        {
            job_id   => $ord,       # ord int per run
            file     => $path,      # test file
            pass     => 0|1,
            tries    => $N,         # number of tries (1 = no retry)
            subtests => [
                { name => $str, pass => 0|1, count_pass => $int, count_fail => $int },
                ...
            ],
        },
        ...
    ],
}
```

Note `jobs` is an ordered array (by job ord), not a hash, so `failed`
command can produce stable ordered output.

Confirm or amend.

ANSWER: confirm

---

## F18. Run service builds collector_report from per-job report.jsonl.zst

To assemble the run's `collector_report`, the run service needs each
job's final state (including the job's subtests array). Two paths:

- **(A)** Run service reads each job's `report.jsonl.zst->report_iter
  ->last` from disk after all jobs done, assembles aggregate.
- **(B)** Each Auditor::Test extends its `test_job_completed` IPC
  payload with the full job state hash (including subtests). Run service
  accumulates in memory as it receives each.
- **(C)** Hybrid: run service tracks lightweight pass/fail in memory
  (already does), reads richer per-job data from disk only when assembling
  collector_report.

(A) is simplest; the per-job file already exists by the time the run
service shuts down. (B) bloats every IPC message with subtests data the
run service may never need.

I lean (A).

ANSWER: B

---

## F19. Generic "no parent" rule for skipping collector_start/end IPC

Per F6 amendment: "If a service has no parent it just skips the
collector start and end reporting that would normally go to a parent.
This can be a generic mechanism for any collector that has no parent."

Concrete rule: a collector skips collector_start / collector_end IPC
emission if both `ipc_parent` and `ipc_run` are undef. Today only the
harness collector matches that condition. (Run-service collectors have
ipc_parent = ipc_harness; global service collectors have ipc_parent =
ipc_harness; job collectors have ipc_run set; preload-spawned jobs still
have ipc_run set per F7.)

Confirm rule.

ANSWER: confirm

---

## F20. `LIVE` sentinel file lifecycle

Per F10 amendment: drop a `LIVE` file at logs/ root with `"1\n"` content.
Not in tar archives. No DB equivalent. Missing in non-live extracts.

Lifecycle:

- **Created**: by the harness collector when initializing the log dir
  (first thing, before any other writes).
- **Removed**: when?
  - **(a)** By the harness collector on clean exit (exit means "no
    longer live").
  - **(b)** Never automatically; only by archive/extract operations
    (live dir stays "live" even after harness exits — until user manually
    archives).
  - **(c)** By the archive/extract operations themselves (since they
    produce non-live output that lacks LIVE; the source dir's LIVE may
    persist or be removed depending on whether source is mutated).

I lean (a) — when harness exits cleanly the dir is no longer being
written to, so LIVE goes away. A crashed harness leaves a stale LIVE
file (consumers can detect "live but no harness running").

Confirm or pick.

ANSWER: a. It can also be used by the test process's renderer subprocess to detect broken EOE detection.

---

## F21. `inspect` command output format

Per F14 amendment: rename `valid_log` → `yath inspect LOGFILE`.

Output strawman:

```
$ yath inspect /path/to/run.yath
Path:     /path/to/run.yath
Type:     tar.zidx
Valid:    yes
Harness:  services/harness/{spec,events}.jsonl.zst present, 1 spec row
Runs:     2  (ords: 0, 1)
Globals:  3  (harness, preload-perl, preload-mod)
```

For SQLite multi-archive:

```
$ yath inspect /path/to/multi.yath
Path:     /path/to/multi.yath
Type:     sqlite
Valid:    yes
Archives: 3
  - $uuid_1  (1 run)
  - $uuid_2  (3 runs)
  - $uuid_3  (1 run)
```

`--json` flag for machine output.

Confirm or amend.

ANSWER: confirm

---

## F22. Renderer EOE-timeout error mode

Per F15 amendment: renderer waits for EOE; if harness pid gone AND no
events arriving AND EOE false for 10s → timeout, report error.

Concrete:

- Renderer detects "harness pid gone" how? Test command tells it (signal
  or IPC). Or renderer polls `kill 0, $harness_pid`?
- I lean: test command knows when harness exits (IPC peer-down), then
  signals or IPC-tells the renderer "harness gone, you have 10s".
- After 10s the renderer:
  - Prints to STDERR: "ERROR: EOE logic bug — harness gone, no new
    events, but `\$log->EOE` still false. Please report this issue."
  - Exits with nonzero code.

Test command sees renderer nonzero exit and folds it into final exit code
(per I3 "if either log or ipc reports failure, then we have a failure").

Confirm.

ANSWER: Confirm, can also watch for LIVE file to go away.

---

## F23. `meta.json` future-work scope

Per F16 future work: `meta.json` at archive root. For the current branch
we should structure the archive layout to ALLOW a future meta.json
without restructuring (i.e., reserve the name and the location).
`Log->artifacts(...)->save('meta.json', ...)` would write it via the
generic save() API once we get there.

Confirm: no `meta.json` written this round, but the archive root is
treated as a valid save target for future arbitrary files (so `save()`
on the dispatcher itself, not on a specific collector's artifacts(),
works for archive-root files).

This implies: a top-level `$log->save($filename, $content, %opts)` that
writes to the archive's root rather than a specific collector's base
dir. OR a special `artifacts()` shape:

```perl
$log->artifacts()->save('meta.json', $content);   # no selector = archive root
```

Which shape do you prefer?

ANSWER: $log->artifacts()->save('meta.json', $content);   # no selector = archive root

---

## F24. Tasks — capture future-work items

Add tracked tasks for after this branch closes:

- Archive metadata + `meta.json` + `inspect` shows metadata.
- `LogDB` object for multi-archive databases + sqlite-as-multi-archive
  `.yath` files (lists archives, returns per-archive `Log` objects).

These are noted in the doc; they should also live in the task tracker so
they don't get forgotten when the branch closes.

Confirm.

ANSWER: confirm

---

## F25. Anything else

ANSWER: nothing

---

## F26. MariaDB/MySQL DATETIME(6) vs producer time format — RESOLVED

DATETIME(6) columns on mariadb/mysql (`runs.started_at`, `runs.ended_at`,
`job_tries.queued_at`/`started_at`/`ended_at`) reject ISO-8601 with `T`/`Z`
separators. Producer (`Test2::Harness2::Collector`) emits epoch `time()`
numbers, which DATETIME(6) also rejects.

Surfaced during B4 (spec/report promotion) when test fixtures used ISO `T`/`Z`
format on those flavors. Pre-existing; affects B3 service_lifetimes
timestamps too but `service_lifetimes.t` doesn't exercise the failure path.

RESOLUTION: commit `d76abbf09 Log/DB: normalize timestamps via DateTime +
DateTime::Format::*`. Adds `_to_datetime` + `_format_datetime` hooks on
Log::DB; per-flavor overrides use DateTime::Format::Pg / MySQL / SQLite
(SQLite uses strftime ISO+millis since DateTime::Format::SQLite truncates
fractional seconds). All producer-side bind sites + reconstruction emit
sites now funnel through these. Verified end-to-end with real archives
on sqlite, postgresql-{10..18}, mariadb-12.2, mysql-9.7.
