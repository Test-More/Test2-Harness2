use Test2::V0;

use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test 1: Scheduler crashes (non-zero exit)
# SchedulerKillerResource dies in tick() after the first task is dispatched,
# leaving remaining tasks pending. The eval in the scheduler catches the error
# and prints diagnostics. The parent runner detects the non-zero exit.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'crash'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler error:.*Intentional scheduler crash/, "Scheduler printed error before exiting");
        like($out->{output}, qr/Scheduler process.*exited unexpectedly/, "Runner detected scheduler crash");
    },
);

# Test 2: Scheduler exits 0 prematurely (with pending work)
# SchedulerKillerResource calls POSIX::_exit(0) after the first task is
# dispatched, bypassing all Perl cleanup. The parent runner detects that
# the scheduler exited cleanly but work remains.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'exit'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler process.*exited prematurely.*pending work/, "Runner detected premature scheduler exit");
    },
);

done_testing;
