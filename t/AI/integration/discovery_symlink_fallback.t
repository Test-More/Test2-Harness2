use Test2::V0;

use File::Spec;
use Time::HiRes qw/sleep/;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;

# This test starts a real persistent runner, proves discovery follows the
# well-known symlink to it, then SIGKILLs the runner (so its socket goes
# unresponsive without the clean-exit cleanup) and proves:
#   * the workdir PID file is the signal fallback (it still names the dead runner);
#   * `which` treats a symlink whose socket no longer connects as "runner absent"
#     and cleans the stale symlink.
skip_all "This test is not run under automated testing" if $ENV{AUTOMATED_TESTING};
skip_all "Cannot fork" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $pdir = $ENV{YATH_PERSISTENCE_DIR};
ok($pdir && -d $pdir, "have a per-process persistence dir") or skip_all "no persistence dir";

# Locate the discovery symlink the runner publishes under $pdir.
sub find_link {
    opendir(my $dh, $pdir) or die "opendir $pdir: $!";
    my ($name) = grep { /yath-runner\.sock\z/ } readdir($dh);
    closedir($dh);
    return defined($name) ? File::Spec->catfile($pdir, $name) : undef;
}

# Read the runner pid from the workdir the symlink points at (the PID-file
# signal fallback path Discovery uses).
sub runner_pid_from_link {
    my ($link) = @_;
    my $target = readlink($link) or return;
    my (undef, $dir, undef) = File::Spec->splitpath($target);
    my $pidfile = File::Spec->catpath('', $dir, 'PID');
    return unless -f $pidfile;
    open(my $fh, '<', $pidfile) or return;
    my $pid = <$fh>;
    close($fh);
    chomp($pid) if defined $pid;
    return (defined($pid) && $pid =~ /^\d+$/) ? $pid : undef;
}

yath(command => 'start', exit => 0);

my $link = find_link();
ok($link && -l $link, "runner published a discovery symlink (not a JSON file)")
    or die "no discovery symlink under $pdir\n";

my $target = readlink($link);
like($target, qr/runner\.socket\z/, "symlink points at runner.socket");
my (undef, $wdir, undef) = File::Spec->splitpath($target);
ok(-d $wdir, "symlink resolves to an existing workdir");

# Discovery works while the runner is live: `which` follows the symlink and
# reports the runner.
yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^\s*Found: .*yath-runner\.sock$/m, "which follows the symlink to the live runner");
    },
);

# The PID-file fallback: the workdir PID file names the live runner.
my $pid = runner_pid_from_link($link);
ok($pid && kill(0, $pid), "workdir PID file names the live runner (the signal fallback) -- pid $pid");

# Wedge the runner: SIGKILL it so the socket dies WITHOUT the clean-exit cleanup
# that would unlink the symlink and remove the workdir. The symlink, the workdir,
# and the PID file all survive -- but the socket no longer connects.
kill('KILL', $pid);
for (1 .. 100) { last unless kill(0, $pid); sleep 0.05 }
ok(!kill(0, $pid), "runner is dead after SIGKILL");

# The PID file is still present (the signal fallback data survives a hard kill),
# proving a client could still resolve the workdir + pid for termination even
# though the socket is gone.
my $stale_pid = runner_pid_from_link($link);
is($stale_pid, $pid, "PID-file fallback still resolves the (now dead) runner pid from the symlink");

ok(-l $link, "stale symlink is still present right after the kill");

# `which` connects to the (now dead) socket; the connect fails, so discovery
# treats the harness as absent AND cleans up the stale symlink.
yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr/No persistent harness was found for the current path\./,
            "a symlink whose socket no longer connects reads as 'runner absent'",
        );
    },
);

ok(!-l $link, "the stale/dangling discovery symlink was cleaned up");

done_testing;
