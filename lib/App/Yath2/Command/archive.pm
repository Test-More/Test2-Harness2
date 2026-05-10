package App::Yath2::Command::archive;
use strict;
use warnings;

our $VERSION = '2.000013';

use File::Spec ();
use POSIX qw/strftime/;

use App::Yath2::Log;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');
include_options('App::Yath2::Options::Log');

option_group {group => 'archive', category => 'Archive Options'} => sub {
    option run => (
        type        => 'List',
        alt         => ['runs'],
        initialize  => sub { [] },
        description => "Restrict the archive to the listed run ids (repeatable). Globals are always included. Mutually exclusive with --exclude-run.",
    );

    option exclude_run => (
        type        => 'List',
        alt         => ['exclude-runs'],
        initialize  => sub { [] },
        description => "Exclude the listed run ids from the archive (repeatable). Globals are always included. Mutually exclusive with --run.",
    );
};

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Archive a yath log directory into a single file" }
sub cli_args { "[--] logdir [archive_filename]" }

sub description {
    return <<"    EOT";
Archive a yath log directory into a single .yath file.

Required first argument: path to the log directory.

Optional second argument: output archive filename. Defaults to
"<system_tmp>/\${project}-\${user}-<YYYYMMDD-HHMMSS>-<pid>.yath" --
the current working directory is never used unless you pass an
explicit path that points at it.

The default archive format is tar.zidx (a USTAR-format tar with
per-file zstd compression and a trailing index for random-access
reads). Pass --log-format=sqlite to write a SQLite-backed archive
instead.

Use --no-log-compress to skip zstd compression and write plaintext
payloads (larger on disk but trivially greppable).
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $args     = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $logdir = shift @$args;
    die "logdir is required\n"                  unless defined $logdir && length $logdir;
    die "logdir '$logdir' is not a directory\n" unless -d $logdir;

    my $archive = shift @$args;
    unless (defined $archive && length $archive) {
        my $project = $settings->yath->project // '__UNKNOWN__';
        my $user    = $settings->yath->user
                   // $ENV{USER}
                   // 'unknown';
        my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);
        $archive = File::Spec->catfile(
            File::Spec->tmpdir(),
            "${project}-${user}-${stamp}-$$.yath",
        );
    }

    die "extra arguments after archive filename\n" if @$args;

    my $format = lc($settings->log->format // 'tar');
    $format = 'tar.zidx' if $format eq 'tar';
    die "unknown archive format '$format' (use 'tar' or 'sqlite')\n"
        unless $format eq 'tar.zidx' || $format eq 'sqlite';

    my $compress = $settings->log->compress ? 1 : 0;

    my $runs    = $settings->archive->run;
    my $exclude = $settings->archive->exclude_run;
    die "--run and --exclude-run are mutually exclusive\n"
        if @$runs && @$exclude;

    my %scope;
    $scope{runs}         = [@$runs]    if @$runs;
    $scope{exclude_runs} = [@$exclude] if @$exclude;

    print "Archiving '$logdir' as '$archive' (format: $format)\n";

    App::Yath2::Log->new(dir => $logdir)->archive(
        $archive,
        format   => $format,
        compress => $compress,
        %scope,
    );

    print "Wrote archive: $archive\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
