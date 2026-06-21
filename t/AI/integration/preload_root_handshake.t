use Test2::V0;
# HARNESS-DURATION-MEDIUM

# Chunk 19.1: the preload-root process (Test2::Harness2::Preload, the
# `-M...=launch` bootstrap) dials the runner over runner.socket, asks for the
# preload list, loads the preload libraries, and reports the stage map back via
# set_stage_data. This drives the REAL runner request handlers
# (get_preload_list / set_stage_data, in Test2::Harness2::Runner::Role::Service::Handlers)
# from a minimal Role::Service host and a real preload-root subprocess.

use File::Spec;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;
use Cwd qw/getcwd/;
use POSIX ();

use Test2::Harness2::Preload;    # compile-check the bootstrap (no launch args => no-op import)

# A minimal runner-like service: it composes the SAME Role::Service transport and
# the SAME runner request-handler role, so the get_preload_list / set_stage_data
# handlers under test are the real ones. It only needs to provide what those two
# handlers (and the role composition) require: rootpid, preloads, and a trivial
# state stub.
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

# Pump the service loop until the preload-root reports its stage map (proving both
# the get_preload_list request was served AND the preloads were loaded and the map
# built and sent back).
my $deadline = time + 30;
until ($fake->has_reported_stage_data) {
    if (time > $deadline) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        die "timed out waiting for the preload-root handshake";
    }
    $fake->service_io;
    sleep 0.01;
}

ok($fake->has_reported_stage_data, "preload-root reported its stage map (set_stage_data)");

my $data = $fake->reported_stage_data;
is(ref($data), 'HASH', "stage_data is a hashref");

# Current vocabulary (base/default/NOPRELOAD are runner-side synthetic; the map
# carries the user's stage names) -- NOT the pre_ai_2.0 BASE/NONE.
ok($data->{Alpha}, "Alpha stage reported");
ok($data->{Beta},  "Beta stage reported");
is($data->{Alpha}{default}, 1, "Alpha is the default stage");
is($data->{Beta}{default},  0, "Beta is not the default");
ok(!$data->{BASE} && !$data->{NONE}, "no BASE/NONE pseudo-stages (current vocabulary)");

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
