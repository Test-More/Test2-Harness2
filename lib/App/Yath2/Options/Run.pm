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

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

            my $mod = $params{val}->[0];
            my $ref = $params{ref};
            $$ref //= {};
            # Trigger fires before the class key is stored, so 'exists' is false exactly on first insertion.
            push @{$$ref->{'@'}} => $mod unless exists $$ref->{$mod};
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
