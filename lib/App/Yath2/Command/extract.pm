package App::Yath2::Command::extract;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Path qw/make_path/;

use App::Yath2::Log;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

option_group {group => 'extract', category => 'Extract Options'} => sub {
    option no_decompress => (
        type        => 'Bool',
        default     => 0,
        description => 'Preserve .zst suffixes and store compressed bytes verbatim instead of decompressing on the way out.',
    );

    option run => (
        type        => 'List',
        alt         => ['runs'],
        initialize  => sub { [] },
        description => "Restrict the extract to the listed run ids (repeatable). Globals are always included. Mutually exclusive with --exclude-run.",
    );

    option exclude_run => (
        type        => 'List',
        alt         => ['exclude-runs'],
        initialize  => sub { [] },
        description => "Exclude the listed run ids from the extract (repeatable). Globals are always included. Mutually exclusive with --run.",
    );
};

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Extract a yath log archive" }
sub cli_args { "[--] archive_filename [destination]" }

sub description {
    return <<"    EOT";
Extract a yath log archive into a directory.

Required first argument: path to the archive file.

Optional second argument: destination directory. Defaults to './logs'.
The destination must NOT already exist; it will be created (along with
any missing parents) before extraction.

Pass --no-decompress to preserve C<.zst>-suffixed payloads verbatim
instead of decompressing on the way out.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $args     = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $no_decompress = $settings->extract->no_decompress ? 1 : 0;

    my $archive = shift @$args;
    unless (defined $archive && length $archive) {
        $archive = App::Yath2::Log->find_latest($settings);
        print STDERR "yath extract: using latest archive: $archive\n"
            if defined $archive && length $archive;
    }
    die "archive_filename is required (no ./last_log.yath and no matching archive in tempdir)\n"
        unless defined $archive && length $archive;
    die "archive '$archive' does not exist\n" unless -e $archive;

    my $dest = shift @$args // './logs';

    die "extra arguments after destination\n" if @$args;

    die "destination '$dest' already exists\n" if -e $dest;

    make_path($dest) or die "could not create destination '$dest': $!\n"
        unless -d $dest;

    my $runs    = $settings->extract->run;
    my $exclude = $settings->extract->exclude_run;
    die "--run and --exclude-run are mutually exclusive\n"
        if @$runs && @$exclude;

    my %scope;
    $scope{runs}         = [@$runs]    if @$runs;
    $scope{exclude_runs} = [@$exclude] if @$exclude;

    my $log = App::Yath2::Log->new(file => $archive);

    print "Extracting '$archive' to '$dest'\n";

    $log->extract(
        $dest,
        compressed => $no_decompress ? 1 : 0,
        %scope,
    );

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
