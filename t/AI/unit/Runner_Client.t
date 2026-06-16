use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec ();
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Runner::Client;

# A minimal runner-shaped service that records the request envelopes it receives
# over runner.socket, using the SAME request_handler_<type> mechanism the real
# runner uses (chunk 5a Role::Service). This pins the wire contract between
# Test2::Harness2::Runner::Client and the runner's request handlers.
{
    package My::Runner;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} = []; return }

    sub request_handler_queue_run ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => ['queue_run', $payload->{run}];
        return undef;
    }

    sub request_handler_queue_task ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => ['queue_task', $payload->{task}];
        return undef;
    }

    sub request_handler_stop_run ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => ['stop_run', $payload->{run_id}];
        return undef;
    }

    sub request_handler_end_queue ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => ['end_queue'];
        return undef;
    }

    sub request_handler_halt_run ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => ['halt_run', $payload->{run_id}];
        return undef;
    }

    # Two-way request: return a reply payload (chunk 6.1-3 reload_state query).
    sub request_handler_reload_state ($self, $payload, $conn) {
        return {ok => 1, reload_state => {default => {'lib/Foo.pm' => {error => 'boom'}}}};
    }
}

my $dir = tempdir(CLEANUP => 1);
my $svc = My::Runner->new(workdir => $dir, name => 'runner');

my $client = Test2::Harness2::Runner::Client->new(workdir => $dir);

is(
    $client->socket_path,
    File::Spec->catfile($dir, 'runner.socket'),
    "client targets runner.socket in the workdir",
);

# Connect-retry: before the runner binds, the socket does not exist yet.
ok(!-S $client->socket_path, "socket not bound before the runner starts");

# Bring the service up, then submit a full run worth of requests over a single
# connection (the client reuses one connection so order is preserved).
$svc->start_service;
ok(-S $client->socket_path, "socket bound once the runner starts");

$client->queue_run({run_id => 'R1', foo => 'bar'});
$client->queue_task({job_id => 'J1', run_id => 'R1', file => 't/a.t'});
$client->queue_task({job_id => 'J2', run_id => 'R1', file => 't/b.t'});
$client->stop_run('R1');
$client->end_queue;
$client->halt_run('R1');

# Drain the requests the service received.
for (1 .. 200) {
    $svc->service_io;
    last if @{$svc->seen} >= 6;
    sleep 0.01;
}

is(
    $svc->seen,
    [
        ['queue_run',  {run_id => 'R1', foo => 'bar'}],
        ['queue_task', {job_id => 'J1', run_id => 'R1', file => 't/a.t'}],
        ['queue_task', {job_id => 'J2', run_id => 'R1', file => 't/b.t'}],
        ['stop_run',   'R1'],
        ['end_queue'],
        ['halt_run',   'R1'],
    ],
    "client submissions arrive in order with the expected envelopes",
);

$svc->close_service;

# Two-way request/reply: reload_state. _request blocks reading the reply, so the
# service must run service_io concurrently -- fork a child that loops service_io
# and answers the request, while the parent's client makes the synchronous query.
subtest reload_state_request_reply => sub {
    my $rdir = tempdir(CLEANUP => 1);
    my $rsvc = My::Runner->new(workdir => $rdir, name => 'runner');
    $rsvc->start_service;

    my $kid = fork // die "fork: $!";
    unless ($kid) {
        # Child: pump the service until the parent's request is answered (or the
        # parent TERMs us), then exit.
        local $SIG{TERM} = sub { POSIX::_exit(0) };
        my $start = time;
        while ((time - $start) < 10) {
            $rsvc->service_io;
            sleep 0.01;
        }
        POSIX::_exit(0);
    }

    my $rclient = Test2::Harness2::Runner::Client->new(workdir => $rdir);
    my $got     = $rclient->reload_state;

    is(
        $got,
        {default => {'lib/Foo.pm' => {error => 'boom'}}},
        "reload_state query returns the runner's canonical reload_state hash",
    );

    kill('TERM', $kid);
    waitpid($kid, 0);
    $rsvc->close_service;
};

done_testing;
