package Test2::Harness2::Util::Zstd::Reader;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Compress::Zstd ();

use Test2::Harness2::Util::Zstd ();

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd::Reader - Frame-oriented reader for
multi-frame zstd files.

=head1 DESCRIPTION

Wraps a multi-frame zstd file (one self-contained frame per record,
as produced by L<Test2::Harness2::Util::Zstd::Writer>) and yields
each frame's decoded payload via L</readline>. Frames are located
using L<Test2::Harness2::Util::Zstd/zstd_frame_size> (RFC 8878
frame-header parser); each frame is decompressed independently via
L<Compress::Zstd/decompress>.

The reader clears sticky-EOF state on every refill, so writers
appending more bytes between reads stay visible to the next
C<readline> call -- usable as a tail-style reader on a live
append-safe file.

Construct via L<Test2::Harness2::Util::Zstd/open_zstd_reader> or
L<Test2::Harness2::Util::Zstd/open_zstd_reader_fh>; this class is
not meant to be instantiated directly.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
    my $r = open_zstd_reader('events.jsonl.zst');
    while (defined(my $line = $r->readline)) { ... }

=cut

sub _open {
    my ($class, $path) = @_;

    croak "path is required"    unless defined $path;
    croak "no such file: $path" unless -e $path;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;

    return bless {
        path    => $path,
        fh      => $fh,
        records => [],
        raw_buf => '',
    } => $class;
}

sub _open_fh {
    my ($class, $fh) = @_;

    croak "fh is required" unless defined $fh;
    binmode $fh;

    return bless {
        path    => '<fh>',
        fh      => $fh,
        records => [],
        raw_buf => '',
    } => $class;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item readline

=item $record = $r->readline

Return the decoded payload of the next zstd frame, or C<undef> when
no complete frame is available. Producers control whether records
carry trailing newlines; this reader adds and strips nothing.

=back

=cut

sub readline {
    my ($self) = @_;

    while (!@{$self->{records}}) {
        my $progress = $self->_refill_records;
        last unless $progress;
    }

    return shift @{$self->{records}} if @{$self->{records}};
    return undef;
}

=over 4

=item close

=item $r->close

Close the underlying file handle. Called automatically on C<DESTROY>.

=back

=cut

sub close {
    my $self = shift;
    my $fh   = delete $self->{fh} or return 1;
    return close($fh);
}

sub _read_more {
    my ($self) = @_;

    seek($self->{fh}, 0, 1);

    my $chunk;
    my $n = read($self->{fh}, $chunk, 65536);
    croak "read '$self->{path}': $!" unless defined $n;

    return 0 unless $n;

    $self->{raw_buf} .= $chunk;
    return $n;
}

sub _refill_records {
    my ($self) = @_;

    my $progress = $self->_read_more;

    while (length $self->{raw_buf}) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size($self->{raw_buf});
        last unless defined $size;

        my $frame = substr($self->{raw_buf}, 0, $size);
        substr($self->{raw_buf}, 0, $size) = '';

        my $plain = Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in '$self->{path}'"
            unless defined $plain;

        push @{$self->{records}} => $plain;
    }

    return $progress;
}

sub DESTROY {
    my $self = shift;
    $self->close if $self->{fh};
}

1;

__END__

=pod

=head1 SEE ALSO

L<Test2::Harness2::Util::Zstd> -- helper module that constructs
this class.

L<Test2::Harness2::Util::Zstd::Writer> -- the symmetric writer.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
