use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

# Chunk 9 (ARCHITECTURE.md §5.2): the unified, symmetric service-channel model.
# Two Role::Service consumers connect to each other over ONE bidirectional
# connection: identity handshake on connect, reuse-never-duplicate, either end may
# send requests, and a simultaneous reverse-connect collapses to a single channel.
{
    package My::Peer;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} //= []; return }

    # One-way request (returns undef -> no reply), so a peer can send to us over
    # whichever side opened the connection.
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
    for (1 .. 80) {
        $alpha->service_io;
        $beta->service_io;
        sleep 0.005;
    }
};

# --- connect + handshake ---------------------------------------------------
my $conn = $alpha->service_connect_peer('beta', $beta->service_socket_path);
ok($conn, "alpha dialed beta");
$pump->();

ok($alpha->service_peer_conn('beta'), "alpha registered beta as a peer");
ok($beta->service_peer_conn('alpha'), "beta learned alpha's identity from the handshake");

# --- symmetric: either end may send a request over the one connection ------
ok($alpha->service_send('beta', {request => 'note', msg => 'a-to-b'}), "alpha sent over the channel");
$pump->();
is($beta->seen, ['a-to-b'], "beta received alpha's request");

ok($beta->service_send('alpha', {request => 'note', msg => 'b-to-a'}), "beta sent back over the SAME channel");
$pump->();
is($alpha->seen, ['b-to-a'], "alpha received beta's request over the connection alpha opened");

# --- reuse, never duplicate -------------------------------------------------
my $again = $alpha->service_connect_peer('beta', $beta->service_socket_path);
is("$again", "$conn", "service_connect_peer reuses the existing connection");

# --- simultaneous reverse-connect collapses to one channel ------------------
{
    my $rdir = tempdir(CLEANUP => 1);
    my $a = My::Peer->new(workdir => $rdir, name => 'alpha');
    my $b = My::Peer->new(workdir => $rdir, name => 'beta');
    $_->start_service for $a, $b;

    my $pump2 = sub { for (1 .. 80) { $a->service_io; $b->service_io; sleep 0.005 } };

    # Both sides dial each other before either handshake is processed.
    $a->service_connect_peer('beta',  $b->service_socket_path);
    $b->service_connect_peer('alpha', $a->service_socket_path);
    $pump2->();

    is(scalar(keys %{$a->{service_conns}}), 1, "alpha collapsed the duplicate to one connection");
    is(scalar(keys %{$b->{service_conns}}), 1, "beta collapsed the duplicate to one connection");

    # The surviving single channel still carries traffic both ways.
    $a->service_send('beta',  {request => 'note', msg => 'x'});
    $b->service_send('alpha', {request => 'note', msg => 'y'});
    $pump2->();
    is($b->seen, ['x'], "beta still receives over the surviving channel");
    is($a->seen, ['y'], "alpha still receives over the surviving channel");
}

done_testing;
