use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;
use Test2::Harness2::DB::Resource;
use Test2::Harness2::DB::ResourceSnapshot;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 't.t2h2');
    return Test2::Harness2->new(path => $path, project => 'test');
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

subtest insert_runner_global_resource => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);

    my ($global) = $h->insert(resources => {
        runner_id => $runner->runner_id,
        class     => 'My::CPU',
        spec      => '{}',
    });
    isa_ok($global, ['Test2::Harness2::DB::Resource']);
    is($global->runner_id, $runner->runner_id);
    is($global->run_id, undef, 'runner-global has null run_id');
    is($global->class, 'My::CPU');

    $h->disconnect;
};

subtest insert_run_scoped_resource => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);
    my $run    = _make_run($h, $runner);

    my ($scoped) = $h->insert(resources => {
        runner_id => $runner->runner_id,
        run_id    => $run->run_id,
        class     => 'My::Mem',
        spec      => '{}',
    });
    isa_ok($scoped, ['Test2::Harness2::DB::Resource']);
    is($scoped->run_id, $run->run_id);

    $h->disconnect;
};

subtest fetch_all_returns_db_class => sub {
    my $h      = _new_harness();
    my $runner = _make_runner($h);
    my $run    = _make_run($h, $runner);

    $h->insert(resources => {runner_id => $runner->runner_id, class => 'My::CPU'});
    $h->insert(resources => {runner_id => $runner->runner_id, run_id => $run->run_id, class => 'My::Mem'});

    my @rows = $h->fetch_all('resources');
    is(scalar(@rows), 2, 'fetched both rows');
    isa_ok($_, ['Test2::Harness2::DB::Resource']) for @rows;

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

    isa_ok($snap, ['Test2::Harness2::DB::ResourceSnapshot']);
    is($snap->resource_id, $res->resource_id);
    is($snap->payload,     '{"v":1}');

    $h->disconnect;
};

done_testing;
