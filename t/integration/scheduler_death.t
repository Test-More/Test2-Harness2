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

# Test 1: Scheduler logic throws (exception in tick()).
# The in-runner scheduler fails fast: a throw out of poll/advance/dispatch is a
# real in-process bug and is left to propagate rather than being retried. The run
# terminates non-zero, surfacing the original error, instead of spinning or
# silently hanging.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'crash'},
    exit    => T(),
    test    => sub {
        my $out = shift;
        ok($out->{exit}, "Run did not hang; it failed fast after the scheduler threw");
        like($out->{output}, qr/Intentional scheduler crash/, "Runner surfaced the original scheduler error");
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

# Test 3: A resource that absorbs its own transient errors lets the run finish.
# The scheduler fails fast, so resilience to transient errors is the resource's
# job: SchedulerKillerResource hits a transient error a few times but swallows it
# inside its own tick(). The run completes successfully and the scheduler never
# sees a throw.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+SchedulerKillerResource'],
    env     => {SCHEDULER_DEATH_MODE => 'recover'},
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/absorbed transient error/, "Resource absorbed its own transient error");
    },
);

done_testing;
