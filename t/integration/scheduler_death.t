use Test2::V0;

use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test 1: Scheduler crashes (repeated non-zero exit)
# SchedulerKillerResource dies in tick() on every iteration after the first
# task is dispatched. The scheduler retries up to 5 times, then aborts.
# The parent runner detects the non-zero exit.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'crash'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler error.*Intentional scheduler crash/, "Scheduler printed error on crash");
        like($out->{output}, qr/Scheduler aborting after .* consecutive errors/, "Scheduler aborted after reaching error limit");
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

# Test 3: Scheduler recovers from transient errors
# SchedulerKillerResource throws 2 times then stops. The scheduler catches
# the errors, retries, and successfully completes the test run.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'recover'},
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler error.*Transient scheduler error/, "Scheduler logged transient error");
        unlike($out->{output}, qr/Scheduler aborting/, "Scheduler did not abort");
    },
);

done_testing;
