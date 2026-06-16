use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

# A minimal consumer of the role: provides the required workdir/name and a
# custom request handler, plus a one-way handler that returns undef.
{
    package My::Svc;
    use v5.38;
    use Object::HashBase qw/<workdir <name <ticks <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+TICKS} = 0; $self->{+SEEN} = []; return }
    sub service_tick ($self) { $self->{+TICKS}++; return }

    sub request_handler_echo ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => $payload->{msg};
        return {ok => 1, msg => $payload->{msg}};
    }

    sub request_handler_oneway ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => 'oneway';
        return undef;
    }
}

my $dir = tempdir(CLEANUP => 1);
my $svc = My::Svc->new(workdir => $dir, name => 'runner');

is(
    $svc->service_socket_path,
    File::Spec->catfile($dir, 'runner.socket'),
    "socket path is runner.socket in workdir",
);

$svc->start_service;
ok(-S $svc->service_socket_path, "socket bound after start_service");
ok(!$svc->service_stopped, "not stopped yet");

# Drive a request/response round trip over the wire.
my $client = connect_unix($svc->service_socket_path);
$client->blocking(0);

my $send = sub ($req) {
    write_frame($client, compress_blob(encode_json($req)));
};

my $recv = sub {
    my $fb = Test2::Collector::Util::Zstd::FrameBuffer->new;
    for (1 .. 200) {
        $svc->service_io;
        my $buf = '';
        my $n   = sysread($client, $buf, 65536);
        $fb->push_bytes($buf) if $n;
        if (my ($rec) = $fb->drain) {
            return decode_json($rec->{payload});
        }
        sleep 0.01;
    }
    return undef;
};

$send->({request => 'echo', msg => 'hello'});
my $resp = $recv->();
is($resp, {ok => 1, msg => 'hello'}, "echo handler round-trips a response");
is($svc->seen, ['hello'], "handler saw the payload");

# Unknown request type is reported, loop is not stopped.
$send->({request => 'nope'});
my $err = $recv->();
is($resp = $err, {ok => 0, error => "unknown request 'nope'"}, "unknown request reported");

# One-way request: handler returns undef, so no reply is written.
$send->({request => 'oneway'});
my $got_reply = 0;
for (1 .. 30) {
    $svc->service_io;
    my $buf = '';
    my $n = sysread($client, $buf, 65536);
    $got_reply++ if $n;
    sleep 0.01;
}
ok(!$got_reply, "one-way request produced no reply");
ok((grep { $_ eq 'oneway' } @{$svc->seen}), "one-way handler still ran");

# Built-in stop request stops the service.
$send->({request => 'stop'});
my $stop_resp = $recv->();
is($stop_resp, {ok => 1, stopping => 1}, "stop handler acknowledges");
ok($svc->service_stopped, "service marked stopped");

$svc->close_service;
ok(!-e $svc->service_socket_path, "socket unlinked on close_service");

done_testing;
