use Test2::V0;
use Time::HiRes qw/time/;

srand(time);

my $num = int(rand(101));
my $div = 50;

subtest maybe => sub {
    sleep(rand(4));
    ok($num <= $div, "($num <= $div) " . (100 - $div) . '% fail rate test');
};

done_testing;
