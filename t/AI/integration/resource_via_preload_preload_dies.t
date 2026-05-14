# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Lifecycle invariant: if the PreloadService that brokered a
# resource-spawn-via-preload dies, the spawned resource service
# survives. The grandchild was double-forked + reparented away from
# the preload, so a SIGTERM to the preload pid must not propagate.
#
# Setup mirrors the RP12 namematch scaffold:
#   - AAPreloader (name='myapp') sorts alphabetically first so the
#     preload is dispatched before MyAppPool's service.
#   - MyAppPool advertises preferred_preload='myapp' and declares one
#     PreloadService instance named 'myappservice' as its service.

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

# Poll yath ps until the via-preload service appears. Capture both
# pids (preload + resource service) in the same poll pass once we
# have a confirmed via_preload=yes row.
my ($preload_pid, $service_pid);
my $last_output;
for (1 .. 40) {
    yath(
        command => 'ps',
        args    => ["--workdir=$dir"],
        exit    => 0,
        test    => sub {
            my $o = shift;
            $last_output = $o->{output};

            return unless $last_output =~ /resource-myappservice .*? \byes\b/x;

            # Walk the rendered table for the two rows we need.
            for my $line (split /\n/, $last_output) {
                if ($line =~ /\|\s*(\d+)\s*\|\s*resource-myappservice\s*\|/) {
                    $service_pid = $1;
                }
                elsif ($line =~ /\|\s*(\d+)\s*\|\s*myapp\s*\|/) {
                    $preload_pid = $1;
                }
            }
        },
    );
    last if $preload_pid && $service_pid;
    sleep 0.25;
}

ok($preload_pid, "preload pid extracted ($preload_pid)")
    or diag "last ps output:\n$last_output";
ok($service_pid, "service pid extracted ($service_pid)")
    or diag "last ps output:\n$last_output";

# Sanity: both pids should currently be alive.
ok(kill(0, $preload_pid), 'preload alive pre-kill');
ok(kill(0, $service_pid), 'service alive pre-kill');

# Kill the preload directly. SIGTERM lets it run its end-of-loop
# cleanup; that's the realistic shutdown signal. SIGKILL would also
# work but TERM is closer to operator behaviour.
kill 'TERM', $preload_pid;

# Wait up to 5s for the preload to actually exit. The harness will
# also notice and call handle_resource_service_exit on the preload's
# tracking entry, which is fine — the resource service isn't
# tracked under the preload's pid.
my $preload_gone = 0;
for (1 .. 20) {
    unless (kill 0, $preload_pid) {
        $preload_gone = 1;
        last;
    }
    sleep 0.25;
}
ok($preload_gone, 'preload exited after SIGTERM');

# The resource service must survive. Give the system a beat to let
# any erroneous SIGTERM-on-process-group propagation play out, then
# assert.
sleep 1;
ok(kill(0, $service_pid), "service ($service_pid) survived preload death");

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
