use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Runner::Subscriber;

# 5f: a client subscribes to a runner over runner.socket, receives a serialized
# snapshot of the runner's canonical state, then receives FORWARDED mutations --
# both a folded collector transition AND a runner-ORIGINATED mutation -- and its
# local mirror ends up matching the runner's state. The run_uuid proxy fan-out of
# the 2.0b reference is intentionally not exercised (single runner.socket).

# A minimal Role::Service consumer standing in for the runner's state hub. It
# folds collector transitions into a Monitor and forwards them to subscribers,
# originates its own job mutations, and answers a subscribe request with a
# snapshot -- mirroring Test2::Harness2::Runner's 5e/5f wiring without the full
# runner's dir/settings machinery. It runs in a child process so the parent can
# drive the real Subscriber (which blocks on its synchronous snapshot reply).
{
    package My::Hub;
    use v5.38;
    use Object::HashBase qw/<workdir <name +monitor/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    use Test2::Collector::Util::Zstd qw/compress_blob/;
    use Test2::Harness2::Util::JSON qw/encode_json/;
    use Test2::Harness2::Runner::Monitor;

    sub monitor ($self) { $self->{+MONITOR} //= Test2::Harness2::Runner::Monitor->new }

    sub request_handler_subscribe ($self, $payload, $conn) {
        $self->add_subscriber($conn) if defined $conn;
        return {ok => 1, snapshot => $self->monitor->snapshot};
    }

    # Fold a collector transition AND forward the verbatim frame to subscribers.
    sub service_transition ($self, $payload, $frame, $conn) {
        $self->monitor->feed($payload);
        $self->forward_frame($frame) if $frame;
        return;
    }

    # Originate a job mutation: fold locally and forward as a harness_runner_job
    # frame, exactly like Test2::Harness2::Runner::announce_job.
    sub announce_job ($self, $job_id, $state, %extra) {
        my $payload = {facet_data => {harness_runner_job => {job_id => $job_id, state => $state, %extra}}};
        $self->monitor->feed($payload);
        $self->forward_frame(compress_blob(encode_json($payload)));
        return;
    }

    # Drive a few scripted state mutations on a timer once a subscriber appears,
    # so the parent observes them flow over the subscription.
    sub service_tick ($self) {
        return unless keys %{$self->{service_subs} // {}};

        my $step = $self->{step} //= 0;

        if ($step == 0) {
            # A folded collector transition (a reporter's start frame).
            my $payload = {facet_data => {
                harness_collector        => {uuid => 'POST', name => 't/post.t', events_file => $self->{+WORKDIR} . '/post.jsonl.zst', try => 1},
                harness_state_transition => {state => 'starting', stamp => 1},
            }};
            $self->service_transition($payload, compress_blob(encode_json($payload)), undef);
        }
        elsif ($step == 1) {
            # A runner-ORIGINATED mutation.
            $self->announce_job('JOB-A', 'running', stage => 'default', file => 't/a.t', run_id => 'RUN-1');
        }
        elsif ($step == 2) {
            $self->stop_service;
        }

        $self->{step}++;
        return;
    }
}

my $dir = tempdir(CLEANUP => 1);

# Build the hub and seed canonical state BEFORE forking, so the snapshot the
# subscriber receives is non-empty and must be reconstructed in the mirror.
my $hub = My::Hub->new(workdir => $dir, name => 'runner');
$hub->monitor->feed({facet_data => {
    harness_collector        => {uuid => 'PRE', name => 't/pre.t', events_file => "$dir/pre.jsonl.zst", try => 1},
    harness_state_transition => {state => 'starting', stamp => 1},
}});
$hub->announce_job('JOB-A', 'dispatched', stage => 'default', file => 't/a.t', run_id => 'RUN-1');

my $pid = fork;
defined $pid or die "fork failed: $!";
if (!$pid) {
    $hub->start_service;
    $hub->run;
    exit 0;
}

# --- parent: drive the real Subscriber against the live hub ---

my $sub = Test2::Harness2::Runner::Subscriber->new(workdir => $dir);
$sub->subscribe;
ok($sub->subscribed, "subscribed to the runner");

my $mirror = $sub->monitor;

# Snapshot reconstructed the pre-subscribe state. (A forwarded mutation may already
# have arrived batched with the snapshot reply, so assert PRE is present rather than
# that it is the ONLY collector.)
ok(scalar(grep { $_ eq 'PRE' } $mirror->tests), "snapshot carried the pre-subscribe collector");
is($mirror->collector('PRE')->{events_file}, "$dir/pre.jsonl.zst", "snapshot carried collector detail");
# JOB-A was 'dispatched' at snapshot time, but a forwarded 'running' mutation can
# arrive batched with the snapshot reply under load, so assert the job is present
# (state dispatched OR already advanced to running) rather than pinning the state.
ok($mirror->job('JOB-A'), "snapshot carried the runner-originated job");
like($mirror->job('JOB-A')->{state}, qr/^(dispatched|running)$/, "job state is dispatched or already-forwarded running");
is($mirror->job('JOB-A')->{stage}, 'default', "snapshot carried job detail");

# Poll forwarded mutations until both arrive (or time out).
my $deadline = Time::HiRes::time() + 15;
until (($mirror->collector('POST') && ($mirror->job('JOB-A')->{state} // '') eq 'running') || Time::HiRes::time() > $deadline) {
    $sub->poll;
    sleep 0.02;
}

# (1) folded collector transition reached the mirror.
ok($mirror->collector('POST'), "forwarded collector transition reached the mirror");
is($mirror->collector('POST')->{events_file}, "$dir/post.jsonl.zst", "forwarded transition detail in the mirror");
is([sort $mirror->tests], ['POST', 'PRE'], "both collectors tracked in the mirror");

# (2) runner-ORIGINATED mutation reached the mirror.
is($mirror->job('JOB-A')->{state}, 'running', "forwarded runner-originated mutation reached the mirror");

waitpid($pid, 0);
ok(1, "hub child exited");

done_testing;
