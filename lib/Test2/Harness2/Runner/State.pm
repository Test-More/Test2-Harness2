package Test2::Harness2::Runner::State;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use File::Spec;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Test2::Harness2::Util qw/mod2file/;

use Getopt::Yath::Settings;
use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run;

use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase(
    # These are construction arguments
    qw{
        eager_stages
        <workdir
        <preloader
        <resources
        job_count
        +settings
    },

    # The scheduler-only runner (preload-root hosts the stages) has NO
    # preloader, so task_stage resolves from the stage map the preload-root reported
    # plus a file_stage_resolver coderef that asks the base stage. eager_stages is
    # writable (not <) because set_stage_data refreshes it once the map arrives.
    qw{
        +stage_map
        file_stage_resolver
    },

    qw{
        <queue_ended

        <pending_tasks <task_lookup
        <pending_runs  +run <stopped_runs
        <retained_runs
        <pending_spawns

        <running
        <running_categories
        <running_durations
        <running_conflicts
        <running_tasks

        <stage_lifecycle

        <task_list

        <halted_runs

        <reload_state

        <last_job_activity
        <total_started

        sorted
    },
);

sub init {
    my $self = shift;

    croak "You must specify a workdir"
        unless defined $self->{+WORKDIR};

    $self->{+JOB_COUNT} //= $self->settings->runner->job_count // 1;

    if (!$self->{+RESOURCES} || !@{$self->{+RESOURCES}}) {
        my $settings = $self->settings;
        my $resources = $self->{+RESOURCES} //= [];
        for my $res (@{$self->settings->runner->resources}) {
            require(mod2file($res));
            push @$resources => $res->new(settings => $self->settings);
        }
    }

    unless (grep { $_->job_limiter } @{$self->{+RESOURCES}}) {
        require Test2::Harness2::Runner::Resource::JobCount;
        push @{$self->{+RESOURCES}} => Test2::Harness2::Runner::Resource::JobCount->new(job_count => $self->{+JOB_COUNT}, settings => $self->settings);
    }

    @{$self->{+RESOURCES}} = sort { $a->sort_weight <=> $b->sort_weight } @{$self->{+RESOURCES}};

    $self->{+RELOAD_STATE} //= {};

    # §6.8: any stage already named in a construction-time stage map is committed/
    # known -- mark it 'starting' so the scheduler knows it will exist before its
    # stage_ready arrives. set_stage_map drives the same transitions on later refreshes.
    if (my $map = $self->{+STAGE_MAP}) {
        my $life = $self->{+STAGE_LIFECYCLE} //= {};
        for my $stage (keys %$map) {
            $self->_set_stage_lifecycle($stage, 'starting') unless $life->{$stage};
        }
    }
}

sub settings {
    my $self = shift;
    return $self->{+SETTINGS} //= Getopt::Yath::Settings->FROM_JSON_FILE(File::Spec->catfile($self->{+WORKDIR}, 'settings.json'));
}

sub run {
    my $self = shift;
    return $self->{+RUN};
}

# Classify a run for the runner's owner-drop sweep (ticket #12 / ARCHITECTURE.md
# §4.2): 'running' if it is the active run or still pending/queued, 'finished' if it
# has already been retained as complete, or undef if the state knows nothing of it
# (already purged). A 'running' run whose owner drops is aborted-or-detached; a
# 'finished' run whose owner drops is purged.
sub run_status {
    my $self = shift;
    my ($run_id) = @_;

    return undef unless defined $run_id;

    my $active = $self->{+RUN};
    return 'running' if $active && $active->run_id eq $run_id;

    return 'running' if grep { $_->run_id eq $run_id } @{$self->{+PENDING_RUNS} // []};

    return 'finished' if $self->{+RETAINED_RUNS}->{$run_id};

    return undef;
}

sub done {
    my $self = shift;

    return 0 if $self->{+RUNNING};
    return 0 if keys %{$self->{+PENDING_TASKS} //= {}};

    return 0 if $self->{+RUN};
    return 0 if @{$self->{+PENDING_RUNS} //= []};

    return 0 unless $self->{+QUEUE_ENDED};

    return 1;
}

sub resource_timeout {
    my $self = shift;
    my ($timeout) = @_;

    return 0 unless $timeout;

    # Must have started at least one test already
    return 0 unless $self->{+TOTAL_STARTED};

    # Must have no tests currently running
    return 0 if $self->{+RUNNING};

    # Must still have pending tasks
    return 0 unless keys %{$self->{+PENDING_TASKS} //= {}};

    my $idle = time - ($self->{+LAST_JOB_ACTIVITY} // time);

    return 0 unless $idle >= $timeout;

    return $idle;
}

sub next_task {
    my $self = shift;
    my ($stage) = @_;

    $self->clear_finished_run();

    while(1) {
        if (@{$self->{+PENDING_SPAWNS} //= []}) {
            my $spawn = shift @{$self->{+PENDING_SPAWNS}};
            next unless $spawn->{stage} eq $stage;
            $self->start_spawn($spawn);
            return $spawn;
        }

        my $task = shift @{$self->{+TASK_LIST}} or return undef;

        # If we are replaying a state then the task may have already completed,
        # so skip it if it is not in the running lookup.
        next unless $self->{+RUNNING_TASKS}->{$task->{job_id}};
        next unless $task->{stage} eq $stage;

        return $task;
    }
}

# Pull tasks the scheduler has started whose run-stage is NOT the
# given (root) stage off the task list, so the runner can dispatch them to the
# matching stage service. Tasks for the root's own stage are left in place for the
# root's own run_job (the no-preload path). Returns the removed tasks; their
# accounting (running counts, resources) was already applied by _start_task, so
# they are still tracked as running -- the stage reports completion back later.
sub take_dispatch_tasks {
    my $self = shift;
    my ($root_stage) = @_;

    my $list = $self->{+TASK_LIST} //= [];
    my (@dispatch, @keep);
    for my $task (@$list) {
        # An undef root_stage means the runner hosts no stage of its
        # own (the preload-root hosts every stage), so dispatch every staged task
        # out. Otherwise dispatch only tasks NOT bound for the root's own stage.
        if (defined($task->{stage}) && (!defined($root_stage) || $task->{stage} ne $root_stage)) {
            push @dispatch => $task;
        }
        else {
            push @keep => $task;
        }
    }

    @$list = @keep;
    return @dispatch;
}

sub advance {
    my $self = shift;

    $_->tick() for @{$self->{+RESOURCES} //= []};

    $self->advance_run();
    return 0 unless $self->{+RUN};
    return 1 if $self->advance_tasks();
    return $self->clear_finished_run();
}

# The runner owns its scheduling state outright and applies every mutation
# in-process immediately. truncate's real work is the halt_run loop.
sub truncate {
    my $self = shift;
    $self->halt_run($_) for keys %{$self->{+PENDING_TASKS} // {}};
}

sub end_queue { $_[0]->{+QUEUE_ENDED} = 1 }

sub halt_run {
    my $self = shift;
    my ($run_id) = @_;

    delete $self->{+PENDING_TASKS}->{$run_id};

    $self->{+HALTED_RUNS}->{$run_id}++;
}

sub queue_run {
    my $self = shift;
    my ($run) = @_;
    $self->_queue_run($run);
}

sub _queue_run {
    my $self = shift;
    my ($run) = @_;

    # Keep the raw queued run item ON the Run object so the runner can forward it
    # verbatim when it dispatches a task to a stage service: the stage
    # rebuilds its own Runner::Run from this item rather than from a serialized live
    # object. Folding it onto the Run (rather than a parallel run_items hash) means it
    # is auto-pruned the moment the run object is dropped -- no leak on a persistent
    # runner (ticket #12 / ARCHITECTURE.md §4.2).
    push @{$self->{+PENDING_RUNS}} => Test2::Harness2::Runner::Run->new(
        %$run,
        raw_item => {%$run},
        workdir  => $self->{+WORKDIR},
    );

    return;
}

# The raw queued run item for the active run, for forwarding to a stage on
# dispatch. Returns undef if there is no active run.
sub run_item {
    my $self = shift;
    my $run = $self->{+RUN} or return undef;
    return $run->raw_item;
}

sub start_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_start_run($run_id);
}

sub _start_run {
    my $self = shift;
    my ($run_id) = @_;

    my $run = shift @{$self->{+PENDING_RUNS}};
    die "$0 - Run stack mismatch, run start requested, but no pending runs to start" unless $run;
    die "$0 - Run stack mismatch, run-id does not match next pending run" unless $run->run_id eq $run_id;

    $self->{+RUN} = $run;

    return;
}

sub stop_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_stop_run($run_id);
}

sub _stop_run {
    my $self = shift;
    my ($run_id) = @_;

    $self->{+STOPPED_RUNS}->{$run_id} = 1;

    # Drop this run's _next sort memo buckets so they do not leak past the run.
    # Assumes a single active run; must be revisited for concurrent multi-run.
    my $sorted = $self->{+SORTED} //= {};
    delete $sorted->{$_} for grep { 0 == index($_, "$run_id\0") } keys %$sorted;

    return;
}

sub queue_spawn {
    my $self = shift;
    my ($spawn) = @_;
    $spawn->{spawn} //= 1;
    $spawn->{id} //= gen_uuid();
    $self->_queue_spawn($spawn);
}

# Resolve the stage a spawn would be routed to and report whether that stage is
# currently a live (ready) preload service. Used by the runner's acknowledged
# queue_spawn handler so a `yath spawn` aimed at a stage that does not exist (or is
# down) fails promptly instead of the command blocking on its worker tempfile until
# that wait's own long timeout. Returns ($stage, $ready_bool).
sub spawn_stage_ready {
    my $self = shift;
    my ($spawn) = @_;

    my $stage = $self->task_stage({%$spawn, use_preload => $spawn->{use_preload} // 1});

    my $ready = $self->stage_is_up($stage) ? 1 : 0;

    return ($stage, $ready);
}

sub _queue_spawn {
    my $self = shift;
    my ($spawn) = @_;

    $spawn->{id} //= gen_uuid();
    $spawn->{spawn} //= 1;
    $spawn->{use_preload} //= 1;

    $spawn->{stage} //= 'default';
    $spawn->{stage} = $self->task_stage($spawn);

    push @{$self->{+PENDING_SPAWNS}} => $spawn;

    return;
}

sub start_spawn {
    my $self = shift;
    my ($spec) = @_;
    $self->_start_spawn($spec);
}

sub _start_spawn {
    my $self = shift;
    my ($spec) = @_;

    my $uuid = $spec->{id} or die "Could not find UUID for spawn";

    @{$self->{+PENDING_SPAWNS}} = grep { $_->{id} ne $uuid } @{$self->{+PENDING_SPAWNS}};

    return;
}

sub queue_task {
    my $self = shift;
    my ($task) = @_;
    $self->_queue_task($task);
}

sub _queue_task {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id} or die "Task missing job_id";
    my $run_id = $task->{run_id} or die "Task missing run_id";

    die "Task already in queue" if $self->{+TASK_LOOKUP}->{$job_id};

    return if $self->{+HALTED_RUNS}->{$run_id};

    $self->{+TASK_LOOKUP}->{$job_id} = $task;

    my $pending = $self->task_pending_lookup($task);
    push @{$pending} => $task;

    # A new task in this bucket invalidates _next's conflict-priority sort memo,
    # so the reinserted task gets re-sorted. Keyed by the stable path tuple.
    # Assumes a single active run; must be revisited for concurrent multi-run.
    delete $self->{+SORTED}->{join("\0", $self->task_fields($task))};

    return;
}

sub start_task {
    my $self = shift;
    my ($spec) = @_;
    $self->_start_task($spec);
}

sub _start_task {
    my $self = shift;
    my ($spec) = @_;

    my $job_id    = $spec->{job_id} or die "No job_id provided";
    my $run_stage = $spec->{stage}  or die "No stage provided";
    my $res       = $spec->{res}    or die "No res provided";
    my $res_skip  = $spec->{resource_skip};

    my $task = $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to start";

    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);

    my $set = $self->{+PENDING_TASKS}->{$run_id}->{$smoke}->{$stage}->{$cat}->{$dur};
    my $count = @$set;
    @$set = grep { $_->{job_id} ne $job_id } @$set;
    die "Task $job_id was not pending ($count -> " . scalar(@$set) . ")" unless $count > @$set;

    $self->prune_hash($self->{+PENDING_TASKS}, $run_id, $smoke, $stage, $cat, $dur);

    # Set the stage, new task hashref
    $task = {%$task, stage => $run_stage} unless $task->{stage} && $task->{stage} eq $run_stage;

    $task->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
    push @{$task->{test_args}} => @{$res->{args}};

    for my $resource (@{$self->{+RESOURCES}}) {
        my $class = ref($resource);
        my $val = $res->{record}->{$class} // next;
        $resource->record($task->{job_id}, $val);
    }

    die "Already running task $job_id" if $self->{+RUNNING_TASKS}->{$job_id};
    $self->{+RUNNING_TASKS}->{$job_id} = $task;

    $task->{resource_skip} = $res_skip if $res_skip;

    push @{$self->{+TASK_LIST}} => $task;

    $self->{+LAST_JOB_ACTIVITY} = time;
    $self->{+TOTAL_STARTED}++;
    $self->{+RUNNING}++;
    $self->{+RUNNING_CATEGORIES}->{$cat}++;
    $self->{+RUNNING_DURATIONS}->{$dur}++;

    my $cfls = $task->{conflicts} //= [];
    for my $cfl (@$cfls) {
        die "Unexpected parallel conflict '$cfl' ($self->{+RUNNING_CONFLICTS}->{$cfl}) running at this time!"
            if $self->{+RUNNING_CONFLICTS}->{$cfl}++;
    }

    return;
}

sub stop_task {
    my $self = shift;
    my ($job_id) = @_;
    $self->_stop_task($job_id);
}

sub _stop_task {
    my $self = shift;
    my ($job_id) = @_;

    my $task = delete $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to stop ($job_id)";

    delete $self->{+RUNNING_TASKS}->{$job_id} or die "Task is not running, cannot stop it ($job_id)";

    $_->release($job_id) for @{$self->{+RESOURCES}};

    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);
    $self->{+LAST_JOB_ACTIVITY} = time;
    $self->{+RUNNING}--;
    $self->{+RUNNING_CATEGORIES}->{$cat}--;
    $self->{+RUNNING_DURATIONS}->{$dur}--;

    my $cfls = $task->{conflicts} //= [];
    $self->{+RUNNING_CONFLICTS}->{$_}-- for @$cfls;

    return;
}

sub retry_task {
    my $self = shift;
    my ($job_id) = @_;

    $self->_retry_task($job_id);
}

sub _retry_task {
    my $self = shift;
    my ($job_id) = @_;

    my $task = $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to retry";

    $self->_stop_task($job_id);

    return if $self->{+HALTED_RUNS}->{$task->{run_id}};

    $task = {is_try => 0, %$task};
    $task->{is_try}++;
    $task->{category} = 'isolation' if $self->{+RUN}->retry_isolated;

    $self->_queue_task($task);

    return;
}

# bloat #3: put a RUNNING task back into the PENDING queue to be re-resolved and
# re-dispatched on a later tick -- WITHOUT consuming a retry. Used when a job was
# started (slot + resources consumed, RUNNING) but never actually accepted by a
# stage: the assigned stage went down/restarting between available/assign and the
# actual dispatch (the assign->launch race, §4.7a), or a self-restarting stage took
# its channel before it could fork the job. This is NOT a failure: the job is owed a
# run, just not by that stage incarnation.
#
# Distinct from retry_task (which consumes a try after a genuine failure) and from
# abort_job (which fails the job). The job_id / try number are preserved, the
# running slot + resources are released (_stop_task -> a fresh assign/record happens
# on re-dispatch), and the %SORTED bucket memo is cleared (_queue_task). Emits no
# terminal subscriber transition -- the runner forwards a 'requeued' mutation (or
# none) rather than 'done'/'aborted'.
#
# TASK_LOOKUP holds the ORIGINAL task (its directive `stage` preference); the
# resolved-stage copy lives only in RUNNING_TASKS and is dropped by _stop_task. So
# re-queuing TASK_LOOKUP's task re-resolves the run stage (directive / file_stage /
# default) against the CURRENT map on the next tick -- a stage that has since come
# back, or a different available stage, can take it.
sub requeue_task {
    my $self = shift;
    my ($job_id) = @_;

    my $task = $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to requeue ($job_id)";

    $self->_stop_task($job_id);

    return if $self->{+HALTED_RUNS}->{$task->{run_id}};

    # A fresh copy (TASK_LOOKUP's was deleted by _stop_task); the try number and the
    # directive stage preference are preserved -- a requeue does not consume a retry.
    $self->_queue_task({%$task});

    return;
}

# §6.8: named stage lifecycle states are the single source of stage
# scheduling state (no parallel readiness map). STAGE_LIFECYCLE
# is a per-stage record {state, stamp} that the scheduler gate (_stage_order,
# spawn_stage_ready) reads as `state eq 'up'`, and that status/ps surface. The four
# states are:
#
#   starting    -- committed/known: the runner learned from the reported stage map
#                  that this stage will exist, before its stage_ready arrived.
#   up          -- the stage reported ready; dispatchable.
#   restarting  -- temporarily down, coming back (an intentional reload, or any
#                  plain exit of a still-mapped stage that the preload-root respawns).
#   down        -- permanent for this map: the stage is absent from the stage map
#                  (never configured, misspelled, or removed by a refresh). A
#                  require-style absence is permanent.
#
# Only 'up' is dispatchable; starting/restarting/down all keep the gate closed (a
# restarting stage is intentionally reloading and must not be dispatched to until
# its fresh incarnation re-readies). The State stores no pid -- a connected stage's
# real pid comes from its peer connection (Connection::peer_pid), threaded into
# status by the runner.
#
# Stale-incarnation reports are rejected by connection-currency in the runner's
# stage-report handlers (a report is honored only from the connection currently
# registered as that stage's `preload-<stage>` peer), NOT by a wire generation
# counter -- so the lifecycle record carries no generation (bloat #3).
sub _set_stage_lifecycle {
    my $self = shift;
    my ($stage, $state) = @_;

    ($self->{+STAGE_LIFECYCLE} //= {})->{$stage} = {
        state => $state,
        stamp => time,
    };

    return;
}

# True if the named stage is currently 'up' (dispatchable). This is the converged
# dispatch gate that replaced the STAGE_READINESS truthiness check.
sub stage_is_up {
    my $self = shift;
    my ($stage) = @_;

    my $life = ($self->{+STAGE_LIFECYCLE} //= {})->{$stage} or return 0;
    return $life->{state} eq 'up' ? 1 : 0;
}

sub stage_ready {
    my $self = shift;
    my ($stage) = @_;
    $self->_set_stage_lifecycle($stage, 'up');
    return;
}

sub stage_down {
    my $self = shift;
    my ($stage) = @_;
    $self->_set_stage_lifecycle($stage, 'down');
    return;
}

# §6.8: a stage announces it is intentionally reloading (tearing down on purpose)
# before it exits and the preload-root respawns it -- distinct from a permanent
# 'down'. Like every non-'up' state it keeps the dispatch gate closed; the fresh
# incarnation's stage_ready returns it to 'up'.
sub stage_restarting {
    my $self = shift;
    my ($stage) = @_;
    $self->_set_stage_lifecycle($stage, 'restarting');
    return;
}

# §6.10: forget every stage's lifecycle. Used when a crashed preload root is
# respawned: the dead incarnation's stages are gone (or stale), so the scheduler
# must wait for the fresh incarnation to re-register before dispatching again.
sub reset_stage_readiness {
    my $self = shift;
    $self->{+STAGE_LIFECYCLE} = {};
    return;
}

# The reported stage map is the runner's commitment record of
# which stages will exist. Setting it transitions lifecycle: every stage present in
# the new map that has no live ('up') record yet is 'starting' (committed/known,
# its stage_ready not yet arrived); a stage that was tracked but is now absent from
# the map is 'down' (permanent for this map -- removed by a refresh, never
# configured, or misspelled). A stage already 'up' keeps its state (its peer is
# still connected; only its stage_down/restarting report demotes it).
sub set_stage_map {
    my $self = shift;
    my ($map) = @_;

    $self->{+STAGE_MAP} = $map;

    my $life = $self->{+STAGE_LIFECYCLE} //= {};
    $map //= {};

    # Stages present in the map: commit them as 'starting' unless already 'up'.
    for my $stage (keys %$map) {
        my $cur = $life->{$stage};
        next if $cur && $cur->{state} eq 'up';
        $self->_set_stage_lifecycle($stage, 'starting');
    }

    # Stages we tracked that are no longer in the map: permanently 'down'.
    for my $stage (keys %$life) {
        next if $map->{$stage};
        next if $life->{$stage}->{state} eq 'down';
        $self->_set_stage_lifecycle($stage, 'down');
    }

    return;
}

sub reload {
    my $self = shift;
    my ($stage, $data) = @_;
    $stage //= 'default';
    $self->_reload({%$data, stage => $stage});
    return;
}

sub _reload {
    my $self = shift;
    my ($data) = @_;

    my $stage    = $data->{stage};
    my $file     = $data->{file};
    my $success  = $data->{reloaded};
    my $error    = $data->{error};
    my $warnings = $data->{warnings};

    my $reload_state = $self->{+RELOAD_STATE} //= {};
    my $stage_state = $reload_state->{$stage} //= {};

    # It either succeeded, or the stage will be reloaded, no need to track brokenness
    if (defined $success) {
        delete $stage_state->{$file};
    }
    else {
        my $fields = {};
        $fields->{error} = $error if defined($error) && length($error);
        $fields->{warnings} = $warnings if $warnings && @{$warnings};

        if (keys %$fields) {
            $stage_state->{$file} = $fields;
        }
        else {
            delete $stage_state->{$file};
        }
    }

    return;
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;

    my $wants = $task->{stage};
    $wants //= 'NOPRELOAD' unless $task->{use_preload};

    # In-runner preload path: the loaded preloader resolves directive / file_stage /
    # default itself.
    return $self->preloader->task_stage($task->{file}, $wants) if $self->preloader;

    # Scheduler-only path: the preload-root hosts the stages, so resolve
    # from the reported stage map plus a file_stage round-trip to the base stage. With
    # neither a preloader nor a stage map (no preload at all) keep the legacy fallback.
    # The base stage always registers as lowercase 'default' (Runner::Preloader),
    # so a non-staged preload-root reports an empty map and an unstaged task must
    # resolve to 'default' -- NOT 'DEFAULT', which would dispatch to a
    # 'preload-DEFAULT' that never registered and abort the jobs as "stage gone".
    my $map = $self->{+STAGE_MAP};
    return $wants // 'default' unless $map && keys %$map;

    # An explicit, valid directive wins; NOPRELOAD is the synthetic no-preload stage.
    return $wants if defined($wants) && length($wants) && ($wants eq 'NOPRELOAD' || $map->{$wants});

    # Otherwise the base stage resolves file_stage // default for this file (the only
    # process with the loaded preload meta + its file_stage callbacks).
    if (my $resolver = $self->{+FILE_STAGE_RESOLVER}) {
        my $stage = $resolver->($task->{file});
        return $stage if defined($stage) && length($stage);
    }

    return $self->_default_stage_from_map($map);
}

# The default stage from the reported map -- the one flagged default, or
# (defensively) the first by name when none is flagged.
sub _default_stage_from_map {
    my $self = shift;
    my ($map) = @_;

    for my $name (sort keys %$map) {
        return $name if $map->{$name}->{default};
    }

    my ($first) = sort keys %$map;
    return $first;
}

sub task_pending_lookup {
    my $self = shift;
    my ($task) = @_;

    # The 5-level PENDING_TASKS nesting IS the scheduler's priority index: the
    # dimensions (run_id -> smoke -> stage -> cat -> dur) mirror _next's nested
    # priority traversal, so _next walks them in priority order by iterating the
    # index in place rather than filtering a flat list each dispatch. Do not
    # flatten it (that would push the partitioning into the hot loop); prune_hash
    # GCs empty sub-keys. (bloat ticket #14)
    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);

    return $self->{+PENDING_TASKS}->{$run_id}->{$smoke}->{$stage}->{$cat}->{$dur} //= [];
}

sub task_fields {
    my $self = shift;
    my ($task) = @_;

    my $run_id = $task->{run_id} or die "No run id provided by task";
    my $smoke  = $task->{smoke} ? 'smoke' : 'main';
    my $stage = $self->task_stage($task);

    my $cat = $task->{category};
    my $dur = $task->{duration};

    die "Invalid category: $cat" unless CATEGORIES->{$cat};
    die "Invalid duration: $dur" unless DURATIONS->{$dur};

    $cat = 'conflicts' if $cat eq 'general' && $task->{conflicts} && @{$task->{conflicts}};

    return ($run_id, $smoke, $stage, $cat, $dur);
}

sub prune_hash {
    my $self = shift;
    my ($hash, @path) = @_;

    die "No path!" unless @path;

    my $key = shift @path;

    if (@path) {
        my $empty = $self->prune_hash($hash->{$key}, @path);
        return 0 unless $empty;
    }

    return 1 unless exists $hash->{$key};

    my $ref = ref($hash->{$key});
    if ($ref eq 'HASH') {
        return 0 if keys %{$hash->{$key}};
    }
    elsif ($ref eq 'ARRAY') {
        return 0 if @{$hash->{$key}};
    }

    delete $hash->{$key};
    return 1;
}

sub advance_run {
    my $self = shift;

    return 0 if $self->{+RUN};

    return 0 unless @{$self->{+PENDING_RUNS} //= []};
    $self->start_run($self->{+PENDING_RUNS}->[0]->run_id);

    return 1;
}

sub clear_finished_run {
    my $self = shift;

    my $run = $self->{+RUN} or return 0;

    return 0 unless $self->{+STOPPED_RUNS}->{$run->run_id};
    return 0 if $self->{+PENDING_TASKS}->{$run->run_id};
    return 0 if $self->{+RUNNING};

    # Retain the finished run (Run object + its raw item + job states) keyed by
    # run_id rather than discarding it outright, so the queuing client may still
    # query it. The runner purges it (purge_run) when that owner connection drops;
    # a run whose owner is already gone is purged immediately by the runner's
    # owner-drop sweep (ticket #12 / ARCHITECTURE.md §4.2).
    $self->{+RETAINED_RUNS}->{$run->run_id} = $run;

    delete $self->{+RUN};

    return 1;
}

# Purge a run's retained/in-flight state entirely: the retained finished Run, plus
# any still-pending tasks and stopped/halted/announced bookkeeping for it. Called by
# the runner when the run's owner connection drops (a finished run whose owner left,
# or a detached run reaching completion). Returns true if anything was purged.
sub purge_run {
    my $self = shift;
    my ($run_id) = @_;

    return 0 unless defined $run_id;

    my $purged = delete $self->{+RETAINED_RUNS}->{$run_id} ? 1 : 0;

    delete $self->{+PENDING_TASKS}->{$run_id};
    delete $self->{+STOPPED_RUNS}->{$run_id};
    delete $self->{+HALTED_RUNS}->{$run_id};

    return $purged;
}

# Abort a run's remaining schedulable work in canonical state: drop its pending
# tasks (so nothing new dispatches) and mark it stopped so the run loop advances off
# it. The runner pairs this with a run-scoped watchdog abort_remaining (which kills
# the run's still-running jobs by signalling their collectors) before calling here.
# Used when the queuing client drops and abort_on_disconnect is true.
sub abort_run {
    my $self = shift;
    my ($run_id) = @_;

    return unless defined $run_id;

    $self->halt_run($run_id);
    $self->_stop_run($run_id);

    return;
}

sub advance_tasks {
    my $self = shift;

    for my $resource (@{$self->{+RESOURCES}}) {
        $resource->refresh();

        next unless $resource->job_limiter;
        return 0 if $resource->job_limiter_at_max();
    }

    my ($run_stage, $task, $res, %params) = $self->_next();

    my $out = 0;
    if ($task) {
        $out = 1;
        $self->start_task({job_id => $task->{job_id}, stage => $run_stage, res => $res, %params});
    }

    $_->discharge() for @{$self->{+RESOURCES}};

    return $out;
}

sub _cat_order {
    my $self = shift;

    my @cat_order = ('conflicts', 'general');

    # Only search immiscible if we have no immiscible running
    # put them first if no others are running so we can churn through them
    # early instead of waiting for them to run 1 at a time at the end.
    unshift @cat_order => 'immiscible' unless $self->{+RUNNING_CATEGORIES}->{immiscible};

    # Only search isolation if nothing is running.
    push @cat_order => 'isolation' unless $self->{+RUNNING};

    return \@cat_order;
}

sub _dur_order {
    my $self = shift;

    my $max = 0;
    for my $resource (@{$self->resources}) {
        next unless $resource->job_limiter;
        my $val = $resource->job_limiter_max;
        $max = $val if !$max || $val < $max;
    }
    $max //= 1;

    my $maxm1 = $max - 1;

    my $durs = $self->{+RUNNING_DURATIONS};

    # 'short' is always ok.
    my @dur_order = ('short');

    # long and medium should be on the front of the search unless we are
    # already running (max - 1) tests of the duration We want long first if
    # we are not saturation on them, followed by medium, whcih is why they
    # are listed in this order.
    for my $c (qw/medium long/) {
        if ($durs->{$c} && $durs->{$c} >= $maxm1) {
            push @dur_order => $c;    # Back of the list
        }
        else {
            unshift @dur_order => $c;    # Front of the list
        }
    }

    return \@dur_order;
}

# This returns a list of [STAGE => RUN_STAGE] pairs. 'STAGE' is the stage in
# which we search for tasks, 'RUN_STAGE' is the stage that actually does the
# work. This is what allows us to find tasks for 'eager' stages that are bored.
sub _stage_order {
    my $self = shift;

    my $life = $self->{+STAGE_LIFECYCLE} //= {};

    my @stage_list = sort grep { $life->{$_}->{state} eq 'up' } keys %$life;

    # Populate list with all ready stages
    my %seen;
    my @stages = map {[$_ => $_]} grep { !$seen{$_}++ } @stage_list;

    # Add in any eager stages, but make sure they are last.
    for my $rstage (@stage_list) {
        next unless exists $self->{+EAGER_STAGES}->{$rstage};
        push @stages => map {[$_ => $rstage]} grep { !$seen{$_}++ } @{$self->{+EAGER_STAGES}->{$rstage}};
    }

    return \@stages;
}

sub _next {
    my $self = shift;

    my $run    = $self->{+RUN} or return;
    my $run_id = $run->run_id;

    my $pending = $self->{+PENDING_TASKS}->{$run_id} or return;

    my $sorted = $self->{+SORTED} //= {};

    my $conflicts = $self->{+RUNNING_CONFLICTS};
    my $cat_order = $self->_cat_order;
    my $dur_order = $self->_dur_order;
    my $stages    = $self->_stage_order();
    my $resources = $self->{+RESOURCES};

    # Ugly....
    my $search = $pending;

    for my $smoke (qw/smoke main/) {
        my $search = $search->{$smoke} or next;

        for my $stage_set (@$stages) {
            my ($lstage, $run_by_stage) = @$stage_set;
            my $search = $search->{$lstage} or next;

            for my $lcat (@$cat_order) {
                my $search = $search->{$lcat} or next;

                for my $ldur (@$dur_order) {
                    my $search = $search->{$ldur} or next;

                    # Make sure anything with conflicts runs early. Memo keyed by the
                    # stable path tuple (address-reuse-safe), cleared when a task is
                    # added to the bucket (_queue_task) or the run stops (_stop_run).
                    my $sort_key = join("\0", $run_id, $smoke, $lstage, $lcat, $ldur);
                    unless ($sorted->{$sort_key}++) {
                        @$search = sort { scalar(@{$b->{conflicts}}) <=> scalar(@{$a->{conflicts}}) } @$search;
                    }

                    for my $task (@$search) {
                        # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                        next if first { $conflicts->{$_} } @{$task->{conflicts}};

                        my $ok = 1;
                        my @resource_skip;
                        for my $resource (@$resources) {
                            my $out = $resource->available($task) || 0; # normalize false to 0

                            push @resource_skip => ref($resource) || $resource if $out < 0;

                            $ok &&= $out;

                            # If we have a temporarily unavailable resource we
                            # skip, but if any resource is never avilable
                            # (skip) we want to finish the loop to add them all
                            # for the skip message.
                            last if !$ok && !@resource_skip;
                        }

                        # Some resource is temporarily not available
                        next unless $ok;

                        my $outres = {args => [], env_vars => {}, record => {}};

                        my @out = ($run_by_stage => $task, $outres);

                        my @record = @$resources;

                        if (@resource_skip) {
                            push @out => (resource_skip => \@resource_skip);

                            # Only the job limiter resources need to be recorded.
                            @record = grep { $_->job_limiter } @record;
                        }

                        for my $resource (@record) {
                            my $res = {args => [], env_vars => {}};
                            $resource->assign($task, $res);
                            push @{$outres->{args}} => @{$res->{args}};
                            $outres->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
                            $outres->{record}->{ref($resource)} = $res->{record};
                        }

                        return @out;
                    }
                }
            }
        }
    }

    return;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::State - State tracking for the runner.

=head1 DESCRIPTION

This module tracks the state for all running tests. This entire module is
considered an "Implementation Detail". Please do not rely on it always staying
the same, or even existing in the future. Do not use this directly.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
