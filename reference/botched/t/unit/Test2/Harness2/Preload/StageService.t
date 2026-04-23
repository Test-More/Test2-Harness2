use strict;
use warnings;
use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness2::Preload::Stage;
use Test2::Harness2::Preload::StageService;

my $BASE = File::Spec->rel2abs('t/selftest');

subtest 'construction requires stage_def' => sub {
    like(
        dies { Test2::Harness2::Preload::StageService->new() },
        qr/stage_def.*required/,
        "dies without stage_def"
    );
};

subtest 'basic construction' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'TestStage',
        load_sequence => [],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    ok($service, "created StageService object");
    is($service->stage_name, 'TestStage', "stage_name derived from stage_def");
    is($service->parent_pid, $$,          "parent_pid defaults to current PID");
    ok(!$service->_loaded,           "_loaded defaults to false");
    ok(!defined $service->_reloader, "_reloader defaults to undef");
};

subtest 'load_modules with empty sequence' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'EmptyStage',
        load_sequence => [],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    ok($service->load_modules(), "load_modules succeeds with empty sequence");
    ok($service->_loaded,        "_loaded set to true after load_modules");
};

subtest 'load_modules with real modules' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'RealModules',
        load_sequence => ['Scalar::Util', 'List::Util'],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    ok($service->load_modules(), "load_modules succeeds with real modules");
    ok($service->_loaded,        "_loaded is true");
    ok($INC{'Scalar/Util.pm'},   "Scalar::Util is loaded in %INC");
    ok($INC{'List/Util.pm'},     "List::Util is loaded in %INC");
};

subtest 'load_modules with coderefs' => sub {
    my @called;
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'CoderefStage',
        load_sequence => [
            sub { push @called, 'first' },
            'Scalar::Util',
            sub { push @called, 'second' },
        ],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    ok($service->load_modules(), "load_modules succeeds with mixed sequence");
    is(\@called, [qw/first second/], "coderefs called in order");
};

subtest 'load_modules dies on bad module' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'BadModule',
        load_sequence => ['This::Module::Does::Not::Exist::XYZZY'],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    like(
        dies { $service->load_modules() },
        qr/Failed to load module/,
        "dies when module cannot be loaded"
    );
    ok(!$service->_loaded, "_loaded still false after failure");
};

subtest 'load_modules dies on failing coderef' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'FailCoderef',
        load_sequence => [sub { die "intentional coderef failure" }],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    like(
        dies { $service->load_modules() },
        qr/Coderef in load_sequence.*failed.*intentional coderef failure/,
        "dies when coderef throws"
    );
};

subtest 'launch_test runs a passing test' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'LaunchStage',
        load_sequence => [],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    my $log_dir = tempdir(CLEANUP => 1);

    my $result = $service->launch_test(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        uuid      => 'stage-test-uuid',
        includes  => ['lib'],
    );

    is(ref($result), 'HASH', "launch_test returns a hashref");
    ok($result->{passed}, "simple.t passed via StageService");
    is($result->{exit_code}, 0,                 "exit_code is 0");
    is($result->{uuid},      'stage-test-uuid', "uuid passed through");
    is($result->{test_file}, "$BASE/simple.t",  "test_file passed through");
};

subtest 'launch_test runs a failing test' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'FailLaunch',
        load_sequence => [],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

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

    my $result = $service->launch_test(
        test_file => $fail_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok(!$result->{passed},        "failing test is not passed");
    ok($result->{exit_code} != 0, "exit_code is non-zero");
};

subtest 'launch_test calls stage callbacks' => sub {
    my @callback_log;

    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'CallbackStage',
        load_sequence => [],
    );

    $stage_def->add_pre_fork_callback(sub { push @callback_log, "pre_fork:$$" });
    $stage_def->add_post_fork_callback(sub { push @callback_log, "post_fork:$$" });
    $stage_def->add_pre_launch_callback(sub { push @callback_log, "pre_launch:$$" });

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    my $log_dir = tempdir(CLEANUP => 1);

    my $result = $service->launch_test(
        test_file => "$BASE/simple.t",
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok($result->{passed}, "test passed with callbacks");

    # pre_fork runs in the parent process
    ok(
        (grep { /^pre_fork:$$/ } @callback_log),
        "pre_fork callback ran in parent process"
    );

    # post_fork and pre_launch run in the child, so they won't be visible
    # in @callback_log in the parent (fork copies the array). We just check
    # that pre_fork was called.
    ok(scalar @callback_log >= 1, "at least pre_fork callback was logged");
};

subtest 'launch_test requires test_file' => sub {
    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'NoFile',
        load_sequence => [],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    like(
        dies { $service->launch_test() },
        qr/test_file is required/,
        "dies without test_file"
    );
};

done_testing;
