use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use POSIX ();
use Time::HiRes qw/time sleep/;

use Test2::Harness2::Runner::Client;
use Test2::Harness2::Role::Service::Connection();

# #109: Test2::Harness2::Runner::Client::_send must CHECK send_request's result.
#
# Before the fix _send ignored the return: when a one-way submission
# (queue_run/queue_task/stop_run/end_queue/halt_run) hit a runner whose socket
# buffer had filled and the connection closed mid-send, the frame was silently
# dropped and the client reconnected and carried on. A dropped queue_task means
# those test files are never run yet the run still reports GREEN -- silent loss.
#
# #108 already gave client connections a bounded-blocking flush (they are not
# owner_flushes), so a merely-slow runner back-pressures rather than losing frames.
# So the contract is now: every queued task is delivered (backpressure) OR the
# client dies loudly -- never a silent green run with missing tasks.

# A minimal runner-shaped service that records the request envelopes it receives,
# using the same request_handler_<type> mechanism the real runner uses.
{
    package My::Runner;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} = []; return }

    sub request_handler_queue_run  ($self, $payload, $conn) { push @{$self->{+SEEN}} => ['queue_run',  $payload->{run}];     return undef }
    sub request_handler_queue_task ($self, $payload, $conn) { push @{$self->{+SEEN}} => ['queue_task', $payload->{task}];    return undef }
    sub request_handler_stop_run   ($self, $payload, $conn) { push @{$self->{+SEEN}} => ['stop_run',   $payload->{run_id}]; return undef }
    sub request_handler_end_queue  ($self, $payload, $conn) { push @{$self->{+SEEN}} => ['end_queue'];                      return undef }
}

# n bytes zstd cannot meaningfully compress, so a frame reliably exceeds the
# socket send buffer (mirrors t/AI/unit/Role_Service_backpressure.t).
sub incompressible {
    my ($n) = @_;
    my $data = '';
    if (open(my $ur, '<:raw', '/dev/urandom')) {
        while (length($data) < $n) {
            my $got = sysread($ur, my $chunk, $n - length($data));
            last unless $got;
            $data .= $chunk;
        }
        close $ur;
    }
    $data .= pack('N', int(rand(2**32))) while length($data) < $n;
    substr($data, $n) = '' if length($data) > $n;
    return unpack('H*', $data);    # hex => JSON-safe, still ~incompressible
}

# ---------------------------------------------------------------------------
# 1. Contract, deterministically: _send checks send_request's return. An undef
#    (connection closed during the send) must croak; a request_id must not.
# ---------------------------------------------------------------------------
subtest send_result_is_checked => sub {
    # A fake connection whose send_request returns a value we control (state on the
    # instance, so no closure-over-lexical footguns), pinning the exact contract
    # _send now depends on: undef => not delivered => croak; request_id => lives.
    {
        package Fake::Conn;
        sub new { my ($c, %a) = @_; bless {sent => [], ret => undef, %a}, $c }
        sub send_request {
            my ($self, $cmd, %args) = @_;
            push @{$self->{sent}} => [$cmd, {%args}];
            return $self->{ret};
        }
    }
    my $conn = Fake::Conn->new;

    my $client = Test2::Harness2::Runner::Client->new(workdir => '/nonexistent');
    no warnings 'redefine';
    local *Test2::Harness2::Runner::Client::connection = sub { $conn };

    # Delivered write: send_request returns a (truthy) request_id -> _send lives.
    $conn->{ret}  = 'req-id-123';
    $conn->{sent} = [];
    ok(lives { $client->queue_task({job_id => 'J1'}) }, "a delivered submission does not croak");
    is($conn->{sent}, [['queue_task', {task => {job_id => 'J1'}, want_reply => 0}]],
        "the frame was handed to send_request as a one-way (want_reply => 0) request");

    # Closed-during-send: send_request returns undef -> _send croaks (loud, not lost).
    $conn->{ret}  = undef;
    $conn->{sent} = [];
    like(
        dies { $client->queue_task({job_id => 'J2'}) },
        qr/submission not delivered/,
        "a submission whose write failed croaks instead of being silently dropped",
    );

    # Every one-way submitter routes through the same guard.
    like(dies { $client->queue_run({run_id => 'R'}) }, qr/submission not delivered/, "queue_run croaks on a failed write");
    like(dies { $client->stop_run('R') },              qr/submission not delivered/, "stop_run croaks on a failed write");
    like(dies { $client->end_queue },                  qr/submission not delivered/, "end_queue croaks on a failed write");
};

# ---------------------------------------------------------------------------
# 2. Backpressure delivers everything: a burst far larger than the socket buffer
#    against a reader that starts draining late still lands EVERY task (no loss),
#    and the client never croaks. Proves the #108 blocking flush + this check
#    give backpressure, not silent drops.
# ---------------------------------------------------------------------------
subtest every_task_arrives_under_backpressure => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $svc = My::Runner->new(workdir => $dir, name => 'runner');
    $svc->start_service;    # binds runner.socket before the client dials

    my $N   = 1000;
    my $pad = incompressible(2 * 1024);    # ~4KB/frame on the wire => >2MB burst

    pipe(my $rd, my $wr) or die "pipe: $!";

    my $kid = fork // die "fork: $!";
    unless ($kid) {
        # Reader: nap first so the parent's burst backs the socket buffer up (this
        # is the backpressure the parent must survive), THEN drain everything.
        close $rd;
        local $SIG{TERM} = sub { POSIX::_exit(0) };
        sleep 0.3;
        my $start = time;
        while ((time - $start) < 20) {
            $svc->service_io;
            my $tasks = grep { $_->[0] eq 'queue_task' } @{$svc->seen};
            if ($tasks >= $N) {
                syswrite($wr, "$tasks\n");
                POSIX::_exit(0);
            }
            sleep 0.005;
        }
        syswrite($wr, "TIMEOUT:" . (grep { $_->[0] eq 'queue_task' } @{$svc->seen}) . "\n");
        POSIX::_exit(0);
    }

    close $wr;

    # Parent: submit the whole burst. queue_task blocks (bounded) while the socket
    # buffer is full and the child is still napping; it must never croak or drop.
    my $ok = eval {
        my $client = Test2::Harness2::Runner::Client->new(workdir => $dir);
        $client->queue_run({run_id => 'R1'});
        $client->queue_task({job_id => "J$_", run_id => 'R1', file => "t/$_.t"}) for 1 .. $N;
        $client->stop_run('R1');
        1;
    };
    my $err = $@;
    ok($ok, "the full burst submitted without a croak (backpressure, not loss)") or diag($err);

    my $got = readline($rd) // '';
    chomp $got;
    kill('TERM', $kid);
    waitpid($kid, 0);
    $svc->close_service;

    is($got, $N, "every one of the $N queued tasks arrived on the runner side (no silent drop)");
};

# ---------------------------------------------------------------------------
# 3. The client dies loudly on a stalled reader: a burst against a runner that
#    binds but NEVER reads must NOT return quietly (the old silent-loss bug); it
#    must croak once the connection stalls out and closes mid-send.
# ---------------------------------------------------------------------------
subtest client_dies_loudly_on_stalled_reader => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $svc = My::Runner->new(workdir => $dir, name => 'runner');
    $svc->start_service;    # binds, but we NEVER call service_io: nothing is read

    # Give the client's connection a tight stall window so the stalled-reader path
    # resolves in a fraction of a second instead of the 10s production default.
    my $orig_new = \&Test2::Harness2::Role::Service::Connection::new;
    no warnings 'redefine';
    local *Test2::Harness2::Role::Service::Connection::new = sub {
        my $class = shift;
        my %args = (@_ == 1 && ref($_[0]) eq 'HASH') ? %{$_[0]} : @_;
        $args{stall_timeout} //= 0.3;
        return $class->$orig_new(%args);
    };

    my $client = Test2::Harness2::Runner::Client->new(workdir => $dir);
    my $pad    = incompressible(256 * 1024);    # each task frame overflows the buffer

    my $start = time;
    my $sent  = 0;
    my $ok    = eval {
        for (1 .. 200) {
            $client->queue_task({job_id => "J$_", run_id => 'R1', file => "t/$_.t", pad => $pad});
            $sent++;
        }
        1;
    };
    my $err = $@;
    my $el  = time - $start;

    ok(!$ok, "submitting a burst to a stalled reader dies (never a silent, complete return)");
    like($err, qr/submission not delivered/, "and it dies with the submission-integrity croak");
    ok($el < 5, "it died bounded (backpressure stall window), no hang: ${el}s");
    ok($sent < 200, "it stopped short of the full burst rather than pretending to deliver it ($sent sent)");

    $svc->close_service;
};

done_testing;
