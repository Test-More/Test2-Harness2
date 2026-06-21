use Test2::V0;
# HARNESS-DURATION-SHORT

use Getopt::Yath::Settings;

use Test2::Harness2::Runner::State;
use Test2::Harness2::Runner::Resource::Preload;
use Test2::Harness2::Runner::Resource::JobCount;

# Ticket #33: --preload-stage-startup-timeout must actually fire in the scheduler.
# The #21 unit test only drove Resource::Preload::available() in isolation; the
# scheduler buckets a task via task_stage and _next only walks 'up' stage buckets,
# so a require_preload task aimed at a stage stuck 'starting'/'restarting' was never
# visited and the resource's -1 was never consulted -- it hung forever.
#
# This drives the FULL scheduler path (advance -> _expire_stale_stages -> _next ->
# available()): a required task on a stage that never comes up is left pending until
# the per-stage startup safeguard elapses, then dispatched as a resource_skip,
# never stranded.

# Bypass the heavy init (workdir/settings.json discovery, resource auto-build): we
# hand it pre-built resources + settings and drive advance() directly.
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {}
}

my $MAP = {default => {default => 1}, ALPHA => {default => 0}};

sub build_state {
    my %params = @_;

    my $settings = Getopt::Yath::Settings->new(
        runner => {
            preload_stage_startup_timeout => $params{timeout} // 0,
            slots_per_job                 => 1,
            job_count                     => 4,
        },
    );

    my $state = FakeState->new(
        preloader => undef,
        stage_map => $MAP,
        settings  => $settings,
        workdir   => '/tmp/fake-workdir',
    );
    $state->set_stage_map($MAP);
    $state->stage_ready('default');
    $state->stage_restarting('ALPHA');    # present in the map but never readies

    my $preload = Test2::Harness2::Runner::Resource::Preload->new(settings => $settings, state => $state);
    my $jobs    = Test2::Harness2::Runner::Resource::JobCount->new(job_count => 4, settings => $settings);
    $state->{$state->RESOURCES} = [$preload, $jobs];

    $state->queue_run({run_id => 'R1'});
    $state->start_run('R1');

    return $state;
}

sub drive {
    my ($state) = @_;
    # advance() returns true while it makes progress; loop it like scheduler_tick.
    1 while $state->advance;
    return;
}

sub require_task {
    return {
        job_id   => 'J1', run_id => 'R1',
        category => 'general', duration => 'short',
        use_preload => 1, require_preload => 1, preload_list => ['ALPHA'],
        conflicts => [],
    };
}

subtest required_task_on_stuck_stage_is_skipped_after_timeout => sub {
    my $state = build_state(timeout => 5);
    $state->queue_task(require_task());

    # The task is bucketed under ALPHA (starting); _next only walks 'up' buckets, so
    # nothing dispatches yet -- this is exactly the hang the safeguard must break.
    drive($state);
    ok(!($state->running_tasks // {})->{'J1'}, "task is parked, not dispatched, while ALPHA is still coming up");
    ok($state->task_lookup->{'J1'}, "task is still pending");

    # Backdate ALPHA so it has been 'restarting' well past the 5s safeguard.
    my $LC = $state->STAGE_LIFECYCLE;
    $state->{$LC}{ALPHA}{stamp} -= 100;

    drive($state);

    my $task = ($state->running_tasks // {})->{'J1'};
    ok($task, "after the safeguard elapses the task is dispatched (not hung)");
    ok($task->{resource_skip}, "it is dispatched as a resource_skip (the required stage is permanently gone)");
    is($state->stage_state('ALPHA'), 'down', "the over-age stage was demoted to 'down'");
};

subtest advisory_task_falls_to_default_after_timeout => sub {
    my $state = build_state(timeout => 5);
    my $task = require_task();
    $task->{require_preload} = 0;    # advisory: falls to default rather than skipping
    $state->queue_task($task);

    drive($state);
    ok(!($state->running_tasks // {})->{'J1'}, "advisory task also parks under the not-up stage");

    my $LC = $state->STAGE_LIFECYCLE;
    $state->{$LC}{ALPHA}{stamp} -= 100;

    drive($state);

    my $started = ($state->running_tasks // {})->{'J1'};
    ok($started, "advisory task is dispatched after the safeguard");
    ok(!$started->{resource_skip}, "advisory task is NOT skipped -- it falls to the default stage");
    is($started->{stage}, 'default', "advisory task runs on the default stage");
};

subtest no_timeout_still_hangs => sub {
    # With the safeguard off (timeout 0, the default) the same stuck stage is waited
    # on indefinitely -- confirms the dispatch is driven by the timeout, not by some
    # other path.
    my $state = build_state(timeout => 0);
    $state->queue_task(require_task());

    my $LC = $state->STAGE_LIFECYCLE;
    $state->{$LC}{ALPHA}{stamp} -= 100;    # old, but no safeguard configured

    drive($state);

    ok(!($state->running_tasks // {})->{'J1'}, "no safeguard => the required task keeps waiting (still pending)");
    is($state->stage_state('ALPHA'), 'restarting', "the stage is not demoted without a safeguard");
};

done_testing;
