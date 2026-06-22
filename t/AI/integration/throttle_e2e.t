use Test2::V0;
use v5.38;

# Chunk 7 / ticket #43: the opt-in throttling resources (-R CPU / -R Memory) wire
# end to end through the real `yath test` path -- the resource is instantiated in
# the runner's State with a backref to read the shared system-load snapshot, and a
# run with these resources still schedules, forks, and passes (the throttling is a
# transient defer, never a stall: the min_concurrent floor keeps a job running).
# Also exercises the inline '=arg' and --utilize option plumbing.

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# -R CPU (default threshold 80): both jobs schedule and pass.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-R', 'CPU'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{PASSED.*aaa\.tx}, "-R CPU: job aaa scheduled and passed");
        like($out->{output}, qr{PASSED.*bbb\.tx}, "-R CPU: job bbb scheduled and passed");
    },
);

# -R Memory=20% (inline arg): both jobs schedule and pass.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-R', 'Memory=20%'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{PASSED.*aaa\.tx}, "-R Memory=20%: job aaa scheduled and passed");
        like($out->{output}, qr{PASSED.*bbb\.tx}, "-R Memory=20%: job bbb scheduled and passed");
    },
);

# -R CPU=70 --utilize 65 plus -R Memory layered: still schedules + passes.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-R', 'CPU=70', '-R', 'Memory', '--utilize', '65'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{PASSED.*aaa\.tx}, "layered CPU=70/Memory/--utilize: aaa passed");
        like($out->{output}, qr{PASSED.*bbb\.tx}, "layered CPU=70/Memory/--utilize: bbb passed");
    },
);

# A bad --utilize is rejected up front (option validation).
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '--utilize', '150'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{utilize must be greater than 0 and less than 100}, "--utilize 150 is rejected");
    },
);

done_testing;
