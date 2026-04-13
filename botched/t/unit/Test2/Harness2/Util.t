use Test2::V0;
use File::Temp qw/tempfile tempdir/;

use Test2::Harness2::Util qw/
    parse_exit
    mod2file
    file2mod
    hub_truth
    clean_path
/;

subtest 'parse_exit' => sub {
    my $result = parse_exit(0);
    is($result, {sig => 0, err => 0, dmp => 0, all => 0}, "zero exit parses correctly");

    # Normal exit code 1 (0 << 0 | 1 << 8)
    $result = parse_exit(256);
    is($result, {sig => 0, err => 1, dmp => 0, all => 256}, "exit code 1 parses correctly");

    # Exit code 2
    $result = parse_exit(512);
    is($result, {sig => 0, err => 2, dmp => 0, all => 512}, "exit code 2 parses correctly");

    # Signal 11 (segfault), no core dump
    $result = parse_exit(11);
    is($result, {sig => 11, err => 0, dmp => 0, all => 11}, "signal 11 parses correctly");

    # Signal 11 with core dump (bit 7 set = 128 + 11 = 139)
    $result = parse_exit(139);
    is($result, {sig => 11, err => 0, dmp => 128, all => 139}, "signal 11 with core dump parses correctly");

    # Exit code 1 with signal 9 (1*256 + 9 = 265)
    $result = parse_exit(265);
    is($result, {sig => 9, err => 1, dmp => 0, all => 265}, "exit code + signal parses correctly");

    ok(dies { parse_exit() }, "parse_exit requires an argument");
};

subtest 'mod2file' => sub {
    is(mod2file('Foo::Bar'),              'Foo/Bar.pm',             "simple module to file");
    is(mod2file('Foo'),                   'Foo.pm',                 "single component module to file");
    is(mod2file('Test2::Harness2::Util'), 'Test2/Harness2/Util.pm', "deep module to file");
    ok(dies { mod2file() }, "mod2file requires an argument");
};

subtest 'file2mod' => sub {
    is(file2mod('Foo/Bar.pm'),             'Foo::Bar',              "simple file to module");
    is(file2mod('Foo.pm'),                 'Foo',                   "single component file to module");
    is(file2mod('Test2/Harness2/Util.pm'), 'Test2::Harness2::Util', "deep file to module");
};

subtest 'hub_truth' => sub {
    # Returns hubs[0] when hubs is present
    my $hub    = {nested => 1};
    my $facets = {hubs   => [$hub]};
    is(hub_truth($facets), $hub, "returns hubs[0] when available");

    # Falls back to trace
    my $trace = {file => 'foo.t', line => 10};
    $facets = {trace => $trace};
    is(hub_truth($facets), $trace, "returns trace when no hubs");

    # Falls back to empty hash
    $facets = {};
    is(hub_truth($facets), {}, "returns empty hash when nothing present");

    # Empty hubs array falls back to trace
    my $trace2 = {file => 'bar.t'};
    $facets = {hubs => [], trace => $trace2};
    is(hub_truth($facets), $trace2, "empty hubs falls back to trace");
};

subtest 'clean_path' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = clean_path($dir);
    ok(-d $path,        "cleaned path exists");
    ok($path !~ /\.\./, "no double-dots in path");

    ok(dies { clean_path() }, "clean_path requires a path");
};

done_testing;
