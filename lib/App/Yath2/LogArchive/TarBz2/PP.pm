package App::Yath2::LogArchive::TarBz2::PP;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'App::Yath2::LogArchive::Tar::PP';

use constant HAVE_DEPS => eval {
    require Archive::Tar;
    require IO::Uncompress::Bunzip2;
    1;
} ? 1 : 0;

sub viable { HAVE_DEPS }

sub _archive_obj {
    my $self = shift;
    return $self->{App::Yath2::LogArchive::Tar::PP::_ARCHIVE()} //= do {
        my $z = IO::Uncompress::Bunzip2->new($self->{App::Yath2::LogArchive::Tar::PP::PATH()})
            or croak "IO::Uncompress::Bunzip2 open: $IO::Uncompress::Bunzip2::Bunzip2Error";
        my $data = '';
        my $buf;
        while ((my $n = $z->read($buf, 65536)) > 0) {
            $data .= $buf;
        }
        $z->close;
        open(my $sfh, '<', \$data) or croak "open scalar: $!";
        binmode $sfh;
        my $t = Archive::Tar->new;
        $t->read($sfh)
            or croak "Archive::Tar read: " . Archive::Tar->error;
        $t;
    };
}

1;
