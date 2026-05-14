# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# End-to-end: a resource whose preferred_preload matches a live
# PreloadService's name is dispatched VIA that preload (not as a
# standalone fork). `yath ps` reports VIA_PRELOAD=yes for that
# service.
#
# Two stub resources installed via -R, ordered so the preload's
# resource sorts alphabetically first (start.pm's _build_resources
# walks the -R Map via `sort keys`, so AAPreloader is dispatched
# before MyAppPool). When MyAppPool's _start_service_entry runs,
# the preload service for 'myapp' is already tracked and the
# preferred_preload='myapp' lookup hits.

my $dir = tempdir(CLEANUP => 1);

my $lib = "$dir/lib";
mkdir $lib                              or die "mkdir $lib: $!";
mkdir "$lib/Test2"                      or die "mkdir $lib/Test2: $!";
mkdir "$lib/Test2/Harness2"             or die "mkdir $lib/Test2/Harness2: $!";
mkdir "$lib/Test2/Harness2/Resource"    or die "mkdir $lib/Test2/Harness2/Resource: $!";

# Resource::Preload subclass that defaults name='myapp' and
# modules=[] so it can be constructed with no CLI args (-R takes
# no value here). Inherits services(), is_usable, mark_*, etc.
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

# Resource that opts in to the preload-mediated spawn pathway by
# returning preferred_preload='myapp' and declares one service
# (another PreloadService instance under a different name). The
# harness's _start_service_entry sees preferred_preload, looks up
# 'myapp', and dispatches the service spawn through that
# PreloadService instead of forking standalone.
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

# Declare one PreloadService instance as our service. The harness
# will route the spawn through the 'myapp' preload because of
# preferred_preload above.
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

# Keep Term::Table from wrapping the 'resource-myappservice' name
# across multiple rendered rows; the assertion below matches a
# single row carrying both the name and the VIA_PRELOAD=yes cell.
local $ENV{TABLE_TERM_SIZE} = 500;

# Start daemon. --dev-lib pushes $lib onto @INC for both the yath
# wrapper's re-exec and (via T2_HARNESS_INCLUDES) the spawned
# harness service so both -R modules resolve.
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

# Poll yath ps until the via-preload service shows up. The
# preload-mediated spawn pathway is async (harness sends
# spawn_service to the PreloadService; the grandchild notifies
# back resource_service_started; only then does the harness call
# track_resource_service with via_preload=1), so there's a brief
# window after `yath start` returns before ps sees it.

my $found_via_preload = 0;
my $last_output;
for (1 .. 40) {
    my $ps_out = yath(
        command => 'ps',
        args    => ["--workdir=$dir"],
        exit    => 0,
    );
    $last_output = $ps_out->{output};

    # Match a single rendered table row carrying both
    # 'resource-myappservice' and 'yes' in the VIA_PRELOAD column.
    if ($last_output =~ /VIA_PRELOAD/
        && $last_output =~ /resource-myappservice .*? \byes\b/x)
    {
        $found_via_preload = 1;
        last;
    }
    sleep 0.25;
}

ok($found_via_preload, 'ps reports resource-myappservice with VIA_PRELOAD=yes')
    or diag "last ps output:\n$last_output";

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
