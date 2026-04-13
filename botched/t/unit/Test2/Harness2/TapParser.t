use Test2::V0;

use Test2::Harness2::TapParser;

# ---- Constructor ----
subtest 'constructor' => sub {
    my $p = Test2::Harness2::TapParser->new();
    ok($p, "constructor returns an object");
    isa_ok($p, 'Test2::Harness2::TapParser');
};

# ---- Non-TAP lines return undef ----
subtest 'non-TAP lines return undef' => sub {
    my $p = Test2::Harness2::TapParser->new();

    is($p->parse_tap_line(""),                     undef, "empty string is undef");
    is($p->parse_tap_line("hello world"),          undef, "random text is undef");
    is($p->parse_tap_line("  some indented text"), undef, "non-multiple-of-4 indent is undef");
    is($p->parse_tap_line("  random"),             undef, "2-space indent non-TAP is undef");
};

# ---- ok / not ok ----
subtest 'ok line' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("ok 1 - basic test");
    ok($fd, "parsed ok line");
    is($fd->{assert}{pass},      1,                   "pass is true");
    is($fd->{assert}{number},    '1',                 "number is 1");
    is($fd->{assert}{details},   'basic test',        "details stripped of dash");
    is($fd->{trace}{nested},     0,                   "top-level nest is 0");
    is($fd->{hubs}[0]{nested},   0,                   "hubs nest is 0");
    is($fd->{from_tap}{source},  'STDOUT',            "from_tap source is STDOUT");
    is($fd->{from_tap}{details}, "ok 1 - basic test", "from_tap details is original line");
};

subtest 'not ok line' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("not ok 2 - failed test");
    ok($fd, "parsed not ok line");
    is($fd->{assert}{pass},    0,             "pass is false");
    is($fd->{assert}{number},  '2',           "number is 2");
    is($fd->{assert}{details}, 'failed test', "details correct");
};

subtest 'ok without number' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("ok - no number");
    ok($fd, "parsed ok without number");
    is($fd->{assert}{pass}, 1, "pass is true");
    ok(!exists $fd->{assert}{number}, "no number key when absent");
    is($fd->{assert}{details}, 'no number', "details correct");
};

# ---- TODO ----
subtest 'TODO directive' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("not ok 3 - broken # TODO fix later");
    ok($fd, "parsed TODO line");
    is($fd->{assert}{pass}, 0, "pass is false");
    my @amnesty = @{$fd->{amnesty} // []};
    my ($todo) = grep { $_->{tag} eq 'TODO' } @amnesty;
    ok($todo, "amnesty TODO entry present");
    is($todo->{details}, 'fix later', "TODO reason captured");
};

# ---- SKIP ----
subtest 'SKIP directive' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("ok 4 # SKIP not on this platform");
    ok($fd, "parsed SKIP line");
    my @amnesty = @{$fd->{amnesty} // []};
    my ($skip) = grep { $_->{tag} eq 'SKIP' } @amnesty;
    ok($skip, "amnesty SKIP entry present");
    is($skip->{details}, 'not on this platform', "SKIP reason captured");
};

# ---- Plan ----
subtest 'plan 1..N' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("1..5");
    ok($fd, "parsed plan");
    is($fd->{plan}{count},      5,        "plan count is 5");
    is($fd->{plan}{skip},       0,        "not a skip plan");
    is($fd->{trace}{nested},    0,        "top-level nested");
    is($fd->{from_tap}{source}, 'STDOUT', "from_tap source");
};

subtest 'skip plan 1..0' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("1..0 # SKIP no tests");
    ok($fd, "parsed skip plan");
    is($fd->{plan}{count},   0,          "plan count is 0");
    is($fd->{plan}{skip},    1,          "skip is true");
    is($fd->{plan}{details}, 'no tests', "skip reason captured");
};

subtest 'skip plan without reason' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("1..0");
    ok($fd, "parsed bare skip plan");
    is($fd->{plan}{count}, 0, "plan count is 0");
    is($fd->{plan}{skip},  1, "skip is true");
};

# ---- Bail out ----
subtest 'bail out' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("Bail out! catastrophic failure");
    ok($fd, "parsed bail out");
    is($fd->{control}{halt},    1,                      "halt is true");
    is($fd->{control}{details}, 'catastrophic failure', "bail reason captured");
    is($fd->{from_tap}{source}, 'STDOUT',               "from_tap source");
};

subtest 'bail out without reason' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("Bail out!");
    ok($fd, "parsed bare bail out");
    is($fd->{control}{halt},    1,  "halt is true");
    is($fd->{control}{details}, '', "empty reason");
};

# ---- Comments / Diagnostics ----
subtest 'comment line (NOTE)' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("# This is a note");
    ok($fd, "parsed comment");
    my $info = $fd->{info}[0];
    ok($info, "info entry present");
    is($info->{tag},            'NOTE',           "tag is NOTE for stdout");
    is($info->{debug},          0,                "debug is false for NOTE");
    is($info->{details},        'This is a note', "details correct");
    is($fd->{from_tap}{source}, 'STDOUT',         "from_tap source");
};

subtest 'comment as DIAG via parse_stderr_tap' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_stderr_tap("# This is a diag");
    ok($fd, "parsed stderr comment");
    my $info = $fd->{info}[-1];
    is($info->{tag},            'DIAG',   "tag is DIAG for stderr");
    is($info->{debug},          1,        "debug is true for DIAG");
    is($fd->{from_tap}{source}, 'STDERR', "from_tap source is STDERR");
};

subtest 'non-comment stderr returns undef' => sub {
    my $p = Test2::Harness2::TapParser->new();

    is($p->parse_stderr_tap("ok 1"), undef, "ok line on stderr is undef");
    is($p->parse_stderr_tap("1..1"), undef, "plan on stderr is undef");
};

# ---- TAP version ----
subtest 'TAP version line' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("TAP version 13");
    ok($fd,                         "parsed TAP version");
    ok($fd->{about} || $fd->{info}, "has about or info facet");
};

# ---- Indented / nested TAP ----
subtest 'indented TAP sets nested level' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("    ok 1 - nested test");
    ok($fd, "parsed indented ok");
    is($fd->{trace}{nested},   1, "trace nested is 1");
    is($fd->{hubs}[0]{nested}, 1, "hubs nested is 1");
    is($fd->{assert}{pass},    1, "pass is correct");
};

subtest 'doubly-indented TAP sets nested level 2' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("        ok 1 - double nested");
    ok($fd, "parsed double-indented ok");
    is($fd->{trace}{nested},   2, "trace nested is 2");
    is($fd->{hubs}[0]{nested}, 2, "hubs nested is 2");
};

subtest 'tab indent equals 4 spaces' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("\tok 1 - tab-indented");
    ok($fd, "parsed tab-indented ok");
    is($fd->{trace}{nested}, 1, "tab = 4 spaces = level 1");
};

subtest 'non-multiple-of-4 indent is not TAP' => sub {
    my $p = Test2::Harness2::TapParser->new();

    is($p->parse_tap_line("  ok 1"),  undef, "2-space indent returns undef");
    is($p->parse_tap_line("   ok 1"), undef, "3-space indent returns undef");
};

# ---- Buffered subtest markers ----
subtest 'buffered subtest start (ok N ... {)' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("ok 1 - my subtest {");
    ok($fd,                           "parsed subtest start");
    ok($fd->{harness}{subtest_start}, "subtest_start flag set");
    ok($fd->{parent},                 "parent facet present");
    is($fd->{assert}{details}, 'my subtest', "trailing { stripped from details");
};

subtest 'buffered subtest end (})' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("}");
    ok($fd,                         "parsed subtest end");
    ok($fd->{harness}{subtest_end}, "subtest_end flag set");
    ok($fd->{parent},               "parent facet present");
};

subtest 'indented subtest end' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my $fd = $p->parse_tap_line("    }");
    ok($fd,                         "parsed indented subtest end");
    ok($fd->{harness}{subtest_end}, "subtest_end flag set");
    is($fd->{trace}{nested}, 1, "nested level preserved");
};

# ---- from_tap on all parsed lines ----
subtest 'from_tap present on all parsed results' => sub {
    my $p = Test2::Harness2::TapParser->new();

    my @lines = (
        "ok 1",
        "not ok 2",
        "1..3",
        "# comment",
        "Bail out! die",
        "TAP version 13",
        "ok 1 - sub {",
        "}",
    );

    for my $line (@lines) {
        my $fd = $p->parse_tap_line($line);
        ok($fd,             "parsed: $line");
        ok($fd->{from_tap}, "from_tap present for: $line");
        is($fd->{from_tap}{source},  'STDOUT', "from_tap source STDOUT for: $line");
        is($fd->{from_tap}{details}, $line,    "from_tap details is original line for: $line");
    }
};

done_testing;
