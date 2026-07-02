use Test2::V0;
# HARNESS-DURATION-SHORT

# #135 finding 16: a sampler/aux process reaped by the runner's subreaper sweep was
# invisible to stop_sampler/stop_aux (only PRELOAD_ROOT had a sweep-side guard), so
# shutdown TERM/KILLed a possibly-RECYCLED pid and stalled 5s+2s after a sampler crash.
# Two layers, exercised here against the REAL Runner methods:
#   G1: _bring_out_yer_dead clears the SAMPLER_PID slot (+ splices AUX_PIDS) when it
#       reaps one, so stop_* never reads a stale pid.
#   G2/G3: stop_sampler/stop_aux signal a pid ONLY when the immediately-preceding
#       waitpid(WNOHANG) returned 0 (still our live child); a waitpid of the pid (reaped
#       here) or -1 (ECHILD) is terminal -- clean the slot and return WITHOUT signaling
#       and WITHOUT the 5s+2s spin. No kill(0) liveness test (the pid-reuse hazard).

use POSIX ();
use Time::HiRes ();

use Test2::Harness2::Runner;

{
    package FakeReapRunner;
    our @ISA = ('Test2::Harness2::Runner');

    sub new {
        my ($class, %args) = @_;
        return bless {
            rootpid          => $$,
            procs            => $args{procs} // {},
            waiting          => {},
            sampler_pid      => $args{sampler_pid},
            aux_pids         => $args{aux_pids} // [],
            preload_root_pid => undef,
            service_io_calls => 0,
        }, $class;
    }

    # Stub the socket surface stop_sampler pumps -- no real service here.
    sub service_io   { $_[0]->{service_io_calls}++; return }
    sub service_send { return 1 }
}

{
    # A Runner whose _emit_preload_failure_output is recorded (not routed through the
    # real stage_host_errors surface), so _fail_preload can be exercised in isolation.
    package FakeFailRunner;
    our @ISA = ('Test2::Harness2::Runner');

    sub new { bless {emit_called => 0, @_[1 .. $#_]}, $_[0] }
    sub _emit_preload_failure_output { $_[0]->{emit_called}++; return }
}

# Fork a child that exits immediately. Returns ($pid, $barrier_read_fh): reading the
# barrier to EOF is a deterministic "the child has exited (and is an unreaped zombie)"
# signal that does NOT reap it -- so _bring_out_yer_dead/stop_* can be the reaper.
sub spawn_exiting_child {
    pipe(my $r, my $w) or die "pipe: $!";
    my $pid = fork // die "fork: $!";
    unless ($pid) { close $r; POSIX::_exit(0); }    # $w closes at exit -> parent sees EOF
    close $w;
    return ($pid, $r);
}

sub wait_exited {
    my ($fh) = @_;
    my $buf;
    1 while sysread($fh, $buf, 128);    # blocks until EOF: the child has exited
    close $fh;
}

# A pid that is guaranteed to NOT be our child (ECHILD on waitpid): spawn one and reap
# it ourselves, then hand back its now-defunct pid.
sub already_reaped_pid {
    my ($pid, $fh) = spawn_exiting_child();
    wait_exited($fh);
    waitpid($pid, 0);    # WE reap it; a later waitpid on this pid returns -1 (ECHILD)
    return $pid;
}

subtest g1_sweep_clears_sampler_and_aux_slots => sub {
    my ($sp, $spr) = spawn_exiting_child();
    my ($ap, $apr) = spawn_exiting_child();
    wait_exited($spr);
    wait_exited($apr);

    my $runner = FakeReapRunner->new(sampler_pid => $sp, aux_pids => [$ap]);

    my $err = '';
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die "reopen STDERR: $!";
        $runner->_bring_out_yer_dead;
    }

    ok(!defined($runner->{sampler_pid}), "G1 cleared the SAMPLER_PID slot on the sweep reap");
    is($runner->{aux_pids}, [], "G1 spliced the reaped aux pid out of AUX_PIDS");
    like($err, qr/sampler \(pid \Q$sp\E\) exited unexpectedly/, "a single diagnostic named the crashed sampler");
};

subtest stop_sampler_returns_immediately_with_cleared_slot => sub {
    my $runner = FakeReapRunner->new();    # SAMPLER_PID undef (G1 already cleared it)

    my $start = Time::HiRes::time;
    $runner->stop_sampler;
    ok((Time::HiRes::time - $start) < 1, "stop_sampler returns at once when the slot is empty");
    is($runner->{service_io_calls}, 0, "no socket pumping without a sampler to stop");
};

subtest stop_sampler_no_spin_on_already_reaped_pid => sub {
    my $pid    = already_reaped_pid();
    my $runner = FakeReapRunner->new(sampler_pid => $pid);

    my $start = Time::HiRes::time;
    $runner->stop_sampler;
    my $elapsed = Time::HiRes::time - $start;

    ok($elapsed < 1, "an already-reaped (ECHILD) sampler pid exits in one waitpid, no 5s+2s spin (${elapsed}s)");
    ok(!defined($runner->{sampler_pid}), "the sampler slot is cleaned even on the ECHILD path");
};

subtest stop_aux_no_spin_on_already_reaped_pid => sub {
    my $pid    = already_reaped_pid();
    my $runner = FakeReapRunner->new(aux_pids => [$pid]);

    my $start = Time::HiRes::time;
    $runner->stop_aux;
    my $elapsed = Time::HiRes::time - $start;

    ok($elapsed < 1, "an already-reaped aux pid is dropped without signaling or spinning (${elapsed}s)");
    is($runner->{aux_pids}, [], "AUX_PIDS is emptied");
};

subtest stop_aux_reaps_a_live_child_without_kill0 => sub {
    # A genuinely live aux child: waitpid==0 -> it IS signaled/reaped. Proves the
    # happy path still works after removing the kill(0) liveness test.
    my $pid = fork // die "fork: $!";
    unless ($pid) { POSIX::setsid(); sleep 30; POSIX::_exit(0); }
    Time::HiRes::sleep(0.05);

    my $runner = FakeReapRunner->new(aux_pids => [$pid]);
    $runner->stop_aux;

    is($runner->{aux_pids}, [], "the live aux child was torn down and cleared");
    is(waitpid($pid, POSIX::WNOHANG), -1, "it was reaped (no lingering zombie)");
};

# ticket #67: the stop_sampler/stop_preload_root reap loop factored into _reap_poll,
# which must EXPOSE #135's tri-state so callers only ever signal on a 0 (still-live)
# status. These assert the three return values directly against the real method.
subtest reap_poll_already_reaped_returns_minus_one => sub {
    my $pid    = already_reaped_pid();
    my $runner = FakeReapRunner->new();

    my $start   = Time::HiRes::time;
    my $status  = $runner->_reap_poll($pid, 250);
    my $elapsed = Time::HiRes::time - $start;

    is($status, -1, "_reap_poll returns -1 (ECHILD) for an already-reaped pid -- the terminal, never-signal value");
    ok($elapsed < 1, "it returns in well under 1s: no spin on ECHILD (${elapsed}s)");
};

subtest reap_poll_exited_child_returns_pid => sub {
    my ($pid, $fh) = spawn_exiting_child();
    wait_exited($fh);    # exited, still an unreaped zombie -- _reap_poll is the reaper

    my $runner = FakeReapRunner->new();
    my $status = $runner->_reap_poll($pid, 250);

    is($status, $pid, "_reap_poll reaps the exited child and returns its pid (reaped-here, never-signal)");
    is(waitpid($pid, POSIX::WNOHANG), -1, "no lingering zombie after _reap_poll reaped it");
};

subtest reap_poll_live_child_returns_zero => sub {
    my $pid = fork // die "fork: $!";
    unless ($pid) { POSIX::setsid(); sleep 30; POSIX::_exit(0); }
    Time::HiRes::sleep(0.05);

    my $runner = FakeReapRunner->new();
    my $status = $runner->_reap_poll($pid, 3);    # small budget; the child stays alive

    is($status, 0, "_reap_poll returns 0 for a still-live child after exhausting its tries -- the ONLY value that licenses a signal");
    ok($runner->{service_io_calls} >= 3, "it pumped the service socket each try");

    kill('KILL', $pid);
    waitpid($pid, 0);
};

# ticket #67: the four preload-root wind-down sites collapse onto _fail_preload.
subtest fail_preload_marks_shutdown_and_emits => sub {
    # Pre-set SIGNAL survives (//=) and no warn without an argument.
    my $r    = FakeFailRunner->new(signal => 'HUP');
    my $warn = '';
    my $ret;
    {
        local $SIG{__WARN__} = sub { $warn .= $_[0] };
        $ret = $r->_fail_preload;
    }
    is($ret, 1, "_fail_preload returns 1 (so callers can `last if`)");
    is($r->{signal}, 'HUP', "a pre-set SIGNAL is preserved by //=");
    is($r->{emit_called}, 1, "_emit_preload_failure_output was called");
    is($warn, '', "no warning is emitted without an argument");

    # With no pre-set SIGNAL: defaults to TERM, and the given warning is emitted.
    my $r2    = FakeFailRunner->new();
    my $warn2 = '';
    {
        local $SIG{__WARN__} = sub { $warn2 .= $_[0] };
        $r2->_fail_preload("boom\n");
    }
    is($r2->{signal}, 'TERM', "SIGNAL defaults to TERM when unset");
    is($r2->{emit_called}, 1, "_emit_preload_failure_output called on the warn path too");
    like($warn2, qr/boom/, "the warning argument is emitted");
};

done_testing;
