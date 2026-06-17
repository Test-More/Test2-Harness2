use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();

# Gemini review (minor #1): a fatal sysread error (errno not EINTR/EAGAIN/
# EWOULDBLOCK, e.g. ECONNRESET) on the blocking read loops in
# Runner::Client::_request and Runner::Subscriber::_read_one_frame used to be
# swallowed -- the loop kept polling can_read(0.05) until the 30s CONNECT_TIMEOUT.
# It must now croak immediately. We force a deterministic fatal read by handing the
# loop a write-only filehandle: select reports it readable but sysread returns
# undef with EBADF, which is not a retryable errno.

# A write-only filehandle: readable per select(), but sysread fails fatally.
sub fatal_read_fh {
    my $dir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$dir/sink") or die "open: $!";
    return $fh;
}

# Override the connection accessor so the read loop uses our fatal fh without
# needing a live runner. CONNECT_TIMEOUT stays 30s, so a swallowed fatal error
# would make these calls take ~30s; we assert they return well under a second.
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
}

subtest client_request_croaks_promptly => sub {
    my $client = Fatal::Client->new(workdir => '/tmp');
    $client->{conn} = fatal_read_fh();

    my $start = time;
    my $err;
    # The fatal fd is write-only on purpose, so sysread emits a benign
    # "opened only for output" warning at the lib read site; swallow it.
    local $SIG{__WARN__} = sub { };
    my $ok = eval { $client->_request({request => 'status'}); 1 };
    $err = $@;
    my $elapsed = time - $start;

    ok(!$ok, "request croaked");
    like($err, qr/fatal error reading from runner socket/, "fatal read diagnostic");
    ok($elapsed < 5, "croaked promptly (${elapsed}s), not after CONNECT_TIMEOUT");
};

subtest subscriber_read_one_frame_croaks_promptly => sub {
    my $sub  = Fatal::Subscriber->new(workdir => '/tmp');
    my $conn = fatal_read_fh();

    my $start = time;
    my $err;
    local $SIG{__WARN__} = sub { };
    my $ok = eval { $sub->_read_one_frame($conn); 1 };
    $err = $@;
    my $elapsed = time - $start;

    ok(!$ok, "read_one_frame croaked");
    like($err, qr/fatal error reading from runner socket/, "fatal read diagnostic");
    ok($elapsed < 5, "croaked promptly (${elapsed}s), not after CONNECT_TIMEOUT");
};

done_testing;
