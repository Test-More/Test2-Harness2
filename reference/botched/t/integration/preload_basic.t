use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw/tempdir/;

use Test2::Harness2::Preload::Manager;
use Test2::Harness2::Preload;
use Test2::Harness2::Preload::Stage;
use Test2::Harness2::Workspace;

subtest 'manager starts with preload modules' => sub {
    my $manager = Test2::Harness2::Preload::Manager->new(
        preloads  => ['Scalar::Util', 'List::Util'],
        workspace => Test2::Harness2::Workspace->new(cleanup => 1),
        includes  => ['lib'],
    );
    ok(lives { $manager->start() }, "start succeeds");
    ok($manager->is_ready,          "manager is ready");
    $manager->stop();
    ok(!$manager->is_ready, "manager is no longer ready after stop");
};

subtest 'manager starts with DSL preload' => sub {
    my $preload = Test2::Harness2::Preload->new();

    # Build a stage directly (without DSL export functions)
    my $stage = Test2::Harness2::Preload::Stage->new(
        name          => 'default',
        load_sequence => ['Scalar::Util'],
        frame         => [__PACKAGE__, __FILE__, __LINE__],
    );
    $preload->set_default_stage('default');
    $preload->add_stage($stage, [__PACKAGE__, __FILE__, __LINE__]);

    my $manager = Test2::Harness2::Preload::Manager->new(
        preload_dsl => $preload,
        workspace   => Test2::Harness2::Workspace->new(cleanup => 1),
        includes    => ['lib'],
    );
    ok(lives { $manager->start() }, "start succeeds with DSL");
    ok($manager->is_ready,          "ready");
    $manager->stop();
};

subtest 'launch test via manager' => sub {
    my $manager = Test2::Harness2::Preload::Manager->new(
        preloads  => ['Scalar::Util'],
        workspace => Test2::Harness2::Workspace->new(cleanup => 1),
        includes  => ['lib'],
    );
    $manager->start();

    my $tmpdir = tempdir(CLEANUP => 1);
    my $result = $manager->launch_test(
        test_file => File::Spec->rel2abs('t/selftest/simple.t'),
        log_dir   => $tmpdir,
        uuid      => 'preload-mgr-test',
        includes  => ['lib'],
    );

    ok($result,           "got result");
    ok($result->{passed}, "test passed via preload manager");
    $manager->stop();
};

subtest 'stage_for_test returns default' => sub {
    my $preload = Test2::Harness2::Preload->new();

    my $stage = Test2::Harness2::Preload::Stage->new(
        name          => 'default',
        load_sequence => [],
        frame         => [__PACKAGE__, __FILE__, __LINE__],
    );
    $preload->set_default_stage('default');
    $preload->add_stage($stage, [__PACKAGE__, __FILE__, __LINE__]);

    my $manager = Test2::Harness2::Preload::Manager->new(
        preload_dsl => $preload,
        workspace   => Test2::Harness2::Workspace->new(cleanup => 1),
        includes    => ['lib'],
    );
    $manager->start();

    my $stage_name = $manager->stage_for_test(undef);
    is($stage_name, 'default', "returns default stage name");
    $manager->stop();
};

subtest 'stage_for_test with requested stage' => sub {
    my $preload = Test2::Harness2::Preload->new();

    my $stage = Test2::Harness2::Preload::Stage->new(
        name          => 'mystage',
        load_sequence => ['Scalar::Util'],
        frame         => [__PACKAGE__, __FILE__, __LINE__],
    );
    $preload->add_stage($stage, [__PACKAGE__, __FILE__, __LINE__]);

    my $manager = Test2::Harness2::Preload::Manager->new(
        preload_dsl => $preload,
        workspace   => Test2::Harness2::Workspace->new(cleanup => 1),
        includes    => ['lib'],
    );
    $manager->start();

    my $found = $manager->stage_for_test('mystage');
    is($found, 'mystage', "returns requested stage");

    my $missing = $manager->stage_for_test('nonexistent');
    is($missing, 'mystage', "falls back when requested stage not found");

    $manager->stop();
};

subtest 'launch_test returns undef when no stages' => sub {
    my $manager = Test2::Harness2::Preload::Manager->new(
        workspace => Test2::Harness2::Workspace->new(cleanup => 1),
        includes  => ['lib'],
    );
    # Manually mark started without loading any stages
    $manager->{_started} = 1;

    my $result = $manager->launch_test(
        test_file => 't/selftest/simple.t',
        log_dir   => '/tmp',
        uuid      => 'test',
    );

    ok(!defined $result, "returns undef when no stages available");
};

done_testing;
