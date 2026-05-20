use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/time sleep/;

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/encode_json/;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 'h.t2h2');
    return ($path, Test2::Harness2->new(path => $path, project => 'test'));
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
    return {runner => $runner, launcher => $launcher, run => $run, tf => $tf};
}

subtest entrypoint_processes_launch => sub {
    my ($path, $h) = _new_harness();
    my $seed = _seed_launcher($h);

    my ($job) = $h->insert(jobs => {
        run_id       => $seed->{run}->run_id,
        test_file_id => $seed->{tf}->test_file_id,
        spec         => encode_json({exec => [$^X, '-e', 'exit 0']}),
    });
    my ($launch) = $h->insert(launches => {
        launcher_id => $seed->{launcher}->launcher_id,
        job_id      => $job->job_id,
        requested   => time(),
    });

    pipe(my $stdin_r, my $stdin_w) or die "pipe: $!";

    my $libdir = File::Spec->rel2abs('lib');

    my $child = fork // die "fork: $!";
    if ($child == 0) {
        close $stdin_w;
        open(STDIN, '<&', $stdin_r) or die "dup stdin: $!";
        close $stdin_r;
        exec(
            $^X,
            "-I$libdir",
            '-MTest2::Harness2::Launcher::ForkExec=start',
            '-e',
            '1',
        ) or die "exec: $!";
    }

    close $stdin_r;

    my %spec = (
        path        => $path,
        project     => 'test',
        launcher_id => $seed->{launcher}->launcher_id,
    );
    print {$stdin_w} encode_json(\%spec), "\n";
    close $stdin_w;

    my $deadline = time() + 10;
    while (time() < $deadline) {
        $launch->refresh;
        last if $launch->started;
        sleep 0.1;
    }

    ok($launch->started, 'launch.started populated via entry-point launcher');

    kill 'TERM', $child;
    waitpid($child, 0);

    $h->disconnect;
};

done_testing;
