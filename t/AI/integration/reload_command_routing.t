use Test2::V0;
use Test2::Require::AuthorTesting;
# HARNESS-DURATION-MEDIUM

# TRUE reload-ROUTING regression (TODO-113 step 3). `yath reload` SIGHUPs the persistent
# runner; the runner must translate that into a 'reload_root' delivered to the
# base/default stage's LIVE channel, which respawns the whole preload tree from a
# clean interpreter. The buggy runner looked the base stage up by PRELOAD_ROOT_PID
# (the collector PARENT) while the stage actually runs in the exec'd GRANDCHILD, so
# the identity never matched and every HUP reload was silently dropped.
#
# Unlike reload_command_respawn.t, this test touches NO preloaded file between start
# and reload, so the file monitor CANNOT fire (nothing changed on disk). The ONLY
# thing that can respawn the tree is the explicit `yath reload` routing itself.
#
# The preload appends one line to a counter file every time its load sequence runs --
# once at initial start, and once more on each respawn (a fresh exec re-runs the whole
# sequence). So the line count STRICTLY INCREASES iff the reload actually routed and
# respawned the tree. Against the pre-fix code the reload is dropped, the tree never
# respawns, and the count stays put -- this test fails.

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "Cannot fork, skipping reload-routing test"
    if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $tmpdir = tempdir(CLEANUP => 1);

# A plain log file, NOT a .pm on @INC, so the preload monitor never watches it: writing
# it cannot itself trigger a monitor reload.
my $count_file = File::Spec->catfile($tmpdir, 'reload_count.log');

sub count_lines {
    return 0 unless -e $count_file;
    open(my $fh, '<', $count_file) or die "read $count_file: $!";
    my $n = 0;
    $n++ while <$fh>;
    close($fh);
    return $n;
}

# A staged preload whose load sequence appends to the counter file. The append lives in
# a `preload sub {}` (executed every time the sequence runs), NOT in a require-guarded
# module, so a respawn's fresh exec re-runs it and the count grows by (at least) one.
{
    open(my $fh, '>', "$tmpdir/Preload.pm") or die "Could not create preload: $!";
    print $fh <<"    EOT";
package Preload;
use strict;
use warnings;

use Test2::Harness2::Runner::Preload;

stage A => sub {
    default();

    preload sub {
        open(my \$fh, '>>', '$count_file') or die "count file: \$!";
        print \$fh "\$\$\\n";
        close(\$fh);
    };
};

1;
    EOT
    close($fh);
}

my $tx = __FILE__ . 'x';

yath(
    command => 'start',
    pre     => ["-D$tmpdir"],
    args    => ["-I$tmpdir", '-PPreload'],
    exit    => 0,
);

# First run: brings the stage fully up and confirms the baseline preload works.
yath(
    command => 'run',
    args    => [$tx],
    exit    => 0,
);

my $before = count_lines();
ok($before >= 1, "preload load sequence ran at least once before reload (count=$before)");

# Touch NOTHING. The only reload trigger is this explicit command.
yath(command => 'reload', exit => 0);

# `yath reload` only signals and returns; the tree respawns asynchronously. Give the
# base/default stage a moment to re-exec and re-register before the next run.
sleep 3;

# A run AFTER the reload must still dispatch -- proves the runner did not wedge/hang and
# the stage came back (the TODO-111/TODO-112 guards keep the respawn from duplicating the tree
# or wedging the base).
yath(
    command => 'run',
    args    => [$tx],
    exit    => 0,
);

my $after = count_lines();
ok(
    $after > $before,
    "the preload load sequence re-ran after `yath reload` (count $before -> $after) -- the reload ROUTED and respawned the tree"
);

yath(command => 'stop', exit => 0);

done_testing;
