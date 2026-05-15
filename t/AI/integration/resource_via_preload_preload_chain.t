# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# End-to-end: a Resource::Preload subclass that declares
# preferred_preload='base' spawns its PreloadService through a live
# 'base' PreloadService rather than forking standalone. Both
# preloads run independently (no tree management).
#
# Two Resource::Preload subclasses installed via -R. AAA prefix in
# the package basename keeps the iteration order deterministic so
# the base preload is dispatched first; with RP14 in place the
# dependent would queue if needed, but the order keeps the test
# stable.

my $dir = tempdir(CLEANUP => 1);

my $lib = "$dir/lib";
mkdir $lib                           or die "mkdir $lib: $!";
mkdir "$lib/Test2"                   or die "mkdir $lib/Test2: $!";
mkdir "$lib/Test2/Harness2"          or die "mkdir $lib/Test2/Harness2: $!";
mkdir "$lib/Test2/Harness2/Resource" or die "mkdir $lib/Test2/Harness2/Resource: $!";

# Base PreloadService -- standalone, name='base'. No preferred_preload,
# so the harness spawns it via the regular standalone path.
open my $bfh, '>', "$lib/Test2/Harness2/Resource/AAABasePreload.pm"
    or die "open AAABasePreload.pm: $!";
print $bfh <<'EOF';
package Test2::Harness2::Resource::AAABasePreload;
use strict;
use warnings;

use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';

sub init {
    my $self = shift;
    $self->{name}    //= 'base';
    $self->{modules} //= [];
    $self->SUPER::init();
}

1;
EOF
close $bfh;

# Derived PreloadService -- declares preferred_preload='base' so
# the harness routes its spawn through the live 'base' preload
# instead of standalone-forking it. Subclassing Resource::Preload
# inherits services() which returns a PreloadService entry, so the
# harness ends up spawning another PreloadService through the base
# PreloadService's spawn_service handler.
open my $afh, '>', "$lib/Test2/Harness2/Resource/AAAAppPreload.pm"
    or die "open AAAAppPreload.pm: $!";
print $afh <<'EOF';
package Test2::Harness2::Resource::AAAAppPreload;
use strict;
use warnings;

use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';

sub init {
    my $self = shift;
    $self->{name}              //= 'app';
    $self->{modules}           //= [];
    $self->{preferred_preload} //= 'base';
    $self->SUPER::init();
}

1;
EOF
close $afh;

# Keep Term::Table from wrapping rows; the VIA_PRELOAD column
# assertions match each rendered service line as a single row.
local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'start',
    args    => [
        "--workdir=$dir",
        '-R', 'Test2::Harness2::Resource::AAABasePreload',
        '-R', 'Test2::Harness2::Resource::AAAAppPreload',
        "--dev-lib=$lib",
    ],
    exit => 0,
);

# Poll yath ps until both preloads are visible AND the 'app' preload
# is reported via_preload=yes. The base preload comes up standalone
# first under its preload name 'base'; the app preload is dispatched
# through the spawn_service pathway once the base preload signals
# preload_ready (the RP14 wait-for-preload queue covers the race
# even if the base isn't ready when AAAAppPreload's
# _start_service_entry runs). The via_preload-spawned service
# registers under its peer name 'resource-<name>', so 'app' shows
# up as 'resource-app'.
my $found_base = 0;
my $found_app  = 0;
my $base_pid;
my $app_pid;
my $last_output;
for (1 .. 80) {
    my $ps_out = yath(
        command => 'ps',
        args    => ["--workdir=$dir"],
        exit    => 0,
    );
    $last_output = $ps_out->{output};

    if (!$found_base && $last_output =~ /\|\s*(\d+)\s*\|\s+base\s+\|/) {
        $base_pid   = $1;
        $found_base = 1;
    }
    if (!$found_app
        && $last_output =~ /\|\s*(\d+)\s*\|\s+resource-app\s+\|.*?\|\s*yes\s*\|/)
    {
        $app_pid   = $1;
        $found_app = 1;
    }
    last if $found_base && $found_app;
    sleep 0.25;
}

ok($found_base, "base preload running (NAME='base')")
    or diag "last ps output:\n$last_output";
ok($found_app, "app preload spawned via base preload (NAME='resource-app', VIA_PRELOAD=yes)")
    or diag "last ps output:\n$last_output";

# Both preloads still run independently after a reload-all request.
# Neither has a reloader configured, so each reports the no-op path
# (ok=1, noop=1) rather than restarting. The intent here is "no
# cascade and no tree management": reloading either preload must not
# take the other one down. We assert that by liveness-checking the
# tracked pids directly (the kill-0 probe is post-reload), since
# preload-from-preload's contract is "each manages its own
# lifecycle", which is a pid-level statement about the OS, not a
# ps-row-formatting statement about the harness's bookkeeping.
yath(
    command => 'reload',
    args    => ["--workdir=$dir", '--wait'],
    exit    => 0,
);

# Brief settle for the no-op reload's reply to land.
sleep 0.25;

SKIP: {
    skip 'base preload pid not captured', 1 unless defined $base_pid;
    ok(kill(0, $base_pid), "base preload pid=$base_pid still alive after reload");
}

SKIP: {
    skip 'app preload pid not captured', 1 unless defined $app_pid;
    ok(kill(0, $app_pid), "app preload pid=$app_pid still alive after reload");
}

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
