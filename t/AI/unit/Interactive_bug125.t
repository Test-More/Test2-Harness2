use v5.38;

use Test2::V0;

use POSIX ();
use Time::HiRes ();
use File::Temp qw/tempdir/;
use IO::Socket::UNIX ();

use App::Yath2;
use App::Yath2::Options::Debug ();

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "These tests require forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

$ENV{'YATH_SELF_TEST'} = 1;

# Ticket TODO-125. On Ctrl-C the interactive accept-loop parent used to fire its
# INT/TERM handler straight into exit(), which ran File::Temp's END cleanup for
# the workdir tempdir while the yath child, runner, and collectors were still
# mid-shutdown and writing into it -- events files vanished under them. The parent
# is the ONLY process that can clean that workdir (File::Temp keys cleanup to the
# pre-fork $$; the child's $$ differs), so cleanup must be DEFERRED, not removed.
#
# The fix: INT/TERM forward the signal to the child and DO NOT exit; the waitpid
# loop reaps the child first, so the parent's exit -- and therefore the File::Temp
# cleanup -- happens only after every workdir user is gone.
#
# This models the real pre-fork process (Workspace weight-0 post creates the
# File::Temp workdir, THEN the weight-99998 interactive post forks): the "wrapper"
# creates the CLEANUP=>1 workdir keyed to itself, forks a "victim" (the yath
# child) that on SIGINT writes into that workdir, then runs the real accept loop.
# We Ctrl-C the WRAPPER only (kill by pid, not the victim) and check that the
# victim's writes all landed in an intact workdir -- which requires BOTH that the
# signal was forwarded AND that the wrapper deferred its exit/cleanup until reap.

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

# $outdir survives the whole test (top-level owns it): it holds the listen socket
# and the cross-process result markers, which must outlive the wrapper's workdir.
my $outdir      = tempdir(CLEANUP => 1);
my $sockpath    = "$outdir/s.sock";
my $result_file = "$outdir/victim_result";
my $wdpath_file = "$outdir/workdir_path";

my $listen = IO::Socket::UNIX->new(
    Type   => IO::Socket::UNIX::SOCK_STREAM(),
    Local  => $sockpath,
    Listen => 1,
) or die "listen socket: $!";

my $wrapper = fork // die "fork wrapper: $!";
if (!$wrapper) {
    # The pre-fork "parent": create the File::Temp workdir (CLEANUP keyed to us,
    # exactly as Workspace.pm does before the interactive fork), advertise its
    # path so the top-level can confirm it is cleaned only after reap, THEN fork.
    my $workdir = tempdir("yath-$$-XXXXXX", CLEANUP => 1);
    if (open(my $wf, '>', $wdpath_file)) {
        print $wf $workdir;
        close($wf);
    }

    my $victim = fork // POSIX::_exit(101);
    if (!$victim) {
        close($listen);

        # The yath child's graceful shutdown: on the forwarded signal, keep
        # writing "events" into the workdir for a spell, recording whether the
        # directory stayed intact the whole time. If the parent had cleaned the
        # workdir out from under us (the TODO-125 bug), these writes would ENOENT.
        my $shutdown = sub {
            my $ok = 1;
            for my $i (1 .. 5) {
                Time::HiRes::sleep(0.05);
                my $f = "$workdir/event_$i.jsonl";
                open(my $efh, '>', $f) or do { $ok = 0; last };
                print $efh "event $i\n";
                close($efh);
                $ok = 0 unless -e $f;
            }
            if (open(my $rfh, '>', $result_file)) {
                print $rfh($ok ? "ok" : "enoent");
                close($rfh);
            }
            POSIX::_exit(0);
        };
        local $SIG{INT}  = $shutdown;
        local $SIG{TERM} = $shutdown;

        Time::HiRes::sleep(10);    # wait to be signaled; bounded well under the alarm
        POSIX::_exit(0);
    }

    # The real command-side accept loop; it exit()s (running File::Temp cleanup)
    # only after the victim is reaped.
    App::Yath2::Options::Debug::_interactive_accept_loop($listen, $sockpath, $victim);
    POSIX::_exit(102);             # unreachable: the loop never returns
}

close($listen);

my $status;
my $ok = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 30;

    # Wait until the wrapper has created the workdir and is about to enter the
    # accept loop, then a beat more so its select() is armed, then Ctrl-C IT.
    Time::HiRes::sleep(0.02) until -e $wdpath_file;
    Time::HiRes::sleep(0.15);
    kill('INT', $wrapper);

    waitpid($wrapper, 0);
    $status = $?;
    alarm 0;
    1;
};
my $err = $@;
alarm 0;

unless ($ok) {
    kill('KILL', $wrapper);
    waitpid($wrapper, 0);
    die "interactive accept-loop wrapper did not exit (possible hang): $err";
}

my $result  = _slurp($result_file);
my $workdir = _slurp($wdpath_file);

is($result, 'ok',
    "victim finished its shutdown writes into an INTACT workdir -- cleanup was deferred until reap (TODO-125)");

is($status & 127, 0, "the wrapper exited normally (was not itself signaled to death)");
is($status >> 8,  0, "the reaped child's clean exit was forwarded (routed through the TODO-140 status expression)");

ok(defined($workdir) && length($workdir), "wrapper advertised its workdir path");
ok(!-e $workdir, "the workdir WAS cleaned -- deferred, not disabled (File::Temp END still fired at wrapper exit)")
    if defined($workdir) && length($workdir);

done_testing;
