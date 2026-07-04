use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix/;
use Test2::Harness2::Role::Service::Connection();

# TODO-106: a connection closed by a BETWEEN-TICK consumer write (service_send /
# send_control failing EPIPE to a vanished peer -- runner -> dead stage 'run_task',
# runner -> dead collector 'terminate', sampler -> runner 'system_load') marks the
# conn and shuts its fh, but the close path cannot pull the fh out of the select
# set. If that dead fd is still registered when the next service_io calls
# can_read(0), select() fails EBADF and reports NOTHING readable -- every live peer
# is starved and the whole service goes deaf. service_io must drop such a conn
# BEFORE it polls, so no dead fd is ever handed to select().
#
# (TODO-108's write pass sweeps closed conns too, but only AFTER can_read within a
# tick, so it cannot protect the FIRST can_read of the tick that follows a
# between-tick close -- this test asserts a SINGLE service_io recovers, which
# distinguishes the pre-read sweep from the after-read one.)

# A minimal Role::Service consumer with an echo handler so we can prove the
# survivor's request was actually read and dispatched.
{
    package My::PoisonSvc;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} = []; return }

    sub request_handler_echo ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => $payload->{msg};
        return {ok => 1, msg => $payload->{msg}};
    }
}

my $dir = tempdir(CLEANUP => 1);
my $svc = My::PoisonSvc->new(workdir => $dir, name => 'runner');
$svc->start_service;

# Dial a peer and return its client-side Connection.
sub dial_peer {
    my ($svc, $id) = @_;
    my $fh = connect_unix($svc->service_socket_path);
    $fh->blocking(0);
    return Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => $id,
    );
}

# The service-side accepted Connection for a peer, found by its announced identity.
sub svc_conn_for {
    my ($svc, $id) = @_;
    for my $conn (values %{$svc->{service_conns}}) {
        return $conn if defined $conn->identity && $conn->identity eq $id;
    }
    return undef;
}

# True if $fh is currently registered in the service's select set.
sub in_select {
    my ($svc, $fh) = @_;
    my %h = map { $_ => 1 } $svc->{service_select}->handles;
    return $h{$fh} ? 1 : 0;
}

my $victim   = dial_peer($svc, 'peerA');
my $survivor = dial_peer($svc, 'peerB');

# Pump the identity handshake for both peers.
for (1 .. 50) {
    $svc->service_io;
    $_->drain for $victim, $survivor;
    last if $victim->ready && $survivor->ready;
    sleep 0.01;
}
ok($victim->ready && $survivor->ready, "both peers completed the identity handshake");

my $svictim   = svc_conn_for($svc, 'peerA');
my $ssurvivor = svc_conn_for($svc, 'peerB');
ok($svictim && $ssurvivor, "service registered both peer connections");
ok(in_select($svc, $svictim->fh),   "victim fh registered in the select set");
ok(in_select($svc, $ssurvivor->fh), "survivor fh registered in the select set");

# --- The peer vanishes, then the service writes to it BETWEEN ticks ----------
# Close the peer end entirely (as a dead stage/collector would). The service has
# NOT drained its EOF yet, so it still believes the conn is live.
close($victim->fh);

# A consumer-side write to the vanished peer (the runner's 'terminate' /
# 'run_task', the sampler's 'system_load') -- done OUTSIDE service_io. The write
# fails EPIPE; the conn closes but its fh stays in the select set. Loop because a
# unix socket may swallow one post-close write before EPIPE surfaces.
for (1 .. 200) {
    last if $svictim->closed;
    $svictim->send_control('terminate', reason => 'peer vanished');
}
ok($svictim->closed, "service-side conn to the vanished peer closed on the failed write");

# This is the poison: the dead fh is still in the select set before the next tick.
ok(in_select($svc, $svictim->fh), "dead fh still registered in the select set (the poison)");

# The survivor sends a request. Its bytes are in the service's receive buffer
# before the next poll, so a single healthy service_io must read and dispatch it.
my $req_id = $survivor->send_request('echo', msg => 'survivor-lives');

# EXACTLY ONE service_io. Without the TODO-106 pre-read sweep, can_read(0) hits the
# poisoned fd -> EBADF -> empty -> the survivor's request is never read this tick.
$svc->service_io;

ok(!in_select($svc, $svictim->fh), "dead fh removed from the select set");
ok(!$svc->{service_conns}{$svictim->fh}, "dead conn removed from the connection map");
ok(in_select($svc, $ssurvivor->fh), "survivor stays in the select set");

# The discriminator: the survivor's request was actually read and handled in that
# single tick, so the service was never wedged by the poisoned fd.
ok(
    (grep { $_ eq 'survivor-lives' } @{$svc->seen}),
    "survivor's request was read and dispatched despite the poisoned fd (no EBADF wedge)",
);

# And the correlated response makes it back to the survivor.
my $resp;
for (1 .. 50) {
    $svc->service_io;
    for my $ev ($survivor->drain) {
        $resp = $ev->{payload} if $ev->{kind} eq 'response' && $ev->{request_id} eq $req_id;
    }
    last if $resp;
    sleep 0.01;
}
is($resp->{msg}, 'survivor-lives', "survivor received its response (service still draining)");

$svc->close_service;

done_testing;
