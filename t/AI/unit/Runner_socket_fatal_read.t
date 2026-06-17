use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();
use Test2::Harness2::Role::Service::Connection();

# A fatal sysread error (errno not EINTR/EAGAIN/EWOULDBLOCK, e.g. ECONNRESET or
# EBADF) must not be swallowed: the Connection drops the connection, so a client
# waiting for a reply sees it closed and croaks immediately instead of looping until
# the 30s CONNECT_TIMEOUT. We force a deterministic fatal read with a write-only
# filehandle: sysread on it returns undef with EBADF, which is not retryable.

# A Connection over a write-only filehandle: writes (identity, requests) succeed,
# but any read fails fatally.
sub fatal_conn {
    my $dir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$dir/sink") or die "open: $!";
    return Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => 'test-client',
    );
}

{
    package Fatal::Client;
    use v5.38;
    use parent -norequire => 'Test2::Harness2::Runner::Client';
    sub connection { return $_[0]->{conn} }
}
{
    package Fatal::Subscriber;
    use v5.38;
    use parent -norequire => 'Test2::Harness2::Runner::Subscriber';
    sub _connect { return $_[0]->{conn} }
}

subtest client_request_croaks_promptly => sub {
    my $client = Fatal::Client->new(workdir => '/tmp');
    # The fatal fd is write-only on purpose, so sysread emits a benign "opened only
    # for output" warning at the read site; swallow it.
    local $SIG{__WARN__} = sub { };
    $client->{conn} = fatal_conn();

    my $start = time;
    my $ok    = eval { $client->_request('status'); 1 };
    my $err   = $@;
    my $elapsed = time - $start;

    ok(!$ok, "request croaked");
    like($err, qr/runner closed the connection/, "fatal read surfaced as a closed connection");
    ok($elapsed < 5, "croaked promptly (${elapsed}s), not after CONNECT_TIMEOUT");
};

subtest subscriber_subscribe_croaks_promptly => sub {
    my $sub = Fatal::Subscriber->new(workdir => '/tmp');
    local $SIG{__WARN__} = sub { };
    $sub->{conn} = fatal_conn();

    my $start = time;
    my $ok    = eval { $sub->subscribe; 1 };
    my $err   = $@;
    my $elapsed = time - $start;

    ok(!$ok, "subscribe croaked");
    like($err, qr/runner closed the connection/, "fatal read surfaced as a closed connection");
    ok($elapsed < 5, "croaked promptly (${elapsed}s), not after CONNECT_TIMEOUT");
};

done_testing;
