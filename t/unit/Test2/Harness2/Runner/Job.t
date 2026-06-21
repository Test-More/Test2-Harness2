use Test2::V0 -target => 'Test2::Harness2::Runner::Job';
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

use File::Temp qw/tempdir/;
use File::Spec;
use Getopt::Yath::Settings;

my $tmp = tempdir(CLEANUP => 1);

{
    package MockRunner;
    sub new { bless {}, shift }
    sub all_libs { () }
}

{
    package MockRun;
    sub new { bless {}, shift }
    sub run_dir { $tmp }
    sub run_id { 'mock-run' }
    sub test_args { undef }
}

sub make_settings {
    my (%overrides) = @_;

    my $settings = Getopt::Yath::Settings->new();

    $settings->group('debug', 1)->create_option(dummy => $overrides{dummy} // 0);

    my $runner = $settings->group('runner', 1);
    $runner->create_option(fail_on_resource_skip => $overrides{fail_on_resource_skip} // 0);
    $runner->create_option(nytprof => 0);

    return $settings;
}

sub make_job {
    my (%args) = @_;

    my $job_dir = File::Spec->catdir($tmp, "job_$$" . ++$main::JOB_COUNT);
    mkdir $job_dir;

    # Create required files in job_dir so open_file calls succeed
    for my $f (qw/stdout stderr/) {
        open my $fh, '>', File::Spec->catfile($job_dir, $f) or die $!;
        close $fh;
    }
    # Create stdin file
    open my $fh, '>', File::Spec->catfile($job_dir, 'stdin') or die $!;
    close $fh;

    my $settings = $args{settings} // make_settings(%{$args{settings_overrides} // {}});

    my $task = $args{task} // {
        job_id => "job-$$-$main::JOB_COUNT",
        file   => __FILE__,
        %{$args{task_overrides} // {}},
    };

    my $runner = $args{runner} // MockRunner->new;
    my $run    = $args{run}    // MockRun->new;

    my $job = $CLASS->new(
        task     => $task,
        runner   => $runner,
        run      => $run,
        settings => $settings,
    );

    # Pre-set job_dir so file operations work
    $job->{+Test2::Harness2::Runner::Job::JOB_DIR()} = $job_dir;

    return $job;
}

# Create shared temp files for mock file handles
my $devnull = File::Spec->catfile($tmp, 'devnull');
open my $dn, '>', $devnull or die $!;
close $dn;

# Mock methods on the Job class that spawn_params calls, so we don't
# need to set up the full settings/runner/run chain.
my $mock = mock $CLASS => (
    override => [
        cli_includes => sub { () },
        switches     => sub { () },
        cli_options  => sub { () },
        args         => sub { () },
        ch_dir       => sub { '' },
        env_vars     => sub { {} },
        out_file     => sub { $devnull },
        err_file     => sub { $devnull },
        in_file      => sub { $devnull },
    ],
);

# collector_target returns a (exec => \@cmd) list. Pull the exec arrayref out.
sub target_exec {
    my $job = shift;
    my %target = $job->collector_target;
    return $target{exec};
}

subtest 'via returns undef for resource_skip' => sub {
    my $job = make_job(
        task_overrides     => {resource_skip => ['SomeResource']},
        settings_overrides => {dummy => 0},
    );

    is($job->via, undef, "via() returns undef when task has resource_skip");
};

subtest 'collector_target with resource_skip (default: skip)' => sub {
    my $job = make_job(
        task_overrides     => {resource_skip => ['Port', 'Database']},
        settings_overrides => {fail_on_resource_skip => 0},
    );

    my $command = target_exec($job);

    # Find the -e argument in the exec array
    my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;

    ok(defined $e_idx, "Found -e flag in exec command");
    my $script = $command->[$e_idx + 1];
    like($script, qr/1\.\.0 # SKIP/, "Generates TAP skip output");
    like($script, qr/Some resources are not available: Port, Database/, "Skip message lists unavailable resources");
    unlike($script, qr/not ok/, "Does not contain a failure");
};

subtest 'collector_target with resource_skip and --fail-on-resource-skip' => sub {
    my $job = make_job(
        task_overrides     => {resource_skip => ['Port', 'Database']},
        settings_overrides => {fail_on_resource_skip => 1},
    );

    my $command = target_exec($job);

    my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;

    ok(defined $e_idx, "Found -e flag in exec command");
    my $script = $command->[$e_idx + 1];
    like($script, qr/1\.\.1/, "Generates TAP with 1 test planned");
    like($script, qr/not ok 1/, "Generates a TAP failure");
    like($script, qr/Some resources are not available: Port, Database/, "Failure message lists unavailable resources");
    unlike($script, qr/# SKIP/, "Does not contain a skip directive");
};

subtest 'collector_target with no resource_skip runs test normally' => sub {
    my $job = make_job(
        settings_overrides => {fail_on_resource_skip => 1},
    );

    my $command = target_exec($job);

    # First element is the perl interpreter, and the run_file (rel_file) is
    # included as the script to run -- no -e short-circuit.
    is($command->[0], $^X, "exec starts with the perl interpreter");

    my $has_e = grep { !ref($_) && $_ eq '-e' } @$command;
    ok(!$has_e, "exec command does not contain -e flag when no resource_skip");

    my $run_file = $job->run_file;
    ok((grep { !ref($_) && $_ eq $run_file } @$command), "exec command runs the run_file");
};

subtest 'collector_target dummy mode still skips even with fail_on_resource_skip' => sub {
    my $job = make_job(
        settings_overrides => {dummy => 1, fail_on_resource_skip => 1},
    );

    my $command = target_exec($job);

    my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;

    ok(defined $e_idx, "Found -e flag in exec command");
    my $script = $command->[$e_idx + 1];
    like($script, qr/1\.\.0 # SKIP dummy mode/, "Dummy mode produces a skip, not a failure");
    unlike($script, qr/not ok/, "No failure for dummy mode");
};

subtest 'collector_target resource_skip with single resource' => sub {
    my $job = make_job(
        task_overrides     => {resource_skip => ['Port']},
        settings_overrides => {fail_on_resource_skip => 1},
    );

    my $command = target_exec($job);

    my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;

    ok(defined $e_idx, "Found -e flag in exec command");
    my $script = $command->[$e_idx + 1];
    like($script, qr/not ok 1 - Some resources are not available: Port/, "Failure message with single resource");
};

subtest 'TAP output is valid when executed' => sub {
    # Verify the generated -e scripts produce valid TAP when run

    subtest 'skip TAP' => sub {
        my $job = make_job(
            task_overrides     => {resource_skip => ['Port']},
            settings_overrides => {fail_on_resource_skip => 0},
        );

        my $command = target_exec($job);
        my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;
        my $script = $command->[$e_idx + 1];

        my $output = `$^X -e '$script'`;
        is($output, "1..0 # SKIP Some resources are not available: Port", "Skip TAP output is correct");
    };

    subtest 'fail TAP' => sub {
        my $job = make_job(
            task_overrides     => {resource_skip => ['Port']},
            settings_overrides => {fail_on_resource_skip => 1},
        );

        my $command = target_exec($job);
        my ($e_idx) = grep { !ref($command->[$_]) && $command->[$_] eq '-e' } 0 .. $#$command;
        my $script = $command->[$e_idx + 1];

        my $output = `$^X -e '$script'`;
        like($output, qr/^1\.\.1\nnot ok 1 - Some resources are not available: Port$/s, "Fail TAP output is correct");
    };
};

# The test-job collector parent now exits HEALTH-ONLY via
# Test2::Collector::Runner->spawn_exit_code (the test verdict rides the
# transitions + connection EOF, ARCHITECTURE.md §5.4). Job::_collector_exit_code
# and Job::bailed_out / bail_file were removed, so the exit-code-mapping subtests
# that lived here are gone. The exit semantics are covered in Test2-Collector's
# own suite (spawn_exit_code) and end-to-end by the integration runs.

done_testing;
