use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;
use IPC::Cmd qw/run/;
use Cwd qw/getcwd/;

my $repo = getcwd();

my $fixture_dir = tempdir(CLEANUP => 1);

# 6 trivially-passing test files. Each completes in well under 1s.
for my $i (1 .. 6) {
    open my $fh, '>', "$fixture_dir/pass_$i.t" or die "open: $!";
    print {$fh} <<'PERL';
use Test2::V0;
ok(1, 'pass');
done_testing;
PERL
    close $fh;
}

sub run_yath {
    my ($args, $timeout) = @_;
    local $ENV{PERL5LIB} = "$repo/lib" . (defined $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '');
    my $cmd = ['yath', '-D', 'test', '-j6', @$args, glob("$fixture_dir/pass_*.t")];
    my $t0  = time;
    my ($ok, $err, $full, $stdout, $stderr) = run(
        command => $cmd,
        timeout => $timeout // 60,
    );
    return {
        ok     => $ok ? 1 : 0,
        wall   => time - $t0,
        stdout => join('', @$stdout),
        stderr => join('', @$stderr),
    };
}

subtest 'baseline: 6 tests with no throttle finish quickly' => sub {
    my $r = run_yath([]);
    ok($r->{ok}, 'yath run succeeded') or diag $r->{stderr};
    like($r->{stdout}, qr/PASSED/i, 'all tests ran');
    ok($r->{wall} < 10, "baseline wall time $r->{wall}s is fast");
};

subtest 'throttle slows the run' => sub {
    # 2 starts per 3s window means: first 2 start at t=0. Trivially-
    # passing tests release almost immediately, so we expect roughly:
    # batch 1 (t=0): 2 start, complete fast (release), but slot is held
    #                for the full 3s window because release before
    #                window expiry does not free the slot -- actually
    #                wait, release DOES free the slot. So the limiting
    #                factor here is start-rate, not active-count.
    #
    # Re-reasoning: tests release nearly immediately (<<1s), so the
    # in-window count drops to 0 right away. Throttling effectively
    # becomes a no-op for very fast tests. To force a wall-time
    # difference we need either: (a) tests that actually run long
    # enough to be in-window when batch 2 wants to start, or (b)
    # accept that with fast tests the throttle window has no effect
    # and skip this assertion.
    #
    # Use slower fixture tests for this subtest. Inline the slow
    # fixture so it doesn't pollute the fast baseline above.
    my $slow_dir = tempdir(CLEANUP => 1);
    for my $i (1 .. 6) {
        open my $fh, '>', "$slow_dir/slow_$i.t" or die "open: $!";
        print {$fh} <<'PERL';
use Test2::V0;
use Time::HiRes qw/sleep/;
sleep 1.5;     # held for 1.5s -- still in window when next batch wants to start
ok(1, 'pass');
done_testing;
PERL
        close $fh;
    }

    local $ENV{PERL5LIB} = "$repo/lib" . (defined $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '');
    my $cmd = [
        'yath', '-D', 'test', '-j6', '-R', 'Throttle=2/3s',
        glob("$slow_dir/slow_*.t")
    ];
    my $t0 = time;
    my ($ok, $err, $full, $stdout, $stderr) = run(
        command => $cmd,
        timeout => 60,
    );
    my $wall = time - $t0;

    ok($ok, 'yath run succeeded') or diag join('', @$stderr);
    like(join('', @$stdout), qr/PASSED/i, 'all tests ran');
    # 6 tests, 2 at a time, 1.5s each, throttle window 3s:
    # - batch 1 (t=0): 2 tests start, run 1.5s, release at 1.5s (slot expires at 3s)
    # - batch 2 (t=3): 2 tests start (slot 1 and 2 aged out), run 1.5s, release at 4.5s
    # - batch 3 (t=6): 2 tests start, run 1.5s, release at 7.5s
    # Expected wall time: ~7.5s. Without throttle, all 6 in parallel = ~1.5s.
    ok(
        $wall >= 5,
        "throttled wall time ${wall}s shows throttle slowed scheduling (>= 5s, expected ~7.5s)"
    ) or diag "stdout: " . join('', @$stdout) . "\nstderr: " . join('', @$stderr);
};

done_testing;
