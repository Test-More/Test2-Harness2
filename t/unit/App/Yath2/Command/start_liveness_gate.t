use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use IO::Socket::UNIX;

use App::Yath2::Command::start;
use App::Yath2::Discovery;

# Ticket TODO-123: `yath start [-d]` must not print 'Persistent runner started!' and
# exit 0 until it has confirmed the runner is actually SERVING. The runner writes
# its PID file BEFORE it binds runner.socket and BEFORE it spawns the preload tree,
# so a PID file proves only that it forked -- a broken -P module still exits on the
# fail-fast path after writing PID. These tests drive the bounded liveness gate
# (wait_for_runner_pid + wait_for_runner_live) and the honest failure reporter.

# A queue-backed stand-in: each method call shifts the next scripted value, sticking
# on the last value once the queue drains (so a steady state can be expressed as a
# single element).
{
    package MockClient;
    sub new { my ($c, @g) = @_; bless {gone => [@g]}, $c }
    sub runner_gone { my $s = shift; @{$s->{gone}} > 1 ? shift(@{$s->{gone}}) : $s->{gone}[0] }

    package MockDisco;
    sub new { my ($c, %p) = @_; bless {%p}, $c }
    sub link    { $_[0]->{link} }
    sub workdir { $_[0]->{workdir} }
    sub resolves { my $s = shift; @{$s->{resolves}} > 1 ? shift(@{$s->{resolves}}) : $s->{resolves}[0] }
    sub pid      { my $s = shift; @{$s->{pid}}      > 1 ? shift(@{$s->{pid}})      : $s->{pid}[0] }

    package MockSettings;
    sub new { bless {}, shift }
}

sub start_cmd {
    my (%client) = @_;
    my $start = App::Yath2::Command::start->new(settings => MockSettings->new);
    $start->{client} = MockClient->new(@{$client{gone} // [0]});
    return $start;
}

# --- wait_for_runner_live -------------------------------------------------------

# Becomes live after a couple of not-yet-bound polls -> 'live' (proves it polls, and
# does not falsely fail while the socket is still coming up).
{
    my $start = start_cmd(gone => [0]);
    my $disco = MockDisco->new(resolves => [0, 0, 1]);
    is($start->wait_for_runner_live($disco), 'live', "waits through the boot window, then reports live");
}

# The broken-preload / boot-crash case: the runner process is gone. Death is checked
# FIRST, so even a socket that would momentarily resolve live loses to the death
# signal -> 'gone' (deterministic; no false success).
{
    my $start = start_cmd(gone => [1]);
    my $disco = MockDisco->new(resolves => [1]);
    is($start->wait_for_runner_live($disco), 'gone', "a gone runner is reported gone even if the socket would resolve live");
}

# Never live, never gone -> bounded timeout (a wedged runner can never hang start).
{
    local $ENV{YATH_START_LIVENESS_TIMEOUT} = 0.2;
    my $start = start_cmd(gone => [0]);
    my $disco = MockDisco->new(resolves => [0]);
    is($start->wait_for_runner_live($disco), 'timeout', "a runner that never serves times out (bounded)");
}

# --- wait_for_runner_live against a REAL live socket + real Discovery ------------
{
    my $dir    = tempdir(CLEANUP => 1);
    my $target = File::Spec->catfile($dir, 'runner.socket');
    my $link   = File::Spec->catfile($dir, 'runner.link');

    # A real listening unix socket is what probe()'s non-blocking connect accepts.
    my $listen = IO::Socket::UNIX->new(Local => $target, Listen => 1)
        or plan skip_all => "could not create a unix listen socket: $!";
    symlink($target, $link) or die "symlink: $!";

    my $disco = App::Yath2::Discovery->new(link => $link, workdir => $dir);
    my $start = start_cmd(gone => [0]);

    is($start->wait_for_runner_live($disco), 'live', "resolves a REAL live runner.socket as live via TODO-145 probe()");

    close($listen);
}

# --- wait_for_runner_pid --------------------------------------------------------

# Happy path: the PID file yields a pid -> return it.
{
    my $start = start_cmd(gone => [0]);
    my $disco = MockDisco->new(pid => [4242]);
    is($start->wait_for_runner_pid($disco), 4242, "returns the runner pid once the PID file appears");
}

# The runner dies before writing its PID: bail immediately (undef) instead of
# stalling the full window -- the old `for (1 .. 600)` sat here silently for ~30s.
{
    my $start = start_cmd(gone => [1]);
    my $disco = MockDisco->new(pid => [undef]);
    is($start->wait_for_runner_pid($disco), undef, "a boot crash before the PID write bails early with undef");
}

# --- _report_start_failure ------------------------------------------------------

# Honest failure: nonzero return, and it does not throw.
{
    my $start = start_cmd(gone => [0]);
    my $rc;
    my $err;
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die "capture STDERR: $!";
        $rc = $start->_report_start_failure('/some/dir', 999, "it exploded");
    }
    is($rc, 1, "_report_start_failure returns a nonzero exit code");
    like($err, qr/failed to start.*pid 999.*it exploded/s, "the failure names the pid and the reason");
    like($err, qr/yath watch/, "the failure points the user at the runner's recorded output");
}

done_testing;
