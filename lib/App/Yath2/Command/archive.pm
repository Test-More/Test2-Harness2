package App::Yath2::Command::archive;
use strict;
use warnings;

our $VERSION = '2.000011';

use POSIX qw/strftime/;

use App::Yath2::LogArchive;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Archive a yath log directory into a single file" }
sub cli_args { "[--] logdir [archive_filename]" }

sub description {
    return <<"    EOT";
Archive a yath log directory into a single tar.zidx file.

Required first argument: path to the log directory.

Optional second argument: output archive filename. Defaults to
"<YYYYMMDD-HHMMSS>.yath".

yath only produces tar.zidx archives. The on-disk shape is a tar
(ustar) with per-file zstd compression and a trailing index for
random-access reads. The archive bundles whatever zstd dictionary
was active for the run (copied from \$logdir/zstd-dict.bin) so
extracts and replays do not depend on the recipient's install.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $logdir = shift @$args;
    die "logdir is required\n"           unless defined $logdir && length $logdir;
    die "logdir '$logdir' is not a directory\n" unless -d $logdir;

    my $archive = shift @$args;
    $archive //= strftime('%Y%m%d-%H%M%S', localtime) . '.yath';

    die "extra arguments after archive filename\n" if @$args;

    print "Archiving '$logdir' as '$archive'\n";

    App::Yath2::LogArchive->create(
        source => $logdir,
        path   => $archive,
    );

    print "Wrote archive: $archive\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
