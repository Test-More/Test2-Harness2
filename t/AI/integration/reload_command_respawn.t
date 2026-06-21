use Test2::V0;
use Test2::Require::AuthorTesting;
# HARNESS-DURATION-MEDIUM

# `yath reload` SIGHUPs the persistent runner, which forwards the reload to the
# base/default stage's LIVE channel; that stage (hosted in the preload-root process)
# respawns the WHOLE preload tree from a clean interpreter. This proves the end-to-
# end respawn path lands: a module preloaded by the base/default stage is changed on
# disk, `yath reload` is issued, and a subsequent run sees the NEW value -- only
# possible if the preload tree actually re-exec'd and re-required the changed file.
#
# This is the during/after-run reload routed through the base stage's live socket,
# NOT the file-monitor (`-r`) path: monitoring is off here, so the only thing that
# can refresh the preloaded value is the explicit `yath reload`.

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "Cannot fork, skipping reload-command test"
    if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $tx = __FILE__ . 'x';

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/Preload") or die "($tmpdir/Preload) $!";

# A base/default-stage preload that requires Preload::Var (whose VALUE we mutate on
# disk between runs). Reloading the tree re-requires it from a clean interpreter.
{
    open(my $fh, '>', "$tmpdir/Preload.pm") or die "Could not create preload: $!";
    print $fh <<'    EOT';
package Preload;
use strict;
use warnings;

use Test2::Harness2::Runner::Preload;

stage A => sub {
    default();

    # Do like this to avoid blacklisting
    preload sub { require Preload::Var };
};

1;
    EOT
    close($fh);
}

sub write_var {
    my ($value) = @_;
    my $path = "$tmpdir/Preload/Var.pm";
    open(my $fh, '>', $path) or die "Could not write $path: $!";
    print $fh <<"    EOT";
package Preload::Var;
use strict;
use warnings;

our \$VALUE = "$value";

1;
    EOT
    close($fh);
}

write_var('v1');

yath(
    command => 'start',
    pre     => ["-D$tmpdir"],
    args    => ["-I$tmpdir", '-PPreload'],
    exit    => 0,
);

# First run: the preloaded value is the original v1.
yath(
    command => 'run',
    args    => [$tx, '::', 'v1'],
    exit    => 0,
);

# Change the preloaded module on disk, then ask the running runner to reload. With
# monitoring off, only this explicit reload can refresh the preloaded value.
write_var('v2');

yath(command => 'reload', exit => 0);

# `yath reload` only sends the signal and returns; the runner re-execs the preload
# tree asynchronously. Give the respawn a moment to re-register the base/default
# stage before dispatching the next run, so the run lands on the fresh incarnation
# rather than racing the old stage's teardown.
sleep 3;

# Second run: if the preload tree respawned and re-required Preload::Var, the
# preloaded value is now v2. If the reload was dropped/unread (the pre-fix bug), the
# stale v1 would still be live and this run would fail its argument check.
yath(
    command => 'run',
    args    => [$tx, '::', 'v2'],
    exit    => 0,
);

yath(command => 'stop', exit => 0);

done_testing;
