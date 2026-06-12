use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use Test2::Harness2::Util::FileMonitor;

subtest initial_changed => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x";
    open(my $fh, '>', $f) or die $!;
    print $fh "a\n";
    close $fh;

    my $m = Test2::Harness2::Util::FileMonitor->new(file => $f);
    ok($m->changed,  'initial returns truthy');
    ok(!$m->changed, 'second returns false');
};

subtest detects_append => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x";
    open(my $fh, '>', $f) or die $!;
    print $fh "a\n";
    close $fh;

    my $m = Test2::Harness2::Util::FileMonitor->new(file => $f);
    $m->changed;        # ack initial
    ok(!$m->changed, 'no change yet');

    sleep 1.1;          # ensure mtime tick
    open(my $w, '>>', $f) or die $!;
    print $w "b\n";
    close $w;

    ok($m->changed, 'sees append');
    ok(!$m->changed, 'ack consumed');
};

subtest delegate => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x";
    open(my $fh, '>', $f) or die $!;
    close $fh;

    my $delegate = bless {}, 'X::Delegate';
    my $m = Test2::Harness2::Util::FileMonitor->new(
        file     => $f,
        delegate => $delegate,
    );
    is($m->changed, $delegate, 'delegate returned on truthy');
    is($m->changed, 0,         'no change after ack');
};

subtest peek_changed => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x";
    open(my $fh, '>', $f) or die $!;
    close $fh;

    my $m = Test2::Harness2::Util::FileMonitor->new(file => $f);
    ok($m->peek_changed, 'peek truthy before ack');
    ok($m->peek_changed, 'peek again still truthy');
    ok($m->changed,      'changed acks the initial');
    ok(!$m->peek_changed, 'peek false after ack');
};

subtest static => sub {
    my $m = Test2::Harness2::Util::FileMonitor->new(static => 1);
    ok($m->changed,  'first changed truthy');
    ok(!$m->changed, 'subsequent calls false');
};

subtest missing_file_required => sub {
    like(
        dies { Test2::Harness2::Util::FileMonitor->new() },
        qr/'file' is a required attribute/,
    );
};

subtest await_change_timeout => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x";
    open(my $fh, '>', $f) or die $!;
    close $fh;

    my $m = Test2::Harness2::Util::FileMonitor->new(file => $f);
    $m->changed;        # ack initial
    my $start = time();
    my $rv = $m->await_change(0.2);
    my $elapsed = time() - $start;
    is($rv, 0, 'timeout returns 0');
    ok($elapsed < 2, 'timeout completed in reasonable time');
};

done_testing;
