use Test2::V0;
# HARNESS-DURATION-SHORT

# Chunk 5g: the runner -- not a gatherer -- is the transient completion / stalled
# authority. This drives the three pieces that replace the gatherer's
# _abort_stalled_jobs / _note_verdict / _final_event over canonical state:
#
#   1. Watchdog::abort_remaining synthesizes an 'aborted' runner-job mutation for
#      every task still tracked as running at wind-down, via announce_job.
#   2. Runner::Monitor folds that mutation and surfaces it on the
#      new_aborted_jobs change list.
#   3. Renderer::Driver renders the aborted job as a failed completion and rolls
#      it up command-side (the job appears under harness_final{failed}, pass=0).

use Test2::Harness2::Runner::Watchdog;
use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Renderer::Driver;
use Getopt::Yath::Settings;

# ---------------------------------------------------------------------------
# A minimal stand-in for the runner: a real Monitor (so we exercise the actual
# fold), a running_tasks map, and announce_job wired exactly as the real runner
# does (feed the harness_runner_job facet into the monitor).
# ---------------------------------------------------------------------------
{
    package FakeRunner;

    sub new {
        my ($class, %args) = @_;
        return bless {
            rootpid      => $$,
            monitor      => Test2::Harness2::Runner::Monitor->new,
            running      => $args{running} // {},
            stopped      => [],
            aborted_runs => [],
            decided      => [],
        }, $class;
    }

    sub rootpid { $_[0]->{rootpid} }
    sub monitor { $_[0]->{monitor} }

    # Mimic Runner::State just enough: running_tasks + stop_task.
    sub state { $_[0] }
    sub running_tasks { $_[0]->{running} }

    sub stop_task {
        my ($self, $job_id) = @_;
        push @{$self->{stopped}} => $job_id;
        delete $self->{running}{$job_id}
            or die "Task is not running, cannot stop it ($job_id)";
        return;
    }

    # Mimic Runner::announce_job: fold into the monitor as a harness_runner_job.
    sub announce_job {
        my ($self, $job_id, $state, %extra) = @_;
        $self->{monitor}->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => $state, %extra}}});
        return;
    }

    # The watchdog now calls these unconditionally (the ->can() guards are gone), so
    # the real runner (which composes Role::Service::Completion) and this fake must
    # both provide them; record calls so the wiring is asserted and a regression
    # fails loudly. Repeatably callable for the idempotency check.
    sub abort_run_collectors {
        my ($self, $run_id, $reason) = @_;
        push @{$self->{aborted_runs}} => [$run_id, $reason];
        return;
    }

    sub mark_job_decided {
        my ($self, $job_id, $job_try) = @_;
        push @{$self->{decided}} => [$job_id, $job_try];
        return;
    }
}

subtest abort_remaining_synthesizes_aborted_mutations => sub {
    my $runner = FakeRunner->new(
        running => {
            'JOB-A' => {job_id => 'JOB-A', file => 't/a.t', run_id => 'R1'},
            'JOB-B' => {job_id => 'JOB-B', file => 't/b.t', run_id => 'R1'},
        },
    );

    my $wd = Test2::Harness2::Runner::Watchdog->new(runner => $runner);
    $wd->abort_remaining("Runner shut down before this job completed");

    # Both running tasks were stopped in the scheduler.
    is([sort @{$runner->{stopped}}], ['JOB-A', 'JOB-B'], "both running tasks stopped");

    # The monitor folded both as aborted runner-job mutations.
    my @aborted = sort $runner->monitor->new_aborted_jobs;
    is(\@aborted, ['JOB-A', 'JOB-B'], "monitor surfaced both as new_aborted_jobs");

    my $j = $runner->monitor->job('JOB-A');
    is($j->{state}, 'aborted', "job state is aborted");
    is($j->{file},  't/a.t',   "job carries its file");
    like($j->{details}, qr/Runner shut down/, "job carries the abort reason");

    # The watchdog drove the runner->collector terminate once for the (single) run
    # and marked each aborted (job, try) decided in the fire-once ledger.
    is(scalar(@{$runner->{aborted_runs}}), 1,    "abort_run_collectors driven once (one run)");
    is($runner->{aborted_runs}[0][0],      'R1', "...for run R1");
    is([sort map { $_->[0] } @{$runner->{decided}}], ['JOB-A', 'JOB-B'], "each aborted job marked decided");

    # Drained once: a second call returns nothing (drain-on-call).
    is([$runner->monitor->new_aborted_jobs], [], "new_aborted_jobs drains");

    # Idempotent: a second abort_remaining with the tasks already stopped does not
    # die and does not re-stop them.
    ok(lives { $wd->abort_remaining }, "second abort_remaining is a no-op (tasks gone)");
};

subtest driver_rolls_up_aborted_job_as_failed => sub {
    my $settings = Getopt::Yath::Settings->new;
    $settings->group('display', 1)->create_option(verbose => 0);

    # The engine dispatches through its cb (the seam the render loop uses to own the
    # fan-out); capture the dispatched events directly.
    my @events;

    my $task = {job_id => 'JOB-X', file => 't/x.t', rel_file => 't/x.t'};

    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings    => $settings,
        dispatch_cb => sub { push @events => $_[0] },
        run_id      => 'R1',
        tasks       => [$task],
    );

    # A monitor mirror that has been told (via the runner's announce_job) the job
    # was aborted -- exactly what a subscriber's mirror holds after the runner
    # winds down with this job unfinished.
    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->feed({facet_data => {harness_runner_job => {job_id => 'JOB-X', state => 'aborted', file => 't/x.t', run_id => 'R1', details => 'Stage gone'}}});

    $driver->step($mon);
    $driver->finalize($mon);

    my $final = $driver->final_data;
    is($final->{pass}, 0, "run did not pass (aborted job)");
    my @failed_ids = map { $_->[0] } @{$final->{failed} // []};
    ok((grep { $_ eq 'JOB-X' } @failed_ids), "aborted job appears in harness_final{failed}");
    is($final->{unseen}, undef, "aborted job is NOT counted as 'unseen' (it has a verdict)");

    # The driver rendered an aborted harness_job_end for it.
    my @ends = grep { $_->{facet_data}{harness_job_end} } @events;
    is(scalar(@ends), 1, "one harness_job_end rendered for the aborted job");
    is($ends[0]->{facet_data}{harness_job_end}{fail},    1, "...marked fail");
    is($ends[0]->{facet_data}{harness_job_end}{aborted}, 1, "...marked aborted");
};

done_testing;
