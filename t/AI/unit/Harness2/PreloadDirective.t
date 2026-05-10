use Test2::V0;
use Test2::Harness2::Util::PreloadDirective qw/parse_preload_directive/;

subtest 'empty / undef normalize to <default>' => sub {
    is(parse_preload_directive(undef),  ['<default>'], 'undef -> [<default>]');
    is(parse_preload_directive(''),     ['<default>'], 'empty string -> [<default>]');
    is(parse_preload_directive('   '),  ['<default>'], 'whitespace-only -> [<default>]');
};

subtest 'bare names' => sub {
    is(parse_preload_directive('Foo'),     ['Foo'],         'single name');
    is(parse_preload_directive('Foo Bar'), ['Foo', 'Bar'],  'two names, ordered');
    is(parse_preload_directive("  Foo\tBar  "), ['Foo', 'Bar'], 'tabs + extra spaces');
};

subtest '<no> alone' => sub {
    is(parse_preload_directive('<no>'), ['<no>'], 'opt-out');
};

subtest '<default> alone (terminal)' => sub {
    is(parse_preload_directive('<default>'), ['<default>'], 'just default');
};

subtest '<default> <no> normalizes to <default>' => sub {
    is(
        parse_preload_directive('<default> <no>'),
        ['<default>'],
        '<no> after <default> is redundant; dropped',
    );
};

subtest 'named + <default>' => sub {
    is(
        parse_preload_directive('Foo Bar <default>'),
        ['Foo', 'Bar', '<default>'],
        'preference list with <default> terminator',
    );
};

subtest 'named + <no>' => sub {
    is(
        parse_preload_directive('Foo Bar <no>'),
        ['Foo', 'Bar', '<no>'],
        'preference list with <no> terminator',
    );
};

subtest 'named + <default> <no> normalizes' => sub {
    is(
        parse_preload_directive('Foo <default> <no>'),
        ['Foo', '<default>'],
        'trailing <no> after <default> dropped',
    );
};

subtest 'validation: <no> mid-list rejected' => sub {
    my $ok = eval { parse_preload_directive('Foo <no> Bar'); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/<no>.*must be the last/i, 'error names <no> placement rule');
};

subtest 'validation: <default> mid-list rejected' => sub {
    my $ok = eval { parse_preload_directive('Foo <default> Bar'); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/<default>.*must be (the )?last/i, 'error names <default> placement rule');
};

subtest 'validation: name after <no> rejected' => sub {
    my $ok = eval { parse_preload_directive('<no> Foo'); 1 };
    ok(!$ok, 'croaked');
    like($@, qr/<no>/, 'error mentions <no>');
};

subtest 'validation: duplicate <default> rejected' => sub {
    my $ok = eval { parse_preload_directive('<default> <default>'); 1 };
    ok(!$ok, 'croaked on duplicate <default>');
};

subtest 'validation: unknown <token> rejected' => sub {
    my $ok = eval { parse_preload_directive('<bogus>'); 1 };
    ok(!$ok, 'croaked on unknown <bogus>');
    like($@, qr/<bogus>/, 'error mentions the unknown token');
};

done_testing;
