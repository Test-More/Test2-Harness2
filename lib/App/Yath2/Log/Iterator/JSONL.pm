package App::Yath2::Log::Iterator::JSONL;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::JSONL::Reader;

use Object::HashBase qw{
    <path
    <live
    <records
    +reader
    +buffer
    +eof
    +read_all
};

# Iterator over a single .jsonl(.zst) file or an in-memory record list.
# Used by the per-artifact events / spec / report iterators returned by
# Artifact->events_iter, spec_iter, report_iter. Decoupled from the
# depth-first walk done by App::Yath2::Log::Directory.
#
# Construction:
#
#     # File-backed (Directory / Live):
#     App::Yath2::Log::Iterator::JSONL->new(path => $path, live => $bool);
#
#     # In-memory (TarZIdx / Sqlite -- always sealed):
#     App::Yath2::Log::Iterator::JSONL->new(records => \@decoded);
#
# When live is false (the default for sealed sources), end-of-file is
# treated as end-of-iteration. When live is true, the reader stays
# open and re-checks for newly-appended bytes; EOE is then a property
# of the parent log (the artifact iterator alone can never decide).

sub init {
    my $self = shift;
    if (defined $self->{+RECORDS}) {
        croak "'records' and 'path' are mutually exclusive"
            if defined $self->{+PATH};
        croak "'records' must be an arrayref"
            unless ref($self->{+RECORDS}) eq 'ARRAY';
        # Records-backed iterators are always sealed: EOE is purely
        # a function of how many records remain.
        $self->{+LIVE} = 0;
    }
    else {
        croak "'path' or 'records' is a required attribute"
            unless defined $self->{+PATH} && length $self->{+PATH};
        $self->{+LIVE} //= 0;
    }
    $self->{+BUFFER}   //= [];
    $self->{+EOF}      //= 0;
    $self->{+READ_ALL} //= 0;
}

# Cached underlying reader. Lazily created so an artifact whose file
# is missing is not an error until something actually tries to read.
sub _reader {
    my $self = shift;
    return undef if defined $self->{+RECORDS};
    return $self->{+READER} //= Test2::Harness2::Util::JSONL::Reader->new(path => $self->{+PATH});
}

# Drain whatever the underlying JSONL reader has buffered into our
# own buffer. Returns the number of records added. For records-backed
# iterators this is a one-shot copy of every remaining record.
sub _pull {
    my $self = shift;
    if (defined $self->{+RECORDS}) {
        return 0 if $self->{+EOF};
        push @{$self->{+BUFFER}} => @{$self->{+RECORDS}};
        my $n = scalar @{$self->{+RECORDS}};
        $self->{+EOF} = 1;
        # Empty-list-once: avoid pushing the same records twice.
        $self->{+RECORDS} = [];
        return $n;
    }
    my $r = $self->_reader or return 0;
    return 0 unless $r->exists;
    my @items = $r->read_lines;
    return 0 unless @items;
    push @{$self->{+BUFFER}} => @items;
    return scalar @items;
}

# Read one record. With $timeout > 0 and live mode, polls until a
# record arrives or the timeout expires. Returns undef when nothing
# is available within the timeout (live) or when the file is fully
# drained (sealed).
sub next {
    my ($self, $timeout) = @_;

    # Fast path: serve from the buffer first.
    return shift @{$self->{+BUFFER}} if @{$self->{+BUFFER}};

    $self->_pull;
    return shift @{$self->{+BUFFER}} if @{$self->{+BUFFER}};

    # Sealed: nothing buffered and pull found nothing -> eof.
    unless ($self->{+LIVE}) {
        $self->{+EOF} = 1;
        return undef;
    }

    # Live + no buffered records: optional poll.
    return undef unless defined($timeout) && $timeout > 0;

    my $deadline = time + $timeout;
    while (time < $deadline) {
        tinysleep(0.05);
        $self->_pull;
        return shift @{$self->{+BUFFER}} if @{$self->{+BUFFER}};
    }
    return undef;
}

# Convenience: return the very first decoded record. Caches the entire
# file's records on the way (cheap for spec / report files; potentially
# expensive for large events files -- callers should prefer ->next for
# events).
sub first {
    my $self = shift;
    $self->_read_all unless $self->{+READ_ALL};
    return undef unless @{$self->{_all}//=[]};
    return $self->{_all}->[0];
}

# Convenience: return the very last decoded record. Same caveat as
# ->first.
sub last {
    my $self = shift;
    $self->_read_all unless $self->{+READ_ALL};
    return undef unless @{$self->{_all}//=[]};
    return $self->{_all}->[-1];
}

# Convenience: number of records in the file. Reads the entire file.
sub count {
    my $self = shift;
    $self->_read_all unless $self->{+READ_ALL};
    return scalar @{$self->{_all}//=[]};
}

sub _read_all {
    my $self = shift;

    if (defined $self->{+RECORDS}) {
        my @all;
        push @all => @{$self->{+BUFFER}};
        $self->{+BUFFER} = [];
        push @all => @{$self->{+RECORDS}};
        $self->{+RECORDS}  = [];
        $self->{+EOF}      = 1;
        $self->{_all}      = \@all;
        $self->{+READ_ALL} = 1;
        return;
    }

    my $r = $self->_reader;
    return unless $r && $r->exists;

    # Drain everything sitting in the underlying reader so far.
    my @all;
    push @all => @{$self->{+BUFFER}};
    $self->{+BUFFER} = [];

    while (1) {
        my @items = $r->read_lines;
        last unless @items;
        push @all => @items;
    }

    $self->{_all}      = \@all;
    $self->{+READ_ALL} = 1;
    return;
}

sub EOE { $_[0]->end_of_events }

sub end_of_events {
    my $self = shift;

    return 0 if @{$self->{+BUFFER}};

    if (defined $self->{+RECORDS}) {
        return @{$self->{+RECORDS}} ? 0 : 1;
    }

    if ($self->{+LIVE}) {
        # Live: only the parent log can declare termination of a live
        # artifact (when the matching harness_collector_end has been
        # observed). At the per-iterator level we report based on the
        # buffer alone.
        return 0;
    }

    return 1 if $self->{+EOF};

    # Try one more pull -- if nothing comes back, we're done.
    $self->_pull;
    return 0 if @{$self->{+BUFFER}};

    $self->{+EOF} = 1;
    return 1;
}

# Reset back to the beginning of the file / record list.
sub reset {
    my $self = shift;
    if (defined $self->{+RECORDS}) {
        # Records-backed iterators retain a private snapshot of the
        # original record list ('_all' is populated lazily by _read_all).
        # Refill RECORDS from that snapshot.
        if ($self->{+READ_ALL}) {
            $self->{+RECORDS} = [@{$self->{_all} // []}];
        }
        else {
            # _pull was called but _read_all was not; the original
            # list was already moved into BUFFER on first _pull.
            # Rebuild from the buffer drained so far + remaining.
            my @snap = (@{$self->{_all} // []}, @{$self->{+BUFFER}}, @{$self->{+RECORDS}});
            $self->{+RECORDS} = [@snap];
            # Re-snapshot for future resets.
            $self->{_all}      = [@snap];
            $self->{+READ_ALL} = 1;
        }
        $self->{+BUFFER}   = [];
        $self->{+EOF}      = 0;
        return;
    }
    if (my $r = delete $self->{+READER}) {
        eval { $r->close; 1 };
    }
    $self->{+BUFFER}   = [];
    $self->{+EOF}      = 0;
    $self->{+READ_ALL} = 0;
    delete $self->{_all};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Iterator::JSONL - Iterator over a single .jsonl(.zst) file or in-memory record list.

=head1 DESCRIPTION

Iterator returned by L<App::Yath2::Log::Artifact/events_iter>,
L<App::Yath2::Log::Artifact/spec_iter>, and
L<App::Yath2::Log::Artifact/report_iter>. Wraps a
L<Test2::Harness2::Util::JSONL::Reader> with the convenience methods
the reader API requires (C<next>, C<first>, C<last>, C<count>,
C<EOE>, C<reset>).

Two construction forms are supported:

=over 4

=item C<< path => $path, live => $bool >>

File-backed iteration via L<Test2::Harness2::Util::JSONL::Reader>.
Used by the Directory and Live backends.

=item C<< records => \@decoded >>

In-memory iteration over a pre-decoded record list. Used by the
TarZIdx (and eventually SQLite) backends, where records are already
in memory after a single bulk decompress. Always sealed.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
