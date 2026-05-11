use Test2::V0;

use Test2::Harness2::Resource::Disk::Threshold qw/parse_threshold/;

subtest 'percent default unit' => sub {
    is(parse_threshold('25'),    {kind => 'pct', value => 25},  'bare number = pct');
    is(parse_threshold('25%'),   {kind => 'pct', value => 25},  'explicit %');
    is(parse_threshold('0.5'),   {kind => 'pct', value => 0.5}, 'fractional pct');
    is(parse_threshold(' 25 %'), {kind => 'pct', value => 25},  'whitespace tolerated');
};

subtest 'byte units' => sub {
    is(parse_threshold('512kb'), {kind => 'bytes', value => 512 * 1024},         'kb');
    is(parse_threshold('512mb'), {kind => 'bytes', value => 512 * 1024**2},      'mb');
    is(parse_threshold('1gb'),   {kind => 'bytes', value => 1 * 1024**3},        'gb');
    is(parse_threshold('2tb'),   {kind => 'bytes', value => 2 * 1024**4},        'tb');
    is(parse_threshold('1.5gb'), {kind => 'bytes', value => int(1.5 * 1024**3)}, 'fractional gb');
    is(parse_threshold('1MB'),   {kind => 'bytes', value => 1024**2},            'case insensitive');
};

subtest 'invalid input croaks' => sub {
    like(dies { parse_threshold('') },     qr/threshold/, 'empty');
    like(dies { parse_threshold('abc') },  qr/threshold/, 'non-numeric');
    like(dies { parse_threshold('-5%') },  qr/threshold/, 'negative');
    like(dies { parse_threshold('100%') }, qr/threshold/, '100% rejected (>= 100)');
    like(dies { parse_threshold('150%') }, qr/threshold/, '> 100%');
    like(dies { parse_threshold('0%') },   qr/threshold/, '0% rejected');
    like(dies { parse_threshold('5xb') },  qr/threshold/, 'unrecognised unit suffix');
    like(dies { parse_threshold('0kb') },  qr/threshold/, 'zero bytes rejected');
    like(dies { parse_threshold('mb') },   qr/threshold/, 'unit only');
    like(dies { parse_threshold(undef) },  qr/threshold/, 'undef');
};

done_testing;
