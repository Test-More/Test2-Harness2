use Test2::V0 -target => 'Test2::Harness2::Runner::Job';
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression tests for ticket #137 -- Runner::Job env/switch handling bundle:
#   (31) a leading-space HARNESS_PERL_SWITCHES (e.g. " -w") must not split to an
#        empty-string switch (which perl would treat as its program, so the test
#        body never runs).
#   (32) the -w switch predicate must match ONLY a bare '-w', not any switch that
#        merely contains "-w" as a substring (e.g. -I.../my-website/lib), which
#        would be dropped onto the fork/preload path (wrong libs) with $^W forced.
#   (33) a spawned (Runner::Spawn) script must get a TMPDIR/TEMPDIR OUTSIDE the
#        workdir (which yath stop/kill deletes) and must NOT carry the harness
#        test markers HARNESS_ACTIVE / TEST2_HARNESS_ACTIVE / TEST2_JOB_DIR.

use File::Temp qw/tempdir/;
use File::Spec;
use Getopt::Yath::Settings;
use Test2::Harness2::Runner::Spawn;

my $tmp = tempdir(CLEANUP => 1);

{
    package MockRunner;
    sub new        { my ($c, %a) = @_; bless {%a}, $c }
    sub all_libs   { () }
    sub switches   { $_[0]->{switches} // [] }
    sub use_fork   { $_[0]->{use_fork} // 1 }
    sub unsafe_inc { 0 }
    sub dir        { $_[0]->{dir} // $tmp }
}

{
    package MockRun;
    sub new      { bless {}, shift }
    sub run_id   { 'mock-run' }
    sub env_vars { {} }
    sub AUTOLOAD { }
}

sub make_job {
    my (%args) = @_;

    my $task = {
        job_id => 'job-1',
        file   => __FILE__,
        %{$args{task} // {}},
    };

    return $CLASS->new(
        task     => $task,
        runner   => MockRunner->new(%{$args{runner} // {}}),
        run      => MockRun->new,
        settings => Getopt::Yath::Settings->new,
    );
}

subtest 'finding 31: leading-space HARNESS_PERL_SWITCHES drops the empty switch' => sub {
    local $ENV{HARNESS_PERL_SWITCHES} = ' -w';

    my $job = make_job();

    is([$job->switches_from_env], ['-w'], "no empty-string switch from a leading space");

    my @sw = $job->switches;
    is(\@sw, ['-w'], "switches carries only the real -w (no '')");
    ok(!(grep { $_ eq '' } @sw), "there is no empty-string switch");
    ok($job->use_w_switch, "the -w switch is still recognized");
};

subtest 'finding 31: interior/trailing whitespace also collapses cleanly' => sub {
    local $ENV{HARNESS_PERL_SWITCHES} = '  -w   -It2clib  ';

    my $job = make_job();

    is([$job->switches_from_env], ['-w', '-It2clib'], "no empty fields from extra whitespace");
};

subtest 'finding 32: a -w-containing -I path is NOT treated as the -w switch' => sub {
    local $ENV{HARNESS_PERL_SWITCHES};
    delete $ENV{HARNESS_PERL_SWITCHES};

    my $lib = '/home/bob/my-website/lib';    # contains "-w" as a substring
    my $job = make_job(
        task   => {switches => ["-I$lib"]},
        runner => {use_fork => 1},
    );

    my @sw = $job->switches;
    ok((grep { $_ eq "-I$lib" } @sw), "the -I switch survives");
    ok(!$job->use_w_switch, "-I.../my-website/lib does NOT enable the -w switch");
    is($job->use_fork, 0, "a real non-w switch forces the exec path (not fork/preload)");
};

subtest 'finding 32: a bare -w still allows the fork path' => sub {
    local $ENV{HARNESS_PERL_SWITCHES};
    delete $ENV{HARNESS_PERL_SWITCHES};

    my $job = make_job(
        task   => {switches => ['-w']},
        runner => {use_fork => 1},
    );

    ok($job->use_w_switch, "bare -w enables the -w switch");
    is($job->use_fork, 1, "a bare -w does not block the fork path");
};

subtest 'finding 32: a clustered -wT forces the exec path' => sub {
    local $ENV{HARNESS_PERL_SWITCHES};
    delete $ENV{HARNESS_PERL_SWITCHES};

    my $job = make_job(
        task   => {switches => ['-wT']},
        runner => {use_fork => 1},
    );

    ok(!$job->use_w_switch, "-wT is not the bare -w switch");
    is($job->use_fork, 0, "-wT forces the exec path");
};

subtest 'finding 33: spawn TMPDIR is outside the workdir and test markers are dropped' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $orig_tmp = File::Spec->tmpdir();

    my $settings = Getopt::Yath::Settings->new;
    $settings->create_group(
        harness => {orig_tmp => $orig_tmp, orig_tmp_perms => 0700},
    );
    $settings->create_group(runner => {nytprof => 0});

    my $spawn = Test2::Harness2::Runner::Spawn->new(
        runner   => MockRunner->new(dir => $workdir),
        settings => $settings,
        task     => {file => __FILE__, env_vars => {}, spawn => 1},
    );

    is($spawn->tmp_dir, $orig_tmp, "spawn tmp_dir is the system tmpdir");

    my $env = $spawn->env_vars;

    is($env->{TMPDIR},  $orig_tmp, "TMPDIR points at the system tmpdir");
    is($env->{TEMPDIR}, $orig_tmp, "TEMPDIR points at the system tmpdir");
    unlike($env->{TMPDIR}, qr/^\Q$workdir\E/, "TMPDIR is not inside the workdir");

    ok(!exists $env->{HARNESS_ACTIVE},       "HARNESS_ACTIVE dropped for a spawn");
    ok(!exists $env->{TEST2_HARNESS_ACTIVE}, "TEST2_HARNESS_ACTIVE dropped for a spawn");
    ok(!exists $env->{TEST2_JOB_DIR},        "TEST2_JOB_DIR dropped for a spawn");
};

subtest 'finding 33 contrast: a normal test job keeps the harness markers' => sub {
    local $ENV{HARNESS_PERL_SWITCHES};
    delete $ENV{HARNESS_PERL_SWITCHES};

    my $workdir = tempdir(CLEANUP => 1);

    my $settings = Getopt::Yath::Settings->new;
    $settings->create_group(
        harness => {orig_tmp => File::Spec->tmpdir(), orig_tmp_perms => 0700},
    );
    $settings->create_group(runner => {nytprof => 0});

    my $job = make_job();
    $job->{+Test2::Harness2::Runner::Job::SETTINGS()} = $settings;
    $job->{+Test2::Harness2::Runner::Job::JOB_DIR()}  = $workdir;
    $job->{+Test2::Harness2::Runner::Job::TMP_DIR()}  = File::Spec->catdir($workdir, 'tmp');

    my $env = $job->env_vars;

    ok($env->{HARNESS_ACTIVE},       "a real test job still sets HARNESS_ACTIVE");
    ok($env->{TEST2_HARNESS_ACTIVE}, "a real test job still sets TEST2_HARNESS_ACTIVE");
    ok(exists $env->{TEST2_JOB_DIR}, "a real test job still sets TEST2_JOB_DIR");
};

done_testing;
