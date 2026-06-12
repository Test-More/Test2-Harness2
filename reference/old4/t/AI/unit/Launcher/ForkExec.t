use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/time sleep/;

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Launcher::ForkExec;
use Test2::Harness2::Collector::Recorder::Files;

require POSIX;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 'h.t2h2');
    return Test2::Harness2->new(path => $path, project => 'test');
}

sub _seed_run {
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
    my ($run) = $h->insert(runs => {
        run_uuid => 'r-1', runner_id => $runner->runner_id,
        project_id => $project->project_id, user_id => $user->user_id,
        run_ord => 1, passed => 0, failed => 0,
    });

    return {runner => $runner, run => $run, project => $project};
}

sub _seed_job_try {
    my ($h, $seed, %spec) = @_;

    my $relative = $spec{test_file};
    $relative =~ s{^.*[\\/]}{};

    my ($tf) = $h->insert(test_files => {
        project_id => $seed->{project}->project_id,
        relative   => $relative,
    });
    my ($job) = $h->insert(jobs => {
        run_id       => $seed->{run}->run_id,
        test_file_id => $tf->test_file_id,
        spec         => encode_json(\%spec),
    });
    my ($job_try) = $h->insert(job_tries => {
        job_id  => $job->job_id,
        try_ord => 1,
    });
    return $job_try;
}

sub _write_test_script {
    my ($dir, $name, $body) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $body;
    close($fh);
    return $path;
}

sub _wait_pid {
    my ($pid, $timeout) = @_;
    $timeout //= 10;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        return ($r, $?) if $r > 0;
        sleep 0.05;
    }
    return (0, undef);
}

subtest launch_runs_passing_test => sub {
    my $h    = _new_harness();
    my $seed = _seed_run($h);

    my $dir  = tempdir(CLEANUP => 1);
    my $script = _write_test_script($dir, 'pass.t', <<'EOT');
use Test2::V0;
ok(1, 'works');
done_testing;
EOT

    my $rec_dir = File::Spec->catdir($dir, 'rec');
    my $rec = Test2::Harness2::Collector::Recorder::Files->new(dir => $rec_dir);

    my $job_try = _seed_job_try(
        $h, $seed,
        test_file => $script,
        includes  => [],
        modules   => [],
    );

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle   => $h,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        recorder => $rec,
    );

    my %reply = $l->launch($job_try);
    is($reply{ok}, 1, 'ok=1') or diag(explain(\%reply));
    my $pid = $reply{pid};
    ok($pid && $pid > 0, "collector pid: $pid");

    my ($r, $status) = _wait_pid($pid);
    is($r, $pid, 'collector reaped');
    is($status, 0, 'collector exited 0');

    ok(-e File::Spec->catfile($rec_dir, 'events.jsonl'), 'events.jsonl written');
    ok(-e File::Spec->catfile($rec_dir, 'exit'),         'exit written');
    ok(-e File::Spec->catfile($rec_dir, 'finalized'),    'finalized marker written');

    open(my $efh, '<', File::Spec->catfile($rec_dir, 'exit')) or die "open exit: $!";
    chomp(my $exit_line = <$efh>);
    close($efh);
    is($exit_line, '0', 'test process exit code recorded as 0');

    $h->disconnect;
};

subtest launch_records_failing_test => sub {
    my $h    = _new_harness();
    my $seed = _seed_run($h);

    my $dir  = tempdir(CLEANUP => 1);
    my $script = _write_test_script($dir, 'fail.t', <<'EOT');
use Test2::V0 -no_pragmas => 1;
exit 3;
EOT

    my $rec_dir = File::Spec->catdir($dir, 'rec');
    my $rec = Test2::Harness2::Collector::Recorder::Files->new(dir => $rec_dir);

    my $job_try = _seed_job_try(
        $h, $seed,
        test_file => $script,
    );

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle   => $h,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        recorder => $rec,
    );

    my %reply = $l->launch($job_try);
    is($reply{ok}, 1, 'ok=1') or diag(explain(\%reply));
    _wait_pid($reply{pid});

    open(my $efh, '<', File::Spec->catfile($rec_dir, 'exit')) or die "open exit: $!";
    chomp(my $exit_line = <$efh>);
    close($efh);
    is($exit_line, '768', 'test process exit code recorded (768 = 3<<8)');

    $h->disconnect;
};

subtest launch_honors_includes_modules_env_cwd => sub {
    my $h    = _new_harness();
    my $seed = _seed_run($h);

    my $dir = tempdir(CLEANUP => 1);
    my $lib_dir = File::Spec->catdir($dir, 'lib');
    mkdir $lib_dir or die "mkdir: $!";
    my $mod_path = File::Spec->catfile($lib_dir, 'PingPong.pm');
    open(my $mfh, '>', $mod_path) or die "open: $!";
    print {$mfh} <<'EOT';
package PingPong;
use strict;
use warnings;
our $LOADED = 1;
1;
EOT
    close($mfh);

    my $outfile = File::Spec->catfile($dir, 'out');
    my $script = _write_test_script($dir, 'probe.t', <<'EOT');
use Cwd qw/getcwd/;
open(my $fh, '>', $ENV{OUT}) or die "open: $!";
print {$fh} getcwd, "\n", ($PingPong::LOADED // ''), "\n", ($ENV{FOO} // ''), "\n";
close($fh);
print "1..1\nok 1\n";
exit 0;
EOT

    my $rec_dir = File::Spec->catdir($dir, 'rec');
    my $rec = Test2::Harness2::Collector::Recorder::Files->new(dir => $rec_dir);

    my $job_try = _seed_job_try(
        $h, $seed,
        test_file => $script,
        includes  => [$lib_dir],
        modules   => ['PingPong'],
        env       => {OUT => $outfile, FOO => 'bar'},
        cwd       => $dir,
    );

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle   => $h,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        recorder => $rec,
    );

    my %reply = $l->launch($job_try);
    is($reply{ok}, 1, 'launch ok') or diag(explain(\%reply));
    _wait_pid($reply{pid});

    open(my $ofh, '<', $outfile) or die "open out: $!";
    chomp(my @lines = <$ofh>);
    close($ofh);

    is(scalar(@lines), 3, '3 probe lines') or diag(explain(\@lines));
    is($lines[0], $dir,  'cwd applied');
    is($lines[1], '1',   'module loaded via -M from -I');
    is($lines[2], 'bar', 'env applied');

    $h->disconnect;
};

subtest launch_rejects_missing_test_file => sub {
    my $h    = _new_harness();
    my $seed = _seed_run($h);

    my $dir = tempdir(CLEANUP => 1);

    # Insert a spec with no test_file.
    my ($tf) = $h->insert(test_files => {
        project_id => $seed->{project}->project_id,
        relative   => 'phantom.t',
    });
    my ($job) = $h->insert(jobs => {
        run_id       => $seed->{run}->run_id,
        test_file_id => $tf->test_file_id,
        spec         => encode_json({includes => []}),
    });
    my ($job_try) = $h->insert(job_tries => {
        job_id => $job->job_id, try_ord => 1,
    });

    my $rec = Test2::Harness2::Collector::Recorder::Files->new(
        dir => File::Spec->catdir($dir, 'rec'),
    );
    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle   => $h,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        recorder => $rec,
    );

    my %reply = $l->launch($job_try);
    is($reply{ok}, 0, 'ok=0');
    is($reply{temporary}, 0, 'permanent');
    like($reply{error}, qr/test_file/, 'mentions test_file');

    $h->disconnect;
};

subtest launch_rejects_non_jobtry_arg => sub {
    my $h = _new_harness();
    my $rec = Test2::Harness2::Collector::Recorder::Files->new(
        dir => File::Spec->catdir(tempdir(CLEANUP => 1), 'rec'),
    );
    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle => $h, recorder => $rec,
        parser => 'Test2::Harness2::Collector::Parser::TAPParser',
    );

    my %reply = $l->launch(undef);
    is($reply{ok}, 0, 'undef rejected');
    like($reply{error}, qr/job_try/);

    %reply = $l->launch({fake => 1});
    is($reply{ok}, 0, 'hashref rejected');

    $h->disconnect;
};

subtest custom_name => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new(
        name => 'mine',
        handle => undef,
    );
    is($l->name, 'mine', 'custom name retained');
};

subtest default_name => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new(handle => undef);
    is($l->name, 'forkexec', 'default name');
};

done_testing;
