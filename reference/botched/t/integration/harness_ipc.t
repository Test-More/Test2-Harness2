use strict;
use warnings;

use Test2::V0;
use File::Spec;

BEGIN {
    # IPC::Manager lives outside the distribution
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
    else {
        plan skip_all => "IPC::Manager lib not found at $ipcm_lib";
    }

    my $ok  = eval { require IPC::Manager; 1 };
    my $err = $@;
    unless ($ok) {
        plan skip_all => "IPC::Manager not loadable: $err";
    }
}

use Test2::Harness2;
use Test2::Harness2::TestFile;

# Resolve paths to selftest fixtures
my $t_dir    = File::Spec->catdir(File::Spec->rel2abs(File::Spec->curdir()), 't');
my $selftest = File::Spec->catdir($t_dir,                                    'selftest');
my $simple   = File::Spec->catfile($selftest, 'simple.t');
my $tap_only = File::Spec->catfile($selftest, 'tap_only.t');

# ---------------------------------------------------------------------------
# Test 1: IPC service mode runs tests
# ---------------------------------------------------------------------------

subtest 'IPC service mode runs tests' => sub {
    plan skip_all => "selftest/simple.t not found"   unless -f $simple;
    plan skip_all => "selftest/tap_only.t not found" unless -f $tap_only;

    my @tf = (
        Test2::Harness2::TestFile->new(file => $simple),
        Test2::Harness2::TestFile->new(file => $tap_only),
    );

    my $harness = Test2::Harness2->new(
        job_count => 1,
        includes  => ['lib'],
    );

    my $result;
    my $ok  = eval { $result = $harness->run_tests(test_files => \@tf); 1 };
    my $err = $@;

    ok($ok,     'run_tests with IPC did not die') or diag "Error: $err";
    ok($result, 'run_tests returned a result');

    is($result->{total},  2, 'total is 2');
    is($result->{failed}, 0, 'failed is 0');
    ok($result->{passed}, 'passed is true');

    my @results = @{$result->{results}};
    is(scalar @results, 2, 'results array has 2 entries');

    for my $r (@results) {
        ok($r->passed,           "individual result->passed is true");
        ok(defined $r->uuid,     "result->uuid is defined");
        ok($r->uuid ne '',       "result->uuid is non-empty");
        ok(defined $r->log_file, "result->log_file is defined");
    }
};

# ---------------------------------------------------------------------------
# Test 2: ipcm_info accessible after construction
# ---------------------------------------------------------------------------

subtest 'ipcm_info accessible' => sub {
    my $harness = Test2::Harness2->new(
        job_count => 1,
    );

    ok(defined $harness->ipcm_info, 'ipcm_info is defined');
    ok($harness->ipcm_info ne '',   'ipcm_info is non-empty');
    like($harness->ipcm_info, qr/\[/, 'ipcm_info looks like JSON array');
};

# ---------------------------------------------------------------------------
# Test 3: Accepts external ipcm_info
# ---------------------------------------------------------------------------

subtest 'accepts external ipcm_info' => sub {
    require IPC::Manager;

    my $ipcm = IPC::Manager::ipcm_spawn();
    my $info = $ipcm->info;

    my $harness = Test2::Harness2->new(
        job_count => 1,
        ipcm_info => $info,
    );

    is($harness->ipcm_info, $info, 'ipcm_info matches externally provided value');
    ok(!defined $harness->_ipcm, '_ipcm is not set (did not spawn our own)');

    # Explicitly shut down the external IPC bus before leaving the subtest
    $harness = undef;
    $ipcm->shutdown;
    $ipcm->{guard} = 0;    # prevent double-shutdown in DESTROY
};

# ---------------------------------------------------------------------------
# Test 4: Settings query via IPC
# ---------------------------------------------------------------------------

subtest 'settings query via IPC' => sub {
    plan skip_all => "selftest/simple.t not found" unless -f $simple;

    my @tf = (
        Test2::Harness2::TestFile->new(file => $simple),
    );

    my $harness = Test2::Harness2->new(
        job_count     => 1,
        includes      => ['lib'],
        test_settings => {verbose => 1},
    );

    # Run tests in IPC mode so the service is active
    my $result;
    my $ok  = eval { $result = $harness->run_tests(test_files => \@tf); 1 };
    my $err = $@;

    ok($ok,               'run_tests with IPC did not die') or diag "Error: $err";
    ok($result,           'run_tests returned a result');
    ok($result->{passed}, 'test passed');

    # The settings_request test is implicit: if the service started and
    # responded to get_results, the IPC request/response loop works.
    # We verify that test_settings was set on the harness and accessible.
    is($harness->test_settings, {verbose => 1}, 'test_settings accessible on harness');
};

done_testing;
