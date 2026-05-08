use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::RunService;
use Test2::Harness2::Run;

# When the run service receives its FIRST test_job_failing IPC, it
# should emit a run_failing event into its own outgoing event stream
# (the run collector picks it up and writes it into
# runs/<id>/events.jsonl.zst). Subsequent test_job_failing messages
# (different jobs, same run) MUST NOT re-emit run_failing -- it's a
# single state-flip event, not a per-failure broadcast.

{
    package Test::RunSvc::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

sub _capturing_emitter {
    my ($store) = @_;
    no warnings 'redefine';
    *Test2::Harness2::Util::EventEmitter::emit_event = sub {
        my ($self, %fields) = @_;
        push @$store, \%fields;
        return 'fake-sync';
    };
}

subtest 'first test_job_failing -> run_failing emitted once' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-fail');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my @emitted;
    _capturing_emitter(\@emitted);

    $svc->{Test2::Harness2::RunService::EMITTER()}
        = bless {}, 'Test2::Harness2::Util::EventEmitter';

    # First failing job.
    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
        kind    => 'test_job_failing',
        run_id  => 'r-fail',
        job_id  => 1,
        job_try => 0,
    }));

    # Two emissions are expected: job_failing (from existing handler)
    # and run_failing (the new state-flip event we add in this commit).
    my @run_failing_events  = grep { exists $_->{run_failing} }  @emitted;
    my @job_failing_events  = grep { exists $_->{kind} && $_->{kind} eq 'job_failing' } @emitted;

    is(scalar @run_failing_events, 1, 'one run_failing event emitted');
    is(scalar @job_failing_events, 1, 'one job_failing event also emitted');

    my $facet = $run_failing_events[0]{run_failing};
    ok(ref($facet) eq 'HASH', 'run_failing facet is a hashref');
    is($facet->{run_id}, 'r-fail', 'run_id on facet');
    is($facet->{job_id}, 1,        'job_id on facet');
    is($facet->{job_try}, 0,       'job_try on facet');
    ok(defined $facet->{stamp}, 'stamp populated');

    is($svc->{Test2::Harness2::RunService::RUN_PASS()}, 0, 'run_pass flipped to 0');
    is($svc->{Test2::Harness2::RunService::RUN_FAILING_EMITTED()}, 1, 'run_failing_emitted latched');

    # Second failing job (different job id) must NOT re-emit run_failing.
    @emitted = ();

    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
        kind    => 'test_job_failing',
        run_id  => 'r-fail',
        job_id  => 2,
        job_try => 0,
    }));

    my @run_failing_after = grep { exists $_->{run_failing} } @emitted;
    is(scalar @run_failing_after, 0, 'no run_failing on the second failing job');

    my @job_failing_after = grep { exists $_->{kind} && $_->{kind} eq 'job_failing' } @emitted;
    is(scalar @job_failing_after, 1, 'job_failing still emitted per failure');
};

subtest 'no emitter -> handler stays a no-op' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-noemit-fail');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my $ok = eval {
        $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
            kind    => 'test_job_failing',
            run_id  => 'r-noemit-fail',
            job_id  => 1,
            job_try => 0,
        }));
        1;
    };
    ok($ok, 'no-op when emitter missing');
};

done_testing;
