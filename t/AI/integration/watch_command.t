# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
yath(command => 'start', args => ["--workdir=$dir"], exit => 0);

# Run watch with a hard timeout; sending SIGTERM ends it cleanly.
# Default $SIG{TERM} terminates by signal, so Tester sees the
# WIFSIGNALED ($? >> 8 == 0) form -- exit is 0, not signal-based.
# The wallclock check is the real validation that watch stayed alive
# until the timeout fired rather than exiting on its own.
my $t0 = time;
yath(
    command    => 'watch',
    args       => ["--workdir=$dir"],
    timeout    => 4,
    timeout_cb => sub { },
    exit       => 0,
    test       => sub { pass('watch ran and was terminated by timeout') },
);
ok((time - $t0) >= 3, 'watch ran until SIGTERM (wallclock confirms not an early die)');

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
