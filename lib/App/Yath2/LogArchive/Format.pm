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

use constant DEFAULT_WRITER_PREFERENCE => ('tar.zidx', 'zip', '7z', 'tar.bz2', 'tar.gz');

sub default_writer_format {
    for my $candidate (DEFAULT_WRITER_PREFERENCE) {
        return $candidate if eval { writer_class_for($candidate); 1 };
    }
    croak "no viable archive format available; install one of: "
        . join(' ', DEFAULT_WRITER_PREFERENCE);
}

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
        seek($fh, 0, SEEK_SET);
    }

    my $buf = '';
    read($fh, $buf, 512);
    close($fh);

    return 'zip'     if length($buf) >= 4 && substr($buf, 0, 4) eq "PK\x03\x04";
    return '7z'      if length($buf) >= 6 && substr($buf, 0, 6) eq "7z\xBC\xAF\x27\x1C";
    return 'tar.gz'  if length($buf) >= 2 && substr($buf, 0, 2) eq "\x1f\x8b";
    return 'tar.bz2' if length($buf) >= 3 && substr($buf, 0, 3) eq "BZh";
    return 'tar'     if length($buf) >= 262 && substr($buf, 257, 5) eq 'ustar';

    croak "LogArchive: unknown format for $path";
}

my %READERS = (
    directory  => ['App::Yath2::LogArchive::Directory'],
    tar        => [qw/App::Yath2::LogArchive::Tar::External App::Yath2::LogArchive::Tar::PP/],
    'tar.gz'   => [qw/App::Yath2::LogArchive::TarGz::External App::Yath2::LogArchive::TarGz::PP/],
    'tar.bz2'  => [qw/App::Yath2::LogArchive::TarBz2::External App::Yath2::LogArchive::TarBz2::PP/],
    'tar.zidx' => [qw/App::Yath2::LogArchive::TarZIdx::External App::Yath2::LogArchive::TarZIdx::PP/],
    zip        => [qw/App::Yath2::LogArchive::Zip::External App::Yath2::LogArchive::Zip::PP/],
    '7z'       => [qw/App::Yath2::LogArchive::SevenZip::External App::Yath2::LogArchive::SevenZip::PP/],
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
    tar        => [qw/App::Yath2::LogArchive::Writer::Tar/],
    'tar.gz'   => [qw/App::Yath2::LogArchive::Writer::Tar/],
    'tar.bz2'  => [qw/App::Yath2::LogArchive::Writer::Tar/],
    'tar.zidx' => [qw/App::Yath2::LogArchive::Writer::TarZIdx/],
    zip        => [qw/App::Yath2::LogArchive::Writer::Zip::External App::Yath2::LogArchive::Writer::Zip::PP/],
    '7z'       => [qw/App::Yath2::LogArchive::Writer::SevenZip/],
);

sub writer_class_for {
    my ($format) = @_;
    my $candidates = $WRITERS{$format}
        or croak "LogArchive: no writer for format '$format'";
    for my $class (@$candidates) {
        my $path = _module_path($class);
        my $ok   = eval { require $path; $class->viable($format) };
        return $class if $ok;
    }
    croak "LogArchive: no writer available for format '$format'";
}

1;
