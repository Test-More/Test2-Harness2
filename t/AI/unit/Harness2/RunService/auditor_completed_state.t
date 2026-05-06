use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::RunService;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;
use Test2::Harness2::TestFile;

# F18: Auditor::Test forwards the full final job state hash
# (including subtests array) on the test_job_completed IPC payload.
# RunService accumulates these in COMPLETED_JOB_STATES so
# _build_collector_report can construct the run-level aggregate
# without per-job disk reads.
#
# This test pins the per-handler stash invariant narrowly. The
# aggregate output shape (emit_run_completed / collector_report) is
# already covered by run_completed.t.

# ---------------------------------------------------------------
# Fake IPC message wrapper matching the pattern in RunService.t
# ---------------------------------------------------------------
{
    package Test::AuditorState::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

# ---------------------------------------------------------------
# Stub emitter that captures emit_run_failing calls without
# trying to open a real IPC channel.
# ---------------------------------------------------------------
{
    package Test::AuditorState::SilentEmitter;
    sub new      { bless {events => []}, shift }
    sub emit_event { push @{$_[0]->{events}}, {@_[1..$#_]}; return }
    sub emit_raw   { push @{$_[0]->{events}}, $_[1];        return }
    sub events     { $_[0]->{events} }
}

# ---------------------------------------------------------------
# mk_svc: construct a minimal RunService through init() so all
# slots are seeded correctly, then stub out the IPC methods that
# reach outside the process.
# ---------------------------------------------------------------
sub mk_svc {
    my (%extra) = @_;

    my $dir = tempdir(CLEANUP => 1);

    # Build a run with two test files by default.
    my $tf_a = Test2::Harness2::TestFile->new(file => "$dir/a.t");
    my $tf_b = Test2::Harness2::TestFile->new(file => "$dir/b.t");
    open(my $fha, '>', "$dir/a.t") or die "open a.t: $!"; close $fha;
    open(my $fhb, '>', "$dir/b.t") or die "open b.t: $!"; close $fhb;

    my $job_a = Test2::Harness2::Run::Job->new(
        test_file => $tf_a,
        job_id    => 'job-a',
        run_id    => 'r-f18',
    );
    my $job_b = Test2::Harness2::Run::Job->new(
        test_file => $tf_b,
        job_id    => 'job-b',
        run_id    => 'r-f18',
    );
    my $run = Test2::Harness2::Run->new(
        run_id => 'r-f18',
        jobs   => [$job_a, $job_b],
    );

    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run, %extra);

    # Stub out the two methods that reach over IPC so the test
    # never tries to open a socket.
    no warnings 'redefine';
    {
        no strict 'refs';
        *{"Test2::Harness2::RunService::_send_to_harness"} = sub { };
    }

    # Mark both jobs running so mark_done in the handler succeeds.
    $svc->run_state->mark_running('job-a');
    $svc->run_state->mark_running('job-b');

    return ($svc, $dir, $run);
}

# ---------------------------------------------------------------
# Subtest 1: dispatching test_job_completed populates
# COMPLETED_JOB_STATES keyed by job_id, and preserves the full
# payload (including subtests array and pass flag).
# ---------------------------------------------------------------
subtest 'test_job_completed payload populates COMPLETED_JOB_STATES' => sub {
    my ($svc) = mk_svc();

    # Silence the _emit_run_log_event path (it reaches for +EMITTER).
    no warnings 'redefine';
    local *Test2::Harness2::RunService::_emit_run_log_event = sub { };

    my $subtests = [
        { name => 'sub one',   pass => 1, count_pass => 3, count_fail => 0 },
        { name => 'sub two',   pass => 1, count_pass => 2, count_fail => 0 },
    ];

    $svc->run_on_general_message(Test::AuditorState::FakeMsg->new({
        kind       => 'test_job_completed',
        run_id     => 'r-f18',
        job_id     => 'job-a',
        job_try    => 1,
        pass       => 1,
        pass_count => 5,
        fail_count => 0,
        exit       => 0,
        stamp      => 1714875010.0,
        subtests   => $subtests,
    }));

    my $states = $svc->{ Test2::Harness2::RunService::COMPLETED_JOB_STATES() };

    ok(exists $states->{'job-a'},            'COMPLETED_JOB_STATES has entry for job-a');
    my $st = $states->{'job-a'};

    is($st->{pass},       1,    'pass flag preserved');
    is($st->{pass_count}, 5,    'pass_count preserved');
    is($st->{fail_count}, 0,    'fail_count preserved');
    is($st->{exit},       0,    'exit preserved');
    is($st->{job_id},     'job-a', 'job_id preserved');
    is($st->{job_try},    1,    'job_try preserved');

    my $ids = $svc->{ Test2::Harness2::RunService::COMPLETED_JOB_IDS() };
    ok($ids->{'job-a'}, 'COMPLETED_JOB_IDS gate set for job-a');

    is(ref($st->{subtests}),  'ARRAY', 'subtests slot is an array');
    is(scalar @{$st->{subtests}}, 2,   'both subtests captured');
};

# ---------------------------------------------------------------
# Subtest 2: subtests array round-trips verbatim through the
# handler -- each subtest hash is preserved intact.
# ---------------------------------------------------------------
subtest 'subtests array is preserved intact' => sub {
    my ($svc) = mk_svc();

    no warnings 'redefine';
    local *Test2::Harness2::RunService::_emit_run_log_event = sub { };

    my $subtests = [
        { name => 'alpha', pass => 1, count_pass => 4, count_fail => 0 },
        { name => 'beta',  pass => 0, count_pass => 1, count_fail => 2 },
    ];

    $svc->run_on_general_message(Test::AuditorState::FakeMsg->new({
        kind       => 'test_job_completed',
        run_id     => 'r-f18',
        job_id     => 'job-b',
        job_try    => 2,
        pass       => 0,
        pass_count => 4,
        fail_count => 2,
        exit       => 256,
        stamp      => 1714875020.0,
        subtests   => $subtests,
    }));

    my $st = $svc->{ Test2::Harness2::RunService::COMPLETED_JOB_STATES() }{'job-b'};
    ok($st, 'state entry for job-b');

    is(ref($st->{subtests}), 'ARRAY', 'subtests is an array ref');
    is(scalar @{$st->{subtests}}, 2, 'both subtests present');

    is($st->{subtests}[0]{name},       'alpha', 'subtest 0 name preserved');
    is($st->{subtests}[0]{pass},       1,       'subtest 0 pass preserved');
    is($st->{subtests}[0]{count_pass}, 4,       'subtest 0 count_pass preserved');
    is($st->{subtests}[0]{count_fail}, 0,       'subtest 0 count_fail preserved');

    is($st->{subtests}[1]{name},       'beta',  'subtest 1 name preserved');
    is($st->{subtests}[1]{pass},       0,       'subtest 1 pass preserved');
    is($st->{subtests}[1]{count_pass}, 1,       'subtest 1 count_pass preserved');
    is($st->{subtests}[1]{count_fail}, 2,       'subtest 1 count_fail preserved');

    # A failing job must not flip a previously-passing run to failing
    # unless it came in with pass=0.
    is($svc->{ Test2::Harness2::RunService::RUN_PASS() }, 0,
        'run_pass flipped to 0 on first failing job');
};

# ---------------------------------------------------------------
# Subtest 3: idempotency -- a duplicate test_job_completed for
# the same job_id is ignored. The stash entry from the first
# delivery is not overwritten.
# ---------------------------------------------------------------
subtest 'duplicate test_job_completed is ignored (idempotency)' => sub {
    my ($svc) = mk_svc();

    no warnings 'redefine';
    local *Test2::Harness2::RunService::_emit_run_log_event = sub { };

    my $payload = {
        kind       => 'test_job_completed',
        run_id     => 'r-f18',
        job_id     => 'job-a',
        job_try    => 1,
        pass       => 1,
        pass_count => 3,
        fail_count => 0,
        exit       => 0,
        stamp      => 1714875005.0,
        subtests   => [{name => 'first delivery', pass => 1, count_pass => 3, count_fail => 0}],
    };

    $svc->run_on_general_message(Test::AuditorState::FakeMsg->new($payload));

    # Second delivery with a different pass_count -- must be dropped.
    my %second = (%$payload, pass_count => 99, subtests => []);
    $svc->run_on_general_message(Test::AuditorState::FakeMsg->new(\%second));

    my $st = $svc->{ Test2::Harness2::RunService::COMPLETED_JOB_STATES() }{'job-a'};
    is($st->{pass_count}, 3,  'pass_count from first delivery unchanged');
    is(scalar @{$st->{subtests}}, 1, 'subtests from first delivery unchanged');
};

done_testing;
