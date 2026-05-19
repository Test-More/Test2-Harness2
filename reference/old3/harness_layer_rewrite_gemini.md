# Findings: harness_layer_rewrite

## High-Risk Findings

1. **Stage 1 intentionally discards the old archive schema, so the main risk is migration sequencing, not compatibility.**

   The clarification says the `App::Yath2` namespace will be rewritten later to use the new schema, and that the old schema can be discarded for now. That removes the earlier concern about preserving `App::Yath2::Log` archive compatibility. The remaining risk is that Stage 1 replaces `share/schema/*.sql` while intentionally leaving all `App::Yath2` consumers broken, which means the repo may have a long interval where only temporary scripts can exercise the harness.

   Recommendation: make the Stage 1 acceptance boundary explicit: which tests are expected to pass, which `App::Yath2` tests are expected to fail, and what temporary commands replace `yath test`, inspect, replay, archive, and spawn until the later rewrite lands. The new schema should still carry a version marker so later `App::Yath2` work can detect incompatible early live DBs.

2. **SQLite is being asked to be the IPC bus, event sink, scheduler state store, and log archive without a concrete write-contention design.**

   The plan stores every event as one row, compressed, with collectors producing hundreds or thousands of events per second, while services poll `requests`, `launches`, terminate flags, service state, and scheduler rows. WAL and batched transactions are mentioned as a question, but SQLite still has a single writer. Multiple collectors plus scheduler/launchers/services will contend for that writer lock.

   Recommendation: make the first milestone a load-bearing SQLite prototype with explicit PRAGMAs, busy timeout policy, transaction sizes, checkpoint behavior, and worst-case event-rate benchmarks. Decide whether collectors write directly, write through a single DB writer process, or use per-process buffers that flush in bounded batches. This should be resolved before committing to one-row-per-event as the core transport.

3. **`launches` and `requests` lack atomic claim/lease semantics, so duplicate handling is likely under concurrent launchers or service retries.**

   The plan says launchers wait for rows they need to act on and set `started` when they start work. It does not define how a launcher atomically claims a row, how multiple launchers of the same class avoid racing, what happens if a launcher dies after claiming but before `started`, or whether a stale claim is recoverable. `requests` has the same issue for services polling request rows.

   Recommendation: add columns such as `status`, `claimed_by`, `claimed_at`, `lease_until`, `attempt`, `completed`, and `error`, and define the only valid state transitions. Use a single conditional update, for example `UPDATE ... WHERE status='pending' ... RETURNING`, as the claim primitive. Tests should intentionally run multiple launchers against the same queue.

4. **Process ownership is underdefined after removing `Test2::Harness2` as a service/process.**

   The current implementation centralizes termination, process-group isolation, subreaper behavior, and pid reaping through `Test2::Harness2::Role::Service` and the harness service. The rewrite says `Test2::Harness2` becomes a DB handle, launchers reap collectors, test collectors do not double-fork, and `yath spawn` processes disconnect. That leaves several ownership gaps: who becomes the subreaper, who kills descendants if a launcher dies, who enforces parent-death shutdown, and who owns hard-stop escalation for orphaned collectors.

   Recommendation: define a single lifecycle owner for each process kind in the schema and in code. Include crash cases: runner exits, scheduler exits, launcher exits while a collector is active, collector exits before writing completion, service ignores terminate, and detached spawn exits. The owner rules should precede implementation of the launcher role.

5. **The clarified no-compatibility stance needs replacement observability contracts.**

   The clarification explicitly says not to work on compatibility and that old log files do not need to be read or supported. That resolves the earlier archive parity objection. The remaining issue is observability during the rewrite: with no `spec.json`, `events.jsonl`, `report.json`, directory logs, tar logs, or old sqlite archive reader, there must still be a defined way to inspect live runs, debug failed collectors, and validate event ordering.

   Recommendation: define the replacement DB read/debug API for Stage 1. At minimum, document queries or helper methods for runner status, service state, run/job/try summaries, collector stderr/stdout events, artifacts, and failed collector diagnostics.

## Design Gaps To Close Before Implementation

6. **The schema sketch is still missing executable detail; `job_tries` is now acknowledged but not specified.**

   The clarification says `job_tries` was forgotten and needs to be specified. Many rows still reference `runner_id`, `run_id`, `collector_id`, and `service_id`, but the table sketches do not list primary key columns consistently. The new rows also need a clear retry/try model, test file identity, exit decoding, top-level subtest names/counts, artifact scopes, and enough metadata for the later `App::Yath2` rewrite.

   Recommendation: write the schema as executable SQL early, not prose. Include `job_tries` before collector/auditor work starts, and add indexes for every scheduler poll, request claim, event iteration, and result query as the clarification notes. Also add a mapping table from current `Run`, `Run::Job`, `TestFile`, auditor final state, and service lifetime fields to the new rows.

7. **Direct SQL from collectors and auditors risks duplicating invariants outside the object layer.**

   The plan allows collectors/auditors to bypass the `Test2::Harness2` object API for performance. That is reasonable for hot paths, but then invariants like `event_ord` allocation, final job summary updates, collector sealing, transaction boundaries, compression flags, and retry-safe updates must live somewhere other than ad hoc SQL in several modules.

   Recommendation: create small DB writer classes for hot-path operations, for example `EventWriter`, `CollectorWriter`, and `JobStateWriter`. They can use prepared SQL directly while keeping invariants and test fixtures centralized.

8. **The clarified tick/backoff model is a good start, but it still needs operational rules.**

   The clarification proposes a tick progression of roughly `0.05s`, `0.1s`, `0.5s`, then `1s`, with `1s` as the longest sleep and `SIGUSR1` wakeups where supported. That addresses the previous missing latency budget. The remaining details are when backoff resets, whether different service classes need different caps, how unsupported platforms wake promptly, and how to avoid signaling a recycled pid.

   Recommendation: make the tick/backoff contract part of the service role, with tests for immediate wake after request insert, termination latency at max backoff, and the no-`SIGUSR1` platform path. Store enough process identity to avoid stale pid signaling.

9. **Resource migration is larger than the plan suggests.**

   The document says current resources probably do not need much porting, but existing resource handling includes global and run-scoped resource services, preload-backed resources, pending preload service starts, broken-resource behavior, resource assignment/release, and teardown ordering. Moving the scheduler to DB rows changes all of those state transitions. The clarifications note that `service_state.info` is the primary channel for Resource Service -> Scheduler communication.

   Recommendation: make resources a separate stage with an acceptance matrix: simple limiters, run-scoped resources, service-backed resources, preload-backed resources, broken/transient/permanent failure, restart, abort, and teardown after run completion.

10. **Preload launch behavior is too complex to leave as a single Stage 1C bullet.**

   The plan relies on a `BEGIN` loop, `Long::Jump`, `goto::file`, state reset, collector fork behavior, and preload launchers acting as services. Current preload behavior already has readiness, reload, resource routing, and spawn semantics. This is one of the riskiest parts of the rewrite.

   Recommendation: split preload into explicit sub-stages: default Unix launcher first, preload service starts and advertises readiness second, preload job launch third, reload/restart fourth, and spawn-from-preload last.

## Lower-Risk Notes

- The new `fetch/fetch_all/insert` API is plausible, but it should not be the only abstraction. Hot-path writers and domain-specific methods will be easier to keep correct than generic table access everywhere.
- Use consistent names before implementation: the document mixes `finalize` and `finish`, `terminate` and `terminated`, `sealed` for collector process exit, and `result`/`pass`/`passed`.
- The clarified `${SYSTEM_TMPDIR}/${USER}-${PROJECT}-${RUNNER_UUID}.yath` path reduces collision risk compared with PID, but it should still specify cleanup policy, permissions, and how clients discover stale vs active DBs.
- Deleting completed `requests` after the requestor reads the response is reasonable, but the request lifecycle still needs ownership rules for abandoned requestors and stale completed rows.
- The `service_state.info` clarification is useful: it makes service state single-writer service-owned data, with scheduler/resource objects as consumers. That should be enforced in code and tests.
- Removing `IPC::Manager` from `ARCHITECTURE.md` and `CLAUDE.md` should be tracked as a doc task in the same stage that removes the code dependency.
- The typo-level issues are not important, but the incomplete bullet at the Stage 1 completion list should be resolved because it marks an undefined porting boundary.

## Suggested Stage Gate

Before replacing existing modules, build one minimal vertical slice:

1. Create the live SQLite DB with executable schema and PRAGMAs.
2. Start one scheduler and one Unix launcher.
3. Queue N simple test jobs.
4. Have collectors insert events and final job state through the DB.
5. Finish the runner and query pass/fail from the DB.
6. Run the same test under parallel collectors with enough output to measure lock contention.
7. Kill the scheduler, launcher, and collector at controlled points and verify recovery or explicit failure state.

That slice should decide the concurrency, lifecycle, and schema shape before the broader `App::Yath2` migration starts.
