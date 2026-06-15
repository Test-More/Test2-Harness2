use Test2::V0;
use Time::HiRes qw/time/;

srand(time);

my $num = $ENV{RANDOM_NUM_VAL} // int(rand(101));
__FILE__ =~ m/(\d+)\./ or die "Invalid file name!";
my $div = int($1);

subtest pass => sub {
    ok(1, "pass");
};

subtest maybe => sub {
    ok($num >= $div, "($num >= $div) " . ($div) . '% fail rate test');
};

done_testing;
