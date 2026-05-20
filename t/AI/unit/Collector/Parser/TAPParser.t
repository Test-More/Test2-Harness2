use Test2::V0;
use Test2::Harness2::Collector::Parser::TAPParser;

my $p = Test2::Harness2::Collector::Parser::TAPParser->new;
isa_ok($p, 'Test2::Harness2::Collector::Parser::TAPParser');
isa_ok($p, 'Test2::Harness2::Collector::Parser::IOParser');

subtest passing_assertion => sub {
    my $e = $p->parse_io(stream => 'stdout', line => 'ok 1 - hello');
    is($e->facet_data->{assert}{pass},    1,       'pass');
    is($e->facet_data->{assert}{number},  1,       'number');
    is($e->facet_data->{assert}{details}, 'hello', 'details');
    is($e->facet_data->{from_tap}{source}, 'STDOUT');
};

subtest failing_assertion => sub {
    my $e = $p->parse_io(stream => 'stdout', line => 'not ok 2 - bad');
    is($e->facet_data->{assert}{pass},    F(),    'not pass');
    is($e->facet_data->{assert}{number},  2);
    is($e->facet_data->{assert}{details}, 'bad');
};

subtest plan_line => sub {
    my $e = $p->parse_io(stream => 'stdout', line => '1..3');
    is($e->facet_data->{plan}{count}, 3, 'plan count');
    is($e->facet_data->{plan}{skip},  0);
};

subtest bail_out => sub {
    my $e = $p->parse_io(stream => 'stdout', line => 'Bail out! flooded');
    is($e->facet_data->{control}{halt},    1);
    is($e->facet_data->{control}{details}, 'flooded');
};

subtest comment_stdout_note => sub {
    my $e = $p->parse_io(stream => 'stdout', line => '# a note');
    is($e->facet_data->{info}->[0]{tag},   'NOTE');
    is($e->facet_data->{info}->[0]{debug}, 0);
};

subtest comment_stderr_diag => sub {
    my $e = $p->parse_io(stream => 'stderr', line => '# something bad');
    is($e->facet_data->{info}->[0]{tag},   'DIAG');
    is($e->facet_data->{info}->[0]{debug}, 1);
    is($e->facet_data->{from_tap}{source}, 'STDERR');
};

subtest stderr_non_comment_falls_back => sub {
    my $e = $p->parse_io(stream => 'stderr', line => 'not a comment');
    ok(!$e->facet_data->{from_tap}, 'no from_tap on STDERR non-comment');
    is($e->facet_data->{from_stream}{source}, 'STDERR', 'fell back to base');
};

subtest non_tap_falls_back => sub {
    my $e = $p->parse_io(stream => 'stdout', line => 'random output');
    ok(!$e->facet_data->{from_tap}, 'no from_tap');
    is($e->facet_data->{from_stream}{source}, 'STDOUT');
};

subtest subtest_nesting => sub {
    my $e = $p->parse_io(stream => 'stdout', line => '    ok 1 - nested');
    is($e->facet_data->{trace}{nested},     1, 'nesting depth');
    is($e->facet_data->{hubs}->[0]{nested}, 1);
};

done_testing;
