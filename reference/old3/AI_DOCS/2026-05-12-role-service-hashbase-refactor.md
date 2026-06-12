# Role::Service HashBase refactor plan

## Status

Not started. This document is the design + migration plan for landing
Object::HashBase slot declarations inside `Test2::Harness2::Role::Service`
(and, for consistency, `Test2::Harness2::Role::ResourceService` which it
composes). The preload_rework branch landed the same pattern for
`Role::Resource` and `Role::TestFile`; this one is broken out because
the blast radius reaches every service consumer (`Test2::Harness2`,
`Test2::Harness2::PreloadService`, plus any future service classes) and
deserves an isolated branch.

## Motivation

`Test2::Harness2::Role::Service` currently `requires` a set of accessors
+ setters that every consumer has to redeclare as HashBase slots in its
own package. The state -- `state`, `kill_timeout`, `own_pgroup`,
`watch_pids`, `pid` -- is identical for every consumer and is part of the
role's contract anyway.

The 2.0 branch already demonstrates the better pattern with
`Role::Resource`: declare the contract slots in the role via HashBase,
let consumers pull them in via `&Test2::Harness2::Role::Service` in their
own HashBase line, and drop the duplicate `requires` + slot-decls on
each consumer.

## Current contract (as of 2026-05-12)

`lib/Test2/Harness2/Role/Service.pm` requires:

- `workdir` (path)
- `name` (string id)
- `emit_service_event` (method on consumer)
- `hard_stop_pids` (method returning pid hash)
- `kill_timeout` (seconds; per-consumer slot)
- `set_state($new)` (setter)
- `set_own_pgroup($bool)` (setter)
- `watch_pids` (arrayref)

The role also defines `pid()` / `set_pid()` by hand:

```perl
sub pid     { $_[0]->{pid} //= $$ }
sub set_pid { $_[0]->{pid} = $_[1] }
```

Consumers (`Test2::Harness2`, `Test2::Harness2::PreloadService`) each
declare their own HashBase slots covering `state`, `kill_timeout`,
`watch_pids`, `own_pgroup`, `pid`, `name`, `workdir`.

## Target shape

```perl
package Test2::Harness2::Role::Service;
use Role::Tiny;
use Object::HashBase qw{
    <name <workdir
    state
    kill_timeout
    own_pgroup
    watch_pids
    pid
};

with 'Test2::Harness2::Role::ResourceService';

# Slots above already satisfy the old `requires 'kill_timeout'`,
# `requires 'set_state'`, etc. -- HashBase generates the readers and
# setters. Keep `requires` only for genuinely consumer-defined
# behaviours that the role cannot provide:
requires 'emit_service_event';
requires 'hard_stop_pids';

# pid() defaults to $$ on first read so a service that never explicitly
# sets one still answers truthfully. HashBase's plain getter cannot do
# this; keep a one-line override.
sub pid { $_[0]->{+PID} //= $$ }
```

Consumers shrink to:

```perl
# Test2::Harness2 (excerpt)
use Object::HashBase qw{
    <logdir <ipc_parent <job_id <test_auditor <parent_pids
    ...  # remaining consumer-private slots
    &Test2::Harness2::Role::Service
};
# Drop redeclared <name, <workdir, state, kill_timeout, own_pgroup,
# watch_pids slots; they come in via the role.
```

```perl
# Test2::Harness2::PreloadService (excerpt)
use Object::HashBase qw{
    <preload_name <modules <scope <run_id ...
    +_pending_spawns
    &Test2::Harness2::Role::Service
};
# Drop redeclared name, kill_timeout, state, own_pgroup, watch_pids,
# pid slots.
```

## Migration checklist

1. **Role::Service** -- add `Object::HashBase qw{<name <workdir state
   kill_timeout own_pgroup watch_pids pid}` line; drop the manual
   `pid`/`set_pid` subs except for the `//= $$` defaulting form on
   `pid`. Drop `requires` lines now satisfied by role-provided slots
   (`kill_timeout`, `set_state`, `set_own_pgroup`, `watch_pids`).
   Keep `requires 'emit_service_event'` + `requires 'hard_stop_pids'`.

2. **Role::ResourceService** -- still no slots, but worth verifying the
   `restartable` default lives on as a method. No change expected.

3. **Test2::Harness2** -- replace the matching slot lines with
   `&Test2::Harness2::Role::Service` in the HashBase qw list. The
   slot constants (`NAME`, `WORKDIR`, `STATE`, etc.) keep working
   through the `&` import.

4. **Test2::Harness2::PreloadService** -- same treatment. Verify the
   `delete $self->{name}` in its `init()` (which currently moves the
   host's `name` arg into `preload_name`) still finds the slot key.
   With HashBase the slot key is the lowercase string `'name'` so
   `delete $self->{+NAME}` reads cleaner.

5. **Tests** -- the failure mode that bit `Role::TestFile` was minimal
   test stubs that bless an empty hash without calling init. Look for
   the same shape under `t/AI/unit/Harness2/` (service stubs) and
   confirm none of them rely on undef-defaulting for `pid` / `state` /
   `kill_timeout`. If they do, either seed via `defaults()` or fix the
   stub to use `$class->new(...)` which fires HashBase's init pathway.

## Non-issues called out

These were considered and rejected as poor fits for the HashBase-on-roles
pattern:

- **Role::Preload** -- `name()` and `modules()` on consumers are class
  methods (`sub name { 'myapp' }`), not instance state. HashBase slots
  don't apply; the role keeps method-default semantics.

- **Role::Reloader** -- state (`project_root`, `last_error`,
  `churn_cache`) lives on `Reloader::Common`, the abstract base class
  that the actual backends inherit from. The role itself is a method
  contract; pulling slots into it would re-route an already-clean
  inheritance graph for no gain.

## Validation plan

After landing each step above:

```
AUTHOR_TESTING=1 yath -D test t/AI/unit/Harness2
AUTHOR_TESTING=1 yath -D test t/AI/integration  # service smokes
AUTHOR_TESTING=1 yath -D test t                  # full suite
```

The PreloadService spawn pathway is the highest-risk integration point
-- watch `t/AI/unit/Harness2/spawn_via_preload.t`,
`t/AI/integration/preload_per_run.t`, and the `yath_*_smoke.t` files
under `t/AI/integration/`.

## Related work

- preload_rework branch commit `refactor(Resource::Preload): use
  &Role::Resource for slot-backed broken state` -- same pattern applied
  to Resource::Preload over Role::Resource.
- preload_rework branch commit `refactor(Role::TestFile): adopt HashBase
  slots for all attributes` -- same pattern applied to Role::TestFile.
  Watch the lazy-default accessors in that commit for the pattern that
  preserves fresh-per-call semantics on mutable defaults; Role::Service
  has fewer mutable defaults so the pattern is simpler.
