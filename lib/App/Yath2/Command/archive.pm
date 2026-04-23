package App::Yath2::Command::archive;
use strict;
use warnings;

our $VERSION = '2.000011';

use POSIX qw/strftime/;

use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/writer_class_for default_writer_format DEFAULT_WRITER_PREFERENCE/;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Archive a yath log directory into a single file" }
sub cli_args { "[--] logdir [archive_filename [format]]" }

sub description {
    my @prefs = DEFAULT_WRITER_PREFERENCE;
    return <<"    EOT";
Archive a yath log directory.

Required first argument: path to the log directory.

Optional second argument: output archive filename. Defaults to
"<YYYYMMDD-HHMMSS>.yath".

Optional third argument: archive format. Must be one of: @prefs.
Defaults to the first one whose backend is available on this system.
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

    my $format = shift @$args;
    if (defined $format) {
        my $ok = eval { writer_class_for($format); 1 };
        die "format '$format' is not viable on this system: $@" unless $ok;
    }
    else {
        $format = default_writer_format();
    }

    die "extra arguments after format\n" if @$args;

    print "Archiving '$logdir' as '$archive' (format: $format)\n";

    App::Yath2::LogArchive->create(
        source => $logdir,
        path   => $archive,
        format => $format,
    );

    print "Wrote archive: $archive\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
