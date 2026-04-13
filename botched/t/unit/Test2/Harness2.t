use strict;
use warnings;
use Test2::V0;

use File::Spec;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
    else {
        plan skip_all => "IPC::Manager lib not found at $ipcm_lib";
    }

    my $ok  = eval { require IPC::Manager; 1 };
    my $err = $@;
    plan skip_all => "IPC::Manager not loadable: $err" unless $ok;
}

use Test2::Harness2;
use Test2::Harness2::TestFile;
use Test2::Harness2::Workspace;
use Test2::Harness2::Scheduler;
use Test2::Harness2::Resource::JobCount;

my $BASE = File::Spec->rel2abs('t/selftest');

# Helper to create TestFile objects from selftest dir
sub make_tf {
    my ($name) = @_;
    return Test2::Harness2::TestFile->new(file => "$BASE/$name");
}

# ---------------------------------------------------------------------------
# Construction: auto-creates workspace, scheduler, JobCount resource
# ---------------------------------------------------------------------------
subtest 'construction and defaults' => sub {
    my $harness = Test2::Harness2->new();

    isa_ok($harness->workspace, ['Test2::Harness2::Workspace'], 'workspace auto-created');
    isa_ok($harness->scheduler, ['Test2::Harness2::Scheduler'], 'scheduler auto-created');
    is($harness->job_count, 1,  'job_count defaults to 1');
    is($harness->resources, [], 'resources defaults to empty arrayref');
    is($harness->plugins,   [], 'plugins defaults to empty arrayref');
    is($harness->includes,  [], 'includes defaults to empty arrayref');
    is($harness->env_vars,  {}, 'env defaults to empty hashref');
    is($harness->switches,  [], 'switches defaults to empty arrayref');
    ok(!defined $harness->test_settings, 'test_settings defaults to undef');

    # Verify JobCount resource is present in scheduler
    my $sched_resources = $harness->scheduler->resources;
    ok(scalar @$sched_resources >= 1, 'scheduler has at least one resource');
    isa_ok($sched_resources->[0], ['Test2::Harness2::Resource::JobCount'], 'first resource is JobCount');

    # Cleanup
    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# Construction with custom job_count
# ---------------------------------------------------------------------------
subtest 'job_count creates correct JobCount resource' => sub {
    my $harness = Test2::Harness2->new(job_count => 4);

    is($harness->job_count, 4, 'job_count is 4');

    my $jc_resource = $harness->scheduler->resources->[0];
    isa_ok($jc_resource, ['Test2::Harness2::Resource::JobCount']);

    # Verify the resource allows 4 jobs
    # Assign 4 jobs - all should succeed
    for my $i (1 .. 4) {
        is($jc_resource->available, 1, "slot $i available");
        $jc_resource->assign;
    }
    is($jc_resource->available, 0, "no more slots after 4 assigns");

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# Construction with provided workspace
# ---------------------------------------------------------------------------
subtest 'provided workspace is used' => sub {
    my $ws      = Test2::Harness2::Workspace->new(cleanup => 1);
    my $harness = Test2::Harness2->new(workspace => $ws);

    is($harness->workspace,            $ws, 'provided workspace is used');
    is($harness->scheduler->workspace, $ws, 'scheduler gets the same workspace');

    $ws->cleanup;
};

# ---------------------------------------------------------------------------
# run_tests with single passing test
# ---------------------------------------------------------------------------
subtest 'run_tests single passing test' => sub {
    my $harness = Test2::Harness2->new(
        includes => ['lib'],
    );

    my @files = (make_tf('simple.t'));

    my $result = $harness->run_tests(test_files => \@files);

    is(ref($result), 'HASH', 'result is a hashref');
    ok($result->{passed}, 'all tests passed');
    is($result->{total},             1, 'total is 1');
    is($result->{failed},            0, 'failed is 0');
    is(scalar @{$result->{results}}, 1, 'one result object');

    my $r = $result->{results}[0];
    isa_ok($r, ['Test2::Harness2::MiniHarness::Result']);
    ok($r->passed, 'individual result passed');
    is($r->exit_code, 0, 'exit code is 0');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# run_tests with multiple tests
# ---------------------------------------------------------------------------
subtest 'run_tests with multiple tests' => sub {
    my $harness = Test2::Harness2->new(
        includes => ['lib'],
    );

    my @files = (make_tf('simple.t'), make_tf('tap_only.t'));

    my $result = $harness->run_tests(test_files => \@files);

    ok($result->{passed}, 'all tests passed');
    is($result->{total},             2, 'total is 2');
    is($result->{failed},            0, 'failed is 0');
    is(scalar @{$result->{results}}, 2, 'two result objects');

    for my $r (@{$result->{results}}) {
        ok($r->passed, 'individual result passed');
    }

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# Failing test detected in results
# ---------------------------------------------------------------------------
subtest 'failing test detected' => sub {
    my $harness = Test2::Harness2->new(
        includes => ['lib'],
    );

    my @files = (make_tf('simple.t'), make_tf('fail.t'));

    my $result = $harness->run_tests(test_files => \@files);

    ok(!$result->{passed}, 'overall not passed when a test fails');
    is($result->{total},  2, 'total is 2');
    is($result->{failed}, 1, 'failed is 1');

    # Find which result failed
    my @failed = grep { !$_->passed } @{$result->{results}};
    is(scalar @failed, 1, 'one failing result');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# run_tests requires test_files
# ---------------------------------------------------------------------------
subtest 'run_tests requires test_files' => sub {
    my $harness = Test2::Harness2->new();

    my $ok  = eval { $harness->run_tests(); 1 };
    my $err = $@;

    ok(!$ok, 'dies without test_files');
    like($err, qr/test_files is required/, 'error message mentions test_files');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# Test2::Harness2->run() convenience API
# ---------------------------------------------------------------------------
subtest 'Test2::Harness2->run() convenience API' => sub {
    require Test2::Harness2;

    my @files = (make_tf('simple.t'));

    my $result = Test2::Harness2->run(
        test_files => \@files,
        includes   => ['lib'],
    );

    is(ref($result), 'HASH', 'result is a hashref');
    ok($result->{passed}, 'test passed via convenience API');
    is($result->{total}, 1, 'total is 1');
};

done_testing;
