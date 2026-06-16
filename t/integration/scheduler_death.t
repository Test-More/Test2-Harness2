use Test2::V0;

use App::Yath2::Tester qw/yath/;

# The scheduler is no longer a separate process (chunk 5b): it is an in-runner
# object advanced each service-loop iteration inside the runner process. A
# scheduler-logic failure therefore surfaces directly in the runner rather than
# as a child-process crash. SchedulerKillerResource fails inside its tick()
# (which the in-runner scheduler calls via State->advance) so we can exercise
# how the runner surfaces and handles those failures without silently hanging.

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test 1: Scheduler logic keeps throwing (repeated exception in tick()).
# The in-runner scheduler catches each error, retries up to its limit, then
# aborts the run cleanly with a useful diagnostic instead of spinning forever.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'crash'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler error.*Intentional scheduler crash/, "Runner surfaced the in-runner scheduler error");
        like($out->{output}, qr/Scheduler aborting after .* consecutive errors/, "Runner aborted after reaching the error limit");
    },
);

# Test 2: Scheduler logic hard-exits the process (POSIX::_exit in tick()).
# In-process, this tears down the whole runner abruptly. The point of the test
# is that this does NOT silently hang: the run terminates with a non-zero exit
# rather than waiting forever for tests that can never be dispatched.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'exit'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        ok($out->{exit}, "Run did not hang; it exited non-zero after the scheduler hard-exited");
    },
);

# Test 3: Scheduler recovers from transient errors.
# SchedulerKillerResource throws twice then stops. The in-runner scheduler
# catches the errors, retries, and the run completes successfully.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'recover'},
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Scheduler error.*Transient scheduler error/, "Runner logged the transient scheduler error");
        unlike($out->{output}, qr/Scheduler aborting/, "Runner did not abort on a transient error");
    },
);

done_testing;
