use Test2::V0;

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test requires forking" unless CAN_REALLY_FORK;

# A real NO-PRELOAD run (no -P): the runner forks each test's collector itself and
# drives the in-process 'default' stage. This is the end-to-end guard for the run-path
# collapse (#29 / chunk 26): once the no-preload run is routed through
# run_scheduler_only, the ported stage_ready('default') is what makes these tasks
# schedulable -- if it is missing the run schedules nothing and hangs (caught here as a
# non-zero exit / missing PASSED lines). It also exercises the no-preload wind-down
# (killall + reap of the runner's own forked collectors).

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{PASSED.*aaa\.tx}, 'no-preload job aaa scheduled, forked, and passed');
        like($out->{output}, qr{PASSED.*bbb\.tx}, 'no-preload job bbb scheduled, forked, and passed');
    },
);

done_testing;
