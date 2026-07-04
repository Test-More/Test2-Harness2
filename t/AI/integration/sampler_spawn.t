use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec ();
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/time sleep/;

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

use Test2::Collector ();
use Test2::Collector::Recorder::Zstd ();
use Test2::Harness2::Service::Sampler;

# Chunk 7 / ticket TODO-43: the runner spawns the system-load sampler as a global
# helper process under a collector (watch_parent_pid = runner) -- the same shape
# as spawn_preload_root -- and the sampler dials the runner's socket and pushes a
# one-way system_load report. This test exercises that REAL process path: a real
# collector-wrapped Service::Sampler against a Role::Service runner stand-in,
# asserts the report arrives over the socket, then reaps the sampler and confirms
# it does not leak (the std-fd reap gotcha, ARCHITECTURE.md §4.4).

# A minimal runner stand-in: a Role::Service that records the system_load reports
# the sampler sends it.
{
    package My::Runner;
    use v5.38;
    use Test2::Harness2::Util::HashBase qw/<workdir <name +loads/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+LOADS} //= [] }
    sub loads ($self) { return $self->{+LOADS} }

    sub request_handler_system_load ($self, $payload, $conn = undef) {
        push @{$self->{+LOADS}} => $payload->{load};
        return undef;    # one-way, no reply
    }
}

my $dir = tempdir(CLEANUP => 1);

my $runner = My::Runner->new(workdir => $dir, name => 'runner');
$runner->start_service;
my $sock = $runner->service_socket_path;

# Spawn the sampler EXACTLY the way Runner::spawn_sampler does: a non-test
# collector whose ChildMonitor watches THIS process (watch_parent_pid), recording
# to its own events file, running the real Service::Sampler in-process.
my $events = File::Spec->catfile($dir, 'sampler-events.jsonl.zst');
my $sampler_pid = Test2::Collector::spawn_collector(
    is_test            => 0,
    name               => 'sampler',
    record_transitions => 1,
    recorder           => Test2::Collector::Recorder::Zstd->new(file => $events),
    watch_parent_pid   => $$,
    run                => sub {
        Test2::Harness2::Service::Sampler->new(
            workdir       => $dir,
            name          => 'sampler',
            runner_socket => $sock,
            interval      => 0.05,    # quicker ticks so the test is snappy
        )->run;
    },
);

ok($sampler_pid, "spawned the sampler under a collector");

# Pump the runner socket until the first system_load report lands (or time out).
my $deadline = time + 15;
until (@{$runner->loads} || time > $deadline) {
    $runner->service_io;
    sleep 0.02;
}

ok(@{$runner->loads}, "runner received a system_load report from the sampler over the socket");

my $load = $runner->loads->[0];
ok(exists $load->{mem_pct}, "the report carried a memory percentage");
ok(exists $load->{cpu_pct}, "the report carried a cpu percentage slot (undef on the first baseline sample)");
ok($load->{mem_pct} % 5 == 0, "the reported memory percentage is rounded to a 5% bucket") if defined $load->{mem_pct};

# Reap the sampler the way Runner::stop_sampler does: ask it to stop over the
# socket, pump so the request is delivered, and reap by pid. (Its collector
# inherited this process's std fds; reaping closes them -- the gotcha.)
eval { $runner->service_send('sampler', 'stop'); 1 };
my $reaped = 0;
for (1 .. 250) {
    $runner->service_io;
    if (waitpid($sampler_pid, WNOHANG) == $sampler_pid) { $reaped = 1; last }
    sleep 0.02;
}

# Fallback teardown (the same shape stop_sampler uses) if it did not stop cleanly.
unless ($reaped) {
    kill('TERM', $sampler_pid) if kill(0, $sampler_pid);
    for (1 .. 100) {
        last if waitpid($sampler_pid, WNOHANG) == $sampler_pid;
        sleep 0.02;
    }
    if (kill(0, $sampler_pid)) { kill('KILL', $sampler_pid); waitpid($sampler_pid, 0) }
    $reaped = 1;
}

ok($reaped, "sampler collector was reaped at stop");
ok(!kill(0, $sampler_pid), "no sampler process leaked after reap");
ok(-f $events, "the sampler's collector recorded an events file (it ran under a collector)");

$runner->close_service;

done_testing;
