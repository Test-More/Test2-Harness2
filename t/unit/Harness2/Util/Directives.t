use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::Directives;

my $C = 'Test2::Harness2::Util::Directives';

subtest 'constructor validation' => sub {
    like(dies { $C->new() }, qr/'comments' is required/, 'comments required');
    like(dies { $C->new(comments => '#') }, qr/array reference/, 'comments must be arrayref');
    like(dies { $C->new(comments => []) }, qr/must not be empty/, 'comments must be non-empty');
    like(dies { $C->new(comments => [undef]) }, qr/non-empty strings/, 'comments entries non-empty');
    like(dies { $C->new(comments => ['']) },   qr/non-empty strings/, 'comments entries non-empty (empty)');
    ok($C->new(comments => ['#']), 'basic construction works');
};

subtest 'empty input -> empty hash' => sub {
    my $h = $C->parse_string('', comments => ['#']);
    is($h, {}, 'empty string -> empty hash');

    my $h2 = $C->parse_string("just a normal line\n# regular comment\n", comments => ['#']);
    is($h2, {}, 'no HARNESS2 directives -> empty hash');
};

subtest 'basic key + values' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: slots 2 8
END
    is($h, { slots => [2, 8] }, 'slots parsed');
};

subtest 'multiple comment prefixes' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#', '//']);
# HARNESS2: smoke @on
// HARNESS2: fork @off
END
    is($h, { smoke => [1], fork => [0] }, 'both prefixes recognized');
};

subtest 'sigils: on/true/yes -> 1, off/false/no -> 0' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: a @on
# HARNESS2: b @true
# HARNESS2: c @yes
# HARNESS2: d @off
# HARNESS2: e @false
# HARNESS2: f @no
END
    is($h, { a=>[1], b=>[1], c=>[1], d=>[0], e=>[0], f=>[0] }, 'boolean sigils');
};

subtest 'unknown sigil -> error' => sub {
    like(
        dies { $C->parse_string("# HARNESS2: slots \@bogus\n", comments => ['#']) },
        qr/unknown sigil '\@bogus'/,
        'unknown sigil throws',
    );
    like(
        dies { $C->parse_string("# HARNESS2: slots \@auto\n", comments => ['#']) },
        qr/unknown sigil '\@auto'/,
        '@auto is not reserved',
    );
};

subtest '@default expands per-key (preload has default; others empty)' => sub {
    my $h = $C->parse_string("# HARNESS2: preload \@default\n", comments => ['#']);
    is($h, { preload => ['default', 0] }, '@default expands for preload');

    my $h2 = $C->parse_string("# HARNESS2: timeout.event \@default\n", comments => ['#']);
    is($h2, {}, '@default on key without defaults -> empty, pruned');

    my $h3 = $C->parse_string("# HARNESS2: preload first \@default last\n", comments => ['#']);
    is(
        $h3,
        { preload => ['first', 'default', 0, 'last'] },
        '@default expansion flattens in place',
    );
};

subtest 'dotted keys nest' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: meta.foo hello
# HARNESS2: meta.foo "with space"
# HARNESS2: meta.bar 1 2 3
END
    is(
        $h,
        { meta => { foo => ['hello', 'with space'], bar => [1, 2, 3] } },
        'dotted keys nested',
    );
};

subtest 'deep nesting' => sub {
    my $h = $C->parse_string("# HARNESS2: meta.foo.bar baz\n", comments => ['#']);
    is($h, { meta => { foo => { bar => ['baz'] } } }, 'three levels');
};

subtest 'multi-line + multi-token append (flat)' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: conflicts db redis
# HARNESS2: conflicts cache
END
    is($h, { conflicts => ['db', 'redis', 'cache'] }, 'flat append');
};

subtest 'quoted strings preserve whitespace' => sub {
    my $h = $C->parse_string(qq{# HARNESS2: meta.note "hello world"\n}, comments => ['#']);
    is($h, { meta => { note => ['hello world'] } }, 'quoted with space');

    my $h2 = $C->parse_string(qq{# HARNESS2: meta.note "with \\"escaped\\" quotes"\n}, comments => ['#']);
    is($h2, { meta => { note => ['with "escaped" quotes'] } }, 'escaped quotes');
};

subtest 'unterminated quote -> error' => sub {
    like(
        dies { $C->parse_string(qq{# HARNESS2: meta.x "open\n}, comments => ['#']) },
        qr/unterminated quote/,
        'unterminated quote throws',
    );
};

subtest 'churn blocks just count' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: churn {
sub heavy_one { 1 }
# HARNESS2: churn }
some other code;
# HARNESS2: churn {
sub heavy_two { 2 }
# HARNESS2: churn }
END
    is($h, { churn => [1, 1] }, 'two churn blocks counted');
};

subtest 'block: nested -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: churn {
# HARNESS2: foo {
END
        },
        qr/nested HARNESS2 block/,
        'nested block throws',
    );
};

subtest 'block: unclosed at EOF -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: churn {
some body
END
        },
        qr/unclosed HARNESS2 block 'churn'/,
        'unclosed block throws',
    );
};

subtest 'block: mismatched close key -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: churn {
# HARNESS2: other }
END
        },
        qr/block close key mismatch/,
        'mismatched close throws',
    );
};

subtest 'block: directive line inside block -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: churn {
# HARNESS2: smoke @on
# HARNESS2: churn }
END
        },
        qr/inside block/,
        'directive inside block throws',
    );
};

subtest 'block: stray close -> error' => sub {
    like(
        dies { $C->parse_string("# HARNESS2: churn }\n", comments => ['#']) },
        qr/unexpected block-close/,
        'stray close throws',
    );
};

subtest 'block: extra tokens with brace -> error' => sub {
    like(
        dies { $C->parse_string("# HARNESS2: churn extra {\n", comments => ['#']) },
        qr/must not have other tokens/,
        'open brace with extra tokens throws',
    );
};

subtest 'key collision: leaf then subtree -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: meta hello
# HARNESS2: meta.foo bar
END
        },
        qr/key collision.*already holds values/,
        'leaf then subtree throws',
    );
};

subtest 'key collision: subtree then leaf -> error' => sub {
    like(
        dies {
            $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: meta.foo bar
# HARNESS2: meta hello
END
        },
        qr/key collision.*already holds subtree/,
        'subtree then leaf throws',
    );
};

subtest 'malformed key -> error' => sub {
    like(
        dies { $C->parse_string("# HARNESS2: BadKey 1\n", comments => ['#']) },
        qr/malformed key/,
        'uppercase rejected',
    );
    like(
        dies { $C->parse_string("# HARNESS2: 1bad 1\n", comments => ['#']) },
        qr/malformed key/,
        'leading digit rejected',
    );
    like(
        dies { $C->parse_string("# HARNESS2: meta. value\n", comments => ['#']) },
        qr/malformed key/,
        'trailing dot rejected',
    );
};

subtest 'directive with no values -> error' => sub {
    like(
        dies { $C->parse_string("# HARNESS2: smoke\n", comments => ['#']) },
        qr/has no values/,
        'naked key throws',
    );
};

subtest 'empty pruning' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: timeout.event @default
# HARNESS2: timeout.postexit @default
# HARNESS2: slots 1
END
    is($h, { slots => [1] }, 'empty subtree pruned, only slots remains');
};

subtest 'streaming via parse_line + finish' => sub {
    my $d = $C->new(comments => ['#']);
    $d->parse_line('# HARNESS2: slots 4 16');
    $d->parse_line('# HARNESS2: conflicts foo');
    $d->parse_line('# HARNESS2: conflicts bar baz');
    is($d->finish, { slots => [4, 16], conflicts => ['foo', 'bar', 'baz'] }, 'streamed parse');
};

subtest 'parse_line rejects embedded newline' => sub {
    my $d = $C->new(comments => ['#']);
    like(
        dies { $d->parse_line("# HARNESS2: a 1\n# HARNESS2: b 2") },
        qr/embedded newline/,
        'embedded newline throws',
    );
};

subtest 'parse_file reads from disk' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "# HARNESS2: smoke \@on\n# HARNESS2: slots 2 4\n";
    close $fh;
    my $h = $C->parse_file($path, comments => ['#']);
    is($h, { smoke => [1], slots => [2, 4] }, 'parse_file works');
};

subtest 'parse_fh reads from filehandle' => sub {
    open my $fh, '<', \"# HARNESS2: stage worker\n" or die "open scalarref: $!";
    my $h = $C->parse_fh($fh, comments => ['#']);
    is($h, { stage => ['worker'] }, 'parse_fh works');
};

subtest 'directives only recognized after configured comment prefix' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
// HARNESS2: smoke @on
something HARNESS2: slots 1
END
    is($h, {}, 'non-comment lines ignored');
};

subtest 'multi-line same key flat append, full directive map sample' => sub {
    my $h = $C->parse_string(<<'END', comments => ['#']);
# HARNESS2: preload moose dancer
# HARNESS2: preload @default
# HARNESS2: fork @on
# HARNESS2: smoke @off
# HARNESS2: duration long
# HARNESS2: category isolation
# HARNESS2: timeout.event 30
# HARNESS2: timeout.postexit 60
# HARNESS2: retry.count 3
# HARNESS2: retry.isolated @on
# HARNESS2: conflicts db
# HARNESS2: conflicts cache
# HARNESS2: slots 2 8
# HARNESS2: stage runner
# HARNESS2: meta.author "Chad Granum"
# HARNESS2: meta.ticket 1234
# HARNESS2: feature.cool @on
END
    is(
        $h,
        {
            preload  => ['moose', 'dancer', 'default', 0],
            fork     => [1],
            smoke    => [0],
            duration => ['long'],
            category => ['isolation'],
            timeout  => { event => [30], postexit => [60] },
            retry    => { count => [3], isolated => [1] },
            conflicts => ['db', 'cache'],
            slots    => [2, 8],
            stage    => ['runner'],
            meta     => { author => ['Chad Granum'], ticket => [1234] },
            feature  => { cool => [1] },
        },
        'composite sample',
    ) or diag explain $h;
};

done_testing;
