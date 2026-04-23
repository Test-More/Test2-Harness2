use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::TestSettings;

subtest 'default values' => sub {
    my $ts = Test2::Harness2::TestSettings->new;

    is($ts->use_stream,        1,  "use_stream defaults to 1");
    is($ts->use_timeout,       1,  "use_timeout defaults to 1");
    is($ts->allow_retry,       1,  "allow_retry defaults to 1");
    is($ts->event_uuids,       1,  "event_uuids defaults to 1");
    is($ts->mem_usage,         1,  "mem_usage defaults to 1");
    is($ts->lib,               1,  "lib defaults to 1");
    is($ts->blib,              1,  "blib defaults to 1");
    is($ts->tlib,              0,  "tlib defaults to 0");
    is($ts->unsafe_inc,        0,  "unsafe_inc defaults to 0");
    is($ts->retry_isolated,    0,  "retry_isolated defaults to 0");
    is($ts->retry,             0,  "retry defaults to 0");
    is($ts->event_timeout,     60, "event_timeout defaults to 60");
    is($ts->post_exit_timeout, 15, "post_exit_timeout defaults to 15");
    is($ts->cover,             U,  "cover defaults to undef");
    is($ts->input,             U,  "input defaults to undef");
    is($ts->input_file,        U,  "input_file defaults to undef");
    is($ts->ch_dir,            U,  "ch_dir defaults to undef");

    is($ts->switches, [], "switches defaults to []");
    is($ts->load,     [], "load defaults to []");
    is($ts->args,     [], "args defaults to []");

    # includes() is computed and adds lib/blib based on settings
    # with default lib=1, blib=1, it will include lib, blib/lib, blib/arch
    my $incs = $ts->includes;
    ok(grep { $_ eq 'lib' } @$incs,       "includes contains 'lib' by default");
    ok(grep { $_ eq 'blib/lib' } @$incs,  "includes contains 'blib/lib' by default");
    ok(grep { $_ eq 'blib/arch' } @$incs, "includes contains 'blib/arch' by default");

    # env_vars() is computed: adds T2_FORMATTER=Stream when use_stream=1
    my $ev = $ts->env_vars;
    is($ev->{T2_FORMATTER}, 'Stream', "env_vars adds T2_FORMATTER=Stream by default");

    # load_import() is computed: adds plugins for event_uuids and mem_usage
    my $li = $ts->load_import;
    ok(grep { $_ eq 'Test2::Plugin::UUID' } @{$li->{'@'}     // []}, "load_import includes Test2::Plugin::UUID by default");
    ok(grep { $_ eq 'Test2::Plugin::MemUsage' } @{$li->{'@'} // []}, "load_import includes Test2::Plugin::MemUsage by default");

    # use_fork and use_preload require explicit setting; by default the internal
    # storage is unset and they return 0 unless explicitly enabled
    ok(defined($ts->use_fork),    "use_fork is defined");
    ok(defined($ts->use_preload), "use_preload is defined");
};

subtest 'platform defaults via explicit setting' => sub {
    my $ts = Test2::Harness2::TestSettings->new(use_fork => 1, use_preload => 1);

    if ($^O eq 'MSWin32') {
        is($ts->use_fork,    0, "use_fork is 0 on Windows even when set");
        is($ts->use_preload, 0, "use_preload is 0 on Windows even when set");
    }
    else {
        is($ts->use_fork,    1, "use_fork is 1 on non-Windows when set");
        is($ts->use_preload, 1, "use_preload is 1 on non-Windows when set");
    }
};

subtest 'construction with values' => sub {
    my $ts = Test2::Harness2::TestSettings->new(
        use_stream        => 0,
        use_timeout       => 0,
        allow_retry       => 0,
        event_timeout     => 120,
        post_exit_timeout => 30,
        retry             => 3,
        switches          => ['-w'],
        load              => ['Foo'],
        args              => ['--bar'],
        env_vars          => {FOO => 'bar'},
        load_import       => {Baz => []},
    );

    is($ts->use_stream,        0,         "use_stream set to 0");
    is($ts->use_timeout,       0,         "use_timeout set to 0");
    is($ts->allow_retry,       0,         "allow_retry set to 0");
    is($ts->event_timeout,     120,       "event_timeout set to 120");
    is($ts->post_exit_timeout, 30,        "post_exit_timeout set to 30");
    is($ts->retry,             3,         "retry set to 3");
    is($ts->switches,          ['-w'],    "switches set");
    is($ts->load,              ['Foo'],   "load set");
    is($ts->args,              ['--bar'], "args set");

    # env_vars() is computed - FOO should be present; use_stream=0 so no T2_FORMATTER
    my $ev = $ts->env_vars;
    is($ev->{FOO}, 'bar', "env_vars contains FOO");
    ok(!exists $ev->{T2_FORMATTER}, "env_vars does not have T2_FORMATTER when use_stream=0");

    # load_import() is computed - Baz should be present alongside plugins
    my $li = $ts->load_import;
    ok(exists $li->{Baz}, "load_import contains Baz");
};

subtest 'event_timeout respects use_timeout' => sub {
    my $ts = Test2::Harness2::TestSettings->new(use_timeout => 0);
    is($ts->event_timeout,     U, "event_timeout is undef when use_timeout=0");
    is($ts->post_exit_timeout, U, "post_exit_timeout is undef when use_timeout=0");

    my $ts2 = Test2::Harness2::TestSettings->new(use_timeout => 1);
    is($ts2->event_timeout,     60, "event_timeout is 60 when use_timeout=1");
    is($ts2->post_exit_timeout, 15, "post_exit_timeout is 15 when use_timeout=1");

    my $ts3 = Test2::Harness2::TestSettings->new(use_timeout => 1, event_timeout => 999);
    is($ts3->event_timeout, 999, "explicit event_timeout respected");
};

subtest 'merge - scalar last-defined-wins' => sub {
    my $a = Test2::Harness2::TestSettings->new(retry => 1, event_timeout => 30);
    my $b = Test2::Harness2::TestSettings->new(retry => 5);

    my $merged = Test2::Harness2::TestSettings->merge($a, $b);
    is($merged->retry, 5, "last-defined wins for scalar (retry)");
};

subtest 'merge - array deduplication and concatenation' => sub {
    my $a = Test2::Harness2::TestSettings->new(switches => ['-w', '-T']);
    my $b = Test2::Harness2::TestSettings->new(switches => ['-T', '-Iblib/lib']);

    my $merged = Test2::Harness2::TestSettings->merge($a, $b);
    is($merged->switches, ['-w', '-T', '-Iblib/lib'], "arrays are concatenated and deduplicated");
};

subtest 'merge - hash overlay' => sub {
    my $a = Test2::Harness2::TestSettings->new(env_vars => {FOO => '1',  BAR => '2'});
    my $b = Test2::Harness2::TestSettings->new(env_vars => {BAR => '99', BAZ => '3'});

    my $merged = Test2::Harness2::TestSettings->merge($a, $b);

    # Check raw internal env_vars hash (not the computed env_vars method)
    my $raw = $merged->{Test2::Harness2::TestSettings::ENV_VARS()};
    is($raw, {FOO => '1', BAR => '99', BAZ => '3'}, "raw env_vars hash is overlaid correctly");
};

subtest 'merge - called as class method' => sub {
    my $a = Test2::Harness2::TestSettings->new(retry => 2);
    my $b = Test2::Harness2::TestSettings->new(retry => 7, load => ['FooModule']);

    my $merged = Test2::Harness2::TestSettings->merge($a, $b);
    isa_ok($merged, ['Test2::Harness2::TestSettings'], "merge returns a TestSettings");
    is($merged->retry, 7,             "scalar merge works");
    is($merged->load,  ['FooModule'], "array merge works");
};

subtest 'merge - called as instance method' => sub {
    my $a = Test2::Harness2::TestSettings->new(retry => 2);
    my $b = Test2::Harness2::TestSettings->new(retry => 7);

    my $merged = $a->merge($b);
    isa_ok($merged, ['Test2::Harness2::TestSettings'], "merge returns a TestSettings when called on instance");
    is($merged->retry, 7, "scalar merge works via instance");
};

subtest 'merge - cleared field removes setting' => sub {
    my $a = Test2::Harness2::TestSettings->new(retry => 5);
    my $b = Test2::Harness2::TestSettings->new;
    $b->{cleared} = {retry => 1};

    my $merged = Test2::Harness2::TestSettings->merge($a, $b);
    # After clearing, the default kicks in (0)
    is($merged->retry, 0, "cleared field resets to default");
};

subtest 'cover method' => sub {
    my $ts = Test2::Harness2::TestSettings->new;
    is($ts->cover, U, "cover undef when not set");

    my $ts_cover_1 = Test2::Harness2::TestSettings->new(cover => 1);
    like($ts_cover_1->cover, qr/silent/, "cover=1 returns default cover args");

    my $ts_cover_custom = Test2::Harness2::TestSettings->new(cover => 'foo,bar');
    is($ts_cover_custom->cover, 'foo,bar', "custom cover args returned as-is");
};

subtest 'TO_JSON' => sub {
    my $ts   = Test2::Harness2::TestSettings->new(retry => 3);
    my $json = $ts->TO_JSON;
    ok(ref($json) eq 'HASH',  "TO_JSON returns a hash");
    ok(exists $json->{class}, "TO_JSON includes class key");
    is($json->{class}, 'Test2::Harness2::TestSettings', "class key has correct value");
};

subtest 'aliases' => sub {
    my $ts = Test2::Harness2::TestSettings->new(use_stream => 1);
    is($ts->stream, $ts->use_stream, "stream is alias for use_stream");

    my $ts2 = Test2::Harness2::TestSettings->new(args => ['foo']);
    is($ts2->test_args, $ts2->args, "test_args is alias for args");
};

done_testing;
