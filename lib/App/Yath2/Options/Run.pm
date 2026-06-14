package App::Yath2::Options::Run;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Run - Run options for Yath.

=head1 DESCRIPTION

This is where command line options for a single test run are defined.

=head1 PROVIDED OPTIONS

=head3 Run Options

=over 4

=item -A

=item --author-testing

=item --no-author-testing

This will set the AUTHOR_TESTING environment to true

Can also be set with the following environment variables: C<AUTHOR_TESTING>

The following environment variables will be set after arguments are processed: C<AUTHOR_TESTING>


=item --dbi-profiling

=item --no-dbi-profiling

Use Test2::Plugin::DBIProfile to collect database profiling data


=item -EVAR=VAL

=item -E VAR=VAL

=item --env-var VAR=VAL

=item --no-env-var

Set environment variables to set when each test is run.

Note: Can be specified multiple times


=item --uuids

=item --event-uuids

=item --no-event-uuids

Use Test2::Plugin::UUID inside tests (default: on)


=item -f JSON_STRING

=item -f name:details

=item --fields JSON_STRING

=item --fields name:details

=item --no-fields

Add custom data to the harness run

Note: Can be specified multiple times


=item --input ARG

=item --input=ARG

=item --no-input

Input string to be used as standard input for ALL tests. See also: --input-file


=item --input-file ARG

=item --input-file=ARG

=item --no-input-file

Use the specified file as standard input to ALL tests


=item --io-events

=item --no-io-events

Use Test2::Plugin::IOEvents inside tests to turn all prints into test2 events (default: off)


=item --link 'https://jenkins.work/job/42'

=item --link 'https://travis.work/builds/42'

=item --link 'https://buildbot.work/builders/foo/builds/42'

=item --no-link

Provide one or more links people can follow to see more about this run.

Note: Can be specified multiple times


=item -m ARG

=item -m=ARG

=item -m '["json","list"]'

=item -m='["json","list"]'

=item --load ARG

=item --load=ARG

=item --load-module ARG

=item --load-module=ARG

=item --load '["json","list"]'

=item --load='["json","list"]'

=item --load-module '["json","list"]'

=item --load-module='["json","list"]'

=item --no-load

Load a module in each test (after fork). The "import" method is not called.

Note: Can be specified multiple times


=item -M Module

=item -M Module=import_arg1,arg2,...

=item --loadim Module

=item --load-import Module

=item --loadim Module=import_arg1,arg2,...

=item --load-import Module=import_arg1,arg2,...

=item --no-load-import

Load a module in each test (after fork). Import is called.

Note: Can be specified multiple times


=item --mem-usage

=item --no-mem-usage

Use Test2::Plugin::MemUsage inside tests (default: on)


=item -rARG

=item -r ARG

=item -r=ARG

=item --retry ARG

=item --retry=ARG

=item --no-retry

Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!


=item --retry-iso

=item --retry-isolated

=item --no-retry-isolated

If true then any job retries will be done in isolation (as though -j1 was set)


=item --id ARG

=item --id=ARG

=item --run-id ARG

=item --run-id=ARG

=item --no-run-id

Set a specific run-id. (Default: a UUID)


=item --stream

=item --use-stream

=item --no-stream

=item --TAP

The TAP format is lossy and clunky. Test2::Harness2 normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.


=item --test-args ARG

=item --test-args=ARG

=item --test-args '["json","list"]'

=item --test-args='["json","list"]'

=item --no-test-args

Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the '::'  argument separator.

Note: Can be specified multiple times


=back


=cut

option_group {group => 'run', category => "Run Options"} => sub {

    # -------------------------------------------------------------------------
    # Links / metadata
    # -------------------------------------------------------------------------

    option link => (
        field         => 'links',
        type          => 'List',
        long_examples => [
            " 'https://travis.work/builds/42'",
            " 'https://jenkins.work/job/42'",
            " 'https://buildbot.work/builders/foo/builds/42'",
        ],
        description => "Provide one or more links people can follow to see more about this run.",
    );

    option fields => (
        type           => 'List',
        short          => 'f',
        long_examples  => [' name:details', ' JSON_STRING'],
        short_examples => [' name:details', ' JSON_STRING'],
        description    => "Add custom data to the harness run",

        # Reshaping input into {name => ..., details => ...} structs is
        # normalize's job (value is already normalised before storage).
        normalize => sub ($raw) {
            if ($raw =~ m/^\s*\{/) {
                my $field;
                my $ok  = eval { $field = decode_json($raw); 1 };
                my $err = $@;
                die "Invalid JSON in fields option '$raw': $err\n"         unless $ok;
                die "Fields must have a 'name' key (error in '$raw')\n"    unless $field->{name};
                die "Fields must have a 'details' key (error in '$raw')\n" unless $field->{details};
                return $field;
            }

            if ($raw =~ m/([^:]+):([^:]+)/) {
                return {name => $1, details => $2};
            }

            die "'$raw' is not a valid field specification.\n";
        },
    );

    option run_id => (
        type        => 'Scalar',
        alt         => ['id'],
        initialize  => \&gen_uuid,
        description => 'Set a specific run-id. (Default: a UUID)',
    );

    # -------------------------------------------------------------------------
    # Stdin / input
    # -------------------------------------------------------------------------

    option input => (
        type        => 'Scalar',
        description => 'Input string to be used as standard input for ALL tests. See also: --input-file',
    );

    option input_file => (
        type        => 'Scalar',
        description => 'Use the specified file as standard input to ALL tests',

        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            my ($file) = @{$params{val}};
            die "Input file not found: $file\n" unless -f $file;

            my $settings = $params{settings};
            if ($settings->run->input) {
                warn "Input file is overriding another source of input.\n";
                $settings->run->option(input => undef);
            }
        },
    );

    # -------------------------------------------------------------------------
    # Stream / TAP
    # -------------------------------------------------------------------------

    # Accepted forms: --stream / --use-stream (enable) and
    # --no-stream / --no-use-stream / --TAP (disable).
    # Note: --TAP is a disable-form only; there is no --no-TAP.
    option use_stream => (
        name        => 'stream',
        type        => 'Bool',
        default     => 1,
        alt         => ['use-stream'],
        alt_no      => ['TAP'],
        description => "The TAP format is lossy and clunky. Test2::Harness2 normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.",
    );

    # -------------------------------------------------------------------------
    # Environment variables passed to each test
    # -------------------------------------------------------------------------

    option env_var => (
        field          => 'env_vars',
        type           => 'Map',
        short          => 'E',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables to set when each test is run.',
    );

    # -------------------------------------------------------------------------
    # Modules loaded in each test
    # -------------------------------------------------------------------------

    option load => (
        type        => 'List',
        short       => 'm',
        alt         => ['load-module'],
        description => 'Load a module in each test (after fork). The "import" method is not called.',
    );

    option load_import => (
        type  => 'Map',
        short => 'M',
        alt   => ['loadim'],

        long_examples  => [' Module', ' Module=import_arg1,arg2,...'],
        short_examples => [' Module', ' Module=import_arg1,arg2,...'],

        description => 'Load a module in each test (after fork). Import is called.',

        # Normalize: split the import-args portion on commas to produce an
        # arrayref of import arguments (e.g. "Mod=a,b" → Mod => ['a','b']).
        normalize => sub ($mod, $args = undef) {
            $mod => [defined($args) ? split(/,/, $args) : ()];
        },

        # Maintain the insertion-ordered '@' key that Job.pm iterates over.
        # $params{ref} is a scalar-ref to the hashref (same as Display.pm renderers).
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            my $ref = $params{ref};
            $$ref //= {};

            # val is a flat (key, val, key, val, ...) list -- one pair per -M for
            # CLI use, but multiple pairs for a single JSON-hashref invocation.
            # Walk every pair so all modules land in the insertion-ordered '@'.
            my @val = @{$params{val}};
            while (my ($mod, $mod_args) = splice(@val, 0, 2)) {
                # Trigger fires before the class key is stored, so 'exists' is false exactly on first insertion.
                push @{$$ref->{'@'}} => $mod unless exists $$ref->{$mod};
            }
        },
    );

    # -------------------------------------------------------------------------
    # Test plugins
    # -------------------------------------------------------------------------

    option event_uuids => (
        type        => 'Bool',
        default     => 1,
        alt         => ['uuids'],
        description => 'Use Test2::Plugin::UUID inside tests (default: on)',
    );

    option mem_usage => (
        type        => 'Bool',
        default     => 1,
        description => 'Use Test2::Plugin::MemUsage inside tests (default: on)',
    );

    option io_events => (
        type        => 'Bool',
        default     => 0,
        description => 'Use Test2::Plugin::IOEvents inside tests to turn all prints into test2 events (default: off)',
    );

    # -------------------------------------------------------------------------
    # Retry
    # -------------------------------------------------------------------------

    option retry => (
        type        => 'Scalar',
        short       => 'r',
        default     => 0,
        description => 'Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!',
    );

    option retry_isolated => (
        type        => 'Bool',
        default     => 0,
        alt         => ['retry-iso'],
        description => 'If true then any job retries will be done in isolation (as though -j1 was set)',
    );

    # -------------------------------------------------------------------------
    # @ARGV for tests
    # -------------------------------------------------------------------------

    option test_args => (
        type        => 'List',
        description => 'Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the \'::\'  argument separator.',
    );

    # -------------------------------------------------------------------------
    # Author / DBI profiling
    # -------------------------------------------------------------------------

    option author_testing => (
        type          => 'Bool',
        short         => 'A',
        set_env_vars  => ['AUTHOR_TESTING'],
        from_env_vars => ['AUTHOR_TESTING'],
        description   => 'This will set the AUTHOR_TESTING environment to true',

        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            # set_env_vars covers the harness process; this stamps run->env_vars so Job.pm passes it to each test child.
            $params{settings}->run->env_vars->{AUTHOR_TESTING} = 1;
        },
    );

    option dbi_profiling => (
        type        => 'Bool',
        description => "Use Test2::Plugin::DBIProfile to collect database profiling data",
    );
};

option_post_process 0 => sub ($options, $state) {
    my $settings = $state->{settings};

    if ($settings->run->dbi_profiling) {
        my $ok  = eval { require Test2::Plugin::DBIProfile; 1 };
        my $err = $@;
        die "Could not enable DBI profiling, could not load 'Test2::Plugin::DBIProfile': $err" unless $ok;

        # Vivify load_import if nothing was set on the CLI yet.
        $settings->run->create_option(load_import => {}) unless defined $settings->run->load_import;
        my $load_import = $settings->run->load_import;
        unless ($load_import->{'Test2::Plugin::DBIProfile'}) {
            push @{$load_import->{'@'}} => 'Test2::Plugin::DBIProfile';
            $load_import->{'Test2::Plugin::DBIProfile'} = [];
        }
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
