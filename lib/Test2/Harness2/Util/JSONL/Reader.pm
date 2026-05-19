package Test2::Harness2::Util::JSONL::Reader;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/ESPIPE/;
use Fcntl qw/SEEK_SET/;

use Test2::Harness2::Util::JSON qw/decode_json/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSONL::Reader - Tail-style JSONL reader
(plain or zstd-framed).

=head1 DESCRIPTION

Tail-style reader that drains newly-arrived JSONL records since the
previous call. Auto-detects the on-disk format from the path suffix:
C<.zst> uses L<Test2::Harness2::Util::Zstd::Reader>, anything else
uses a plain newline-delimited byte-position reader. Both modes
return decoded JSON records.

Also accepts an in-memory C<bytes> or C<bytes_zstd> source, or a
pre-opened plain JSONL filehandle.

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSONL::Reader;
    use Test2::Harness2::Util::FileMonitor;

    my $delegate = Test2::Harness2::Util::JSONL::Reader->new(path => $path);
    my $monitor  = Test2::Harness2::Util::FileMonitor->new(
        file     => $path,
        delegate => $delegate,
    );

    while (my $d = $monitor->changed) {
        my @items = $d->read_lines;
        ... handle decoded items ...
    }

=cut

sub new {
    my ($class, %opts) = @_;
    my $fh         = delete $opts{fh};
    my $bytes      = delete $opts{bytes};
    my $bytes_zstd = delete $opts{bytes_zstd};
    my $path       = delete $opts{path} // delete $opts{name};

    croak "path, fh, bytes, or bytes_zstd is required"
        unless defined $fh
        || defined $bytes
        || defined $bytes_zstd
        || defined $path;

    my $self = bless {
        path   => $path,
        buffer => [],
    } => $class;

    $self->_init_source($fh, $bytes, $bytes_zstd, $path);

    return $self;
}

sub _init_source {
    my ($self, $fh, $bytes, $bytes_zstd, $path) = @_;

    if (defined $bytes_zstd) {
        $self->{_bytes} = $bytes_zstd;
        open(my $sfh, '<', \$self->{_bytes})
            or croak "open scalar fh: $!";
        require Test2::Harness2::Util::Zstd;
        $self->{reader}  = Test2::Harness2::Util::Zstd::open_zstd_reader_fh($sfh);
        $self->{zstd}    = 1;
        $self->{fh_mode} = 1;
        return;
    }
    if (defined $bytes) {
        $self->{_bytes} = $bytes;
        open(my $sfh, '<', \$self->{_bytes})
            or croak "open scalar fh: $!";
        $self->{fh}      = $sfh;
        $self->{zstd}    = 0;
        $self->{pos}     = 0;
        $self->{fh_mode} = 1;
        return;
    }
    if (defined $fh) {
        $self->{fh}      = $fh;
        $self->{zstd}    = 0;
        $self->{pos}     = 0;
        $self->{fh_mode} = 1;
        return;
    }
    if ($path =~ /\.zst\z/) {
        require Test2::Harness2::Util::Zstd;
        $self->{zstd} = 1;
        return;
    }
    $self->{zstd} = 0;
    $self->{pos}  = 0;
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item read_lines

=item @items = $r->read_lines

Drain every record that has arrived since the previous call. Returns
decoded JSON records as a list. Torn / partial input is held back.

=back

=cut

sub read_lines {
    my $self = shift;

    $self->_drain;

    my @out = @{$self->{buffer}};
    $self->{buffer} = [];
    return @out;
}

=over 4

=item readline

=item $item = $r->readline

Return one decoded record, or C<undef> when none is buffered.

=back

=cut

sub readline {
    my $self = shift;

    $self->_drain unless @{$self->{buffer}};
    return undef  unless @{$self->{buffer}};
    return shift @{$self->{buffer}};
}

=over 4

=item exists

=item $bool = $r->exists

True when the underlying path exists, or when the reader was
constructed from an in-memory / pre-opened source.

=back

=cut

sub exists {
    my $self = shift;
    return 1 if $self->{fh_mode};
    return -e $self->{path} ? 1 : 0;
}

=over 4

=item close

=item $r->close

Close the underlying file handle / zstd reader. Called automatically
on C<DESTROY>.

=back

=cut

sub close {
    my $self = shift;

    if (my $reader = delete $self->{reader}) {
        $reader->close;
    }
    if (my $fh = delete $self->{fh}) {
        return close($fh);
    }
    return 1;
}

sub _ensure_reader {
    my $self = shift;

    if ($self->{zstd}) {
        return $self->{reader} if $self->{reader};
        return undef unless -e $self->{path};
        $self->{reader} = Test2::Harness2::Util::Zstd::open_zstd_reader($self->{path});
        return $self->{reader};
    }

    return $self->{fh} if $self->{fh};
    return undef unless -e $self->{path};

    open(my $fh, '<', $self->{path}) or croak "open '$self->{path}': $!";
    binmode $fh;
    $self->{fh} = $fh;
    return $fh;
}

sub _drain {
    my $self = shift;
    return $self->_drain_zstd if $self->{zstd};
    return $self->_drain_plain;
}

sub _drain_zstd {
    my $self = shift;

    my $reader = $self->_ensure_reader or return;
    while (defined(my $payload = $reader->readline)) {
        my $decoded;
        my $ok  = eval { $decoded = decode_json($payload); 1 };
        my $err = $@;
        unless ($ok) {
            chomp $err;
            warn "Skipping zstd JSONL frame that failed to decode in '$self->{path}': $err\n";
            next;
        }
        push @{$self->{buffer}} => $decoded;
    }
    return;
}

sub _drain_plain {
    my $self = shift;

    my $fh = $self->_ensure_reader or return;

    unless (seek($fh, $self->{pos}, SEEK_SET)) {
        my $errno = $!;
        croak "non-seekable handle for '$self->{path}'" if $errno == ESPIPE;

        delete $self->{fh};
        $self->{pos} = 0;
        return;
    }

    while (defined(my $line = <$fh>)) {
        if (substr($line, -1, 1) ne "\n") {
            seek($fh, $self->{pos}, SEEK_SET);
            last;
        }
        $self->{pos} = tell($fh);
        my $decoded;
        my $ok  = eval { $decoded = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            chomp $err;
            warn "Skipping JSONL line that failed to decode in '$self->{path}': $err\n";
            next;
        }
        push @{$self->{buffer}} => $decoded;
    }

    return;
}

sub DESTROY {
    my $self = shift;
    $self->close if $self->{fh} || $self->{reader};
}

1;

__END__

=pod

=head1 SEE ALSO

L<Test2::Harness2::Util::Zstd::Reader> -- zstd-framed primitive used
internally for C<.zst> paths.

L<Test2::Harness2::Util::FileMonitor> -- change-detection driver.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
