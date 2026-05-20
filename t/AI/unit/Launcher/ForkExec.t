use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/time sleep/;

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Launcher::ForkExec;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 'h.t2h2');
    return Test2::Harness2->new(path => $path, project => 'test');
}

sub _seed_launcher {
    my ($h) = @_;

    my ($host)     = $h->insert(hosts    => {name => 'localhost'});
    my ($user)     = $h->insert(users    => {name => 'tester'});
    my ($project)  = $h->insert(projects => {name => 'p'});
    my ($instance) = $h->insert(instances => {
        instance_uuid => 'i-1', host_id => $host->host_id,
        user_id => $user->user_id, started => time(),
    });
    my ($runner) = $h->insert(runners => {
        instance_id => $instance->instance_id, pid => $$, started => time(),
    });
    my ($collector) = $h->insert(collectors => {
        runner_id => $runner->runner_id, name => 'launcher-collector',
        pid => $$, is_test => 0, start_time => time(),
    });
    my ($launcher) = $h->insert(launchers => {
        runner_id    => $runner->runner_id,
        collector_id => $collector->collector_id,
        name         => 'fe',
        class        => 'Test2::Harness2::Launcher::ForkExec',
    });
    my ($tf) = $h->insert(test_files => {
        project_id => $project->project_id, relative => 't/dummy.t',
    });
    my ($run) = $h->insert(runs => {
        run_uuid => 'r-1', runner_id => $runner->runner_id,
        project_id => $project->project_id, user_id => $user->user_id,
        run_ord => 1, passed => 0, failed => 0, abort => 0,
    });

    return {
        runner   => $runner,
        launcher => $launcher,
        run      => $run,
        tf       => $tf,
    };
}

sub _queue_launch {
    my ($h, $seed, $exec) = @_;
    my ($job) = $h->insert(jobs => {
        run_id       => $seed->{run}->run_id,
        test_file_id => $seed->{tf}->test_file_id,
        spec         => encode_json({exec => $exec}),
    });
    my ($launch) = $h->insert(launches => {
        launcher_id => $seed->{launcher}->launcher_id,
        job_id      => $job->job_id,
        requested   => time(),
    });
    return ($job, $launch);
}

subtest tick_starts_and_reaps => sub {
    my $h    = _new_harness();
    my $seed = _seed_launcher($h);

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle      => $h,
        launcher_id => $seed->{launcher}->launcher_id,
    );

    my ($job, $launch) = _queue_launch($h, $seed, [$^X, '-e', 'exit 0']);

    my $started = $l->tick;
    is($started, 1, 'tick started one launch');

    $launch->refresh;
    ok($launch->started, 'launches.started populated');

    my $deadline = time() + 5;
    while (keys %{$l->children}) {
        last if time() >= $deadline;
        $l->reap_children;
        sleep 0.05;
    }
    is(scalar(keys %{$l->children}), 0, 'child reaped');

    $h->disconnect;
};

subtest scheduler_pid_gets_sigusr1 => sub {
    my $h    = _new_harness();
    my $seed = _seed_launcher($h);

    my $sigfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'usr1.flag');

    my $sched = fork // die "fork: $!";
    if ($sched == 0) {
        local $SIG{USR1} = sub {
            open(my $fh, '>', $sigfile) or exit 9;
            print {$fh} "got\n";
            close($fh);
            exit 0;
        };
        sleep 5;
        exit 1;
    }

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle        => $h,
        launcher_id   => $seed->{launcher}->launcher_id,
        scheduler_pid => $sched,
    );

    _queue_launch($h, $seed, [$^X, '-e', 'exit 0']);

    $l->tick;
    my $deadline = time() + 5;
    while (keys %{$l->children}) {
        last if time() >= $deadline;
        $l->reap_children;
        sleep 0.05;
    }

    waitpid($sched, 0);
    is($? >> 8, 0, 'scheduler child caught SIGUSR1');
    ok(-e $sigfile, 'sigusr1 flag file written');

    $h->disconnect;
};

subtest multi_launch_drains => sub {
    my $h    = _new_harness();
    my $seed = _seed_launcher($h);

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle      => $h,
        launcher_id => $seed->{launcher}->launcher_id,
    );

    _queue_launch($h, $seed, [$^X, '-e', 'exit 0']) for 1 .. 3;

    my $started = $l->tick;
    is($started, 3, 'tick started three launches');

    my $deadline = time() + 5;
    while (keys %{$l->children}) {
        last if time() >= $deadline;
        $l->reap_children;
        sleep 0.05;
    }
    is(scalar(keys %{$l->children}), 0, 'all three children reaped');

    my $rows = $h->dbh->selectall_arrayref(
        "SELECT started FROM launches WHERE launcher_id = ?",
        {Slice => {}},
        $seed->{launcher}->launcher_id,
    );
    is(scalar(@$rows), 3, 'three launches');
    for my $r (@$rows) {
        ok($r->{started}, 'launch started');
    }

    $h->disconnect;
};

done_testing;
