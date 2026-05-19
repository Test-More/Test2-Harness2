# Default Renderer Port

**Date:** 2026-04-24
**Branch:** renderers_and_filters

## What the task was

Port `App::Yath2::Renderer::Default` (and its `Composer` helper) from the
`reference/old2` tree into the new codebase, adapting it to the clean
filter/renderer boundary established by the output pipeline refactor.

## What already existed

`lib/App/Yath2/Renderer/Default.pm` and `lib/App/Yath2/Renderer/Default/Composer.pm`
were already present in the new codebase as near-verbatim copies from `reference/old2`
but were broken: they used constants that `Object::HashBase` never defined
(the old2 code used `Test2::Harness2::Util::HashBase` which auto-defines constants
for every accessed slot; the new `Object::HashBase` only defines constants for
explicitly declared attributes).

`lib/App/Yath2/Theme.pm` was also already ported.

## What was changed

### `lib/App/Yath2/Renderer/Default.pm` (rewritten)

Key adaptations from old2:

1. **Added missing `Object::HashBase` attributes** — `show_job_end`,
   `show_job_launch`, `show_job_info`, `show_run_info`, `show_run_fields`,
   `show_times`, `wrap` — were used as constants but not declared; added them.

2. **Auto-create `Theme` in `init`** — old2 assumed a `Theme` was always
   injected; new code creates `App::Yath2::Theme->new(use_color => ...)` when
   none is provided.

3. **Fixed `COLOR` initialisation** — old2 had a subtle bug where
   `$use_color = $self->{+TTY} unless defined $use_color` never fired because
   `$use_color` was always defined (it was `0` rather than `undef`). Fixed to
   `$self->{+COLOR} //= $self->{+TTY} ? 1 : 0`.

4. **Added `desired_filters()`** — returns `Filter::Quiet` for `log_level =
   quiet`, `Filter::Verbose` for `log_level = verbose`, and `Filter::Verbose`
   for the default level.

5. **Updated event model** — old2 used top-level facet keys
   (`harness_job_launch`, `harness_job_end`, `harness_job_queued`) that no
   longer exist. Replaced with `facet_data.harness.test_job_completed`.
   The old `$f->{harness} = {%$event}` envelope-injection was removed; the
   `harness` facet is now set upstream by the parser's `normalize_event` call
   and supplemented by the ArtifactLayer.

6. **Simplified `update_active_disp`** — without launch/queue events the
   status line now tracks only pass/fail counts from `test_job_completed`.

### `lib/App/Yath2/ArtifactLayer.pm` (updated)

`_replay_job` now injects `run_id` and `job_id` into `facet_data.harness` for
each event read from the JSONL file before dispatching. JSONL events don't
carry job context inside each record (it's implicit from the filename), so the
renderer had no way to identify which job an event belonged to without this.

### `t/AI/unit/App/Yath2/Renderer/Default.t` (new)

11 unit subtests covering: construction, `desired_filters` at all log levels,
`render_event` for assert pass/fail, plan, and `test_job_completed`
pass/fail, and end-to-end integration with `OutputManager`.

## Design decisions

**Composer is unchanged.** The Composer operates on standard Test2 facets
(`assert`, `info`, `errors`, `plan`, etc.) which haven't changed between
old2 and the new model. It was already a correct near-verbatim copy.

**`harness_job_launch` handling removed.** The new ArtifactLayer dispatches
events only after a job completes (full JSONL replay), so there are no
launch/start/exit lifecycle events reaching the renderer. These can be
added back if the pipeline is ever made incremental.

**`desired_filters` defaults to `Filter::Verbose`.** The Default renderer
should show all meaningful events by default. Without an explicit `log_level`
setting, `Filter::Verbose` ensures housekeeping events are still suppressed
while asserts, diags, plans, and job summaries all get through.
