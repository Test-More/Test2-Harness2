# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
yath(
    command => 'start',
    args    => ["--workdir=$dir", '-P', 'Scalar::Util'],
    exit    => 0,
);

# Reload exits 0 and prints at least one peer.
yath(
    command => 'reload',
    args    => ["--workdir=$dir"],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/preload-/, 'reload prints peer name');
    },
);

# --wait blocks until each peer returns.
yath(
    command => 'reload',
    args    => ["--workdir=$dir", '--wait'],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/(reloaded ok|no-op \(no reloader configured\))/, 'reload --wait reports completion');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
