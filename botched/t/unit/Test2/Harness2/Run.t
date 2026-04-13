use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub fake_tf {
    my ($name) = @_;
    return bless {file => $name}, 'FakeTestFile';
}

sub fake_settings {
    return bless {timeout => 60}, 'FakeTestSettings';
}

# ---------------------------------------------------------------------------
# Construction: uuid, status, jobs created from test_files
# ---------------------------------------------------------------------------
subtest 'construction basics' => sub {
    my $tf1 = fake_tf('t/foo.t');
    my $tf2 = fake_tf('t/bar.t');

    my $run = Test2::Harness2::Run->new(
        test_files => [$tf1, $tf2],
    );

    ok(defined $run->uuid, "uuid is set");
    like($run->uuid, qr/\S+/, "uuid is non-empty string");

    is($run->status, 'pending', "status starts as 'pending'");

    my $jobs = $run->jobs;
    is(scalar @$jobs, 2, "two jobs created from two test_files");

    isa_ok($jobs->[0], ['Test2::Harness2::Run::Job'], "job 0 is a Run::Job");
    isa_ok($jobs->[1], ['Test2::Harness2::Run::Job'], "job 1 is a Run::Job");
};

# ---------------------------------------------------------------------------
# run_id in each job matches the run's uuid
# ---------------------------------------------------------------------------
subtest 'jobs carry run_id matching run uuid' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/a.t'), fake_tf('t/b.t')],
    );

    my $run_uuid = $run->uuid;
    for my $job (@{$run->jobs}) {
        is($job->run_id, $run_uuid, "job run_id matches run uuid");
    }
};

# ---------------------------------------------------------------------------
# test_file stored on each job
# ---------------------------------------------------------------------------
subtest 'test_file stored on job' => sub {
    my $tf  = fake_tf('t/mytest.t');
    my $run = Test2::Harness2::Run->new(test_files => [$tf]);

    is($run->jobs->[0]->test_file, $tf, "test_file object stored on job");
};

# ---------------------------------------------------------------------------
# Construction with no test_files
# ---------------------------------------------------------------------------
subtest 'construction with no test_files' => sub {
    my $run = Test2::Harness2::Run->new();

    is($run->jobs,       [],        "jobs is empty arrayref");
    is($run->test_files, [],        "test_files is empty arrayref");
    is($run->status,     'pending', "status still pending");
};

# ---------------------------------------------------------------------------
# test_settings stored
# ---------------------------------------------------------------------------
subtest 'test_settings stored' => sub {
    my $settings = fake_settings();
    my $run      = Test2::Harness2::Run->new(
        test_files    => [],
        test_settings => $settings,
    );

    is($run->test_settings, $settings, "test_settings stored and returned");
};

# ---------------------------------------------------------------------------
# add_test_files appends jobs
# ---------------------------------------------------------------------------
subtest 'add_test_files' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/one.t')],
    );

    is(scalar @{$run->jobs}, 1, "one job initially");

    $run->add_test_files([fake_tf('t/two.t'), fake_tf('t/three.t')]);

    is(scalar @{$run->jobs}, 3, "three jobs after add_test_files");

    # New jobs should also carry the correct run_id
    for my $job (@{$run->jobs}) {
        is($job->run_id, $run->uuid, "added job run_id matches run uuid");
    }
};

# ---------------------------------------------------------------------------
# pending_jobs / running_jobs / complete_jobs filtering
# ---------------------------------------------------------------------------
subtest 'job status filtering' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/a.t'), fake_tf('t/b.t'), fake_tf('t/c.t')],
    );

    my ($j1, $j2, $j3) = @{$run->jobs};

    # All pending at start
    is(scalar @{$run->pending_jobs},  3, "all three pending initially");
    is(scalar @{$run->running_jobs},  0, "no running jobs initially");
    is(scalar @{$run->complete_jobs}, 0, "no complete jobs initially");

    $j1->set_status('running');

    is(scalar @{$run->pending_jobs},  2, "two pending after one starts");
    is(scalar @{$run->running_jobs},  1, "one running");
    is(scalar @{$run->complete_jobs}, 0, "still no complete");

    $j1->set_status('complete');
    $j2->set_status('complete');

    is(scalar @{$run->pending_jobs},  1, "one pending");
    is(scalar @{$run->running_jobs},  0, "zero running");
    is(scalar @{$run->complete_jobs}, 2, "two complete");
};

# ---------------------------------------------------------------------------
# is_complete
# ---------------------------------------------------------------------------
subtest 'is_complete' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/x.t'), fake_tf('t/y.t')],
    );

    my ($j1, $j2) = @{$run->jobs};

    ok(!$run->is_complete, "not complete with pending jobs");

    $j1->set_status('complete');
    ok(!$run->is_complete, "not complete with one pending");

    $j2->set_status('complete');
    ok($run->is_complete, "complete when all jobs complete");
};

# ---------------------------------------------------------------------------
# is_complete false when run has no jobs
# ---------------------------------------------------------------------------
subtest 'is_complete false with no jobs' => sub {
    my $run = Test2::Harness2::Run->new();
    ok(!$run->is_complete, "is_complete false when there are no jobs");
};

# ---------------------------------------------------------------------------
# passed: all pass
# ---------------------------------------------------------------------------
subtest 'passed — all jobs pass' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/p1.t'), fake_tf('t/p2.t')],
    );

    for my $job (@{$run->jobs}) {
        $job->set_status('complete');
        $job->set_result(passed => 1, exit_code => 0);
    }

    ok($run->is_complete, "run is complete");
    ok($run->passed,      "passed returns true when all jobs pass");
};

# ---------------------------------------------------------------------------
# passed: one fails
# ---------------------------------------------------------------------------
subtest 'passed — one job fails' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/f1.t'), fake_tf('t/f2.t')],
    );

    my ($j1, $j2) = @{$run->jobs};

    $j1->set_status('complete');
    $j1->set_result(passed => 1, exit_code => 0);

    $j2->set_status('complete');
    $j2->set_result(passed => 0, exit_code => 1);

    ok($run->is_complete, "run is complete");
    ok(!$run->passed,     "passed returns false when any job fails");
};

# ---------------------------------------------------------------------------
# passed: false when not yet complete
# ---------------------------------------------------------------------------
subtest 'passed — false when not complete' => sub {
    my $run = Test2::Harness2::Run->new(
        test_files => [fake_tf('t/z.t')],
    );

    ok(!$run->is_complete, "not complete");
    ok(!$run->passed,      "passed is false when not complete");
};

# ---------------------------------------------------------------------------
# uuid uniqueness across runs
# ---------------------------------------------------------------------------
subtest 'uuid uniqueness' => sub {
    my $r1 = Test2::Harness2::Run->new();
    my $r2 = Test2::Harness2::Run->new();

    isnt($r1->uuid, $r2->uuid, "distinct runs get distinct UUIDs");
};

done_testing;
