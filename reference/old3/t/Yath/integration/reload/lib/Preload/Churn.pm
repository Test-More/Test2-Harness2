package Preload::Churn;
use strict;
use warnings;

our $counter;
$counter //= 0;
die "Counter incremented!" if $counter;
$counter++;

# HARNESS2: churn {
our $counter2;
$counter2 //= 0;
print STDERR "$$ $0 - Churn 1\n";
$counter2++;
my $foo = "foo $counter2";
sub foo { $foo }
print STDERR "$$ $0 - FOO: " . Preload::Churn->foo . "\n";
# HARNESS2: churn }

# HARNESS2: churn {
print STDERR "$$ $0 - Churn 2\n";
# HARNESS2: churn }

# HARNESS2: churn {
our $counter3;
$counter3 //= 0;
die "$$ $0 - Died on count $counter3\n" if $counter3++;
print STDERR "$$ $0 - Churn 3\n";
$counter3++;
# HARNESS2: churn }

1;
