# Chunk 9 — unified service channel (full bidirectional RPC)

## Task / trigger

Migration chunk 9 (ARCHITECTURE.md §5.2, from the `thoughts` brief): replace the
runner/stage IPC's two separate connection structures — an accept-only inbound set
plus discrete write-only outbound clients — with **one bidirectional connection per
peer**, so two endpoints share a single channel regardless of which side dialed.
Scope chosen with the user: build the infra **and** collapse the runner↔stage pair
onto it now (pulling chunk 10's direction-reversal forward).

The design evolved through review discussion: an initial one-way handshake +
simultaneous-connect-dedup was **replaced** with a full bidirectional RPC protocol
(mandatory identity exchange, request_id-correlated request/response, no ordering
assumption), because that is what the wire actually needs and is cleaner than
bolting identity onto an otherwise order-dependent stream.

## What landed

1. **`Test2::Harness2::Role::Service::Connection` — the per-connection transport.**
   One framed connection owns the whole wire protocol so it lives in one place
   rather than per client. Five frame kinds keyed by top-level field:
   `{identity=>{name}}`, `{request=>{request_id,command,...}}`,
   `{response=>{request_id,...}}`, and pass-through collector
   `{transition}` / `{facet_data}`.
   - **Identity exchange:** a dialer announces itself on open; an accepter replies
     only after seeing the peer's identity (so it never sends identity to a one-way
     reporter). A non-identity first frame, or no identity before a ~5s timeout,
     drops the connection.
   - **Reporter lane:** a connection whose first frame is a transition is a one-way
     collector reporter (no identity) — this keeps the external Test2-Collector
     `Recorder::Socket` reporters working unchanged.
   - **No ordering:** `send_request` returns a request_id; responses are matched by
     id (unmatched / fire-and-forget responses are discarded). An endpoint may
     receive unrelated frames between a request and its response.
   - **Bad-frame policy:** after identity, 3 consecutive corrupt/invalid frames
     close the connection (any valid frame resets); a fatal `sysread`
     (ECONNRESET/EBADF) drops it at once.
   - Covered by `t/AI/unit/Role_Service_Connection.t` (socketpair-driven).

2. **`Test2::Harness2::Role::Service` drives a set of Connections.** One
   `service_conns` / `service_select` set covering accepted **and** dialed
   connections; a `service_peers{identity}` registry backing
   `service_send($identity, $command, %args)` and `service_connect_peer` (reuse,
   never duplicate). It dispatches each request to `request_handler_<command>` and
   sends the return value back as a response (a handler returning `undef` is a
   one-way request, no response); routes responses to `service_on_response`; hands
   transitions to `service_transition`.

3. **runner↔stage collapsed to one channel.** The stage dials `runner.socket`,
   identifies as `preload-<stage>`, reports up
   (`stage_ready`/`stage_down`/`stop_task`/`retry_task`/`job_pid`/`reload`/`halt_run`)
   and receives `run_task`/`stop` dispatch back down the same channel. The runner no
   longer connects out to `preload-<stage>.socket` (reserved for `yath spawn`, §4.8).
   `Runner::Stage::Client` deleted; the in-stage delegate (`Runner::Stage`) reports
   via the runner's `service_send`.

4. **Commands are full peers.** `Runner::Client` and `Runner::Subscriber` wrap a
   `Connection` (identity on connect; correlated `_request`; subscribe replays
   transitions batched with the snapshot reply). `App::Yath2::Client` is unchanged
   (a facade over those two).

## Decisions / alternatives

- **Full RPC over one-way handshake.** The first cut sent a one-way identity frame
  and resolved a simultaneous-connect race by dedup. Review concluded the dedup was
  unneeded for any current pair (only the stage dials the runner), and that the real
  requirement is order-independent request/response — so identity became a mandatory
  two-way exchange and every request carries a `request_id`. This also let the
  command clients become real peers instead of relying on a fragile
  read-next-frame-is-my-reply model (which would have broken the moment the runner
  pushed any unsolicited frame).

- **Stage-initiated, not runner-initiated.** The collapse keeps the *stage* as the
  dialer (it already dialed `runner.socket` for `stage_ready`). A runner-initiated
  collapse would need the runner to proactively connect to each stage and the stage
  to defer `stage_ready` until that connection appeared — a connect/ready ordering
  deadlock. Stage-initiated avoids it and matches the §4.7 target ("a stage
  registers itself with the runner"), so chunk 9 delivered chunk 10's registration
  + dispatch-over-registered-channel; chunk 10 is reduced to its residual (explicit
  lifecycle states + stage-owned restart).

- **Reporter lane is exempt from identity.** Collector reporters live in the
  external Test2-Collector dist and stream `{facet_data}` with no identity. Rather
  than change that dist, a transition-first connection is recognized as a one-way
  reporter, so the mandatory-identity rule applies only to request/response peers.

- **Non-blocking client connect.** Clients send their identity on `Connection`
  construction but do **not** block waiting for the peer's identity before
  returning, because they match responses by id and never need the peer identity —
  and blocking there would deadlock a single-threaded caller that pumps the runner
  only after the connect returns.

## Architectural impact

- `IPC.md` §2-§5 updated to the RPC protocol (frame kinds, lifecycle, one
  connection set).
- `ARCHITECTURE.md` §4.7 / §5.2 status tags `[target]` → `[migrating]`; §5.2
  rewritten to the identity-exchange + correlation model.
- The 9/10 boundary shift recorded in `MIGRATION.md`.

Full suite green throughout (final: Files=97, Tests=1693).
