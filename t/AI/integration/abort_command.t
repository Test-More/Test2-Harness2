# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use POSIX qw/_exit WNOHANG/;
use Time::HiRes qw/sleep/;
use Cwd qw/abs_path/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath tester_ipc_dir/;
use App::Yath2::Util qw/find_yath/;

# Resolve the checkout's lib/ so the run child loads this branch's code,
# not the installed dist. Test is run from the repo root so 'lib' resolves
# to the worktree's lib regardless of which worktree we're in.
my $lib = abs_path('lib') or die "could not resolve lib/ from cwd";

my $tmp = tempdir(CLEANUP => 1);
my $td  = "$tmp/tests";
make_path($td);

# Build two pending tests; one sleeps so the run is unlikely to drain
# before we abort it.
open(my $sf, '>', "$td/slow.t") or die $!;
print $sf "use Test2::V0;\n";
print $sf "sleep 30;\n";
print $sf "ok(1);\ndone_testing;\n";
close $sf;

open(my $pf, '>', "$td/pending.t") or die $!;
print $pf "use Test2::V0;\nok(1);\ndone_testing;\n";
close $pf;

yath(command => 'start', args => ["--workdir=$tmp"], exit => 0);

# Empty-state: no active runs -> abort exits 0 with no work.
yath(
    command => 'abort',
    args    => ["--workdir=$tmp", '--all'],
    exit    => 0,
    test    => sub { my $o = shift; like($o->{output}, qr/no.*run|nothing/i, 'no runs message') },
);

# Real-run case: fork+exec `yath run` so we have an in-flight run to abort.
# Pin YATH_IPC_DIR in the child so it scans the same directory where the
# yath()-launched `yath start` (above) published its IPC info file.
# Without this, the spawned `yath run` falls back to dir_order discovery
# and never finds the daemon, even with --workdir matching.
my $yath_bin = find_yath();
my $ipc_dir  = tester_ipc_dir();
my $child    = fork // die "fork: $!";
if (!$child) {
    $ENV{YATH_IPC_DIR} = $ipc_dir;
    open STDOUT, '>',  "$tmp/run.out" or die $!;
    open STDERR, '>&', STDOUT;
    { exec $^X, "-I$lib", $yath_bin, 'run',
        "--workdir=$tmp", "$td/slow.t", "$td/pending.t"; }
    _exit(127);
}

# Wait for the queued run to register and slow.t to start.
sleep 2;

yath(
    command => 'abort',
    args    => ["--workdir=$tmp", '--all'],
    exit    => 0,
    test    => sub { my $o = shift; like($o->{output}, qr/aborted:\s*\S+/, 'abort prints aborted run id') },
);

# Idempotent: the run is now latched, so a second abort matches nothing.
yath(
    command => 'abort',
    args    => ["--workdir=$tmp", '--all'],
    exit    => 0,
    test    => sub { my $o = shift; like($o->{output}, qr/no.*match.*run|no.*active|nothing/i, 'idempotent abort message') },
);

# Reap the run child cleanly.
my $deadline = time + 30;
while (time < $deadline) {
    my $r = waitpid $child, WNOHANG;
    last if $r == $child;
    sleep 0.1;
}
if (kill 0, $child) {
    kill 'TERM', $child;
    waitpid $child, 0;
}

yath(command => 'stop', args => ["--workdir=$tmp", '--timeout=10'], exit => 0);

done_testing;
