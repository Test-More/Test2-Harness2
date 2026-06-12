use Test2::V0;

use App::Yath2::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test 1: Without --fail-on-resource-skip, tests with unavailable resources
# are skipped and the overall run succeeds (exit 0).
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', "-D$dir", '-R+UnavailableResource'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/SKIP/i, "Output mentions skipped tests");
        unlike($out->{output}, qr/FAILED/i, "No failures reported");
    },
);

# Test 2: With --fail-on-resource-skip, tests with unavailable resources
# are marked as failures and the overall run fails (exit != 0).
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', "-D$dir", '-R+UnavailableResource', '--fail-on-resource-skip'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/FAIL.*Some resources are not available/s, "Output shows failures for unavailable resources");
        like($out->{output}, qr/FAILED/, "Overall result is FAILED");
        like($out->{output}, qr/UnavailableResource/, "Output mentions the unavailable resource name");
    },
);

# Test 3: With --no-fail-on-resource-skip (explicit default), same as test 1.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', "-D$dir", '-R+UnavailableResource', '--no-fail-on-resource-skip'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/SKIP/i, "Output mentions skipped tests with explicit --no-fail-on-resource-skip");
        unlike($out->{output}, qr/FAILED/i, "No failures with explicit --no-fail-on-resource-skip");
    },
);

done_testing;
