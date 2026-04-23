use strict;
use warnings;
use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness2::MiniHarness;
use Test2::Harness2::Util::JSON qw/decode_json/;

my $BASE = File::Spec->rel2abs('t/selftest');

subtest 'Result class basics' => sub {
    my $r = Test2::Harness2::MiniHarness::Result->new(
        passed    => 1,
        exit_code => 0,
        uuid      => 'test-uuid-123',
        log_file  => '/tmp/test.jsonl',
    );

    ok($r->passed, "passed is true");
    is($r->exit_code, 0,                 "exit_code is 0");
    is($r->uuid,      'test-uuid-123',   "uuid matches");
    is($r->log_file,  '/tmp/test.jsonl', "log_file matches");

    my $r2 = Test2::Harness2::MiniHarness::Result->new(
        passed    => 0,
        exit_code => 256,
        uuid      => 'fail-uuid',
        log_file  => '/tmp/fail.jsonl',
    );

    ok(!$r2->passed, "failed result is not passed");
    is($r2->exit_code, 256, "exit_code reflects failure");
};

subtest 'run simple.t (passing test)' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $result  = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    isa_ok($result, ['Test2::Harness2::MiniHarness::Result'], 'result is a Result object');
    ok($result->passed, "simple.t passed");
    is($result->exit_code, 0, "exit code is 0");
    ok(defined $result->uuid,     "uuid is defined");
    ok(length($result->uuid) > 0, "uuid is non-empty");
    ok(defined $result->log_file, "log_file is defined");
    ok(-f $result->log_file,      "log file exists on disk");

    # Check log file has events
    open my $fh, '<', $result->log_file or die "Cannot open log: $!";
    my @lines = <$fh>;
    close $fh;
    ok(scalar @lines > 0, "log file has events (got " . scalar(@lines) . " lines)");

    # Each line should be valid JSON
    my $first_ok  = eval { decode_json($lines[0]); 1 };
    my $first_err = $@;
    ok($first_ok, "first log line is valid JSON") or diag("Error: $first_err");
};

subtest 'run tap_only.t (pure TAP)' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $result  = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/tap_only.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok($result->passed, "tap_only.t passed");
    is($result->exit_code, 0, "exit code is 0");
    ok(-f $result->log_file, "log file exists");
};

subtest 'run mixed_output.t (Stream2 + direct prints)' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $result  = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/mixed_output.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok($result->passed, "mixed_output.t passed");
    is($result->exit_code, 0, "exit code is 0");
};

subtest 'run a failing test' => sub {
    my $log_dir = tempdir(CLEANUP => 1);

    # Create a temporary failing test
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $fail_test = File::Spec->catfile($tmpdir, 'fail.t');
    open my $fh, '>', $fail_test or die "Cannot write failing test: $!";
    print $fh <<'FAIL';
use strict;
use warnings;
use Test2::V0;
ok(0, "this should fail");
done_testing;
FAIL
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $fail_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok(!$result->passed, "failing test is not passed");
};

subtest 'run a test that exits non-zero' => sub {
    my $log_dir = tempdir(CLEANUP => 1);

    my $tmpdir    = tempdir(CLEANUP => 1);
    my $exit_test = File::Spec->catfile($tmpdir, 'badexit.t');
    open my $fh, '>', $exit_test or die "Cannot write test: $!";
    print $fh <<'TEST';
print "1..1\n";
print "ok 1 - fine\n";
exit 42;
TEST
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $exit_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok(!$result->passed,        "non-zero exit means not passed");
    ok($result->exit_code != 0, "exit_code is non-zero");
};

subtest 'custom uuid' => sub {
    my $log_dir     = tempdir(CLEANUP => 1);
    my $custom_uuid = 'my-custom-uuid-42';

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
        uuid      => $custom_uuid,
    );

    is($result->uuid, $custom_uuid, "custom uuid is used");
    like($result->log_file, qr/\Q$custom_uuid\E\.jsonl$/, "log file uses custom uuid");
};

subtest 'auto tempdir when no log_dir given' => sub {
    my $result = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/simple.t",
        includes  => ['lib'],
    );

    ok($result->passed,           "test passed");
    ok(defined $result->log_file, "log_file is defined");
    ok(-f $result->log_file,      "log file exists");
};

subtest 'env vars passed to child' => sub {
    my $log_dir  = tempdir(CLEANUP => 1);
    my $tmpdir   = tempdir(CLEANUP => 1);
    my $env_test = File::Spec->catfile($tmpdir, 'env.t');
    open my $fh, '>', $env_test or die "Cannot write test: $!";
    print $fh <<'TEST';
use strict;
use warnings;
use Test2::V0;
ok($ENV{MINIHARNESS_TEST_VAR} eq 'hello_world', "env var was set");
done_testing;
TEST
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $env_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
        env       => {MINIHARNESS_TEST_VAR => 'hello_world'},
    );

    ok($result->passed, "test with env vars passed");
};

subtest 'preloaded parameter accepted (exec fallback)' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $result  = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
        preloaded => 1,
    );

    isa_ok($result, ['Test2::Harness2::MiniHarness::Result'], 'result is a Result object');
    ok($result->passed, "simple.t passed with preloaded => 1");
    is($result->exit_code, 0, "exit code is 0");
    ok(-f $result->log_file, "log file exists");
};

subtest 'preloaded => 0 works the same as default' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $result  = Test2::Harness2::MiniHarness->run(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
        preloaded => 0,
    );

    ok($result->passed, "simple.t passed with preloaded => 0");
    is($result->exit_code, 0, "exit code is 0");
};

subtest 'switches passed to child' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $tmpdir  = tempdir(CLEANUP => 1);
    my $sw_test = File::Spec->catfile($tmpdir, 'switch.t');
    open my $fh, '>', $sw_test or die "Cannot write test: $!";
    # -w enables warnings; we just check it doesn't break anything
    print $fh <<'TEST';
use strict;
use Test2::V0;
ok(1, "switches work");
done_testing;
TEST
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $sw_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
        switches  => ['-w'],
    );

    ok($result->passed, "test with switches passed");
};

done_testing;
