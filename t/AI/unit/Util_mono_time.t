use Test2::V0;
use v5.38;

use Time::HiRes ();
use Test2::Harness2::Util qw/mono_time/;

# #134 finding 104: mono_time() is an exported, numeric, monotonically
# non-decreasing interval clock (CLOCK_MONOTONIC where available, wall-clock
# fallback otherwise). It is used for deadlines/elapsed math, never for event
# stamps.

my $t1 = mono_time();
ok(defined $t1, "mono_time returned a defined value");
like($t1, qr/^\d+(?:\.\d+)?$/, "mono_time is a non-negative number");

Time::HiRes::sleep(0.05);

my $t2 = mono_time();
ok($t2 >= $t1, "mono_time is non-decreasing across a sleep ($t1 -> $t2)");
ok($t2 > $t1, "mono_time advanced after a 0.05s sleep");

# Non-decreasing across a tight burst.
my $prev = mono_time();
my $ok   = 1;
for (1 .. 1000) {
    my $now = mono_time();
    if ($now < $prev) { $ok = 0; last }
    $prev = $now;
}
ok($ok, "mono_time never went backwards across 1000 rapid reads");

done_testing;
