use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

# Chunk 9 (ARCHITECTURE.md §5.2): the unified service channel at the Role::Service
# level. One service dials another; after the identity exchange BOTH ends can send
# requests over the one connection (symmetric), and service_connect_peer reuses an
# existing connection rather than opening a second one.
{
    package My::Peer;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} //= []; return }

    # One-way request (returns undef -> no reply): a peer records what it received.
    sub request_handler_note ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => $payload->{msg};
        return undef;
    }
}

my $dir = tempdir(CLEANUP => 1);

my $alpha = My::Peer->new(workdir => $dir, name => 'alpha');
my $beta  = My::Peer->new(workdir => $dir, name => 'beta');
$_->start_service for $alpha, $beta;

my $pump = sub {
    for (1 .. 60) {
        $alpha->service_io;
        $beta->service_io;
        sleep 0.005;
    }
};

# --- connect + identity exchange -------------------------------------------
my $conn = $alpha->service_connect_peer('beta', $beta->service_socket_path);
ok($conn, "alpha dialed beta");
$pump->();

ok($alpha->service_peer_conn('beta'),  "alpha has beta as a peer");
ok($beta->service_peer_conn('alpha'),  "beta learned alpha from the identity exchange");

# --- symmetric: either end may send a request over the one connection ------
ok($alpha->service_send('beta', 'note', msg => 'a-to-b'), "alpha sent over the channel");
$pump->();
is($beta->seen, ['a-to-b'], "beta received alpha's request");

ok($beta->service_send('alpha', 'note', msg => 'b-to-a'), "beta sent back over the SAME channel");
$pump->();
is($alpha->seen, ['b-to-a'], "alpha received beta's request over the connection alpha opened");

# --- reuse, never duplicate -------------------------------------------------
my $again = $alpha->service_connect_peer('beta', $beta->service_socket_path);
is("$again", "$conn", "service_connect_peer reuses the existing connection");

done_testing;
