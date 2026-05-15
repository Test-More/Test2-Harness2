# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = tempdir(CLEANUP => 1);

# No daemon yet -> exits nonzero with a friendly message.
yath(
    command => 'which',
    args    => ["--workdir=$dir"],
    exit    => T(),
    test    => sub { my $o = shift; like($o->{output}, qr/no IPC info|no.*running.*daemon/i, 'no daemon message') },
);

# Spin one up.
yath(
    command => 'start',
    args    => ["--workdir=$dir"],
    exit    => 0,
);

# Text mode finds it.
yath(
    command => 'which',
    args    => ["--workdir=$dir"],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/pid\s*[:=]/i, 'pid line present');
        like($o->{output}, qr/\Q$dir\E/, 'workdir line present');
    },
);

# JSON mode parses.
yath(
    command => 'which',
    args    => ["--workdir=$dir", '--json'],
    exit    => 0,
    test    => sub {
        my $o = shift;
        my $rec;
        my $ok = eval { $rec = decode_json($o->{output}); 1 };
        ok($ok, 'JSON parses') or diag $@;
        is(ref $rec, 'HASH', 'JSON is an object');
        ok($rec->{pid}, 'pid in JSON');
        is($rec->{workdir}, $dir, 'workdir in JSON');
    },
);

# JSONL mode under --all.
yath(
    command => 'which',
    args    => ["--workdir=$dir", '--all', '--json'],
    exit    => 0,
    test    => sub {
        my $o = shift;
        my @lines = grep { length } split /\n/, $o->{output};
        ok(@lines, '--all --json produced at least one record line');
        my @recs;
        for my $line (@lines) {
            my $rec;
            my $ok = eval { $rec = decode_json($line); 1 };
            ok($ok, "JSONL line parses") or diag $@;
            push @recs, $rec if $ok;
        }
        ok((grep { $_->{workdir} eq $dir } @recs), '--all --json contains our daemon');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
