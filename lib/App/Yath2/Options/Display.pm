package App::Yath2::Options::Display;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util qw/mod2file/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Display - Display options for Yath.

=head1 DESCRIPTION

This is where display options are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=cut

option_group {group => 'display', category => "Display Options"} => sub {
    option color => (
        type          => 'Bool',
        description   => "Turn color on, default is true if STDOUT is a TTY.",
        default       => sub { -t STDOUT ? 1 : 0 },
        from_env_vars => ['YATH_COLOR', 'CLICOLOR_FORCE'],
        set_env_vars  => ['YATH_COLOR'],
    );

    option quiet => (
        type        => 'Count',
        short       => 'q',
        description => "Be very quiet.",
        initialize  => 0,
    );

    option verbose => (
        type        => 'Count',
        short       => 'v',
        description => "Be more verbose",
        initialize  => 0,
    );

    option no_wrap => (
        type        => 'Bool',
        description => "Do not do fancy text-wrapping, let the terminal handle it",
        default     => 0,
    );

    option no_final_table => (
        type        => 'Bool',
        description => "When printing final results, don't use table-style display",
        default     => 0,
    );

    option show_times => (
        type        => 'Bool',
        short       => 'T',
        description => 'Show the timing data for each job',
    );

    option hide_runner_output => (
        type        => 'Bool',
        description => 'Hide output from the runner, showing only test output. (See Also truncate_runner_output)',
        default     => 0,
    );

    option truncate_runner_output => (
        type        => 'Bool',
        description => 'Only show runner output that was generated after the current command. This is only useful with a persistent runner.',
        default     => 0,
    );

    option term_width => (
        type          => 'Scalar',
        alt           => ['term-size'],
        description   => 'Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.',
        long_examples => [' 80', ' 200'],
        from_env_vars => ['TABLE_TERM_SIZE'],
        set_env_vars  => ['TABLE_TERM_SIZE'],
    );

    option progress => (
        type        => 'Bool',
        default     => sub { -t STDOUT ? 1 : 0 },
        description => "Toggle progress indicators. On by default if STDOUT is a TTY. You can use --no-progress to disable the 'events seen' counter and buffered event pre-display",
    );

    option renderers => (
        type           => 'Map',
        alt            => ['renderer'],
        description    => 'Specify renderers, (Default: "Formatter=Test2"). Use "+" to give a fully qualified module name. Without "+" "Test2::Harness2::Renderer::" will be prepended to your argument.',
        long_examples  => [' +My::Renderer', ' Renderer=arg1,arg2,...'],
        short_examples => [' +My::Renderer', ' Renderer=arg1,arg2,...'],
        normalize      => sub ($class, $args = undef) {
            $class = "Test2::Harness2::Renderer::$class"
                unless $class =~ s/^\+//;

            my $file = mod2file($class);
            my $ok   = eval { require $file; 1 };
            warn "Failed to load renderer '$class': $@" unless $ok;

            return ($class, [split(',', $args // '')]);
        },
        trigger => sub ($self, %args) {
            return unless $args{action} eq 'set';
            my $ref = $args{ref};
            my ($class) = @{$args{val}};
            $$ref //= {};
            # Maintain legacy '@' key: insertion-ordered class list consumed by
            # Command/test.pm. Trigger fires before the class key is stored, so
            # 'exists' is false exactly on first insertion.
            push @{$$ref->{'@'}} => $class unless exists $$ref->{$class};
        },
    );
};

option_group {group => 'formatter', category => "Formatter Options"} => sub {
    option formatter => (
        type        => 'Scalar',
        description => 'Specify the formatter to use. (Default: "Test2", or "QVF" if --qvf is set)',
    );

    option qvf => (
        type        => 'Bool',
        description => '[Q]uiet, but [V]erbose on [F]ailure. Hide all output from tests when they pass, except to say they passed. If a test fails then ALL output from the test is verbosely output.',
    );

    option show_job_end => (
        type        => 'Bool',
        description => 'Show output when a job ends. (Default: on)',
        default     => 1,
    );

    option show_job_info => (
        type        => 'Bool',
        description => 'Show the job configuration when a job starts. (Default: off, unless -vv)',
        default     => 0,
    );

    option show_job_launch => (
        type        => 'Bool',
        description => "Show output for the start of a job. (Default: off unless -v)",
        default     => 0,
    );

    option show_run_info => (
        type        => 'Bool',
        description => 'Show the run configuration when a run starts. (Default: off, unless -vv)',
        default     => 0,
    );
};

option_post_process 100 => sub ($options, $state) {
    my $settings = $state->{settings};

    my $display = $settings->display;
    $display->create_option(renderers => {}) unless defined $display->renderers;
    my $renderers = $display->renderers;

    my $quiet   = $display->quiet;
    my $verbose = $display->verbose;

    die "The 'quiet' and 'verbose' options may not be used together.\n"
        if $verbose && $quiet;

    if ($quiet) {
        delete $renderers->{'Test2::Harness2::Renderer::Formatter'};
        @{$renderers->{'@'}} = grep { $_ ne 'Test2::Harness2::Renderer::Formatter' } @{$renderers->{'@'} // []};
        return;
    }

    my @args = map { $_ => $settings->formatter->$_ } qw{
            formatter
            show_run_info
            show_job_info
            show_job_launch
            show_job_end
        };

    push @args => map { $_ => $settings->display->$_ } qw{
            progress
            color
            quiet
            verbose
            show_times
        };

    if (my $formatter_args = $renderers->{'Test2::Harness2::Renderer::Formatter'}) {
        @$formatter_args = @args unless @$formatter_args;
        return;
    }

    return if $renderers->{'@'} && @{$renderers->{'@'}};

    push @{$renderers->{'@'}} => 'Test2::Harness2::Renderer::Formatter';
    $renderers->{'Test2::Harness2::Renderer::Formatter'} = \@args;
};

option_post_process 90 => sub ($options, $state) {
    my $settings = $state->{settings};

    $settings->formatter->create_option(formatter => $settings->formatter->qvf ? 'QVF' : 'Test2')
        unless defined $settings->formatter->formatter;

    $settings->formatter->create_option(show_job_launch => 1)
        if $settings->display->verbose > 0;

    if ($settings->display->verbose > 1) {
        $settings->formatter->create_option(show_job_info => 1);
        $settings->formatter->create_option(show_run_info => 1);
    }
};

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
