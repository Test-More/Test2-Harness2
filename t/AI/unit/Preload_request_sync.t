use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use IO::Select ();
use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness2::Role::Service::Connection;
use Test2::Harness2::Preload;

# TODO-134 finding 94: the preload-root handshake wait (_request_sync) must notice a
# dropped runner connection and fail fast, instead of idling out the full
# preload_map_timeout. drain marks the held $conn closed on EOF, so the loop
# croaks "closed while waiting".

# A do-nothing listener so service_io's accept loop is a no-op.
package FakeListen { sub accept { return } }

# A Preload whose service_io closes the far end on its first serviced tick,
# simulating the runner dropping the connection right after we sent the request.
package TestPreload {
    use parent -norequire, 'Test2::Harness2::Preload';
    our $FAR;
    sub service_io {
        my $self = shift;
        if ($FAR) { close($FAR); $FAR = undef }
        return $self->SUPER::service_io(@_);
    }
}

my $dir = tempdir(CLEANUP => 1);
my $pl  = TestPreload->new(runner_socket => "$dir/runner.socket", workdir => $dir);

socketpair(my $near, my $far, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
$_->blocking(0) for $near, $far;

my $conn = Test2::Harness2::Role::Service::Connection->new(
    fh          => $near,
    outbound    => 1,
    my_identity => 'preload-root',
);

# Inject the peer directly into the service registry (no real bind/accept).
$pl->{service_listen} = bless {}, 'FakeListen';
$pl->{service_select} = IO::Select->new($near);
$pl->{service_conns}  = {$near => $conn};
$pl->{service_peers}  = {runner => $conn};
$pl->{service_subs}   = {};

$TestPreload::FAR = $far;    # service_io will close this on the first tick

my $start = time;
my $ok    = eval { $pl->_request_sync('runner', 'get_preload_list'); 1 };
my $err   = $@;
my $took  = time - $start;

ok(!$ok, "_request_sync failed when the peer dropped");
like($err, qr/closed while waiting/, "it croaked on the closed connection (not a timeout)");
ok($took < 2, "it failed fast in ${took}s (well under preload_map_timeout)");

done_testing;
