use Test2::V0;
use v5.38;

use POSIX ();
use File::Temp qw/tempdir/;
use Test2::Util qw/CAN_REALLY_FORK/;

use Test2::Harness2::Util::IPC qw/run_cmd/;

# TODO-134 finding 14 (guard G1): a run_cmd fork-child must NEVER unwind into the
# parent's inherited stack. A failure anywhere in the child body (the command
# coderef, a run_in_child callback, chdir, dup, exec) must be caught and turned
# into POSIX::_exit(127) -- the child may only ever exec() or _exit(). If it
# escaped, it would run the parent's cleanup (kill real pids, unlink
# runner.socket, write the 'complete' marker) in the wrong process.

skip_all "System cannot really fork" unless CAN_REALLY_FORK;

# Shape matches run_cmd's real callers, which pass [caller()] =
# (package, filename, line); the child's $die formats [1] and [2].
my $caller = [__PACKAGE__, __FILE__, __LINE__];

# A sentinel that ONLY an escaped child (one that returned from run_cmd into this
# caller's stack) could ever create: after run_cmd returns, an escaped child has
# $$ != $parent_pid, so it would fall through and touch these parent-owned files.
sub run_case {
    my (%params) = @_;

    my $parent_pid = $$;
    my $dir        = tempdir(CLEANUP => 1);
    my $sentinel   = "$dir/child-escaped";
    my $sockfile   = "$dir/fake.socket";

    # A pre-existing parent-owned file the child's escaped cleanup would unlink.
    open(my $fh, '>', $sockfile) or die "open: $!";
    close($fh);

    my $pid = run_cmd(%params, caller1 => $caller, caller2 => $caller);
    ok($pid, "run_cmd returned a pid to the parent");

    # This block runs in the parent normally. If a fork child ever unwound back
    # into run_cmd's caller, it would run here with a different pid.
    if ($$ != $parent_pid) {
        open(my $sfh, '>', $sentinel);
        close($sfh);
        unlink($sockfile);      # the parent-owned cleanup a rogue child must never do
        POSIX::_exit(0);
    }

    my $reaped = waitpid($pid, 0);
    my $status = $?;
    is($reaped, $pid, "reaped the child");
    is($status >> 8, 127, "child _exit(127) on a failed child body");

    ok(!-e $sentinel, "child never returned into the parent's stack (no sentinel)");
    ok(-e $sockfile,  "the parent-owned socket file was never unlinked by a rogue child");
}

subtest command_coderef_dies => sub {
    run_case(command => sub { die "boom\n" });
};

subtest run_in_child_callback_dies => sub {
    run_case(command => ['/bin/true'], run_in_child => [sub { die "child-setup boom\n" }]);
};

subtest chdir_failure => sub {
    run_case(command => ['/bin/true'], chdir => "/no/such/dir/anywhere/$$");
};

done_testing;
