use Test2::V0;
# HARNESS-DURATION-MEDIUM

# The preload-root process (Test2::Harness2::Preload, the `-M...=launch`
# bootstrap) dials the runner over runner.socket and performs a LIGHTWEIGHT
# handshake: it identifies itself and asks the runner for the preload list (which
# also conveys the real runner pid + the persistent-vs-transient flag). It does
# NOT load the preload libraries here -- that happens once, later, under the
# test2_start_preload guard in the stage host (Test2::Harness2::Preload::Host),
# which is also where the stage map (set_stage_data) is reported. So this test
# drives the REAL runner request handlers (get_preload_list, in
# Test2::Harness2::Runner::Role::Service::Handlers) from a minimal Role::Service
# host and a real preload-root subprocess, and confirms the handshake completes
# and the channel is bidirectional (the preload-root reports back over it).
#
# The stage map itself is reported by the stage host, which needs a full run
# workdir (settings.json + a run to schedule); that path is exercised by the
# preloaded end-to-end integration runs, not by this minimal handshake test. Here
# the stage host has no settings.json, so the preload-root reports
# stage_host_exited back over the SAME channel -- which is exactly the signal we
# wait on to prove the handshake + bidirectional channel work end-to-end.

use File::Spec;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;
use Cwd qw/getcwd/;
use POSIX ();

use Test2::Harness2::Preload;    # compile-check the bootstrap (no launch args => no-op import)

# A minimal runner-like service: it composes the SAME Role::Service transport and
# the SAME runner request-handler role, so the get_preload_list handler under test
# is the real one. It only needs to provide what that handler (and the role
# composition) require: rootpid, preloads, and a trivial state stub.
BEGIN {
    package FakeRunner;
    use Test2::Harness2::Util::HashBase qw{ <workdir <preloads <monitor_preloads };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';
    with 'Test2::Harness2::Runner::Role::Service::Handlers';

    sub name  { 'runner' }
    sub state { $_[0]->{state} //= bless {}, 'FakeState' }

    sub init {
        my $self = shift;
        $self->{rootpid} = $$;
        $self->{+PRELOADS} //= [];
    }
}

my $tmp    = tempdir(CLEANUP => 1);
my $socket = File::Spec->catfile($tmp, 'runner.socket');

my $fake = FakeRunner->new(workdir => $tmp, preloads => ['TestRootPreload']);
$fake->start_service;
ok(-S $socket, "runner.socket is bound");

my $fixture_lib = File::Spec->rel2abs('t/AI/integration/preload_root_handshake/lib', getcwd());

# Fork+exec a clean perl that loads the bootstrap with launch. This is exactly the
# command the runner builds (minus the collector wrap, which is the runner's
# concern and not what this test exercises).
my @inc = grep { !ref($_) && length($_) && $_ ne '.' } @INC;
my @cmd = (
    $^X,
    (map { "-I$_" } @inc),
    "-I$fixture_lib",
    "-MTest2::Harness2::Preload=launch,$socket",
    '-e' => '1;',
);

my $pid = fork // die "Could not fork: $!";
unless ($pid) {
    # child
    exec {$cmd[0]} @cmd or die "exec failed: $!";
}

# Pump the service loop until the preload-root reports back over the channel. It
# completes the handshake (get_preload_list served -> it learned the runner pid),
# then drives the stage host. With no settings.json here the host cannot come up,
# so the preload-root reports stage_host_exited over the SAME channel it dialed --
# proving the handshake succeeded AND the channel is bidirectional with the real
# runner handlers.
my $deadline = time + 30;
until ($fake->stage_host_exited) {
    if (time > $deadline) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        die "timed out waiting for the preload-root handshake";
    }
    $fake->service_io;
    sleep 0.01;
}

ok($fake->stage_host_exited, "preload-root completed the handshake and reported back over the channel");

# The preload-root only reaches the stage-host attempt (and thus stage_host_exited)
# after a successful get_preload_list -- a failed handshake never gets that far --
# so this confirms the real get_preload_list handler served the request.
ok($fake->{service_peers}{'preload-root'}, "preload-root connected and identified as the 'preload-root' peer");

# The stage map is NOT reported by the bare handshake anymore (it is the stage
# host's job, covered by the preloaded end-to-end runs); confirm it stayed absent
# here.
ok(!$fake->has_reported_stage_data, "the bare handshake does not report the stage map (the stage host does)");

# Tell the preload-root to stop, pump so it is delivered, and reap it.
$fake->service_send('preload-root', 'stop');
for (1 .. 200) {
    $fake->service_io;
    last if waitpid($pid, POSIX::WNOHANG()) == $pid;
    sleep 0.01;
}
if (kill(0, $pid)) {
    kill('TERM', $pid);
    waitpid($pid, 0);
}
ok(1, "preload-root stopped and reaped");

$fake->close_service;

done_testing;
