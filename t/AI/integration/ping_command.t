# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);

# No daemon -> nonzero.
yath(command => 'ping', args => ["--workdir=$dir", '--count=1'], exit => T());

yath(command => 'start', args => ["--workdir=$dir"], exit => 0);

# Single-shot ping returns success and prints one timing line.
yath(
    command => 'ping',
    args    => ["--workdir=$dir", '--count=1'],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/1:\s*[\d.]+s/, 'ping reports rtt');
    },
);

# Multi-shot prints multiple lines.
yath(
    command => 'ping',
    args    => ["--workdir=$dir", '--count=3', '--interval=0'],
    exit    => 0,
    test    => sub {
        my $o = shift;
        my @hits = ($o->{output} =~ /\n?(\d+):\s*[\d.]+s/g);
        is(scalar(@hits), 3, '3 ping lines');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
