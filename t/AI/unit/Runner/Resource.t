use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;
use Test2::Harness2::Runner::Resource;
use Test2::Harness2::Runner::Run::Resource;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 't.t2h2');
    return Test2::Harness2->new(discovery_path => $path);
}

sub _make_runner {
    my ($h) = @_;
    my ($host) = $h->insert(hosts => {name => 'localhost'});
    my ($user) = $h->insert(users => {name => 'tester'});
    my ($inst) = $h->insert(instances => {
        instance_uuid => 'aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
        host_id       => $host->host_id,
        user_id       => $user->user_id,
        started       => 1,
    });
    my ($run) = $h->insert(runners => {
        instance_id => $inst->instance_id,
        pid         => $$,
        started     => 1,
    });
    return $run;
}

sub _make_run {
    my ($h, $runner) = @_;
    my ($proj) = $h->insert(projects => {name => 'p'});
    my ($user) = $h->fetch(users => name => 'tester');
    my ($run) = $h->insert(runs => {
        run_uuid   => 'bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb',
        runner_id  => $runner->runner_id,
        project_id => $proj->project_id,
        user_id    => $user->user_id,
        run_ord    => 1,
    });
    return $run;
}

subtest class_for_row_picks_base_when_run_id_null => sub {
    is(
        Test2::Harness2::Runner::Resource->class_for_row({runner_id => 1}),
        'Test2::Harness2::Runner::Resource',
        'null run_id -> base class',
    );
};

subtest class_for_row_picks_subclass_when_run_id_set => sub {
    is(
        Test2::Harness2::Runner::Resource->class_for_row({runner_id => 1, run_id => 7}),
        'Test2::Harness2::Runner::Run::Resource',
        'run_id set -> Run::Resource subclass',
    );
};

subtest insert_dispatches_to_subclass => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);
    my $run    = _make_run($h, $runner);

    my ($global) = $h->insert(resources => {
        runner_id => $runner->runner_id,
        class     => 'My::CPU',
        spec      => '{}',
    });
    my ($scoped) = $h->insert(resources => {
        runner_id => $runner->runner_id,
        run_id    => $run->run_id,
        class     => 'My::Mem',
        spec      => '{}',
    });

    isa_ok($global, ['Test2::Harness2::Runner::Resource'], 'runner-global = base class');
    ok(
        !$global->isa('Test2::Harness2::Runner::Run::Resource'),
        'runner-global is not the Run subclass',
    );
    isa_ok($scoped, ['Test2::Harness2::Runner::Run::Resource'], 'run-scoped = subclass');
    isa_ok($scoped, ['Test2::Harness2::Runner::Resource'], 'subclass still isa base');

    $h->disconnect;
};

subtest fetch_all_dispatches_per_row => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);
    my $run    = _make_run($h, $runner);

    $h->insert(resources => {
        runner_id => $runner->runner_id,
        class     => 'My::CPU',
    });
    $h->insert(resources => {
        runner_id => $runner->runner_id,
        run_id    => $run->run_id,
        class     => 'My::Mem',
    });

    my @rows = sort { ($a->run_id // 0) <=> ($b->run_id // 0) } $h->fetch_all('resources');
    is(scalar(@rows), 2, 'fetched both rows');
    isa_ok($rows[0], ['Test2::Harness2::Runner::Resource']);
    ok(!$rows[0]->isa('Test2::Harness2::Runner::Run::Resource'));
    isa_ok($rows[1], ['Test2::Harness2::Runner::Run::Resource']);

    $h->disconnect;
};

subtest snapshot_table => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);

    my ($res) = $h->insert(resources => {
        runner_id => $runner->runner_id,
        class     => 'My::CPU',
    });

    my ($snap) = $h->insert(resource_snapshots => {
        resource_id => $res->resource_id,
        stamp       => 12345.6,
        payload     => '{"v":1}',
    });

    isa_ok($snap, ['Test2::Harness2::Runner::Resource::Snapshot']);
    is($snap->resource_id, $res->resource_id);
    is($snap->payload,     '{"v":1}');

    $h->disconnect;
};

done_testing;
