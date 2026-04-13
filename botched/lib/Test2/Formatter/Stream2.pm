package Test2::Formatter::Stream2;
use strict;
use warnings;

our $VERSION = '2.000012';

use IO::Handle;
use Atomic::Pipe;
use Carp qw/croak confess/;
use Time::HiRes qw/time/;
use Test2::Util qw/get_tid/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util qw/hub_truth apply_encoding/;

use parent qw/Test2::Formatter/;
use Test2::Harness2::Util::HashBase qw{
    +encoding
    <no_header
    <no_numbers
    <no_diag
    <stream_id
    <pipe_write
    <tb
    <tb_handles
};

sub hide_buffered { 0 }

sub init {
    my $self = shift;

    $self->{+STREAM_ID} = 1;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stdout()->autoflush(1);
        Test2::API::test2_stderr()->autoflush(1);
    }

    # If no pipe_write supplied, construct one from STDOUT.
    # The harness redirects STDOUT to the Atomic::Pipe before exec,
    # so FD 1 IS the pipe writer.
    unless ($self->{+PIPE_WRITE}) {
        my $w = Atomic::Pipe->from_fh('>&=', \*STDOUT);
        $w->set_mixed_data_mode();
        $self->{+PIPE_WRITE} = $w;
    }

    if ($self->{check_tb}) {
        require Test::Builder::Formatter;
        $self->{+TB}         = Test::Builder::Formatter->new();
        $self->{+TB_HANDLES} = [@{$self->{+TB}->handles}];
    }
}

sub _send_event {
    my ($self, $facets, $num) = @_;

    my $pipe = $self->{+PIPE_WRITE};

    my $event_id = $facets->{about}{uuid} //= gen_uuid();

    my $event = {
        facet_data => $facets,
        event_id   => $event_id,
        stream_id  => $self->{+STREAM_ID}++,
        stamp      => time(),
        pid        => $$,
        tid        => get_tid(),
    };

    $event->{assert_count} = $num if defined $num;

    my $json;
    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };
        $json = encode_json($event);
    }

    $pipe->write_message($json);
}

if ($^C) {
    no warnings 'redefine';
    *write = sub { };
}

sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= $e->facet_data if defined $e;

    $self->_set_encoding($f->{control}{encoding}) if $f && $f->{control}{encoding};

    # Hide these if we must, but do not remove them for good.
    local $f->{info} if $self->{+NO_DIAG}   && $f;
    local $f->{plan} if $self->{+NO_HEADER} && $f;

    my $tb_only = 0;
    if ($self->{+TB}) {
        $tb_only ||= $self->{+TB_HANDLES}->[0] != $self->{+TB}{handles}->[0];
        $tb_only ||= $self->{+TB_HANDLES}->[1] != $self->{+TB}{handles}->[1];

        my $todo_match = $self->{+TB_HANDLES}->[0] == $self->{+TB}{handles}->[2]
            || $self->{+TB_HANDLES}->[1] == $self->{+TB}{handles}->[2];

        $tb_only ||= !$todo_match;

        if ($tb_only) {
            my $buffered = hub_truth($f)->{buffered};
            $self->{+TB}->write($e, $num, $f) if $self->{+TB} && !$buffered;
            return;
        }
    }

    my $assert_count = $self->{+NO_NUMBERS} ? undef : $num;
    $self->_send_event($f //= {}, $assert_count);
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        $self->_send_event({control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+ENCODING};
}

sub _set_encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);
        $self->{+ENCODING} = $enc;
    }

    return $self->{+ENCODING};
}

sub handles {
    my $self = shift;
    return $self->{+TB}->handles if $self->{+TB};
    return;
}

sub set_no_header {
    my $self = shift;
    ($self->{+NO_HEADER}) = @_;
    $self->{+TB}->set_no_header(@_) if $self->{+TB};
    $self->{+NO_HEADER};
}

sub set_no_diag {
    my $self = shift;
    ($self->{+NO_DIAG}) = @_;
    $self->{+TB}->set_no_diag(@_) if $self->{+TB};
    $self->{+NO_DIAG};
}

sub set_no_numbers {
    my $self = shift;
    ($self->{+NO_NUMBERS}) = @_;
    $self->{+TB}->set_no_numbers(@_) if $self->{+TB};
    $self->{+NO_NUMBERS};
}

sub set_handles {
    my $self = shift;
    return $self->{+TB}->set_handles(@_) if $self->{+TB};
    return;
}

sub terminate {
    my $self = shift;
    return $self->SUPER::terminate(@_) unless $self->{+TB};
    return $self->{+TB}->terminate(@_);
}

sub finalize {
    my $self = shift;
    return $self->SUPER::finalize(@_) unless $self->{+TB};
    return $self->{+TB}->finalize(@_);
}

sub DESTROY { }

our $AUTOLOAD;

sub AUTOLOAD {
    my $this = shift;

    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $type = ref($this);

    return $this->{+TB}->$meth(@_)
        if $type && $this->{+TB} && $this->{+TB}->can($meth);

    $type ||= $this;
    croak qq{Can't locate object method "$meth" via package "$type"};
}

sub isa {
    my $in = shift;
    return $in->SUPER::isa(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::isa(@_) || $in->{+TB}->isa(@_);
}

sub can {
    my $in = shift;
    return $in->SUPER::can(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::can(@_) || $in->{+TB}->can(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream2 - Test2 Formatter that sends events via Atomic::Pipe.

=head1 DESCRIPTION

Formatter used by L<Test2::Harness2> when running tests. Serializes Test2
events to JSON and writes them atomically through an L<Atomic::Pipe> in mixed
data mode, allowing structured events to be interleaved with raw STDOUT/STDERR
output.

=head1 CONSTRUCTOR OPTIONS

=over 4

=item pipe_write

An L<Atomic::Pipe> writer instance. If not supplied, the module constructs one
from STDOUT (which the harness has already redirected to the pipe).

=item no_header

Suppress plan facets from being forwarded.

=item no_diag

Suppress info/diagnostic facets from being forwarded.

=item no_numbers

Suppress C<assert_count> from event messages.

=back

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
