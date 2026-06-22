use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use Test2::Util qw/CAN_REALLY_FORK/;

use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Runner::Subscriber;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

# Chunk 7 / ticket #43: the runner stores the sampler's system_load snapshot and
# announces a harness_system transition that is BROADCAST GLOBALLY to every
# subscriber (latest retained for late subscribers). This drives a real Subscriber
# against a Role::Service hub that mirrors the runner's announce_system_load
# wiring, and asserts the snapshot reaches the mirror's system_load() both via the
# initial snapshot (late subscriber) and via a forwarded mutation (live).

{
    package My::Hub;
    use v5.38;
    use Test2::Harness2::Util::HashBase qw/<workdir <name +monitor +step/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    use Test2::Collector::Util::Zstd qw/compress_blob/;
    use Test2::Harness2::Util::JSON qw/encode_json/;
    use Test2::Harness2::Runner::Monitor;

    sub monitor ($self) { $self->{+MONITOR} //= Test2::Harness2::Runner::Monitor->new }

    sub request_handler_subscribe ($self, $payload, $conn) {
        $self->add_subscriber($conn, $payload->{run_id}) if defined $conn;
        return {ok => 1, snapshot => $self->monitor->snapshot($payload->{run_id})};
    }

    # Mirror Test2::Harness2::Runner::announce_system_load: fold the snapshot and
    # forward it GLOBALLY (run_id => undef), so every subscriber sees it.
    sub announce_system_load ($self, $load) {
        my $payload = {facet_data => {harness_system => $load}};
        $self->monitor->feed($payload);
        $self->forward_frame(compress_blob(encode_json($payload)), undef);
        return;
    }

    sub service_tick ($self) {
        return unless keys %{$self->{service_subs} // {}};

        my $step = $self->{+STEP} //= 0;

        # Once a subscriber appears, push a live load change, then stop.
        $self->announce_system_load({cpu_pct => 75, mem_pct => 20, load_avg => [1, 1, 1]}) if $step == 0;
        $self->stop_service if $step == 1;

        $self->{+STEP}++;
        return;
    }
}

my $dir = tempdir(CLEANUP => 1);

# Seed a load snapshot BEFORE the subscriber connects, so the snapshot it receives
# already carries current load (the late-subscriber path).
my $hub = My::Hub->new(workdir => $dir, name => 'runner');
$hub->announce_system_load({cpu_pct => 45, mem_pct => 10, load_avg => [0.5, 0.4, 0.3]});

my $pid = fork // die "fork failed: $!";
if (!$pid) {
    $hub->start_service;
    until ($hub->service_stopped) {
        $hub->service_io;
        $hub->service_tick;
        Time::HiRes::sleep(0.01);
    }
    $hub->close_service;
    exit 0;
}

# --- parent: drive the real Subscriber against the live hub ---

my $sub = Test2::Harness2::Runner::Subscriber->new(workdir => $dir);
$sub->subscribe;
ok($sub->subscribed, "subscribed to the runner");

my $mirror = $sub->monitor;

# Late subscriber: the snapshot carried current load (the pre-subscribe value, or
# the forwarded change already batched with the snapshot reply under load -- like
# the JOB-A state race in Runner_Subscriber.t).
ok($mirror->system_load, "snapshot carried current system load to the late subscriber");
ok($mirror->system_load->{cpu_pct} == 45 || $mirror->system_load->{cpu_pct} == 75,
    "snapshot system_load cpu_pct is the seeded value (or the already-forwarded change)");
ok(defined $mirror->system_load->{load_avg}, "snapshot system_load carried the load average too");

# Live: poll until the forwarded load change (cpu 75) reaches the mirror.
my $deadline = Time::HiRes::time() + 15;
until ((($mirror->system_load->{cpu_pct} // 0) == 75) || Time::HiRes::time() > $deadline) {
    $sub->poll;
    sleep 0.02;
}

is($mirror->system_load->{cpu_pct}, 75, "forwarded system-load change reached the mirror (broadcast globally)");
is($mirror->system_load->{mem_pct}, 20, "forwarded system_load mem_pct updated");

waitpid($pid, 0);
ok(1, "hub child exited");

done_testing;
