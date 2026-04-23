use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
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

# Resolve paths to selftest fixtures relative to this file's location.
my $t_dir    = File::Spec->catdir(File::Spec->rel2abs(File::Spec->curdir()), 't');
my $selftest = File::Spec->catdir($t_dir,                                    'selftest');
my $simple   = File::Spec->catfile($selftest, 'simple.t');
my $tap_only = File::Spec->catfile($selftest, 'tap_only.t');

# ---------------------------------------------------------------------------
# Test 1: Programmatic harness API — simple run
#   Run simple.t and tap_only.t through the Harness, verify all pass,
#   2 tests ran, 0 failures, log files exist for each result.
# ---------------------------------------------------------------------------

subtest 'programmatic harness API - simple run' => sub {
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

    ok($ok,     'run_tests did not die') or diag "Error: $err";
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
        ok(-f $r->log_file,      "log file exists: " . $r->log_file);
        ok(-s $r->log_file,      "log file is non-empty");
    }
};

# ---------------------------------------------------------------------------
# Test 2: Mixed pass/fail
#   Run simple.t plus a dynamically-created failing test, verify run fails,
#   total=2, failed=1.
# ---------------------------------------------------------------------------

subtest 'mixed pass/fail run' => sub {
    plan skip_all => "selftest/simple.t not found" unless -f $simple;

    my $tmp_dir = tempdir(CLEANUP => 1);

    # Create an inline failing test
    my $fail_file = File::Spec->catfile($tmp_dir, 'failing.t');
    open(my $fh, '>', $fail_file) or die "Cannot write $fail_file: $!";
    print $fh <<'END_FAIL';
use strict;
use warnings;
use Test2::V0;
ok(0, 'this test intentionally fails');
done_testing;
END_FAIL
    close $fh;

    my @tf = (
        Test2::Harness2::TestFile->new(file => $simple),
        Test2::Harness2::TestFile->new(file => $fail_file),
    );

    my $harness = Test2::Harness2->new(
        job_count => 1,
        includes  => ['lib'],
    );

    my $result;
    my $ok  = eval { $result = $harness->run_tests(test_files => \@tf); 1 };
    my $err = $@;

    ok($ok,     'run_tests did not die') or diag "Error: $err";
    ok($result, 'run_tests returned a result');

    is($result->{total},  2, 'total is 2');
    is($result->{failed}, 1, 'failed is 1');
    ok(!$result->{passed}, 'passed is false (overall run failed)');
};

# ---------------------------------------------------------------------------
# Test 3: Workspace log structure
#   Run a test, verify logs/ dir exists, has a run_* subdirectory,
#   contains a .jsonl file.
# ---------------------------------------------------------------------------

subtest 'workspace log structure' => sub {
    plan skip_all => "selftest/simple.t not found" unless -f $simple;

    use Test2::Harness2::Workspace;

    my $workspace = Test2::Harness2::Workspace->new(cleanup => 0);
    my $log_dir   = $workspace->log_dir;

    ok(-d $log_dir, "logs/ dir exists under workspace root");

    my @tf = (
        Test2::Harness2::TestFile->new(file => $simple),
    );

    my $harness = Test2::Harness2->new(
        job_count => 1,
        includes  => ['lib'],
        workspace => $workspace,
    );

    my $result;
    my $ok  = eval { $result = $harness->run_tests(test_files => \@tf); 1 };
    my $err = $@;

    ok($ok,     'run_tests did not die') or diag "Error: $err";
    ok($result, 'run_tests returned a result');

    # logs/ should now have at least one run_* subdirectory
    opendir(my $dh, $log_dir) or die "Cannot opendir $log_dir: $!";
    my @run_dirs = grep { /^run_/ && -d File::Spec->catdir($log_dir, $_) } readdir($dh);
    closedir $dh;

    ok(scalar @run_dirs >= 1, 'logs/ has at least one run_* subdirectory');

    # Each run_* dir should contain at least one .jsonl file
    my $found_jsonl = 0;
    for my $run_subdir (@run_dirs) {
        my $full_run_dir = File::Spec->catdir($log_dir, $run_subdir);
        opendir(my $rdh, $full_run_dir) or next;
        my @jsonl = grep { /\.jsonl$/ } readdir($rdh);
        closedir $rdh;
        $found_jsonl += scalar @jsonl;
    }

    ok($found_jsonl >= 1, 'run_* subdirectory contains at least one .jsonl file');

    # Cleanup manually since we set cleanup => 0
    $workspace->cleanup();
};

# ---------------------------------------------------------------------------
# Test 4: Custom env vars reach tests
#   Create a test that checks $ENV{HARNESS_TEST_VAR}, run via harness with
#   env_vars => { HARNESS_TEST_VAR => 'hello' }, verify passes.
# ---------------------------------------------------------------------------

subtest 'custom env vars reach test child processes' => sub {
    my $tmp_dir = tempdir(CLEANUP => 1);

    my $env_file = File::Spec->catfile($tmp_dir, 'env_check.t');
    open(my $fh, '>', $env_file) or die "Cannot write $env_file: $!";
    print $fh <<'END_ENV';
use strict;
use warnings;
use Test2::V0;
is($ENV{HARNESS_TEST_VAR}, 'hello', 'HARNESS_TEST_VAR is set to hello');
done_testing;
END_ENV
    close $fh;

    my @tf = (
        Test2::Harness2::TestFile->new(file => $env_file),
    );

    my $harness = Test2::Harness2->new(
        job_count => 1,
        includes  => ['lib'],
        env_vars  => {HARNESS_TEST_VAR => 'hello'},
    );

    my $result;
    my $ok  = eval { $result = $harness->run_tests(test_files => \@tf); 1 };
    my $err = $@;

    ok($ok,               'run_tests did not die') or diag "Error: $err";
    ok($result,           'run_tests returned a result');
    ok($result->{passed}, 'env var test passed');
    is($result->{failed}, 0, 'no failures');

    my ($r) = @{$result->{results}};
    ok($r->passed, 'individual result->passed is true');
};

# ---------------------------------------------------------------------------
# Test 5: Test2::Harness2 convenience API
#   Use Test2::Harness2->run(...) to verify it works end-to-end.
# ---------------------------------------------------------------------------

subtest 'Test2::Harness2 convenience API' => sub {
    plan skip_all => "selftest/simple.t not found" unless -f $simple;

    my @tf = (
        Test2::Harness2::TestFile->new(file => $simple),
    );

    my $result;
    my $ok = eval {
        $result = Test2::Harness2->run(
            job_count  => 1,
            includes   => ['lib'],
            test_files => \@tf,
        );
        1;
    };
    my $err = $@;

    ok($ok,               'Test2::Harness2->run did not die') or diag "Error: $err";
    ok($result,           'Test2::Harness2->run returned a result');
    ok($result->{passed}, 'convenience API run passed');
    is($result->{total},  1, 'total is 1');
    is($result->{failed}, 0, 'failed is 0');

    my ($r) = @{$result->{results}};
    ok($r->passed,       'result->passed is true');
    ok(defined $r->uuid, 'result->uuid is defined');
    ok($r->uuid ne '',   'result->uuid is non-empty');
    # Note: the auto-created workspace uses cleanup => 1, so the log file may
    # already have been removed by the time we check here.  We verify the path
    # is at least a non-empty string rather than asserting the file still exists.
    ok(defined $r->log_file, 'result->log_file is defined');
    ok($r->log_file ne '',   'result->log_file is non-empty string');
    like($r->log_file, qr/\.jsonl$/, 'result->log_file ends with .jsonl');
};

done_testing;
