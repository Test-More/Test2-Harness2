# Chunk 9 — unified, symmetric service channel

## Task / trigger

Migration chunk 9 (ARCHITECTURE.md §5.2, from the `thoughts` brief): replace the
runner/stage IPC's two separate connection structures — an accept-only inbound set
plus discrete write-only outbound clients — with **one bidirectional connection
set** per service, a **peer-identity handshake**, and **reuse-never-duplicate**, so
two services share a single channel regardless of which side dialed. Scope chosen
with the user: build the infra **and** collapse the runner↔stage pair onto it now
(pulling chunk 10's direction-reversal forward).

## What landed

1. **`Test2::Harness2::Role::Service` — the reusable channel.**
   - One set: `service_conns` now holds per-connection metadata (`fb`, `identity`,
     `outbound`) for both **accepted** and **dialed** connections; all live in
     `service_select`, so a dialed connection is readable too — either end may send
     requests.
   - Handshake: a discriminated `{handshake => {identity => ...}}` frame. The dialer
     sends its identity on connect; the accepter replies with its own. A connection
     that never handshakes (collector reporters, plain request/reply command
     clients) is unaffected — the handshake is one more frame kind, not a preamble.
   - `service_connect_peer($identity, $path)` (reuse-or-dial+handshake),
     `service_peer_conn`, `service_send`, and a `service_peers` registry keyed by
     identity.
   - Simultaneous-connect dedup: both ends keep the connection whose **initiator has
     the lexically-smaller identity** and drop the duplicate, converging on one
     channel. (`_keep_this_conn`.)
   - Covered by `t/AI/unit/Role_Service_channel.t`.

2. **runner↔stage collapsed to one channel.** The stage dials `runner.socket`,
   registers as `preload-<stage>`, reports up that channel
   (`stage_ready`/`stage_down`/`stop_task`/`retry_task`/`job_pid`/`reload`/`halt_run`)
   and receives `run_task`/`stop` dispatch back **down the same channel**
   (`service_send` by peer identity). The runner no longer connects out to
   `preload-<stage>.socket`; the stage still binds it but it is **reserved for
   `yath spawn`** (§4.8). `Test2::Harness2::Runner::Stage::Client` deleted; the
   in-stage delegate (`Runner::Stage`) reports via the runner's `service_send`
   instead of a separate `Runner::Client` connect-out.

## Decisions / alternatives

- **Stage-initiated, not runner-initiated.** The collapse keeps the *stage* as the
  dialer (it already dialed `runner.socket` for `stage_ready`). A runner-initiated
  collapse would need the runner to proactively connect to each stage and the stage
  to defer `stage_ready` until that connection appeared — a connect/ready ordering
  deadlock to dance around. Stage-initiated avoids it and matches the §4.7 target
  direction ("a stage registers itself with the runner"). This means chunk 9
  delivered chunk 10's registration + dispatch-over-registered-channel; chunk 10 is
  reduced to its residual (explicit lifecycle states + stage-owned restart).

- **Correlation ids deferred, deliberately.** §5.2's target mentions request/response
  correlation on the shared stream, but it is **not** built here: every symmetric
  message in place is one-way, and the two-way requests (`status`/`truncate`/
  `subscribe`/…) are single-initiator and read their one reply. Correlation is only
  needed once a service issues concurrent two-way requests on a shared channel; left
  for that need. Recorded in ARCHITECTURE.md §5.2 status.

- **Command clients stay plain clients, not service peers.** `App::Yath2::Client` /
  `Runner::Client` / `Runner::Subscriber` connect to `runner.socket`, do their work,
  and close; they are not long-lived peers and do **not** handshake. Handshaking them
  would corrupt their request/reply framing (the runner would send a handshake reply
  the client would read as its response) for no benefit. §5.2 keeps collector
  reporters and plain request/reply clients as a separate lane from service channels.

- **Per-connection metadata as a hashref, not a Connection class.** Handlers,
  `add_subscriber`, `forward_frame`, and `service_transition` all pass the raw `$conn`
  filehandle as the public token. Keeping that (and parking metadata in a parallel
  per-fd hashref) avoided threading a `.fh` accessor through every call site. A
  Connection value object remains a possible later cleanup.

## Architectural impact

- `IPC.md` §2/§3/§4/§5 updated to the one-bidirectional-set / handshake model.
- `ARCHITECTURE.md` §4.7 and §5.2 status tags moved `[target]` → `[migrating]`
  (§5.2 gained a status note on what is implemented and that correlation is deferred).
- Boundary shift between chunks 9 and 10 recorded in `MIGRATION.md`.

Full suite green at each step (infra: Files=96/Tests=1689; collapse: Files=96/Tests=1683).
