# Post-6 redesign — source briefs (`thoughts` / `thoughts2`)

Durable copy of Chad's two design notes that drove the **post-6 revised-target**
work (migration chunks 9-16). The decisions are restated in `ARCHITECTURE.md`
(§1, §4.4/§4.7/§4.7a/§4.8/§5.2/§5.3) and mapped to chunks in `MIGRATION.md`; this
file preserves the original briefs verbatim so they survive worktree cleanup.

## `thoughts` — service IPC, discovery, spawn, preload lifecycle

> We should migrate away from having a yath-persist.json, should replace it with
> a symlink to the main harness/runner socket.
>
> Spawn should probably bypass the runner. Maybe look for the persist file (or
> symlink to the runner socket and follow the link tot he workdir) and then look
> at what preload sockets are available. Then the spawn can directly connect to
> the preload and request the spawn process be started, using the sockets means
> we can also migrate away from the current IO proxying to proper IO sharing over
> sockets. The spawned child should be double-fork and no collector since it is
> not to remain associated with either the runner or the preload once it has been
> started and all IO is connected to the `yath spawn` command terminal.
>
> The current IPC for services like runner and preload stages is wasteful and
> complex, we maintain multiple pools of connections. Each should have a listen
> socket where it obtains new connections, and those new connections go into the
> set of connections. However when one needs to reach out to the other is should
> put that new connection into the same structure. If a connection between 2
> already exists it should be reused. There should not be 2 channels between 2
> processes, one channel used for both regardless of who established it. Once a
> connection is made both ends can send and recieve requests and responses. This
> should be captured in a reusable library, a Role or a base class (or both?)
> that services like Runner, preload stages, and the future system load service
> can all reuse. When we have the future system load service it should connect to
> the runner once it starts so it can send updates, but other processes should be
> able to connect to it as well and it can send updates to all connected
> processes.
>
> Right now the runner reaches out to preloads, this is backwards, specially once
> the single-channel work above is done. Once a preload stage starts it should
> register itself with the runner and establish a connection. It can then use
> this connection to mark its state such as 'starting', 'up', 'restarting',
> 'down'. The stage makes decisions about when to restart, and needs to provide
> status updates. The same channel (when in 'up') can be used to send the job
> start requests to the stages. The listen socket on stages can be used by the
> 'spawn' command directly bypassing the runner. The runner can know about stages
> it has tried to start, but until they reach back it should assume they are not
> available yet.
>
> If preload is not yet a resource it should be refactored to include a resource
> class, that way jobs are gated on preload availability (expected existance and
> current status) the way any resource is.

## `thoughts2` — scoping `Test2::Harness2::TestFile`

> Test2::Harness2::TestFile  is incorrectly scoped. It lives in Test2::Harness2,
> but it reads test files to make decisisons about how the tests will run. Most
> of the logic here should actually live in App::Yath2. We need to split it,
> there should be a state-only representation of this data in Test2::Harness2,
> and that already established state is what should be passed into
> Test2::Harness2 when a run is queued. However populating that state should
> occur in App::Yath2, the `test` and `run` commands should gather the files,
> calculate the state that Test2::Harness2::TestFile reads from the tests, then
> once the state is read pass the completed form to the runner by queuing the run
> with jobs.
