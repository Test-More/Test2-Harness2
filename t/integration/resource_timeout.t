use Test2::V0;

use App::Yath2::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test 1: resource-timeout fires when a resource stalls
# StalledResource lets the first test run, then blocks all subsequent tests.
# With --resource-timeout=2, yath should abort after 2 seconds of being unable
# to start any new tests.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+StalledResource', '--resource-timeout=2'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Resource timeout after/, "Got resource timeout message");
    },
);

# Test 2: no timeout when --resource-timeout is 0 (disabled) and tests complete normally
# Without the stalled resource, both tests should pass fine and no timeout message appears.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', '--resource-timeout=0'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr/Resource timeout after/, "No resource timeout when disabled");
    },
);

done_testing;
