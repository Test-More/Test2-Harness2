package App::Yath2::Options::Runner;
use v5.38;

our $VERSION = '2.000000';

use Test2::Util qw/IS_WIN32/;
use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use File::Spec;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Runner - Runner options for Yath.

=head1 DESCRIPTION

This is where command line options for the runner are defined.

=head1 PROVIDED OPTIONS

=head3 Runner Options

=over 4

=item --abort-on-bail

=item --no-abort-on-bail

Abort all testing if a bail-out is encountered (default: on)


=item -b

=item --blib

=item --no-blib

(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path


=item --cover

=item --cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

=item --no-cover

Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: -silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

Can also be set with the following environment variables: C<T2_DEVEL_COVER>

The following environment variables will be set after arguments are processed: C<T2_DEVEL_COVER>


=item --dump-depmap

=item --no-dump-depmap

When using staged preload, dump the depmap for each stage as json files


=item --et SECONDS

=item --event-timeout SECONDS

=item --no-event-timeout

Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.


=item --fail-on-resource-skip

=item --no-fail-on-resource-skip

Treat resource-skipped tests as failures instead of skips. When enabled, tests that would be skipped due to unavailable resources will be marked as failing.


=item -I ARG

=item -I=ARG

=item -I '["json","list"]'

=item -I='["json","list"]'

=item --include ARG

=item --include=ARG

=item --include '["json","list"]'

=item --include='["json","list"]'

=item --no-include

Add a directory to your include paths

Note: Can be specified multiple times


=item -j4

=item -j8:2

=item --jobs 4

=item --jobs 8:2

=item --job-count 4

=item --job-count 8:2

=item --no-job-count

Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.

Can also be set with the following environment variables: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>

The following environment variables will be cleared after arguments are processed: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>


=item -l

=item --lib

=item --no-lib

(Default: include if it exists) Include 'lib' in your module path


=item --nytprof

=item --no-nytprof

Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.


=item --pet SECONDS

=item --post-exit-timeout SECONDS

=item --no-post-exit-timeout

Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness2 detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.


=item -WARG

=item -W ARG

=item -W=ARG

=item --Pt ARG

=item --Pt=ARG

=item --preload-threshold ARG

=item --preload-threshold=ARG

=item --no-preload-threshold

Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload.


=item -P ARG

=item -P=ARG

=item -P '["json","list"]'

=item -P='["json","list"]'

=item --preload ARG

=item --preload=ARG

=item --preloads ARG

=item --preloads=ARG

=item --preload '["json","list"]'

=item --preload='["json","list"]'

=item --preloads '["json","list"]'

=item --preloads='["json","list"]'

=item --no-preloads

Preload a module before running tests

Note: Can be specified multiple times


=item -R Port

=item --resource Port

=item --resource +Test2::Harness2::Runner::Resource::Port

=item --no-resource

Use a resource module to assign resource assignments to individual tests

Note: Can be specified multiple times


=item --rt SECONDS

=item --resource-timeout SECONDS

=item --no-resource-timeout

Abort the test run if no tests have been able to start for SECONDS seconds while there are pending tests and none running. This is useful when a resource class is broken and always claims a resource will become available, preventing yath from ever finishing. (Default: 0, meaning no timeout)


=item --runner-id ARG

=item --runner-id=ARG

=item --no-runner-id

Runner ID (usually a generated uuid)


=item -x2

=item --slots-per-job 2

=item --no-slots-per-job

This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.

Can also be set with the following environment variables: C<T2_HARNESS_JOB_CONCURRENCY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_JOB_CONCURRENCY>


=item -S ARG

=item -S=ARG

=item -S '["json","list"]'

=item -S='["json","list"]'

=item --switch ARG

=item --switch=ARG

=item --switch '["json","list"]'

=item --switch='["json","list"]'

=item --no-switch

Pass the specified switch to perl for each test. This is not compatible with preload.

Note: Can be specified multiple times


=item --tlib

=item --no-tlib

(Default: off) Include 't/lib' in your module path


=item --unsafe-inc

=item --no-unsafe-inc

perl is removing '.' from @INC as a security concern. This option keeps things from breaking for now.

Can also be set with the following environment variables: C<PERL_USE_UNSAFE_INC>


=item --fork

=item --use-fork

=item --no-use-fork

(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.

Can also be set with the following environment variables: C<!T2_NO_FORK>, C<T2_HARNESS_FORK>, C<!T2_HARNESS_NO_FORK>, C<YATH_FORK>, C<!YATH_NO_FORK>


=item --timeout

=item --use-timeout

=item --no-use-timeout

(default: on) Enable/disable timeouts


=back


=cut

my $DEFAULT_COVER_ARGS = '-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';

option_group {group => 'runner', category => "Runner Options"} => sub {

    option use_fork => (
        type          => 'Bool',
        alt           => ['fork'],
        from_env_vars => [qw/!T2_NO_FORK T2_HARNESS_FORK !T2_HARNESS_NO_FORK YATH_FORK !YATH_NO_FORK/],
        default       => sub {
            return 0 if IS_WIN32;
            return 1;
        },
        description => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.",
    );

    option abort_on_bail => (
        type        => 'Bool',
        default     => 1,
        description => "Abort all testing if a bail-out is encountered (default: on)",
    );

    option use_timeout => (
        type        => 'Bool',
        alt         => ['timeout'],
        default     => 1,
        description => "(default: on) Enable/disable timeouts",
    );

    # jobs_post_process is registered before cover_post_process to preserve live
    # execution order: both are weight=0, and Instance.pm preserves push-order
    # within a weight bucket.
    option_post_process 0 => \&jobs_post_process;

    option job_count => (
        type           => 'Scalar',
        short          => 'j',
        alt            => ['jobs'],
        from_env_vars  => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        long_examples  => [' 4', ' 8:2'],
        short_examples => ['4',  '8:2'],
        description    => 'Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.',

        # The '8:2' form RESHAPES the stored value: mutate @{$params{val}} to keep
        # only the jobs portion and side-channel the slots_per_job.
        # fix_job_resources is deferred to jobs_post_process (runs after all args
        # are processed) so that the full settings context is available.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            my ($val) = @{$params{val}};
            return unless $val && $val =~ m/:/;

            my ($jobs, $slots) = split /:/, $val;
            @{$params{val}} = ($jobs);
            $params{settings}->runner->create_option(slots_per_job => $slots) if defined $slots;
        },
    );

    option slots_per_job => (
        type           => 'Scalar',
        short          => 'x',
        from_env_vars  => ['T2_HARNESS_JOB_CONCURRENCY'],
        clear_env_vars => ['T2_HARNESS_JOB_CONCURRENCY'],
        long_examples  => [' 2'],
        short_examples => ['2'],
        description    => "This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.",
    );

    option dump_depmap => (
        type        => 'Bool',
        default     => 0,
        description => "When using staged preload, dump the depmap for each stage as json files",
    );

    option includes => (
        type        => 'PathList',
        name        => 'include',
        short       => 'I',
        description => "Add a directory to your include paths",
    );

    option resources => (
        type           => 'List',
        name           => 'resource',
        short          => 'R',
        long_examples  => [' Port', ' +Test2::Harness2::Runner::Resource::Port'],
        short_examples => [' Port'],
        description    => "Use a resource module to assign resource assignments to individual tests",

        normalize => sub ($val) {
            $val = "Test2::Harness2::Runner::Resource::$val"
                unless $val =~ s/^\+//;
            return $val;
        },
    );

    option tlib => (
        type        => 'Bool',
        default     => 0,
        description => "(Default: off) Include 't/lib' in your module path",

        # Same pattern as lib/blib: path lands in includes, flag is suppressed
        # so Test2::Harness2::Runner::all_libs doesn't double-add t/lib when
        # it sees tlib true.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            push @{$params{settings}->runner->includes} => File::Spec->catdir('t', 'lib');
            @{$params{val}} = (0);    # suppress flag storage
        },
    );

    option lib => (
        type        => 'Bool',
        short       => 'l',
        default     => 1,
        description => "(Default: include if it exists) Include 'lib' in your module path",

        # Trigger fires before add_value stores the result.  Mutating
        # @{$params{val}} to (0) suppresses this flag being set to 1
        # (the path lands in includes instead).  Only THIS flag is
        # suppressed: blib is independent and stays at its own default,
        # so `--lib` adds lib without dropping blib (matching 1.0, where
        # lib/blib are additive and both default-on).
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            push @{$params{settings}->runner->includes} => 'lib';
            @{$params{val}} = (0);    # suppress flag storage
        },
    );

    option blib => (
        type        => 'Bool',
        short       => 'b',
        default     => 1,
        description => "(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path",

        # Same pattern as lib above: paths land in includes, only this flag
        # is suppressed; lib is independent and stays at its own default.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            push @{$params{settings}->runner->includes} => (
                File::Spec->catdir('blib', 'lib'),
                File::Spec->catdir('blib', 'arch'),
            );
            @{$params{val}} = (0);    # suppress flag storage
        },
    );

    option unsafe_inc => (
        type          => 'Bool',
        from_env_vars => [qw/PERL_USE_UNSAFE_INC/],
        default       => 0,
        description   => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
    );

    option preloads => (
        type        => 'List',
        alt         => ['preload'],
        short       => 'P',
        description => 'Preload a module before running tests',
    );

    option preload_threshold => (
        type        => 'Scalar',
        short       => 'W',
        alt         => ['Pt'],
        default     => 0,
        description => "Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload.",
    );

    option nytprof => (
        type          => 'Bool',
        long_examples => [''],
        description   => "Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.",
    );

    # cover_post_process registered after jobs_post_process to maintain live
    # execution order within weight=0.
    option_post_process 0 => \&cover_post_process;

    option cover => (
        type          => 'Auto',
        from_env_vars => [qw/T2_DEVEL_COVER/],
        set_env_vars  => [qw/T2_DEVEL_COVER/],
        autofill      => $DEFAULT_COVER_ARGS,
        long_examples => ['', "=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl"],
        description   => "Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: $DEFAULT_COVER_ARGS",
    );

    option switch => (
        type        => 'List',
        field       => 'switches',
        short       => 'S',
        description => 'Pass the specified switch to perl for each test. This is not compatible with preload.',
    );

    option fail_on_resource_skip => (
        type          => 'Bool',
        default       => 0,
        long_examples => [''],
        description   => 'Treat resource-skipped tests as failures instead of skips. When enabled, tests that would be skipped due to unavailable resources will be marked as failing.',
    );

    option resource_timeout => (
        type           => 'Scalar',
        alt            => ['rt'],
        default        => 0,
        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Abort the test run if no tests have been able to start for SECONDS seconds while there are pending tests and none running. This is useful when a resource class is broken and always claims a resource will become available, preventing yath from ever finishing. (Default: 0, meaning no timeout)',
    );

    option event_timeout => (
        type           => 'Scalar',
        alt            => ['et'],
        default        => 60,
        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.',
    );

    option post_exit_timeout => (
        type           => 'Scalar',
        alt            => ['pet'],
        default        => 15,
        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness2 detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
    );

    option runner_id => (
        type        => 'Scalar',
        initialize  => \&gen_uuid,
        description => 'Runner ID (usually a generated uuid)',
    );
};

sub jobs_post_process ($options, $state) {
    my $settings = $state->{settings};

    my $runner = $settings->check_group('runner') ? $settings->runner : undef;
    return unless $runner;

    fix_job_resources($settings);

    $ENV{T2_HARNESS_MY_JOB_COUNT}           = $runner->job_count;
    $ENV{T2_HARNESS_MY_MAX_JOB_CONCURRENCY} = $runner->slots_per_job;
}

sub fix_job_resources ($settings) {
    my $runner = $settings->runner;

    my %found;
    for my $r (@{$runner->resources}) {
        require(mod2file($r));
        next unless $r->job_limiter;
        $found{$r}++;
    }

    unless (keys %found) {
        require Test2::Harness2::Runner::Resource::JobCount;
        unshift @{$runner->resources} => 'Test2::Harness2::Runner::Resource::JobCount';
    }

    $runner->create_option(job_count     => 1) if $runner && !$runner->job_count;
    $runner->create_option(slots_per_job => 1) if $runner && !$runner->slots_per_job;

    my $run_slots = $runner->job_count;
    my $job_slots = $runner->slots_per_job;

    die "The slots_per_job (set to $job_slots) must not be larger than the job_count (set to $run_slots).\n" if $job_slots > $run_slots;
}

sub cover_post_process ($options, $state) {
    my $settings = $state->{settings};

    my $runner = $settings->check_group('runner') ? $settings->runner : undef;
    return unless $runner;

    # T2_DEVEL_COVER is consumed via from_env_vars on the cover option; no env fallback needed here.
    return unless $runner->cover;

    # For nested things
    $ENV{T2_NO_FORK}     = 1;
    $ENV{T2_DEVEL_COVER} = $runner->cover;
    $runner->create_option(use_fork => 0);

    return unless $settings->check_group('run');

    # Maintain the '@' insertion-order key that Job.pm iterates over —
    # same pattern as Run.pm's dbi_profiling post and the load_import trigger.
    $settings->run->create_option(load_import => {}) unless defined $settings->run->load_import;
    my $load_import = $settings->run->load_import;
    unless ($load_import->{'Devel::Cover'}) {
        push @{$load_import->{'@'}} => 'Devel::Cover';
        $load_import->{'Devel::Cover'} = [split(/,/, $runner->cover)];
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
