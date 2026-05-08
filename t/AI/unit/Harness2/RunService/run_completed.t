use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::RunService;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;
use Test2::Harness2::TestFile;

# At clean shutdown the run service emits one final event carrying
# both run_completed (state-flip announcement) and collector_report
# (data the run collector merges into report.jsonl.zst). The
# aggregate is built from COMPLETED_JOB_STATES (per F18: full per-job
# state hashes shipped by Auditor::Test in test_job_completed).

{
    package Test::RunSvc::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

{
    package Test::CapturingEmitter;
    sub new {
        my ($c, $store) = @_;
        bless {store => $store}, $c;
    }

    sub emit_event {
        my ($self, %fields) = @_;
        push @{$self->{store}}, \%fields;
        return 'fake-sync';
    }

    # emit_run_completed uses emit_raw so collector_report can sit at
    # the top of facet_data (not nested under harness, per F4=A).
    # Flatten both forms so subtests see a uniform hash.
    sub emit_raw {
        my ($self, $event) = @_;
        my $fd = ref($event) eq 'HASH' ? $event->{facet_data} : undef;
        my %flat;
        if (ref($fd) eq 'HASH') {
            for my $fk (keys %$fd) {
                if ($fk eq 'harness' && ref($fd->{$fk}) eq 'HASH') {
                    %flat = (%flat, %{$fd->{$fk}});
                }
                else {
                    $flat{$fk} = $fd->{$fk};
                }
            }
        }
        push @{$self->{store}}, \%flat;
        return 'fake-sync';
    }
}

sub _capturing_emitter {
    my ($store) = @_;
    return Test::CapturingEmitter->new($store);
}

# RunService normally publishes run_state_update messages through the
# IPC::Manager bus to the harness service. These tests build the
# service in isolation (no bus), so capture _send_to_harness into an
# array instead of letting it try to construct a real handle. We
# don't assert against @sent_to_harness here -- this stub exists to
# stop the legitimate "no ipcm_info" warning from RunService and to
# leave a hook in case future subtests want to inspect IPC traffic.
our @sent_to_harness;
{
    no warnings 'redefine';
    *Test2::Harness2::RunService::_send_to_harness = sub {
        my (undef, $msg) = @_;
        push @sent_to_harness, $msg;
        return;
    };
}

subtest 'run_completed + collector_report aggregate' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Build a run with two jobs so the collector_report aggregate
    # has something to walk.
    my $tf_a = Test2::Harness2::TestFile->new(file => "$dir/a.t");
    my $tf_b = Test2::Harness2::TestFile->new(file => "$dir/b.t");
    open(my $fha, '>', "$dir/a.t") or die $!; close $fha;
    open(my $fhb, '>', "$dir/b.t") or die $!; close $fhb;

    my $job_a = Test2::Harness2::Run::Job->new(
        test_file => $tf_a, job_id => 'job-a', run_id => 'r-done',
    );
    my $job_b = Test2::Harness2::Run::Job->new(
        test_file => $tf_b, job_id => 'job-b', run_id => 'r-done',
    );
    my $run = Test2::Harness2::Run->new(
        run_id => 'r-done',
        jobs   => [$job_a, $job_b],
    );

    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my @emitted;
    $svc->{Test2::Harness2::RunService::EMITTER()} = _capturing_emitter(\@emitted);

    # Pretend we saw the start.
    $svc->{Test2::Harness2::RunService::STARTED_AT()} = 1714875000.0;

    # Two job_completed messages with the per-job state shapes
    # Auditor::Test ships in test_job_completed (per F18). One pass,
    # one fail; one with subtests, one without.
    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
        kind    => 'test_job_completed',
        run_id  => 'r-done',
        job_id  => 'job-a',
        job_try => 1,
        pass    => 1,
        pass_count => 5,
        fail_count => 0,
        exit       => 0,
        stamp      => 1714875010.0,
        subtests   => [
            { name => 'subtest one',  pass => 1, count_pass => 3, count_fail => 0 },
            { name => 'subtest two', pass => 1, count_pass => 2, count_fail => 0 },
        ],
    }));

    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
        kind    => 'test_job_completed',
        run_id  => 'r-done',
        job_id  => 'job-b',
        job_try => 2,
        pass    => 0,
        pass_count => 4,
        fail_count => 2,
        exit       => 256,
        stamp      => 1714875020.0,
        subtests   => [
            { name => 'broken subtest', pass => 0, count_pass => 1, count_fail => 1 },
        ],
    }));

    # Now drive the shutdown emission. We don't go through full
    # run_on_cleanup because that touches resources / Run::State
    # mark_finished etc.; just call emit_run_completed directly.
    $svc->{Test2::Harness2::RunService::ENDED_AT()} = 1714875030.0;
    @emitted = ();    # only care about the run_completed event itself
    $svc->emit_run_completed;

    is(scalar @emitted, 1, 'one event emitted at run_completed');

    my $fields = $emitted[0];
    ok(exists $fields->{run_completed},     'run_completed facet present');
    ok(exists $fields->{collector_report},  'collector_report facet present');

    my $rc = $fields->{run_completed};
    is($rc->{run_id}, 'r-done', 'run_completed.run_id');
    ok(defined $rc->{stamp}, 'run_completed.stamp populated');

    my $report = $fields->{collector_report};
    is($report->{pass},         0,           'pass = 0 (one job failed)');
    is($report->{started_at},   1714875000.0, 'started_at preserved');
    is($report->{ended_at},     1714875030.0, 'ended_at preserved');
    is($report->{total_jobs},   2,           'total_jobs = 2');
    is($report->{passed_jobs},  1,           'passed_jobs = 1');
    is($report->{failed_jobs},  1,           'failed_jobs = 1');
    is($report->{aborted_jobs}, 0,           'aborted_jobs = 0');

    is(ref($report->{jobs}), 'ARRAY', 'jobs is an array');
    is(scalar @{$report->{jobs}}, 2, 'two jobs in aggregate');

    # Order: as queued in Run->jobs (job-a first, job-b second).
    is($report->{jobs}[0]{job_id}, 'job-a', 'job-a first');
    is($report->{jobs}[0]{pass},   1,       'job-a passed');
    is($report->{jobs}[0]{tries},  1,       'job-a one try');
    is($report->{jobs}[0]{file},   "$dir/a.t", 'job-a file');
    is(scalar @{$report->{jobs}[0]{subtests}}, 2, 'job-a 2 subtests');
    is($report->{jobs}[0]{subtests}[0]{name}, 'subtest one', 'job-a subtest 0 name');

    is($report->{jobs}[1]{job_id}, 'job-b', 'job-b second');
    is($report->{jobs}[1]{pass},   0,       'job-b failed');
    is($report->{jobs}[1]{tries},  2,       'job-b two tries (try=2 -> tries=2)');
    is(scalar @{$report->{jobs}[1]{subtests}}, 1, 'job-b 1 subtest');
    is($report->{jobs}[1]{subtests}[0]{pass}, 0, 'job-b subtest failed');

    # Idempotent: a second emit_run_completed must NOT re-emit.
    @emitted = ();
    $svc->emit_run_completed;
    is(scalar @emitted, 0, 'idempotent -- second call emits nothing');
};

subtest 'pass=1 when every job passes' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = Test2::Harness2::TestFile->new(file => "$dir/p.t");
    open(my $fh, '>', "$dir/p.t") or die $!; close $fh;
    my $job = Test2::Harness2::Run::Job->new(test_file => $tf, job_id => 'j', run_id => 'r-pass');
    my $run = Test2::Harness2::Run->new(run_id => 'r-pass', jobs => [$job]);

    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my @emitted;
    $svc->{Test2::Harness2::RunService::EMITTER()} = _capturing_emitter(\@emitted);

    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
        kind    => 'test_job_completed',
        run_id  => 'r-pass',
        job_id  => 'j',
        job_try => 1,
        pass    => 1,
        pass_count => 1,
        fail_count => 0,
        exit       => 0,
        stamp      => time,
    }));

    @emitted = ();
    $svc->emit_run_completed;

    is(scalar @emitted, 1, 'one event emitted');
    my $report = $emitted[0]{collector_report};
    is($report->{pass}, 1, 'pass=1 when every job passes');
    is($report->{passed_jobs}, 1, 'passed_jobs=1');
    is($report->{failed_jobs}, 0, 'failed_jobs=0');
};

done_testing;
