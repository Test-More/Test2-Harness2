# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
my $script = "$dir/x.pl";
open my $sfh, '>', $script; print $sfh "1;\n"; close $sfh;

# No -R: zero preload stages.
yath(command => 'start', args => ["--workdir=$dir"], exit => 0);
sleep 1;

yath(
    command => 'spawn',
    args    => ["--workdir=$dir", '--', $script],
    exit    => sub { $_[0] != 0 },
    test    => sub {
        like($_[0]->{output}, qr/no preload stages running/, 'clear error');
    },
);

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);
done_testing;
