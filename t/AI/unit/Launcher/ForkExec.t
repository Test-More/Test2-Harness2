use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/time sleep/;

use Test2::Harness2::Launcher::ForkExec;

sub _await_exit {
    my ($pid, $timeout) = @_;
    $timeout //= 5;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        return ($r, $?) if $r > 0;
        sleep 0.05;
    }
    return (0, undef);
}

require POSIX;

subtest launch_runs_to_exit_zero => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new;
    is($l->name, 'forkexec', 'default name');

    my %reply = $l->launch({exec => [$^X, '-e', 'exit 0']});
    is($reply{ok}, 1, 'ok=1') or diag(explain(\%reply));
    my $pid = $reply{pid};
    ok($pid && $pid > 0, 'got a pid');

    my ($r, $status) = _await_exit($pid);
    is($r, $pid, 'child reaped');
    is($status, 0, 'child exited 0');
};

subtest launch_propagates_exec_failure => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new;

    my %reply = $l->launch({exec => [$^X, '-e', 'exit 7']});
    is($reply{ok}, 1, 'fork+exec ok');
    my ($r, $status) = _await_exit($reply{pid});
    is($status >> 8, 7, 'exit 7 propagated');
};

subtest launch_rejects_missing_exec => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new;

    my %reply = $l->launch({});
    is($reply{ok}, 0, 'ok=0');
    is($reply{temporary}, 0, 'permanent');
    like($reply{error}, qr/exec/i, 'mentions exec');
};

subtest launch_rejects_bad_spec => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new;

    like(
        dies { $l->launch("not a hash") },
        qr/hashref/i,
        'non-hash spec dies',
    );

    my %reply = $l->launch({exec => "string"});
    is($reply{ok}, 0, 'string exec rejected');
    like($reply{error}, qr/arrayref/i);

    %reply = $l->launch({exec => []});
    is($reply{ok}, 0, 'empty exec rejected');
    like($reply{error}, qr/empty/i);
};

subtest launch_honors_cwd_and_env => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'out');

    my $script = <<'EOF';
use Cwd qw/getcwd/;
open(my $fh, '>', $ENV{OUT}) or die "open: $!";
print {$fh} getcwd(), "\n", $ENV{FOO} // '', "\n";
close($fh);
exit 0;
EOF

    my $l = Test2::Harness2::Launcher::ForkExec->new;
    my %reply = $l->launch({
        exec => [$^X, '-e', $script],
        cwd  => $dir,
        env  => {OUT => $out, FOO => 'bar'},
    });
    is($reply{ok}, 1, 'launched');
    _await_exit($reply{pid});

    open(my $fh, '<', $out) or die "open $out: $!";
    chomp(my @lines = <$fh>);
    close($fh);
    is(scalar(@lines), 2, 'two lines written');
    is($lines[1], 'bar', 'env propagated');
    like($lines[0], qr/\Q$dir\E$/, 'cwd honored');
};

subtest custom_name => sub {
    my $l = Test2::Harness2::Launcher::ForkExec->new(name => 'mine');
    is($l->name, 'mine', 'custom name retained');
};

done_testing;
