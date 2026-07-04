use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness2::Service::Sampler;

# TODO-134/TODO-138: service_tick's cadence (next_at / $now) is MONOTONIC interval math
# (mono_time), not wall clock. The connection-driven subtests below poke the
# private next_at field to force a tick, so they must use the SAME clock -- a
# wall-clock value would never satisfy the monotonic `$now < next_at` gate and
# the tick body would never run.
use Test2::Harness2::Util qw/mono_time/;

# The sampler samples every tick but reports only when a metric (cpu or memory),
# rounded up to the nearest 5%, changes from the last sent: increases
# immediately, decreases only once they have held for decrease_delay. A message
# is sent when EITHER metric triggers and carries both rounded values.

sub sampler (%args) {
    return Test2::Harness2::Service::Sampler->new(
        workdir       => tempdir(CLEANUP => 1),
        runner_socket => '/unused/in/this/test',
        interval      => 0.2,
        decrease_delay => 1.0,
        %args,
    );
}

# Drive one metric's policy the way service_tick does: decide, then commit if it
# fired. Returns the rounded value when it would send, else undef.
sub feed ($s, $name, $raw, $now) {
    my $r = $s->_round_up_5($raw);
    my $t = $s->_metric_triggers($name, $r, $now);
    $s->_commit_metric($name, $r) if $t;
    return $t ? $r : undef;
}

subtest round_up_5 => sub {
    my $s = sampler();
    is($s->_round_up_5(0),    0,   "0 -> 0");
    is($s->_round_up_5(0.1),  5,   "0.1 -> 5");
    is($s->_round_up_5(5),    5,   "exact 5 stays 5");
    is($s->_round_up_5(50),   50,  "exact 50 stays 50");
    is($s->_round_up_5(51),   55,  "51 -> 55");
    is($s->_round_up_5(99.9), 100, "99.9 -> 100");
    is($s->_round_up_5(100),  100, "100 -> 100");
};

subtest initial_and_increase => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 42, 1), 45,    "first reading sent, rounded up");
    is(feed($s, 'cpu', 43, 2), undef, "same 5% bucket sends nothing");
    is(feed($s, 'cpu', 46, 3), 50,    "increase reported immediately");
    is(feed($s, 'cpu', 61, 4), 65,    "another increase, immediately");
};

subtest decrease_must_persist => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 48, 0),    50,    "start at 50");
    is(feed($s, 'cpu', 41, 10.0), undef, "decrease (->45) not trusted yet");
    is(feed($s, 'cpu', 41, 10.5), undef, "still inside the 1s window");
    is(feed($s, 'cpu', 41, 10.9), undef, "still inside the 1s window");
    is(feed($s, 'cpu', 41, 11.0), 45,    "held >= 1s -> reported");
    is(feed($s, 'cpu', 41, 11.2), undef, "steady at 45 -> nothing");
};

subtest equal_resets_window => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 58, 0),   60,    "start at 60");
    is(feed($s, 'cpu', 41, 1.0), undef, "decrease window opens");
    is(feed($s, 'cpu', 57, 1.5), undef, "back to 60 (==last) breaks the window");
    is(feed($s, 'cpu', 41, 2.0), undef, "window restarts");
    is(feed($s, 'cpu', 41, 2.9), undef, "only 0.9s in");
    is(feed($s, 'cpu', 41, 3.0), 45,    "1s into the restarted window -> sent");
};

subtest increase_during_decrease_window => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 58, 0),   60,    "start at 60");
    is(feed($s, 'cpu', 41, 1.0), undef, "decrease window opens");
    is(feed($s, 'cpu', 72, 1.2), 75,    "increase during the window fires immediately");
    is(feed($s, 'cpu', 41, 2.0), undef, "fresh decrease window");
    is(feed($s, 'cpu', 41, 2.5), undef, "still within it");
};

subtest memory_uses_the_same_policy => sub {
    my $s = sampler();
    is(feed($s, 'mem', 12, 0),    15,    "memory rounded up and sent");
    is(feed($s, 'mem', 11, 1),    undef, "same bucket, nothing");
    is(feed($s, 'mem', 16, 2),    20,    "memory increase immediate");
    is(feed($s, 'mem', 6,  10.0), undef, "memory decrease not trusted yet");
    is(feed($s, 'mem', 6,  11.0), 10,    "memory decrease held >= 1s -> sent");
};

# A FakeSource yields a fixed sequence of [cpu, mem] readings.
package FakeSource {
    sub new ($class, @samples) { bless {s => [@samples]}, $class }
    sub sample ($self) {
        my $p = shift @{$self->{s}};
        return {cpu_pct => $p->[0], mem_pct => $p->[1], ncpu => 4};
    }
}

# A minimal peer service that accepts the sampler's connection and collects the
# system_load requests it sends. It consumes Role::Service (so the identity
# handshake and framing match the real runner) and records each system_load load.
package FakeRunner {
    use Test2::Harness2::Util::HashBase qw{ <workdir <name +loads };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+LOADS} //= [] }
    sub loads ($self) { return $self->{+LOADS} }

    sub request_handler_system_load ($self, $payload, $conn = undef) {
        push @{$self->{+LOADS}} => $payload->{load};
        return undef;    # one-way
    }
}

subtest either_metric_triggers_a_send_over_a_real_connection => sub {
    my $wd = tempdir(CLEANUP => 1);

    my $runner = FakeRunner->new(workdir => $wd, name => 'runner');
    $runner->start_service;
    my $sock = $runner->service_socket_path;

    # [cpu, mem]: t1 both initial; t2 mem up only; t3 nothing; t4 cpu up only.
    my $s = sampler(
        workdir       => $wd,
        runner_socket => $sock,
        source        => FakeSource->new([42, 10], [43, 11], [43, 11], [80, 11]),
    );
    $s->start_service;
    $s->{conn} = $s->service_connect_peer('runner', $sock) or die "sampler could not dial runner";

    # Pump both sides until a load report lands (or a short deadline).
    my $tick = sub {
        my ($want) = @_;
        my $deadline = time + 2;
        while (time < $deadline) {
            $runner->service_io;
            $s->service_io;
            $s->{next_at} = mono_time() - 1;
            $s->service_tick;
            $runner->service_io;
            return if @{$runner->loads} >= $want;
            Time::HiRes::sleep(0.01);
        }
    };

    $tick->(1);
    my $m1 = $runner->loads->[0];
    is($m1->{cpu_pct}, 45, "t1 reports rounded cpu");
    is($m1->{mem_pct}, 10, "t1 reports rounded mem");

    $tick->(2);
    my $m2 = $runner->loads->[1];
    is($m2->{mem_pct}, 15, "memory increase triggered the send");
    is($m2->{cpu_pct}, 45, "...carrying the current rounded cpu too");

    # t3 changes nothing; t4 cpu jumps. The third recorded load is the t4 send.
    $tick->(3);
    my $m4 = $runner->loads->[2];
    is($m4->{cpu_pct}, 80, "cpu increase triggered the send");
    is($m4->{mem_pct}, 15, "...carrying the current rounded mem too");

    $runner->close_service;
    $s->close_service;
};

subtest stops_when_connection_breaks => sub {
    my $wd = tempdir(CLEANUP => 1);

    my $runner = FakeRunner->new(workdir => $wd, name => 'runner');
    $runner->start_service;
    my $sock = $runner->service_socket_path;

    my $s = sampler(
        workdir       => $wd,
        runner_socket => $sock,
        source        => FakeSource->new([10, 10], [20, 10], [30, 10]),
    );
    $s->start_service;
    $s->{conn} = $s->service_connect_peer('runner', $sock) or die "sampler could not dial runner";

    # First tick sends.
    $runner->service_io;
    $s->service_io;
    $s->{next_at} = mono_time() - 1; $s->service_tick;
    $runner->service_io;

    # Runner goes away.
    $runner->close_service;

    # Subsequent ticks should detect the broken connection and stop the sampler.
    for (1 .. 20) {
        $s->service_io;
        $s->{next_at} = mono_time() - 1; $s->service_tick;
        last if $s->service_stopped;
        Time::HiRes::sleep(0.01);
    }

    ok($s->service_stopped, "sampler stops when the runner connection breaks");

    $s->close_service;
};

done_testing;
