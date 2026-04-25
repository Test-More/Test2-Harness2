package App::Yath2::LogArchive::Format;
use strict;
use warnings;

use Carp qw/croak/;
use Exporter qw/import/;
use Fcntl qw/SEEK_END SEEK_SET/;

our @EXPORT_OK = qw/
    detect_format
    reader_class_for
    writer_class_for
    default_writer_format
    DEFAULT_WRITER_PREFERENCE
    TAR_ZIDX_MAGIC
    TAR_ZIDX_FOOTER_LEN
/;

use constant TAR_ZIDX_MAGIC      => "YZIDXv1\0";
use constant TAR_ZIDX_FOOTER_LEN => 32;

# Yath ships exactly one archive format on disk: tar.zidx. The
# multi-format dispatch the codebase used to carry (tar / tar.gz /
# tar.bz2 / zip / 7z) was deleted as part of the zstd-loggers spec --
# Compress::Zstd is now a hard prereq and tar.zidx is pure-Perl end
# to end, so there is no reason to ship the alternatives.
use constant DEFAULT_WRITER_PREFERENCE => ('tar.zidx');

sub default_writer_format { return 'tar.zidx' }

sub detect_format {
    my ($path) = @_;
    croak "LogArchive: path required" unless defined $path && length $path;

    return 'directory' if -d $path;
    croak "LogArchive: no such file: $path" unless -e $path;

    open(my $fh, '<', $path) or croak "LogArchive: cannot open $path: $!";
    binmode $fh;

    if ((-s $path) >= TAR_ZIDX_FOOTER_LEN) {
        seek($fh, -TAR_ZIDX_FOOTER_LEN, SEEK_END);
        my $foot = '';
        read($fh, $foot, TAR_ZIDX_FOOTER_LEN);
        if (length($foot) == TAR_ZIDX_FOOTER_LEN
            && substr($foot, 0, length(TAR_ZIDX_MAGIC)) eq TAR_ZIDX_MAGIC)
        {
            close($fh);
            return 'tar.zidx';
        }
    }

    close($fh);
    croak "LogArchive: unknown archive format for '$path' (yath only produces tar.zidx)";
}

my %READERS = (
    directory  => ['App::Yath2::LogArchive::Directory'],
    'tar.zidx' => [qw/App::Yath2::LogArchive::TarZIdx/],
);

sub reader_class_for {
    my ($format) = @_;
    my $candidates = $READERS{$format}
        or croak "LogArchive: no reader for format '$format'";
    for my $class (@$candidates) {
        my $path = _module_path($class);
        my $ok   = eval { require $path; $class->viable };
        return $class if $ok;
    }
    croak "LogArchive: no reader available for format '$format'; install one of: @$candidates";
}

sub _module_path {
    my $class = shift;
    (my $p = "$class.pm") =~ s{::}{/}g;
    return $p;
}

my %WRITERS = (
    'tar.zidx' => [qw/App::Yath2::LogArchive::Writer::TarZIdx/],
);

# The writer class lives in the consolidated TarZIdx.pm file
# (alongside the reader), so requiring the writer class's own
# filename does not work. Pre-load the consolidated module before
# any class-name dispatch.
require App::Yath2::LogArchive::TarZIdx;

sub writer_class_for {
    my ($format) = @_;
    my $candidates = $WRITERS{$format}
        or croak "LogArchive: no writer for format '$format'";
    for my $class (@$candidates) {
        return $class if $class->viable($format);
    }
    croak "LogArchive: no writer available for format '$format'";
}

1;
