# System-load sampler service + opt-in CPU/memory throttling resources

## Task

Chunk 7 / ticket TODO-43. Give the harness an always-current view of system CPU and
memory load, sampled on a consistent interval, and use it to optionally throttle
test concurrency. The sampler design was locked with the user (ported in spirit
from `reference/harness_service`); the throttling-resource model was ported from
`reference/old3` (`Resource::CPU`/`Resource::Memory`) but **rewired to read the
sampler's shared snapshot** instead of sampling `/proc` inline, which makes it
cross-platform (Linux + BSD) and drops old3's Linux-only restriction.

## What landed

### Sampling primitive — `Test2::Harness2::SystemLoad`

`sample()` returns `{cpu_pct, ncpu, load_avg, mem_total, mem_available, mem_used,
mem_pct, stamp}`. Holds only the previous CPU reading; the first sample reports
`cpu_pct => undef` (a baseline) because CPU% is a delta between two readings.
Backends: Linux (`/proc/stat`, `/proc/meminfo`, `/proc/loadavg`) and BSD/DragonFly
(`sysctl`). The `/proc` reads and `sysctl` shell-outs are overridable test seams.
The CPU-math correctness fix from the reference is preserved: sum only `/proc/stat`
fields 0..7 (guest/guest_nice are already folded into user/nice); on BSD idle is
always the last `kern.cp_time` state regardless of the 5/6-state count.

### Dedicated sampler service — `Test2::Harness2::Service::Sampler`

Consumes `Test2::Harness2::Role::Service`. The runner spawns it always-on at
startup as a global helper process under a collector — the same shape as the
preload-root (`watch_parent_pid` = runner so it self-terminates on runner death) —
recording to `sampler-events.jsonl.zst`. It runs in-process via a `run` sub (no
fork+exec of a separate Perl process). It dials `runner.socket` as a service peer
(identity handshake) and pushes one-way `system_load` requests on a steady 0.2s
tick.

**Reporting is change-gated** (the `_metric_triggers`/`_commit_metric`/`_round_up_5`
state machine, ported verbatim-in-spirit): each metric is rounded up to the nearest
5% and tracked independently; an increase reports immediately, a decrease only once
it holds `decrease_delay` (1.0s ≈ 5 ticks), an unchanged value reports nothing; a
message carries both metrics' current rounded values plus the load average.

**Adaptation to 2.0d:** the reference's `Role::Service` drove
`service_on_start`/`service_tick`/`service_on_stop` hooks; the current
`Role::Service` does not (the consumer drives its own loop), so the sampler owns a
`run` method that binds its socket, dials the runner, then loops
`service_io` + `service_tick`. And rather than the reference's raw `connect_unix` +
`write_frame` of a bare `{request=>'system_load'}` frame, it uses the current
connection model: `service_connect_peer('runner', $sock)` + `service_send('runner',
'system_load', load => $snap)`, which performs the mandatory identity exchange and
the `{request=>{request_id,command,...}}` framing (§5.2). The runner's handler
returns `undef` (one-way, no reply).

### Runner side

- `request_handler_system_load` (`Runner::Role::Service::Handlers`) stores the
  snapshot in canonical `State` via `State::set_system_load` (new `<system_load`
  slot + writer) **and** calls `announce_system_load`, which folds a
  `harness_system` facet into `Runner::Monitor` and forwards it **globally**
  (`forward_frame($frame, undef)`) to every subscriber.
- `Runner::Monitor` learns the `harness_system` facet: a global singleton stored in
  a new `system_load` slot (latest-wins, not accumulated), exposed via
  `system_load()` and carried in **both** the global and run-scoped snapshots so a
  late subscriber immediately gets current load.
- `Runner::spawn_sampler` / `Runner::stop_sampler` spawn the sampler after
  `start_service` and reap it before `stop`/`close_service`. The reap closes the std
  fds the sampler's collector inherited from the runner (the reap-at-stop gotcha),
  so the runner's own collector is not held open past shutdown.

### Throttling resources

`Test2::Harness2::Role::Resource::Utilizer` provides the `should_defer_for_utilization`
floor: defer only when `in_flight >= min_concurrent` (default 1) AND the consumer's
`is_temporarily_unavailable` is true. It tracks in-flight via `track_started` /
`track_released` (called from the resource's `record`/`release`).

- `Test2::Harness2::Runner::Resource::CPU` — `available` returns 0 (defer) when the
  reported rounded `cpu% >= utilize_percent` (default 80). `-R CPU[=70]`.
- `Test2::Harness2::Runner::Resource::Memory` — defers when reported free memory
  `< min_free` (default 5% of total, or an absolute `512mb`); conservative-wins when
  layered with `--utilize`. `-R Memory[=20%|512mb]`.

Both read the runner's `system_load` snapshot through a `State` backref — the
resources are instantiated in `Runner::State::init` with `settings => ..., state =>
$self` (the same backref pattern `Resource::Preload` already uses). A throttle is
always a transient defer (`0`), never a permanent skip (`-1`).

### Options

- `--utilize`/`-U` (Runner options) sets the shared utilization-threshold percentage.
- `-R CPU=70` / `-R Memory=20%`: the existing `resources` List option (which stores
  bare class names) gained a `normalize`+`trigger` pair that splits the inline
  `=arg` off the class name and stashes it in a parallel `resource_args` Map option
  keyed by the fully-qualified class. `State::init` passes that arg to the
  resource's `new` as `arg => ...`. (The current List-type option does not carry
  per-resource args the way old3's Map+`mod_adds_options` did, so this is the
  minimal adaptation.)
- Threshold precedence in CPU/Memory: inline `=arg`, then `--utilize`, then the
  per-resource default.

## Decisions / notes

- **Always-on sampler (user decision).** The sampler runs whenever the runner runs,
  regardless of whether a throttling resource was requested, so the rendered /
  archived run shows system load at each point independent of gating.
- **Resources read the snapshot, not `/proc`.** This is the key change from old3 and
  is what makes the throttling cross-platform.
- **The renderer does not yet display `harness_system`.** The runner-side contract
  (store snapshot + announce transition + reach a subscriber) is the deliverable
  here and is fully wired; surfacing system load in the terminal/archived render is
  future renderer work (§4.5). The integration tests assert the snapshot reaches a
  subscriber's monitor mirror, not the rendered text.
- **The 30s `_read_one_frame` EOF busy-spin** the reference AI_DOC root-caused does
  not exist on 2.0d — `Role::Service::Connection::drain` already treats `sysread`
  == 0 / a fatal read error as connection-closed.

## Tests

- `t/AI/unit/SystemLoad.t` — Linux + BSD backends via the read seams (CPU delta
  math, guest-not-double-counted, 5/6-state `kern.cp_time`, meminfo fallback,
  missing-counter degradation).
- `t/AI/unit/Service/Sampler.t` — the change-gated policy (round-up-5,
  increase-immediate, decrease-after-delay, equal-resets-window, memory same
  policy) plus an end-to-end send over a real `Role::Service` peer and a
  stop-on-broken-connection check.
- `t/AI/unit/Resource_Throttle.t` — CPU defers at threshold (reading a fake
  snapshot), Memory min_free (pct + absolute), the Utilizer min_concurrent floor,
  and Memory conservative-wins with `--utilize`.
- `t/AI/unit/Runner_Monitor_system_load.t` — the `harness_system` facet stored,
  replaced, carried in global + run-scoped snapshots, and round-tripped through
  `apply_snapshot`.
- `t/AI/integration/system_load.t` — a real `Subscriber` against a hub mirroring
  `announce_system_load`: the snapshot carries current load to a late subscriber and
  a forwarded change reaches the mirror (global broadcast).
- `t/AI/integration/sampler_spawn.t` — the real spawn path: a collector-wrapped
  `Service::Sampler` (watch_parent_pid) reports `system_load` over a real socket,
  then is reaped with no leaked process.
- `t/AI/integration/throttle_e2e.t` — `-R CPU`, `-R Memory=20%`, layered
  `-R CPU=70 -R Memory --utilize 65`, and a rejected `--utilize 150`, all end to end
  through `yath test`.

## Not done (deferred)

- Per-core CPU breakdown; BSD memory-available on non-FreeBSD flavors.
- Renderer display of `harness_system` (the renderer learning the facet).
