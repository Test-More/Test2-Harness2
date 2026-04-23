package App::Yath2::LogArchive::TarGz::PP;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'App::Yath2::LogArchive::Tar::PP';

use constant HAVE_DEPS => eval { require Archive::Tar; require IO::Zlib; 1 } ? 1 : 0;

sub viable { HAVE_DEPS }

sub _archive_obj {
    my $self = shift;
    return $self->{App::Yath2::LogArchive::Tar::PP::_ARCHIVE()} //= do {
        my $fh = IO::Zlib->new($self->{App::Yath2::LogArchive::Tar::PP::PATH()}, 'rb')
            or croak "IO::Zlib open: $!";
        my $t = Archive::Tar->new;
        $t->read($fh)
            or croak "Archive::Tar read: " . Archive::Tar->error;
        $fh->close;
        $t;
    };
}

1;
