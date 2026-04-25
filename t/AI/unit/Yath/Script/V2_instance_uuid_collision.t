use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

my $N = 10_000;

my (@last8, @first8);
for (1 .. $N) {
    my $u = gen_uuid();
    $u =~ tr/-//d;
    push @last8  => lc substr($u, -8);
    push @first8 => lc substr($u, 0, 8);
}

# Last 8 hex must be unique across N rapid generations and never
# repeat consecutively. If this ever fails the IPC info file naming
# scheme has lost its uniqueness guarantee.
my %seen_last;
$seen_last{$_}++ for @last8;
my $last_dupes = grep { $_ > 1 } values %seen_last;
is($last_dupes, 0, "last-8 hex unique across $N gen_uuid() calls");

my $consec_repeats = 0;
for my $i (1 .. $#last8) {
    $consec_repeats++ if $last8[$i] eq $last8[$i - 1];
}
is($consec_repeats, 0, "no two consecutive last-8 hex are equal");

# First 8 hex are *expected* to collide on a tight loop because
# UUID v7's first 48 bits are the unix-ms timestamp. If this stops
# being true, the tail-substring rule in App::Yath::Script::V2 may be
# unnecessary -- update the policy and this test together.
my %seen_first;
$seen_first{$_}++ for @first8;
my $first_collisions = grep { $_ > 1 } values %seen_first;
ok(
    $first_collisions > 0,
    "first-8 hex DO collide on tight-loop generation (regression sentinel)",
);

done_testing;
