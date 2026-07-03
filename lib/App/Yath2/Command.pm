package App::Yath2::Command;
use v5.38;

our $VERSION = '2.000000';

use File::Spec;
use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use List::Util qw/max/;
use Test2::Harness2::Util qw/mod2file/;
use Test2::Util::Table qw/table/;
use Test2::Harness2::Util::Term qw/USE_ANSI_COLOR/;

use Test2::Harness2::Util::HashBase qw/-settings -args +renderers <final_data <tests_seen <asserts_seen/;

use Test2::Harness2::Util::File::JSON();

sub internal_only   { 0 }
sub always_keep_dir { 0 }
sub summary         { "No Summary" }
sub description     { "No Description" }
sub group           { "Z-UNFINISHED" }
sub cli_args        { '' }

# Bridge cli_args (a single usage string) into the doc-generator interface.
# Commands that need structured [name => text] argument docs may override
# doc_args directly; cli_help/generate_pod render either form.
sub doc_args {
    my $args = $_[0]->cli_args;
    return length($args) ? ($args) : ();
}

# Commands that provide options override this to return a
# Getopt::Yath::Instance.
sub options { undef }

sub name { $_[0] =~ m/([^:=]+)(?:=.*)?$/; $1 || $_[0] }

sub run {
    my $self = shift;

    warn "This command is currently empty";

    return 1;
}

sub _options_for_docs ($class, $settings = undef) {
    require App::Yath2;
    my $app = App::Yath2->new($settings ? (settings => $settings) : ());

    my $options = $app->options;

    # Only include the command's options when options() hands back a
    # Getopt::Yath::Instance; skip anything else as a safety check.
    if ($class->can('options')) {
        my $add = $class->options;
        $options->include($add) if blessed($add) && $add->isa('Getopt::Yath::Instance');
    }

    return $options;
}

sub cli_help {
    my $class  = shift;
    my %params = @_;

    my $settings = $params{settings};
    my $script   = ($settings ? $settings->maybe(harness => 'script') : undef) // $0;

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options = $params{options} // $class->_options_for_docs($settings);

    my $opt_docs = $options ? $options->docs('cli', settings => $settings) : '';

    my $usage = "Usage: $script [YATH OPTIONS] $cmd";

    my @out;

    if ($opt_docs) {
        $usage .= ' [OPTIONS]';

        $opt_docs =~ s/^/  /mg;
        push @out => "[OPTIONS]\n$opt_docs";
    }

    if (@args) {
        $usage .= " [COMMAND ARGUMENTS]";

        my @desc;
        for my $arg (@args) {
            if (ref($arg)) {
                my ($name, $text) = @$arg;
                push @desc => $name;
                $text =~ s/^/  /mg;
                push @desc => "$text\n";
            }
            else {
                push @desc => "$arg\n";
            }
        }

        my $desc = join "\n" => @desc;
        $desc =~ s/^/  /mg;

        push @out => "[COMMAND ARGUMENTS]\n$desc";
    }

    chomp(my $desc = $class->description);
    unshift @out => ("$cmd - " . $class->summary, $desc, $usage);

    return join("\n\n" => grep { $_ } @out) . "\n";
}

sub generate_pod {
    my $class = shift;

    my $cmd = $class->name;
    my (@args) = $class->doc_args;

    my $options  = $class->_options_for_docs();
    my $opt_docs = $options ? $options->docs('pod', head => 3, applicable => 1) : '';

    my $usage = "    \$ yath [YATH OPTIONS] $cmd";

    my @head2s;

    if ($opt_docs) {
        $usage .= " [OPTIONS]";
        push @head2s => ("=head2 OPTIONS", $opt_docs);
    }

    if (@args) {
        $usage .= " [COMMAND ARGUMENTS]";

        push @head2s => (
            "=head2 COMMAND ARGUMENTS",
            "=over 4",
            (map { ref($_) ? ("=item $_->[0]", $_->[1]) : ("=item $_") } @args),
            "=back"
        );
    }

    my @out = (
        "=head1 NAME",
        "$class - " . $class->summary,
        "=head1 DESCRIPTION",
        $class->description,
        "=head1 USAGE",
        $usage,
        @head2s
    );

    return join("\n\n" => grep { $_ } @out);
}

sub write_settings_to {
    my $self = shift;
    my ($dir, $file) = @_;

    croak "'directory' is a required parameter" unless $dir;
    croak "'filename' is a required parameter"  unless $file;

    my $settings      = $self->settings;
    my $settings_file = Test2::Harness2::Util::File::JSON->new(name => File::Spec->catfile($dir, $file));
    $settings_file->write($settings->TO_JSON);
    return $settings_file->name;
}

# Whether runner/stage output should be shown (the inverse of --hide-runner-output),
# defaulting to shown when the display option group is absent. Shared by the
# test/watch/stop render setup. NOTE: this is deliberately NOT defaulted in
# Renderer::Base::init -- stop uses the value to decide whether to build a renderer
# at all, so the derivation stays command-side.
sub show_runner_output {
    my $self     = shift;
    my $settings = $self->settings;

    return 1 unless $settings->check_group('display');
    return $settings->display->hide_runner_output ? 0 : 1;
}

sub setup_resources {
    my $self     = shift;
    my $settings = $self->settings;

    return unless $settings->check_group('runner');
    my $runner = $settings->runner;
    my $res    = $runner->resources or return;
    return unless @$res;

    for my $res (@$res) {
        require(mod2file($res)) unless ref $res;
        $res->setup($settings);
    }
}

sub finalize_plugins {
    my $self = shift;
    $_->finalize($self->settings) for @{$self->settings->harness->plugins};
}

# Build (and memoize) the renderer instances from the display->renderers option.
# Shared by the test/run/watch/replay render paths (each is only ever called
# where a 'display' option group exists). command_class => ref($self) tells a
# renderer which command it is serving.
sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->{+SETTINGS};

    my @renderers;
    for my $class (@{$settings->display->renderers->{'@'}}) {
        require(mod2file($class));
        my $args     = $settings->display->renderers->{$class};
        my $renderer = $class->new(@$args, settings => $settings, command_class => ref($self));
        push @renderers => $renderer;
    }

    # Default-on terminal-reset renderer: when STDOUT is a TTY, append it LAST so
    # its finish() (terminal reset) runs after every other renderer has flushed.
    # No-op render_event; only the finish()/END reset matters. Rely on list order
    # (no renderer weight sorting). Skipped entirely when not a TTY.
    if (-t STDOUT) {
        my $class = 'App::Yath2::Renderer::ResetTerm';
        require(mod2file($class));
        push @renderers => $class->new(settings => $settings, command_class => ref($self));
    }

    return $self->{+RENDERERS} = \@renderers;
}

sub render_summary {
    my $self = shift;
    my ($pass, $time_data, $cpu_usage) = @_;

    return if $self->settings->display->quiet > 1;

    my $final_data = $self->{+FINAL_DATA};
    my $failures   = @{$final_data->{failed} // []};

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $self->{+TESTS_SEEN}",
        "Assertion Count: $self->{+ASSERTS_SEEN}",
        $time_data
        ? (
            sprintf("      Wall Time: %.2f seconds",                                                       $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%",                                                               $cpu_usage),
            )
        : (),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->settings->display->color && USE_ANSI_COLOR) {
        my $color = $pass ? Term::ANSIColor::color('bold bright_green') : Term::ANSIColor::color('bold bright_red');
        my $reset = Term::ANSIColor::color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

# Section specs shared by the table and plain final-data renderers. Each entry
# names the final_data key + banner, the table header, and the plain-mode field
# list ([label => row-index, $skip_falsy] pairs, filename-first). 'failed' also
# carries a per-row table transform (stringify the subtest map into one cell) +
# collapse, and a subtest_index so plain mode can emit the map as a nested list.
my @FINAL_DATA_SECTIONS = (
    {
        key    => 'retried',
        banner => 'The following jobs failed at least once:',
        header => ['Job ID', 'Times Run', 'Test File', 'Succeeded Eventually?'],
        plain  => [[filename => 2], [job_id => 0], [times_run => 1], [succeeded_eventually => 3]],
    },
    {
        key           => 'failed',
        banner        => 'The following jobs failed:',
        header        => ['Job ID', 'Test File', 'Subtests'],
        collapse      => 1,
        table_row     => sub { my $r = [@{$_[0]}]; $r->[2] = stringify_subtest_map($r->[2]) if $r->[2]; $r },
        plain         => [[filename => 1], [job_id => 0]],
        subtest_index => 2,
    },
    {
        key    => 'halted',
        banner => 'The following jobs requested all testing be halted:',
        header => ['Job ID', 'Test File', 'Reason'],
        plain  => [[filename => 1], [job_id => 0], [reason => 2, 1]],
    },
    {
        key    => 'unseen',
        banner => 'The following jobs never ran:',
        header => ['Job ID', 'Test File'],
        plain  => [[filename => 1], [job_id => 0]],
    },
);

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->settings->display->quiet > 1;

    my $plain = $self->settings->display->no_final_table;

    for my $sec (@FINAL_DATA_SECTIONS) {
        my $rows = $final_data->{$sec->{key}} or next;
        print "\n$sec->{banner}\n";

        if ($plain) {
            $self->_render_section_plainly($sec, $rows);
            next;
        }

        my @trows = $sec->{table_row} ? map { $sec->{table_row}->($_) } @$rows : @$rows;
        print join "\n" => table(
            ($sec->{collapse} ? (collapse => 1) : ()),
            header => $sec->{header},
            rows   => \@trows,
        );
        print "\n";
    }
}

sub _render_section_plainly {
    my $self = shift;
    my ($sec, $rows) = @_;

    for my $row (@$rows) {
        my $first = 1;
        for my $field (@{$sec->{plain}}) {
            my ($label, $idx, $skip_falsy) = @$field;
            my $val = $row->[$idx];
            next if $skip_falsy && !$val;
            print $first ? "- $label: $val\n" : "  $label: $val\n";
            $first = 0;
        }

        next unless defined $sec->{subtest_index};
        my $map = $row->[$sec->{subtest_index}] or next;
        print "  subtests:\n";
        print "  - $_\n" for _subtest_paths($map);
    }
}

sub _subtest_paths {
    my ($map) = @_;

    my @paths;
    my @todo = @$map;
    my @state;
    while (my $st = shift @todo) {
        if (!ref($st)) {
            pop @state if $st eq 'pop';
            next;
        }
        push @state, $st->[0];
        push @paths, join(' -> ', @state);
        unshift @todo, (@{$st->[1]}, 'pop');
    }

    return @paths;
}

sub stringify_subtest_map {
    my ($map) = @_;

    # An empty map yields "" (no trailing newline); a non-empty one is the paths
    # joined by newlines plus a trailing newline.
    my @paths = _subtest_paths($map);
    return "" unless @paths;
    return join("\n", @paths) . "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command - Base class for yath commands

=head1 DESCRIPTION

This is the base class for any/all yath commands. If you wish to add a new yath
command you should subclass this package.

=head1 SYNOPSIS

    package App::Yath2::Command::mycommand;
    use strict;
    use warnings;

    use Getopt::Yath;
    use parent 'App::Yath2::Command';

    # Add some custom options. The 'options' method this generates returns
    # a Getopt::Yath::Instance which yath will include when the command is
    # loaded.
    option_group {group => 'mycommand', category => 'mycommand options'} => sub {
        option foo => (
            type        => 'Bool',
            description => "the foo option",
            default     => 0,
        );
    };

    # This is used to sort/group commands in the "yath help" output
    sub group { 'thirdparty' }

    # Brief 1-line summary
    sub summary { "This is a third party command, it does stuff..." }

    # Longer description of the command (used in yath help mycommand)
    sub description {
        return <<"    EOT";
    This command does:
    This
    That
    Those
        EOT
    }

    # Entrypoint
    sub run {
        my $self = shift;

        my $settings = $self->settings;
        my $args     = $self->args;

        print "Hello Third Party!\n"

        # Return an exit value.
        return 0;
    }

=head1 CLASS METHODS

=over 4

=item $string = $cmd_class->cli_help(settings => $settings, options => $options)

This method generates the command line help for any given command. In general
you will NOT want to override this.

$settings should be an instance of L<Getopt::Yath::Settings>.

$options should be an instance of L<Getopt::Yath::Instance> if provided. This
method is usually capable of filling in the details when this is omitted.

=item $multi_line_string = $cmd_class->description()

Long-form description of the command. Used in C<cli_help()>.

=item $string = $cmd_class->cli_args()

A single usage string describing the command's positional arguments (for
example C<"[--] event_log.jsonl [job1, job2, ...]">). Defaults to an empty
string (no arguments). Rendered in the C<[COMMAND ARGUMENTS]> section of
C<cli_help()> and C<generate_pod()>.

=item @list = $cmd_class->doc_args()

A list of argument entries used to generate documentation. By default this
bridges C<cli_args()>: it returns the single C<cli_args> string when non-empty,
or an empty list otherwise. Override directly to supply structured
C<[$name =E<gt> $text]> entries.

=item $string = $cmd_class->generate_pod()

This can be used to generate POD documentation from the command itself using
the other fields listed in this section, as well as all applicable command
lines options specified in the command.

=item $string = $cmd_class->group()

Used for sorting/grouping commands in the C<yath help> output.

Existing groups:

    ' test'     # Space in front to make sure test related command float up
    'log'       # Log processing commands
    'persist'   # Commands related to the persistent runner
    'zinit'     # The init command and related command sink to the bottom.

Unless your command OBVIOUSLY and CLEARLY belongs in one of the above groups
you should probably create your own. Please do not prefix it with a space to
make it float, C<' test'> is a special case, you are not that special.

=item $string = $cmd_class->name()

Name of the command. By default this is the last part of the package name. You
will probably never want to override this.

=item $instance_or_undef = $cmd_class->options()

Returns the L<Getopt::Yath::Instance> with the command's options, or undef
for commands that have no options of their own.

=item $short_string = $cmd_class->summary()

A short summary of what this command is.

=back

=head1 OBJECT METHODS

=over 4

=item $bool = $cmd->always_keep_dir()

By default the working directory is deleted when yath exits. Some commands such
as L<App::Yath2::Command::start> need to keep the directory. Override this
method to return true if your command uses the workdir and needs to keep it.

=item $arrayref = $cmd->args()

Get an arrayref of command line arguments B<AFTER> options have been
process/removed.

=item $bool = $cmd->internal_only()

Set this to true if you do not want your command to show up in the help output.

=item $exit_code = $cmd->run()

This is the main entrypoint for the command. You B<MUST> override this. This
method should return an exit code.

=item $settings = $cmd->settings()

Get the settings as populated by the command line options.

=item $cmd->write_settings_to($directory, $filename)

A helper method to write the settings to a specified directory and filename.
File is written as JSON.

If you are subclassing another command such as L<App::Yath2::Command::test> you
may want to override this to a no-op to prevent the settings file from being
written, the L<App::Yath2::Command:run> command does this.

=back

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
