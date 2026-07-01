use Test2::V0 -target => 'Test2::Harness2::Util::Units';
# HARNESS-DURATION-SHORT

use ok $CLASS => qw/parse_count_or_pct parse_duration/;

imported_ok(qw/parse_count_or_pct parse_duration/);

subtest parse_count_or_pct => sub {
    is(parse_count_or_pct('5'),   {kind => 'count', value => 5},  '"5" -> count 5');
    is(parse_count_or_pct('1'),   {kind => 'count', value => 1},  '"1" -> count 1');
    is(parse_count_or_pct(' 12 '), {kind => 'count', value => 12}, 'whitespace stripped -> count 12');

    is(parse_count_or_pct('50%'), {kind => 'pct', value => 50}, '"50%" -> pct 50');
    is(parse_count_or_pct('1%'),  {kind => 'pct', value => 1},  '"1%" -> pct 1');
    is(parse_count_or_pct('99%'), {kind => 'pct', value => 99}, '"99%" -> pct 99');

    like(dies { parse_count_or_pct('0') },     qr/count must be > 0/,           '"0" count croaks');
    like(dies { parse_count_or_pct('0%') },    qr/pct must be > 0 and < 100/,   '"0%" pct croaks');
    like(dies { parse_count_or_pct('100%') },  qr/pct must be > 0 and < 100/,   '"100%" pct croaks');
    like(dies { parse_count_or_pct('1.5') },   qr/invalid/,                     'fractional count croaks');
    like(dies { parse_count_or_pct('5gb') },   qr/invalid/,                     'unit suffix croaks');
    like(dies { parse_count_or_pct('') },      qr/is required/,                 'empty croaks');
    like(dies { parse_count_or_pct(undef) },   qr/is required/,                 'undef croaks');
    like(dies { parse_count_or_pct('0', name => 'workers') }, qr/workers/,      'name used in error');
};

subtest parse_duration => sub {
    is(parse_duration('2'),     2,    '"2" -> 2s (default unit)');
    is(parse_duration('2s'),    2,    '"2s" -> 2');
    is(parse_duration('500ms'), 0.5,  '"500ms" -> 0.5');
    is(parse_duration('1m'),    60,   '"1m" -> 60');
    is(parse_duration('1.5s'),  1.5,  '"1.5s" -> 1.5');
    is(parse_duration('2M'),    120,  'case-insensitive unit "2M" -> 120');
    is(parse_duration('30', default_unit => 'm'), 1800, 'default_unit override');

    like(dies { parse_duration('0') },    qr/must be > 0/,  'zero croaks');
    like(dies { parse_duration('5h') },   qr/invalid/,      'unknown unit croaks');
    like(dies { parse_duration('') },     qr/is required/,  'empty croaks');
    like(dies { parse_duration('0', name => 'timeout') }, qr/timeout/, 'name used in error');
};

done_testing;
