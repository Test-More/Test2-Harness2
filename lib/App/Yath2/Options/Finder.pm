package App::Yath2::Options::Finder;
use v5.38;

our $VERSION = '2.000000';

use List::Util qw/first/;
use Test2::Harness2::Util qw/fqmod mod2file/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Finder - Finder options for Yath.

=head1 DESCRIPTION

This is where the command line options for discovering test files are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=cut

my %RERUN_MODES = (
    all     => "Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    failed  => "Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    retried => "Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    passed  => "Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    missed  => "Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
);

option_group {group => 'finder', category => "Finder Options"} => sub {

    # -------------------------------------------------------------------------
    # Finder class
    # -------------------------------------------------------------------------

    # mod_adds_options is NOT used here because live Finder subclasses may still
    # use the old App::Yath2::Options machinery whose options() returns a legacy
    # object that Getopt::Yath::Instance->include() cannot accept.  We guard
    # exactly like PreCommand.pm's plugins trigger: require the class, check
    # ->can('options'), and only call include() when the result is a
    # Getopt::Yath::Instance.
    option finder => (
        type    => 'Scalar',
        default => 'Test2::Harness2::Finder',

        long_examples => [' MyFinder', ' +Test2::Harness2::Finder::MyFinder'],
        description   => 'Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness2::Finder::XXX namespace is assumed.',

        normalize => sub ($val) { fqmod('Test2::Harness2::Finder', $val) },

        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            for my $class (@{$params{val}}) {
                my $file = mod2file($class);
                my $ok   = eval { require $file; 1 };
                my $err  = $@;
                die "Failed to load finder '$class': $err" unless $ok;

                next unless $class->can('options');
                my $finder_opts = $class->options;
                # Guard: only include if it is a Getopt::Yath::Instance.
                # Old-style finders return an App::Yath2::Options object which
                # cannot be passed to include().
                next unless ref($finder_opts) && $finder_opts->isa('Getopt::Yath::Instance');
                $params{options}->include($finder_opts);
            }
        },
    );

    # -------------------------------------------------------------------------
    # File extensions
    # -------------------------------------------------------------------------

    # Intentional rename: live 'extension' (field=extensions) -> 'extensions'.
    # Old singular spelling kept as alt.  split_on allows --extensions a,b form.
    option extensions => (
        type     => 'List',
        alt      => ['ext', 'extension'],
        split_on => ',',

        default => sub { 't', 't2' },

        description => 'Specify valid test filename extensions, default: t and t2',

        normalize => sub ($val) {
            $val =~ s/^\.+//g;
            $val;
        },
    );

    # -------------------------------------------------------------------------
    # Search paths
    # -------------------------------------------------------------------------

    option search => (
        type        => 'List',
        description => 'List of tests and test directories to use instead of the default search paths. Typically these can simply be listed as command line arguments without the --search prefix.',
    );

    # -------------------------------------------------------------------------
    # Duration filtering
    # -------------------------------------------------------------------------

    option no_long => (
        type        => 'Bool',
        description => "Do not run tests that have their duration flag set to 'LONG'",
    );

    option only_long => (
        type        => 'Bool',
        description => "Only run tests that have their duration flag set to 'LONG'",
    );

    # -------------------------------------------------------------------------
    # Changed-files options (not applicable for the projects command)
    # -------------------------------------------------------------------------

    option show_changed_files => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        description => "Print a list of changed files if any are found",
    );

    option changed_only => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        description => "Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())",
    );

    option changed => (
        type          => 'List',
        applicable    => \&changes_applicable,
        description   => "Specify one or more files as having been changed.",
        long_examples => [' path/to/file'],
    );

    # Intentional renames: singular -> plural (singular kept as alt).
    option changes_exclude_files => (
        type          => 'List',
        alt           => ['changes-exclude-file'],
        applicable    => \&changes_applicable,
        description   => 'Specify one or more files to ignore when looking at changes',
        long_examples => [' path/to/file'],
    );

    option changes_exclude_patterns => (
        type          => 'List',
        alt           => ['changes-exclude-pattern'],
        applicable    => \&changes_applicable,
        description   => 'Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
    );

    option changes_filter_files => (
        type          => 'List',
        alt           => ['changes-filter-file'],
        applicable    => \&changes_applicable,
        description   => 'Specify one or more files to check for changes. Changes to other files will be ignored',
        long_examples => [' path/to/file'],
    );

    option changes_filter_patterns => (
        type          => 'List',
        alt           => ['changes-filter-pattern'],
        applicable    => \&changes_applicable,
        description   => 'Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
    );

    option changes_diff => (
        type          => 'Scalar',
        applicable    => \&changes_applicable,
        description   => "Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`",
        long_examples => [' path/to/diff.diff'],
    );

    option changes_plugin => (
        type          => 'Scalar',
        applicable    => \&changes_applicable,
        description   => "What plugin should be used to detect changed files.",
        long_examples => [' Git', ' +App::Yath2::Plugin::Git'],
    );

    option changes_include_whitespace => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        default     => 0,
        description => "Include changed lines that are whitespace only (default: off)",
    );

    option changes_exclude_nonsub => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        default     => 0,
        description => "Exclude changes outside of subroutines (perl files only) (default: off)",
    );

    option changes_exclude_loads => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        default     => 0,
        description => "Exclude coverage tests which only load changed files, but never call code from them. (default: off)",
    );

    option changes_exclude_opens => (
        type        => 'Bool',
        applicable  => \&changes_applicable,
        default     => 0,
        description => "Exclude coverage tests which only open() changed files, but never call code from them. (default: off)",
    );

    # -------------------------------------------------------------------------
    # Rerun options
    # -------------------------------------------------------------------------

    option rerun => (
        type          => 'Auto',
        description   => "Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
        long_examples => ['', '=path/to/log.jsonl', '=plugin_specific_string'],

        # Live autofill semantics: find the most recent log file.
        autofill => sub {
            my $log = first { -e $_ } qw{./lastlog.jsonl ./lastlog.jsonl.bz2 ./lastlog.jsonl.gz};
            return $log // -1;
        },
    );

    # Intentional rename: rerun_plugin -> rerun_plugins (singular kept as alt).
    option rerun_plugins => (
        type          => 'List',
        alt           => ['rerun-plugin'],
        description   => "What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used to set an order of priority)",
        long_examples => [' Foo', ' +App::Yath2::Plugin::Foo'],
    );

    # BoolMap replaces the live rerun_modes (List) + five generated rerun_all/
    # failed/retried/passed/missed (Auto) options.  CLI flags --rerun-failed,
    # --rerun-failed=log.jsonl, --no-rerun-failed etc. all work via the pattern.
    #
    # BoolMap->pattern() wraps the stored raw pattern as:
    #   qr/^--(no-)?rerun-($modes)(=.+)?$/
    # custom_matches captures: $1=no-, $2=mode, $3==path
    my $modes = join '|' => sort keys %RERUN_MODES;
    option rerun_modes => (
        type => 'BoolMap',

        # Default: all modes enabled.
        default => sub { all => 1 },

        # Raw pattern stored; BoolMap->pattern() prepends ^--(no-)? and appends $
        pattern => qr/rerun-($modes)(=.+)?/,

        long_examples => [' ' . join(',', sort keys %RERUN_MODES)],

        # Space form `--rerun-modes failed` requires an argument; the
        # custom_matches --rerun-MODE forms never consult requires_arg, so 1
        # is safe for both paths.
        requires_arg => 1,

        normalize => sub {
            # When called from the BoolMap custom_matches path, normalize
            # receives ($key, $bool) where $bool is always defined — already
            # valid; pass through as-is.
            # Note: defined-pair = custom_matches --rerun-MODE path.
            #       Single-arg or undef-second-arg = --rerun-modes=LIST form
            #       that must split and validate.
            return @_ if @_ > 1 && defined $_[1];
            # Called from --rerun-modes=LIST form: validate and expand.
            my ($val) = @_;
            map { die "'$_' is not a valid rerun mode\n" unless $RERUN_MODES{$_}; $_ => 1 }
                split /[\s,]+/, $val;
        },

        description => join(
            " " => "Pick which test categories to re-run.",
            map { sprintf("%-8s %s", "$_:", $RERUN_MODES{$_}) } sort keys %RERUN_MODES
        ),

        # Trigger: when a mode is selected via --rerun-MODE, also activate the
        # rerun option (set to 1) if it hasn't been set to a path yet.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            $params{settings}->finder->rerun(1)
                unless $params{settings}->finder->rerun;
        },

        # custom_matches: handles --rerun-MODE and --rerun-MODE=path.
        # BoolMap->custom_matches() calls this as:
        #   $self->{+CUSTOM_MATCHES}->($self, $input, $state)
        custom_matches => sub ($opt, $input, $state) {
            my $pattern = $opt->pattern;
            return unless $input =~ $pattern;

            my ($no, $key, $val) = ($1, $2, $3);

            if (defined $val) {
                $val =~ s/^=//;
                $state->{settings}->finder->rerun($val);
            }

            return ($opt, 1, [$key => $no ? 0 : 1]);
        },

        notes => "This will turn on the 'rerun' option. If the --rerun-MODE form is used, you can specify the log file with --rerun-MODE=logfile.",
    );

    # -------------------------------------------------------------------------
    # Durations
    # -------------------------------------------------------------------------

    option durations => (
        type => 'Scalar',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option maybe_durations => (
        type => 'Scalar',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option durations_threshold => (
        type        => 'Scalar',
        alt         => ['Dt'],
        default     => undef,
        description => "Only fetch duration data if running at least this number of tests. Default (-j value + 1)",
    );

    # -------------------------------------------------------------------------
    # Exclusions
    # -------------------------------------------------------------------------

    # Intentional renames: singular -> plural (singular kept as alt).
    option exclude_files => (
        type => 'List',
        alt  => ['exclude-file'],

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a file from testing",
    );

    option exclude_patterns => (
        type => 'List',
        alt  => ['exclude-pattern'],

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a pattern from testing, matched using m/\$PATTERN/",
    );

    option exclude_lists => (
        type => 'List',
        alt  => ['exclude-list'],

        long_examples  => [' file.txt', ' http://example.com/exclusions.txt'],
        short_examples => [' file.txt', ' http://example.com/exclusions.txt'],

        description => "Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).",
    );

    # -------------------------------------------------------------------------
    # Default search paths
    # -------------------------------------------------------------------------

    option default_search => (
        type        => 'List',
        description => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",
    );

    option default_at_search => (
        type        => 'List',
        description => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",
    );

    option_post_process 0 => \&_post_process;
};

sub changes_applicable ($opt, $options, $settings) {
    return 1 unless $settings && $settings->check_group('harness') && $settings->harness->check_option('command');
    my $cmd = $settings->harness->command;
    return 0 if $cmd && $cmd->isa('App::Yath2::Command::projects');
    return 1;
}

sub _post_process ($options, $state) {
    my $settings = $state->{settings};
    my $finder   = $settings->finder;

    # ---- rerun_modes BoolMap fold ----
    # rerun_modes is now a hashref of mode => bool.
    # Validate all keys present (including any false/negated entries) before
    # filtering, so invalid mode names are caught rather than silently dropped.
    my $modes_href = $finder->rerun_modes // {};
    for my $m (keys %$modes_href) {
        die "'$m' is not a valid rerun mode\n" unless $RERUN_MODES{$m};
    }
    my @keep = grep { $modes_href->{$_} } sort keys %RERUN_MODES;
    push @keep, 'all' unless @keep;

    # Rebuild the hashref: only truthy entries for active modes.
    %{$modes_href} = map { $_ => 1 } @keep;

    # ---- durations_threshold: live j+1 semantics ----
    if (!defined($finder->durations_threshold)) {
        if ($settings->check_group('runner')) {
            my $jc = $settings->runner->job_count // 1;
            $finder->durations_threshold($jc + 1);
        }
        else {
            $finder->durations_threshold(1);
        }
    }

    # ---- default search paths ----
    $finder->default_search(['./t', './t2', 'test.pl'])
        unless $finder->default_search && @{$finder->default_search};

    $finder->default_at_search(['./xt'])
        unless $finder->default_at_search && @{$finder->default_at_search};

    # ---- extension leading-dot strip ----
    # Inline default handles 't','t2' already; strip dots from any user-supplied
    # extensions (matching live post behaviour).
    s/^\.//g for @{$finder->extensions // []};
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
