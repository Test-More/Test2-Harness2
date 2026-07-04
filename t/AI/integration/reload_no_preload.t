use Test2::V0;
use Test2::Require::AuthorTesting;
# HARNESS-DURATION-MEDIUM

# Ticket TODO-114 (fork A): `yath reload` against a persistent runner started with NO
# preload stages must NOT falsely report success. On such a runner the SIGHUP handler
# is an explicit no-op -- there is nothing to reload -- so the command warns and exits
# 2 instead of the pre-fix behavior of printing "Sending SIGHUP" and exiting 0.
#
# End-to-end sibling of reload_command_respawn.t (which pins the preloaded-runner
# exit-0 respawn path); this pins the no-preload exit-2 path. The two together cover
# the exit-code contract's 0 vs 2 distinction against real runners.

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "Cannot fork, skipping reload-no-preload test"
    if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

# Start a persistent runner with NO -P/--preload: it has no preload stages.
yath(
    command => 'start',
    exit    => 0,
);

# Reload it. With no preload stages there is nothing to reload, so this must warn and
# exit 2 (process exit code 2 == raw wait-status 2<<8). The old code exited 0 here.
yath(
    command => 'reload',
    test    => sub {
        my $out = shift;
        is($out->{exit} >> 8, 2, "reload of a no-preload runner exits 2 (nothing to reload)");
        like($out->{output}, qr/no preload stages/, "warns that the runner has no preload stages");
        like($out->{output}, qr/yath stop.*yath start/s, "tells the user to restart the runner");
    },
);

yath(command => 'stop', exit => 0);

done_testing;
