use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Role::Service::Connection();

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

# Drive a request/response round trip over the wire, through a real Connection
# (identity exchange + request_id-correlated response).
my $cfh = connect_unix($svc->service_socket_path);
$cfh->blocking(0);
my $client = Test2::Harness2::Role::Service::Connection->new(fh => $cfh, outbound => 1, my_identity => 'client');

# Send a request and pump the service until its correlated response arrives.
my $request = sub ($command, %args) {
    my $id = $client->send_request($command, %args);
    for (1 .. 200) {
        $svc->service_io;
        for my $ev ($client->drain) {
            return $ev->{payload} if $ev->{kind} eq 'response' && $ev->{request_id} eq $id;
        }
        sleep 0.01;
    }
    return undef;
};

my $resp = $request->('echo', msg => 'hello');
is($resp->{ok},  1,       "echo handler returns ok");
is($resp->{msg}, 'hello', "echo handler round-trips the payload");
is($svc->seen, ['hello'], "handler saw the payload");

# Unknown command is reported, loop is not stopped.
my $err = $request->('nope');
is($err->{ok}, 0, "unknown command not ok");
like($err->{error}, qr/invalid command: nope/, "unknown command reported");

# One-way request: handler returns undef, so no reply is written.
my $oneway_id = $client->send_request('oneway');
my $got_reply = 0;
for (1 .. 30) {
    $svc->service_io;
    for my $ev ($client->drain) {
        $got_reply++ if $ev->{kind} eq 'response' && $ev->{request_id} eq $oneway_id;
    }
    sleep 0.01;
}
ok(!$got_reply, "one-way request produced no reply");
ok((grep { $_ eq 'oneway' } @{$svc->seen}), "one-way handler still ran");

# Built-in stop request stops the service.
my $stop_resp = $request->('stop');
is($stop_resp->{ok},       1, "stop handler acknowledges");
is($stop_resp->{stopping}, 1, "stop handler reports stopping");
ok($svc->service_stopped, "service marked stopped");

$svc->close_service;
ok(!-e $svc->service_socket_path, "socket unlinked on close_service");

# Chunk 6.1-2: a run-scoped consumer (one that provides run_id) nests its socket
# under runs/<run_id>/ so two runs on one persistent runner cannot collide on a
# stage socket. A consumer with NO run_id keeps the flat workdir path.
{
    package My::RunSvc;
    use v5.38;
    use Object::HashBase qw/<workdir <name <run_id/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';
    sub init ($self) { return }
}

my $rdir = tempdir(CLEANUP => 1);
my $rsvc = My::RunSvc->new(workdir => $rdir, name => 'preload-default', run_id => 'RUN-ABC');
is(
    $rsvc->service_socket_path,
    File::Spec->catfile($rdir, 'runs', 'RUN-ABC', 'preload-default.socket'),
    "run-scoped socket nests under runs/<run_id>/",
);

my $gsvc = My::RunSvc->new(workdir => $rdir, name => 'preload-default', run_id => undef);
is(
    $gsvc->service_socket_path,
    File::Spec->catfile($rdir, 'preload-default.socket'),
    "a global (no run_id) stage socket stays flat in the workdir",
);

$rsvc->start_service;
ok(-S $rsvc->service_socket_path, "run-scoped socket binds (subdir created)");
$rsvc->close_service;

done_testing;
