package App::Yath2::Options::Logging;
use v5.38;

our $VERSION = '2.000000';

use POSIX qw/strftime/;
use Test2::Harness2::Util qw/clean_path/;
use File::Spec;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Logging - jsonl-renderer options for yath

=head1 DESCRIPTION

This is where the command line options for the jsonl renderer are defined. The
old whole-run jsonl log is no longer a command-level "logger" sink: it is a plain
renderer (L<App::Yath2::Renderer::Jsonl>). These options control that renderer
and, when any of them is given, inject it into the renderer list. The C<-L> short
form (and C<--log>) was retired -- C<-L> is being repurposed for the DB logger --
along with the C<-F>/C<-B>/C<-G> short forms.

=head1 PROVIDED OPTIONS

=head3 JSONL Renderer Options

=over 4

=item --bzip2

=item --bz2

=item --no-bzip2

Use bzip2 compression when writing the jsonl log. Enabling this turns on the jsonl
renderer. The .bz2 suffix is added to the file name for you.


=item --gzip

=item --gz

=item --no-gzip

Use gzip compression when writing the jsonl log. Enabling this turns on the jsonl
renderer. The .gz suffix is added to the file name for you.


=item --jsonl-dir ARG

=item --jsonl-dir=ARG

=item --no-jsonl-dir

Specify a directory for the jsonl log. Will fall back to the system temp dir.


=item --jsonl-file ARG

=item --jsonl-file=ARG

=item --no-jsonl-file

Specify the name of the jsonl log file. Enabling this turns on the jsonl renderer.


=item --jsonl-format ARG

=item --jsonl-format=ARG

=item --no-jsonl-format

Specify the format for automatically-generated jsonl log files. Overridden by
--jsonl-file, if given. (Default: $YATH_LOG_FILE_FORMAT, if that is set, or else
"%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl"). This is a string in which percent-escape
sequences will be replaced as per POSIX::strftime. The following special escape
sequences are also replaced: (%!P : Project name followed by a ~, if a project is
defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process
ID) (%!S : the number of seconds since local midnight UTC)

Can also be set with the following environment variables: C<YATH_LOG_FILE_FORMAT>, C<TEST2_HARNESS_LOG_FORMAT>


=back


=cut

# The renderer the jsonl options inject when enabled.
sub JSONL_RENDERER() { 'App::Yath2::Renderer::Jsonl' }

option_group {group => 'jsonl', category => "JSONL Renderer Options"} => sub {
    # Internal flag: another module (e.g. the YathUI plugin force-enable, or this
    # group's own implicit-enable) sets it to inject the renderer. Not a CLI option
    # the user sets directly -- there is no short/long for it.
    option enabled => (
        type        => 'Bool',
        description => 'Internal: when true the jsonl renderer is injected into the renderer list.',
    );

    option format => (
        type          => 'Scalar',
        alt           => ['jsonl-format'],
        from_env_vars => [qw/YATH_LOG_FILE_FORMAT TEST2_HARNESS_LOG_FORMAT/],
        default       => '%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl',
        description   => 'Specify the format for automatically-generated jsonl log files. Overridden by --jsonl-file, if given. (Default: $YATH_LOG_FILE_FORMAT, if that is set, or else "%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!P : Project name followed by a ~, if a project is defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)',
    );

    option bzip2 => (
        type        => 'Bool',
        alt         => ['bz2'],
        description => 'Use bzip2 compression when writing the jsonl log. Enabling this turns on the jsonl renderer. The .bz2 suffix is added to the file name for you.',
    );

    option gzip => (
        type        => 'Bool',
        alt         => ['gz'],
        description => 'Use gzip compression when writing the jsonl log. Enabling this turns on the jsonl renderer. The .gz suffix is added to the file name for you.',
    );

    option dir => (
        type        => 'Scalar',
        alt         => ['jsonl-dir'],
        normalize   => \&clean_path,
        description => 'Specify a directory for the jsonl log. Will fall back to the system temp dir.',
    );

    option file => (
        type        => 'Scalar',
        alt         => ['jsonl-file'],
        normalize   => \&clean_path,
        description => 'Specify the name of the jsonl log file. Enabling this turns on the jsonl renderer.',
    );
};

# Resolve the jsonl renderer settings + inject it into the renderer list.
#
# Runs at weight 101 -- AFTER App::Yath2::Options::Display's weight-100
# post_process, which sets up the default Formatter renderer by checking whether
# the renderer '@' list is already populated. Injecting before that would make
# Display think a renderer was already requested and skip the default formatter.
#
# Enable when any jsonl option was given OR when another module set jsonl->enabled
# (the YathUI force-enable -- replacing the old logging->log force-set). The
# resolved file path is stored back on jsonl->file so replay/YathUI can find it.
option_post_process 101 => sub ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->check_group('jsonl');
    my $jsonl = $settings->jsonl;

    die "You cannot use both --bzip2 and --gzip\n" if $jsonl->bzip2 && $jsonl->gzip;

    # Implicit-enable: any explicit jsonl request turns the renderer on (the old
    # -L/--log enable flag was retired; -L is reserved for the DB logger). The
    # 'enabled' flag is the other-module force-enable channel (YathUI). 'format'
    # has a default so it is NOT an enable trigger; 'dir' has none, so an explicit
    # --jsonl-dir is.
    my $enabled = $jsonl->enabled || $jsonl->bzip2 || $jsonl->gzip || $jsonl->file || $jsonl->dir;
    return unless $enabled;

    # Make sure the flag is recorded (so other consumers see a single truth).
    $jsonl->create_option(enabled => 1);

    unless ($jsonl->file) {
        my $dir = $jsonl->dir // ($settings->check_group('workspace') ? $settings->workspace->tmp_dir : File::Spec->tmpdir);

        mkdir($dir) or die "Could not create dir '$dir': $!"
            unless -d $dir;

        my $format   = $jsonl->format;
        my $filename = expand_jsonl_format($format, $settings);
        $jsonl->create_option(file => clean_path(File::Spec->catfile($dir, $filename)));
    }

    my $file = $jsonl->file;
    $file =~ s{/+$}{}g;
    $file =~ s/\.(gz|bz2)$//;
    $file =~ s/\.jsonl?$//;
    $file .= ".jsonl";
    $file .= ".bz2" if $jsonl->bzip2;
    $file .= ".gz"  if $jsonl->gzip;
    $jsonl->create_option(file => $file);

    inject_jsonl_renderer($settings);
};

# Push the jsonl renderer onto the display renderer list (idempotently), the same
# shape Options/Display builds: the insertion-ordered '@' list + a per-class args
# arrayref. Shared by this group's implicit-enable and any other force-enable.
sub inject_jsonl_renderer ($settings) {
    return unless $settings->check_group('display');

    my $display = $settings->display;
    $display->create_option(renderers => {}) unless defined $display->renderers;
    my $renderers = $display->renderers;

    my $class = JSONL_RENDERER();
    return if grep { $_ eq $class } @{$renderers->{'@'} // []};

    push @{$renderers->{'@'}} => $class;
    $renderers->{$class} //= [];

    return;
}

sub time_for_strftime { time() }

sub expand_jsonl_format ($pattern, $settings) {
    $pattern =~ s{%!(\w)}{expand($1, $settings)}ge;
    my $res = strftime($pattern, localtime(time_for_strftime()));
    return $res;
}

sub expand ($letter, $settings) {
    if    ($letter eq "U") { return $settings->run->run_id }
    elsif ($letter eq "p") { return $$ }
    elsif ($letter eq "P") {
        my $project = $settings->harness->project // return "";
        return $project . "~";
    }
    elsif ($letter eq "S") {
        # Number of seconds since midnight
        my ($s, $m, $h) = (localtime(time_for_strftime()))[0, 1, 2];
        return sprintf("%05d", $s + 60 * $m + 3600 * $h);
    }
    else {
        # unrecognized `%!x` expansion.  Should we warn?  Die?
        return "%!$letter";
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
