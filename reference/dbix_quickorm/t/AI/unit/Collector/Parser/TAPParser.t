use Test2::V0;
use v5.38;

use Test2::Harness2::Collector::Parser::TAPParser;

my $parser = Test2::Harness2::Collector::Parser::TAPParser->new;

sub fd ($stream, $line) {
    my $event = $parser->parse_io(stream => $stream, line => $line);
    return $event ? $event->facet_data : undef;
}

subtest assertions => sub {
    my $ok = fd(stdout => 'ok 1 - pass one');
    ok($ok->{assert}{pass}, "ok line is a passing assert");
    is($ok->{assert}{details}, 'pass one', "assert details parsed");
    is($ok->{assert}{number}, 1, "assert number parsed");
    is($ok->{from_tap}{source}, 'STDOUT', "from_tap source recorded");

    my $not = fd(stdout => 'not ok 2 - boom');
    ok(!$not->{assert}{pass}, "not ok line is a failing assert");
    is($not->{assert}{details}, 'boom', "failing assert details parsed");
};

subtest directives => sub {
    my $todo = fd(stdout => 'ok 3 - later # TODO not yet');
    is($todo->{amnesty}[0]{tag}, 'TODO', "TODO directive -> amnesty");
    is($todo->{amnesty}[0]{details}, 'not yet', "TODO reason parsed");

    my $skip = fd(stdout => 'ok 4 - maybe # skip no good');
    is($skip->{amnesty}[0]{tag}, 'SKIP', "SKIP directive -> amnesty");
};

subtest plan_and_misc => sub {
    is(fd(stdout => '1..5')->{plan}{count}, 5, "plan count parsed");

    my $skip_all = fd(stdout => '1..0 # SKIP nope');
    is($skip_all->{plan}{count}, 0, "skip-all plan count 0");
    ok($skip_all->{plan}{skip}, "skip-all plan flagged skip");

    is(fd(stdout => 'TAP version 13')->{info}[0]{tag}, 'INFO', "version preamble");

    my $bail = fd(stdout => 'Bail out! kaboom');
    ok($bail->{control}{halt}, "bail out -> control halt");
    is($bail->{control}{details}, 'kaboom', "bail reason parsed");
};

subtest comments_and_nesting => sub {
    my $note = fd(stdout => '# a note');
    is($note->{info}[0]{tag}, 'NOTE', "stdout comment -> NOTE");

    my $diag = fd(stderr => '# a diagnostic');
    is($diag->{info}[0]{tag}, 'DIAG', "stderr comment -> DIAG");
    ok($diag->{info}[0]{debug}, "DIAG marked debug");

    my $nested = fd(stdout => '    ok 1 - deep');
    is($nested->{trace}{nested}, 1, "4-space indent -> nesting depth 1");
};

subtest fallthrough => sub {
    my $raw = fd(stdout => 'just some output');
    ok($raw->{from_stream}, "non-TAP line falls back to from_stream");
    is($raw->{from_stream}{details}, 'just some output', "raw line preserved");
    ok(!$raw->{from_tap}, "no from_tap facet on a fallthrough line");

    my $raw_err = fd(stderr => 'plain stderr noise');
    is($raw_err->{info}[0]{tag}, 'STDERR', "non-comment stderr falls back to raw");
};

done_testing;
