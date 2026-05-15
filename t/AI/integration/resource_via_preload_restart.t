# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Lifecycle invariant: when a via_preload resource service crashes,
# the harness restarts it via the preload (preload is still healthy),
# emits a fresh resource_spawn_via_preload event, and the new
# instance comes up under a different pid that `yath ps` can see.
# The restart relies on IPC::Manager Base::FS reaping the SIGKILL'd
# peer's on-disk artifacts so the new grandchild can re-register
# under the same bus name; without that reap (IPC::Manager <
# 0.000037) the respawn croaks "UNIX Socket or marker file already
# exists" and the pending-spawn timeout fires instead.
#
# Assertions:
#
#   * After SIGKILL the harness emits a fresh resource_spawn_via_preload
#     (proves handle_resource_service_exit -> _start_service_entry took
#     the preload branch again, and proves the IPC peer cleanup worked).
#   * No resource_spawn_preload_timeout / resource_service_start_failed
#     in the restart window.
#   * `yath ps` reports the new service under a fresh pid (proves the
#     new grandchild actually registered on the IPC bus and is visible
#     to clients).

my $dir = tempdir(CLEANUP => 1);

my $lib = "$dir/lib";
mkdir $lib                           or die "mkdir $lib: $!";
mkdir "$lib/Test2"                   or die "mkdir $lib/Test2: $!";
mkdir "$lib/Test2/Harness2"          or die "mkdir $lib/Test2/Harness2: $!";
mkdir "$lib/Test2/Harness2/Resource" or die "mkdir $lib/Test2/Harness2/Resource: $!";

open my $pfh, '>', "$lib/Test2/Harness2/Resource/AAPreloader.pm"
    or die "open AAPreloader.pm: $!";
print $pfh <<'EOF';
package Test2::Harness2::Resource::AAPreloader;
use strict;
use warnings;

use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';

sub init {
    my $self = shift;
    $self->{name}    //= 'myapp';
    $self->{modules} //= [];
    $self->SUPER::init();
}

1;
EOF
close $pfh;

open my $rfh, '>', "$lib/Test2/Harness2/Resource/MyAppPool.pm"
    or die "open MyAppPool.pm: $!";
print $rfh <<'EOF';
package Test2::Harness2::Resource::MyAppPool;
use strict;
use warnings;

use Object::HashBase qw{
    &Test2::Harness2::Role::Resource
};

sub preferred_preload { 'myapp' }
sub resource_name     { 'myapppool' }
sub restartable       { 1 }
sub status            { { resource => 'myapppool' } }
sub needed            { 0 }
sub available         { 0 }

sub services {
    my @inc = grep { defined && length } @INC;
    my @cmd = map  { "-I$_" } @inc;

    return ([
        'Test2::Harness2::PreloadService',
        name             => 'myappservice',
        modules          => [],
        scope            => 'global',
        is_role_consumer => 0,
        exec             => { cmd => \@cmd, stay_in_begin => 1 },
    ]);
}

1;
EOF
close $rfh;

local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'start',
    args    => [
        "--workdir=$dir",
        '-R', 'Test2::Harness2::Resource::AAPreloader',
        '-R', 'Test2::Harness2::Resource::MyAppPool',
        "--dev-lib=$lib",
    ],
    exit => 0,
);

# Get the initial service pid. Each `yath ps` is a fresh subprocess
# so it always gets a clean handle; the polling loop is just covering
# the start->ps race (the harness emits service_started before the
# preload's grandchild has called track_resource_service).
sub _ps_service_pid {
    my $found;
    my $last_output;
    yath(
        command => 'ps',
        args    => ["--workdir=$dir"],
        exit    => 0,
        test    => sub {
            my $o = shift;
            $last_output = $o->{output};
            return unless $last_output =~ /resource-myappservice .*? \byes\b/x;
            for my $line (split /\n/, $last_output) {
                if ($line =~ /\|\s*(\d+)\s*\|\s*resource-myappservice\s*\|/) {
                    $found = $1;
                }
            }
        },
    );
    return ($found, $last_output);
}

my $service_pid;
my $last_output;
for (1 .. 40) {
    ($service_pid, $last_output) = _ps_service_pid();
    last if $service_pid;
    sleep 0.25;
}
ok($service_pid, "initial service pid extracted ($service_pid)")
    or diag "last ps output:\n$last_output";

my $log = "$dir/logs/services/harness/events.jsonl.zst";
ok(-f $log, "harness event log exists at $log");

# Snapshot how many lifecycle events the harness has emitted before
# the kill. We expect exactly one resource_spawn_via_preload (the
# initial spawn) and zero terminal events for the restart.
sub _count_event_kind {
    my ($path, $kind) = @_;
    return 0 unless -f $path;
    my $out = `zstd -d -c \Q$path\E 2>/dev/null`;
    my $n = 0;
    for my $line (split /\n/, $out) {
        $n++ if $line =~ /"kind"\s*:\s*"\Q$kind\E"/;
    }
    return $n;
}

my $spawns_before  = _count_event_kind($log, 'resource_spawn_via_preload');
my $timeouts_before = _count_event_kind($log, 'resource_spawn_preload_timeout');
my $failures_before = _count_event_kind($log, 'resource_service_start_failed');

is($spawns_before,   1, 'one initial via_preload spawn emitted');
is($timeouts_before, 0, 'no preload timeouts before kill');
is($failures_before, 0, 'no service-start failures before kill');

# Crash the resource service. handle_resource_service_exit fires on
# the next IPC::Manager tick, takes the preload branch in
# _start_service_entry (preload is still alive), and the preload
# grandchild registers a fresh peer under the same bus name — which
# only works because IPC::Manager Base::FS reaps the SIGKILL'd peer's
# on-disk artifacts (see Changes for v0.000037).
kill 'KILL', $service_pid;

# Wait for a second resource_spawn_via_preload event.
my $restart_event_seen = 0;
my $deadline = time + 30;
while (time < $deadline) {
    my $spawns   = _count_event_kind($log, 'resource_spawn_via_preload');
    my $timeouts = _count_event_kind($log, 'resource_spawn_preload_timeout');
    my $failures = _count_event_kind($log, 'resource_service_start_failed');

    if ($spawns > $spawns_before) {
        $restart_event_seen = 1;
        diag "restart spawn observed: "
            . "spawns=$spawns timeouts=$timeouts failures=$failures";
        last;
    }
    last if $timeouts > $timeouts_before || $failures > $failures_before;
    sleep 0.25;
}

ok($restart_event_seen,
    'harness emitted a fresh resource_spawn_via_preload for the dead service');

is(_count_event_kind($log, 'resource_spawn_preload_timeout'), 0,
    'no preload spawn timeouts in restart window');
is(_count_event_kind($log, 'resource_service_start_failed'), 0,
    'no service-start failures in restart window');

# Verify the new instance came up under a fresh pid and reports
# via_preload=yes. Retry briefly to cover the spawn->register race.
my $new_pid;
for (1 .. 40) {
    ($new_pid, $last_output) = _ps_service_pid();
    last if $new_pid && $new_pid != $service_pid;
    sleep 0.25;
}
ok($new_pid, "restarted service pid extracted (" . ($new_pid // '<none>') . ")")
    or diag "last ps output:\n", ($last_output // '<no output>');
isnt($new_pid, $service_pid,
    "restarted service runs under a new pid (was $service_pid, now "
    . ($new_pid // '<none>') . ")");

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);

done_testing;
