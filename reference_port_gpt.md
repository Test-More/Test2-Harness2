# Review: reference-port features spec

Target: `AI_DOCS/2026-06-22-reference-port-features-spec.md`

## Findings

### 1. The directives ticket is aimed at the wrong live object in places

Severity: high

Item 1 describes replacing `TestFile::_scan` and opens with
`App::Yath2::TestFile::_scan`, but its current-state text also refers to
`Test2::Harness2::TestFile::_scan`. The live tree has already completed the
split: `App::Yath2::TestFile` is the file-reading/parser object, while
`Test2::Harness2::TestFile` is state-only and must stay file-free.

Action: make the TODO/ARCH text explicit that only `App::Yath2::TestFile` gets
the scanner/compat changes. The harness-side `Test2::Harness2::TestFile` should
only gain accessors if the task payload gains new already-computed fields; it
must not load the directives parser or read files.

### 2. Directive `feature.*` / `meta.*` has no durable path yet

Severity: high

Item 1 says free-form `meta.*` and `feature.*` nested subtrees persist into JSON
columns. Today `App::Yath2::TestFile->queue_item` only carries selected structural
fields (`duration`, `category`, `retry`, timeouts, preload fields, etc.). It does
not carry the full `features` or `meta` hashes, and
`Test2::Harness2::TestFile` has no `features` / `meta` accessors.

If the parser emits richer data but the queue item drops it, the DB logger cannot
recover it later from transitions.

Action: add an explicit task-payload contract before implementation. Either add
`fields` / `meta` / `features` to per-job task state and transition snapshots, or
define a normalized `job_fields` shape that the logger reads. Include a test that
a `HARNESS2: meta.foo "bar"` and `HARNESS2: feature.trace @on` directive survives
from scan -> queue item -> runner snapshot/logger input.

### 3. New directive parse errors need a decided producer policy

Severity: medium

The parser is specified to `croak` on syntax errors, collisions, unterminated
blocks, and unknown sigils. The legacy scanner mostly warns and keeps discovery
alive. The harness_service reference catches parser errors and warns, but the
new spec does not say whether a bad `HARNESS2:` line should abort discovery,
turn the individual test into a synthetic failure, or warn and ignore the new
grammar.

Action: choose one behavior in the ticket. My recommendation is: parser croaks,
`App::Yath2::TestFile` catches, marks the individual test invalid, and queueing
that test creates a harness-visible failure instead of aborting the whole run.
Add tests for bad quote, mismatched block close, and mixed good/bad files in one
run.

### 4. The DB row shape changes conflict with the current DB spec

Severity: high

Items 3 and 5 fold into DB tickets `#46` and `#50`, but the current DB spec still
has a different `job_tries` shape in places:

- `AI_DOCS/2026-06-21-db-layer-rewrite-quickorm-spec.md` still lists
  `stdout/stderr text`; Item 5 says to drop them and read output from artifact
  blobs.
- The DB spec uses `parameters` JSON; Item 5 says `params` JSON.
- Item 5 adds `result`, `assertion_count`, `subtests`, `subtests_passed`, and
  `subtests_failed`; the current DB ticket text still talks in terms of
  `fail/retry` bools plus counts.
- Item 3 says `jobs.passed = any try passed`, but the DB spec also has
  `jobs.failed` and run counters without defining how they fold when an early try
  fails and a later try passes.

Action: update the canonical DB spec and TODO tickets before DB-2 DDL starts.
Spell the final `jobs` and `job_tries` columns in one place, pick `params` vs
`parameters`, remove `stdout/stderr` if artifact blobs are the source, and define
the fold rules for `jobs.passed`, `jobs.failed`, `runs.passed/failed/retried`,
and `retry` visibility.

### 5. The DB logger ticket should depend on the 1-based try producer change

Severity: high

The reference-port spec correctly says `try_ord` is 1-based, but the live
producer still emits try `0`: `Runner::Job->is_try` defaults to `0`, the
collector identity carries that value, and retry increments from there. The DB
plan has ticket `#49` for the producer change, but `#50` (DB logger process) does
not list `#49` as a dependency.

Action: make `#49` an explicit prerequisite for `#50`, or state that the logger
temporarily maps wire `0` to DB `1`. The current design prefers changing the
producer, so the simpler action is to add `#49` to `#50`'s dependency list and
add an integration test that the first collector identity for a job carries
try `1`.

### 6. Re-introducing `resources` / `resource_types` is underspecified

Severity: high

Item 10 says to un-defer the `resources` and `resource_types` tables and have the
logger record resource-state rows. The current DB spec and ARCH still explicitly
defer resource telemetry tables. More importantly, "resource-state row" is not
defined against the live resource contract.

Current resources expose:

- `available($task)` for scheduler gating.
- `assign($task, $state)` and `record($job_id, $record_arg)` for per-job
  assignment state.
- `status_data()` / `resources` command output for live human status.
- `system_load` transitions for CPU/memory snapshots.

Those are different data classes. A table for per-job assignments is not the
same as a table for sampled disk/fd/pipe telemetry.

Action: before un-deferring the tables, define the schema and source of truth:
per-resource config, per-job assignment, sampled utilization, or all three. Add
column sketches, cardinality, sync behavior, and which transition/artifact feeds
the DB logger. If this is just live resource status, prefer sampler events or
artifact blobs and keep DB telemetry deferred.

### 7. The sampler extension needs a metric contract, not just "carry everything"

Severity: medium

Item 10 suggests extending the system-load sampler so pipe, rlimit, and disk
resources read one shared snapshot. That is reasonable for slow or global
metrics, but the three proposed resources need different sampling models:

- `PipeLimits` in the old3 reference already computes usage from configured
  service/test counts and in-flight jobs, not from a sampler.
- `UnixLimits` reads `/proc/self/limits`, `/proc/self/status`, and
  `/proc/self/fd`; those are process-local to the sampler if moved there, not
  necessarily the runner's current fd/thread state.
- `Disk` can be sampled periodically, but its failure/low-space state needs
  clear handling because it can become a permanent skip/abort condition.

Action: split Item 10 into a metric-source decision. Static kernel caps can be
sampled; volatile runner-local usage should remain in the runner/resource object;
disk can use cached samples with a refresh interval. Document the exact keys in
the shared snapshot only for metrics that are valid when sampled out of process.

### 8. The `Disk` dependency note contradicts the reference implementation

Severity: medium

Item 10 says `Filesys::Df` is optional only when a disk-percent limit is
requested, and that absolute free-space limits work without it. The old3
`Disk.pm` lazy-requires `Filesys::Df` in `init` before any threshold mode is
evaluated, because both percent and absolute thresholds need free/total bytes.
Perl core does not provide a portable statvfs API.

Action: either change the spec to say `Filesys::Df` is an optional dependency
required when the `Disk` resource is requested at all, or specify the concrete
core/external fallback used for absolute thresholds. Add tests for missing
`Filesys::Df` with `Disk=/tmp:1gb` and `Disk=/tmp:10%` so the behavior is locked.

### 9. `parse_duration` must not blur scheduling labels with seconds

Severity: medium

Item 11 says `parse_duration` is useful for `timeout` / `duration` directives.
Timeouts are numeric durations in the live runner (`event_timeout` maps to
collector `silence_timeout`; `post_exit_timeout` maps to `orphan_timeout`).
The `duration` directive, however, is a scheduling/ranking label
(`short` / `medium` / `long`), not elapsed seconds.

Action: scope `parse_duration` to timeout-like values unless a new numeric
runtime-duration feature is intentionally being added. Keep `HARNESS2: duration
short|medium|long` as labels, and use `parse_duration` for `timeout.event` /
`timeout.postexit`. If numeric duration labels are desired later, add a separate
field name so it does not collide with scheduler duration.

### 10. `ResetTerm` class placement conflicts with renderer option normalization

Severity: medium

Item 13 names `App::Yath2::Renderer::ResetTerm`, but the live `--renderers`
option prepends `Test2::Harness2::Renderer::` unless the class is written with a
leading `+`. The default renderer injection also instantiates classes from
`settings->display->renderers->{'@'}` in order. There is no active renderer
`weight` sorting like old3's `ResetTerm->weight`.

Action: choose the class location and injection path. If it lives under
`App::Yath2::Renderer`, default injection must push `+App::Yath2::Renderer::ResetTerm`
or otherwise bypass normalization. If it lives under
`Test2::Harness2::Renderer::ResetTerm`, the option path is simpler but the class
is a UI terminal concern. Either way, append it last in the renderer list and
test finish order with a fake TTY.

### 11. `list` needs a discovery enumeration API, not just a glob

Severity: medium

Item 15 says `yath list` should glob `/{tmpdir}/.*-yath-runner.sock`. The live
path rules are more complex:

- `find_runner_link` may use `harness.persist_file`.
- It may use `harness.persist_dir` or `YATH_PERSISTENCE_DIR`.
- If there is no project and the current directory is writable, discovery can
  walk upward through the current directory tree instead of the temp dir.
- The symlink basename is synthesized from user, host, and project variants.

A raw tmpdir glob will miss valid runners and may scan/delete links outside the
settings scope.

Action: add `App::Yath2::Discovery->list($settings, %params)` or a
`find_runner_links` utility that reuses the same directory/name rules as
`find_runner_link`, returns all candidate symlinks, probes liveness, and cleans
only links it is allowed to clean. Then build `yath list` on that API.

### 12. `ping` needs both client and runner service support

Severity: medium

Item 15 says to add `Client->ping()` if missing. It is missing, and there is no
`request_handler_ping` in the runner service handlers either. The pre_ai
reference command uses the old `App::Yath::Client`, not the current
`App::Yath2::Client` / `Test2::Harness2::Runner::Client` transport.

Action: add a no-side-effect `ping` request handler on the runner service
(return at least `{ok => 1, pid => $$}` or a timestamp), expose it through
`Test2::Harness2::Runner::Client` and/or `App::Yath2::Client`, then implement the
command loop. Add a unit test for the request handler and an integration-style
test that `ping` against a started persistent runner reports latency and exits
cleanly when interrupted.
