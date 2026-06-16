package Test2::Harness2::Runner::Monitor;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Collector::Util::Zstd qw/decompress_blob/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    +collectors
    +pending_new
    +pending_failing
    +pending_diagnosing
    +pending_completed
    +pending_exits
    +pending_finalized
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Monitor - Fold collector transition messages into the
runner's canonical in-process state.

=head1 DESCRIPTION

The runner is the hub of the transition channel: every collector except the
runner's own connects its reporter to C<runner.socket> and streams the small
high-value set of transition messages -- C<harness_collector> (start),
C<harness_state_transition>, C<harness_final_state>, and
C<harness_collector_finalized>. This monitor folds those messages into
per-collector state, keyed on the collector C<uuid> that rides on every message
(see L<Test2::Collector>).

The runner owns the listening socket (via L<Test2::Harness2::Role::Service>),
so this monitor is fed already-read frames or already-decoded payloads rather
than owning a socket of its own. It can then be queried for the collectors it
has seen, each one's status, events file, and (once complete) final result, plus
"what changed since I last asked" deltas -- L</new_collectors>, L</new_failing>,
L</new_test_exits>, and friends -- each of which drains and returns the uuids
that entered that state since the previous call.

This is the per-run baseline: there is a single C<runner.socket> and no
per-run-uuid fan-out. The C<run_uuid> still rides on every message and is
tracked per collector, but the monitor does not filter or proxy on it.

=head1 SYNOPSIS

    use Test2::Harness2::Runner::Monitor;

    my $mon = Test2::Harness2::Runner::Monitor->new;

    # Fold an already-decoded transition payload (one harness_collector message).
    $mon->feed($decoded_transition_payload);

    # Or fold a raw zstd frame read off the socket.
    $mon->feed_frame($zstd_frame);

    $_ and free_slot($_) for $mon->new_test_exits;

=cut

sub init ($self) {
    $self->{+COLLECTORS} = {};

    $self->{+PENDING_NEW}        = [];
    $self->{+PENDING_FAILING}    = [];
    $self->{+PENDING_DIAGNOSING} = [];
    $self->{+PENDING_COMPLETED}  = [];
    $self->{+PENDING_EXITS}      = [];
    $self->{+PENDING_FINALIZED}  = [];

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $mon->feed($payload)

Fold one already-decoded transition message C<$payload> (a
C<< {facet_data =E<gt> ...} >> hashref carrying a C<harness_collector> facet)
into state.

=item $payload = $mon->feed_frame($frame)

Decode one raw zstd frame and fold the transition message it carries into state.
Returns the decoded payload, or C<undef> for a frame that carries no collector
identity.

=item @uuids = $mon->collectors

=item @uuids = $mon->tests

=item @uuids = $mon->services

The uuids of all collectors seen, or just the tests / just the (non-test)
service collectors.

=item collector

=item $state = $mon->collector($uuid)

The state hashref for one collector (or C<undef>): C<uuid>, C<category>
(C<test> / C<service>), C<name>, C<events_file>, C<try>, C<run_uuid>, C<status>
(C<running> / C<complete> / C<finalized>), the C<failing> / C<diagnosing>
flags, and C<final_state> once seen.

=item $status = $mon->status($uuid)

=item $path = $mon->events_file($uuid)

=item $state = $mon->final_state($uuid)

Conveniences for individual fields of L</collector>.

=item new_collectors

=item @uuids = $mon->new_collectors

=item new_failing

=item @uuids = $mon->new_failing

=item @uuids = $mon->new_diagnosing

=item @uuids = $mon->new_completed

=item new_test_exits

=item @uuids = $mon->new_test_exits

=item @uuids = $mon->new_finalized

Drain-on-call change lists: each returns the collector uuids that entered the
named state since the previous call to that method, then forgets them.
C<new_collectors> reports collectors seen for the first time (their events file
is available by then); C<new_test_exits> reports tests whose process has exited
(the C<completed> transition), which the scheduler uses to free a slot.
C<new_completed> also covers plain (non-test) collectors, which signal the end
of their run with an C<exited> transition instead of C<completed>.

=back

=cut

sub feed ($self, $payload) {
    $self->_process($payload);
    return;
}

sub feed_frame ($self, $frame) {
    my $payload;
    croak "monitor: feed_frame given an undecodable frame"
        unless eval { $payload = decompress_blob($frame); 1 } && defined $payload;

    my $decoded;
    unless (eval { $decoded = decode_json($payload); 1 }) {
        warn "monitor: could not decode a transition frame: $@\n";
        return undef;
    }

    my $uuid = ref($decoded) eq 'HASH' ? $decoded->{facet_data}{harness_collector}{uuid} : undef;
    return undef unless defined $uuid;

    $self->_process($decoded);
    return $decoded;
}

sub collectors ($self) { return keys %{$self->{+COLLECTORS}} }

sub tests ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'test' }
        keys %{$self->{+COLLECTORS}};
}

sub services ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'service' }
        keys %{$self->{+COLLECTORS}};
}

sub collector ($self, $uuid) { return $self->{+COLLECTORS}{$uuid} }

sub status ($self, $uuid) {
    my $c = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{status};
}

sub events_file ($self, $uuid) {
    my $c = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{events_file};
}

sub final_state ($self, $uuid) {
    my $c = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{final_state};
}

sub new_collectors ($self) { return $self->_drain(PENDING_NEW) }
sub new_failing    ($self) { return $self->_drain(PENDING_FAILING) }
sub new_diagnosing ($self) { return $self->_drain(PENDING_DIAGNOSING) }
sub new_completed  ($self) { return $self->_drain(PENDING_COMPLETED) }
sub new_test_exits ($self) { return $self->_drain(PENDING_EXITS) }
sub new_finalized  ($self) { return $self->_drain(PENDING_FINALIZED) }

=head1 PRIVATE METHODS

=over 4

=item @uuids = $self->_drain($slot)

Return and clear one of the pending change lists.

=item $self->_process($payload)

Fold one decoded message into per-collector state and the pending change lists,
keyed by the message's collector uuid.

=item $self->_process_transition($state_hash, $state, $hc)

Apply one C<harness_state_transition> (C<starting> / C<failing> /
C<diagnosing> / C<completed> / C<exited>) to a collector's state hash.

=back

=cut

sub _drain ($self, $slot) {
    my $list = $self->{$slot};
    $self->{$slot} = [];
    return @$list;
}

sub _process ($self, $payload) {
    my $fd   = $payload->{facet_data}   or return;
    my $hc   = $fd->{harness_collector} or return;
    my $uuid = $hc->{uuid} // return;

    my $c = $self->{+COLLECTORS}{$uuid};
    unless ($c) {
        $c = $self->{+COLLECTORS}{$uuid} = {
            uuid       => $uuid,
            status     => 'running',
            failing    => 0,
            diagnosing => 0,
        };
        push @{$self->{+PENDING_NEW}} => $uuid;
    }

    if (my $transition = $fd->{harness_state_transition}) {
        $self->_process_transition($c, $transition->{state}, $hc);
        return;
    }

    if (my $final = $fd->{harness_final_state}) {
        $c->{final_state} = $final;
        return;
    }

    if ($fd->{harness_collector_finalized}) {
        $c->{status} = 'finalized';
        push @{$self->{+PENDING_FINALIZED}} => $uuid;
        return;
    }

    return;
}

sub _process_transition ($self, $c, $state, $hc) {
    if ($state eq 'starting') {
        $c->{name}        = $hc->{name};
        $c->{events_file} = $hc->{events_file};
        $c->{try}         = $hc->{try};
        $c->{run_uuid}    = $hc->{run_uuid};
        $c->{category}    = defined $hc->{try} ? 'test' : 'service';
        $c->{status}      = 'running';
        return;
    }

    if ($state eq 'failing') {
        return if $c->{failing};
        $c->{failing} = 1;
        push @{$self->{+PENDING_FAILING}} => $c->{uuid};
        return;
    }

    if ($state eq 'diagnosing') {
        return if $c->{diagnosing};
        $c->{diagnosing} = 1;
        push @{$self->{+PENDING_DIAGNOSING}} => $c->{uuid};
        return;
    }

    if ($state eq 'completed') {
        $c->{status} = 'complete';
        push @{$self->{+PENDING_COMPLETED}} => $c->{uuid};
        push @{$self->{+PENDING_EXITS}} => $c->{uuid}
            if ($c->{category} // '') eq 'test';
        return;
    }

    # Plain (non-test) collectors have no auditor; the collector itself emits an
    # 'exited' transition in place of the auditor's 'completed'.
    if ($state eq 'exited') {
        $c->{status} = 'complete';
        push @{$self->{+PENDING_COMPLETED}} => $c->{uuid};
        return;
    }

    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
