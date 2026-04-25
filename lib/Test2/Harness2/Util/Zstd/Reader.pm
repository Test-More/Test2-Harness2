package Test2::Harness2::Util::Zstd::Reader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Compress::Zstd ();
use Compress::Zstd::Decompressor;
use Compress::Zstd::DecompressionContext;

use Test2::Harness2::Util::Zstd ();

# A reader for a multi-frame zstd file produced by
# Test2::Harness2::Util::Zstd::Writer (or any other producer that
# emits one self-contained zstd frame per record).
#
# Two implementations live behind one interface:
#
# * No-dict path: feed raw bytes through a long-lived
#   Compress::Zstd::Decompressor (the streaming binding handles
#   concatenated frames natively) and split the decoded output on
#   "\n" to yield jsonl lines.
#
# * Dict path: the streaming binding does not accept a dict, so we
#   walk the raw bytes one frame at a time. Frame boundaries come
#   from Test2::Harness2::Util::Zstd::zstd_frame_size, which parses
#   the zstd frame header per RFC 8878. Each isolated frame goes to
#   DecompressionContext->decompress_using_dict with a reused
#   context and dict instance.

sub _open {
    my ($class, $path, %opts) = @_;

    croak "path is required" unless defined $path;
    croak "no such file: $path" unless -e $path;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;

    my $self = bless {
        path     => $path,
        fh       => $fh,
        ddict    => Test2::Harness2::Util::Zstd::_load_ddict(%opts),
        line_buf => '',
        raw_buf  => '',
    } => $class;

    if ($self->{ddict}) {
        $self->{dctx} = Compress::Zstd::DecompressionContext->new;
    }
    else {
        $self->{decompressor} = Compress::Zstd::Decompressor->new;
        $self->{decompressor}->init;
    }

    return $self;
}

# Try to read more bytes from the underlying file handle. Returns the
# number of bytes appended to raw_buf -- 0 means "nothing right now"
# (which can be transient: a writer may append more bytes between
# this and the next call).
sub _read_more {
    my ($self) = @_;

    # Clear any sticky EOF state on the handle before each read so
    # bytes appended by another writer (or this process) since the
    # last read are visible. Idempotent: a no-op when EOF is not set.
    seek($self->{fh}, 0, 1);

    my $chunk;
    my $n = read($self->{fh}, $chunk, 65536);
    croak "read '$self->{path}': $!" unless defined $n;

    return 0 unless $n;

    $self->{raw_buf} .= $chunk;
    return $n;
}

sub _refill_line_buf {
    my ($self) = @_;

    if ($self->{ddict}) {
        return $self->_refill_with_dict;
    }
    return $self->_refill_no_dict;
}

sub _refill_no_dict {
    my ($self) = @_;

    my $progress = $self->_read_more;
    return 0 unless $progress;

    # Hand the freshly-read raw bytes to the streaming decompressor.
    # It returns whatever decoded plaintext is available; partial
    # frames are buffered internally so we can call repeatedly.
    my $out = $self->{decompressor}->decompress($self->{raw_buf});
    $self->{raw_buf} = '';
    return $progress unless defined $out && length $out;

    $self->{line_buf} .= $out;
    return $progress;
}

sub _refill_with_dict {
    my ($self) = @_;

    my $progress = $self->_read_more;

    my $dctx  = $self->{dctx};
    my $ddict = $self->{ddict};

    # Walk frames out of raw_buf using zstd_frame_size for exact
    # boundaries -- no magic-byte scan.
    while (length $self->{raw_buf}) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size($self->{raw_buf});
        last unless defined $size;

        my $frame = substr($self->{raw_buf}, 0, $size);
        my $plain = $dctx->decompress_using_dict($frame, $ddict);
        croak "decompress_using_dict failed in '$self->{path}'"
            unless defined $plain;

        $self->{line_buf} .= $plain;
        substr($self->{raw_buf}, 0, $size) = '';
    }

    return $progress;
}

sub readline {
    my ($self) = @_;

    while (1) {
        my $nl = index($self->{line_buf}, "\n");
        if ($nl >= 0) {
            my $line = substr($self->{line_buf}, 0, $nl + 1);
            substr($self->{line_buf}, 0, $nl + 1) = '';
            return $line;
        }

        # No newline yet; try to pull more bytes off disk. If the
        # refill made no progress, we have nothing right now -- yield
        # whatever partial line buffer we have (treating it as the
        # final unterminated line) or undef. The caller can poll
        # again later if a writer is still appending.
        my $progress = $self->_refill_line_buf;
        last unless $progress;
    }

    if (length $self->{line_buf}) {
        my $line = $self->{line_buf};
        $self->{line_buf} = '';
        return $line;
    }

    return undef;
}

sub close {
    my $self = shift;
    my $fh   = delete $self->{fh} or return 1;
    return close($fh);
}

sub DESTROY {
    my $self = shift;
    $self->close if $self->{fh};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd::Reader - Line-oriented reader for multi-frame zstd files.

=head1 SYNOPSIS

Construct via L<Test2::Harness2::Util::Zstd>'s C<open_zstd_reader>;
this class is not meant to be instantiated directly.

    use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;

    my $r = open_zstd_reader('events.jsonl.zst', dict_path => $dict_path);
    while (defined(my $line = $r->readline)) { ... }

=head1 DESCRIPTION

Wraps a multi-frame zstd file (one self-contained frame per record,
as produced by L<Test2::Harness2::Util::Zstd::Writer>) and yields
decoded lines via L</readline>. Without a dict, uses
L<Compress::Zstd::Decompressor>'s streaming interface (handles
concatenated frames natively). With a dict, walks frames using
C<Test2::Harness2::Util::Zstd::zstd_frame_size> and decompresses
each via L<Compress::Zstd::DecompressionContext>'s
C<decompress_using_dict> with a reused context.

The reader recovers from sticky-EOF state on every refill so writers
appending more bytes between reads stay visible to the next readline
call -- usable as a tail-style reader on a live append-safe file.

=head1 METHODS

=over 4

=item $line = $r->readline

Returns the next decoded line including its trailing C<"\n">, or
C<undef> when no more bytes are available. A partial trailing line
(no terminating newline) is returned once at EOF.

=item $r->close

Closes the underlying file handle. Called automatically on
C<DESTROY>.

=back

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
