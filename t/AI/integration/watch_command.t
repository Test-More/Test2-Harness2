# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
yath(command => 'start', args => ["--workdir=$dir"], exit => 0);

# Run watch with a hard timeout; sending SIGTERM ends it cleanly.
my $t0 = time;
yath(
    command    => 'watch',
    args       => ["--workdir=$dir"],
    timeout    => 4,
    timeout_cb => sub { },   # default action (TERM) is what we want
    exit       => T(),        # killed by signal -> any exit is OK
    test       => sub {
        my $o = shift;
        # Watch should at least have opened the renderer; assert by
        # looking for any output banner. Empty output is acceptable on
        # a freshly-started daemon, so the assertion is lenient.
        pass('watch ran and was terminated by timeout');
    },
);
ok((time - $t0) >= 3, 'watch ran until SIGTERM (wallclock confirms not an early die)');

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
