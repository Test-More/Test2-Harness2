package Test2::Harness2::Util::Zstd::Writer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Fcntl qw/O_WRONLY O_APPEND O_CREAT/;

use Compress::Zstd ();

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd::Writer - Append-safe, frame-per-record
zstd writer.

=head1 DESCRIPTION

Wraps an C<O_APPEND> filehandle. Each call to L</print> compresses the
joined payload as one self-contained zstd frame and atomically appends
that frame to the file via C<syswrite>. Concurrent writers are safe as
long as a frame fits in C<PIPE_BUF> (4 KiB on Linux); the per-line
jsonl events the harness emits stay well below that.

Construct via L<Test2::Harness2::Util::Zstd/open_zstd_writer>; this
class is not meant to be instantiated directly.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    my $w = open_zstd_writer('events.jsonl.zst');
    $w->print($json_line, "\n");
    $w->close;

=cut

sub _open {
    my ($class, $path) = @_;

    croak "path is required" unless defined $path;

    sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or croak "open '$path' for append: $!";
    binmode $fh;

    return bless {
        path => $path,
        fh   => $fh,
    } => $class;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item print

=item $w->print(@list)

Compresses the concatenation of C<@list> as one zstd frame and
appends it. Returns C<1> on success, croaks on failure.

=back

=cut

sub print {
    my $self    = shift;
    my $payload = join '', @_;
    my $frame   = Compress::Zstd::compress($payload);
    return $self->_emit_frame($frame);
}

=over 4

=item say

=item $w->say(@list)

Same as L</print> but appends a trailing C<"\n"> to C<@list> before
compressing, so the decompressed payload is a complete line.

=back

=cut

sub say {
    my $self = shift;
    return $self->print(@_, "\n");
}

=over 4

=item print_raw_frame

=item $w->print_raw_frame($frame)

Append a fully-formed zstd frame to the file without re-compressing.
The caller is responsible for ensuring the frame was produced with a
matching level so a reader can decode it. Used by callers that
already hold a compressed frame (e.g. the collector caches the
on-wire frame from L<Atomic::Pipe>).

=back

=cut

sub print_raw_frame {
    my $self = shift;
    my ($frame) = @_;
    croak "frame is required" unless defined $frame;
    return $self->_emit_frame($frame);
}

=over 4

=item close

=item $w->close

Close the underlying file handle. Called automatically on C<DESTROY>.

=back

=cut

sub close {
    my $self = shift;
    my $fh   = delete $self->{fh} or return 1;
    return close($fh);
}

sub _emit_frame {
    my ($self, $frame) = @_;

    my $fh   = $self->{fh};
    my $len  = length $frame;
    my $sent = syswrite($fh, $frame);
    croak "syswrite '$self->{path}': $!"
        unless defined $sent;
    croak "short syswrite ('$self->{path}'): $sent of $len"
        if $sent != $len;

    return 1;
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

L<Test2::Harness2::Util::Zstd::Reader> -- the symmetric reader.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
