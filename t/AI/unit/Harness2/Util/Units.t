use Test2::V0;

use Test2::Harness2::Util::Units qw/parse_quantity parse_byte_size parse_duration parse_count_or_pct parse_size_or_pct/;

subtest 'parse_quantity: explicit unit' => sub {
    is(
        [parse_quantity('512mb', units => [qw/kb mb gb tb/])],
        [512, 'mb'], 'mb lower-case'
    );
    is(
        [parse_quantity('512MB', units => [qw/kb mb gb tb/])],
        [512, 'mb'], 'mb upper-case lowercased on output'
    );
    is(
        [parse_quantity(' 1 gb ', units => [qw/kb mb gb tb/])],
        [1, 'gb'], 'whitespace stripped'
    );
    is(
        [parse_quantity('1.5gb', units => [qw/kb mb gb tb/])],
        [1.5, 'gb'], 'fractional'
    );
};

subtest 'parse_quantity: default_unit' => sub {
    is(
        [parse_quantity('5', units => [qw/ms s m/], default_unit => 's')],
        [5, 's'], 'bare number uses default'
    );
    is(
        [parse_quantity('500ms', units => [qw/ms s m/], default_unit => 's')],
        [500, 'ms'], 'explicit overrides default'
    );
};

subtest 'parse_quantity: required unit' => sub {
    like(
        dies { parse_quantity('5', units => [qw/kb mb gb tb/]) },
        qr/unit required/, 'no default + bare number = croak'
    );
};

subtest 'parse_quantity: invalid input croaks' => sub {
    like(
        dies { parse_quantity('', units => [qw/s/]) },
        qr/required/, 'empty'
    );
    like(
        dies { parse_quantity(undef, units => [qw/s/]) },
        qr/required/, 'undef'
    );
    like(
        dies { parse_quantity('abc', units => [qw/s/]) },
        qr/expected NUMBER/, 'non-numeric'
    );
    like(
        dies { parse_quantity('-5s', units => [qw/s/]) },
        qr/expected NUMBER/, 'negative rejected'
    );
    like(
        dies { parse_quantity('5xb', units => [qw/kb mb gb tb/]) },
        qr/expected NUMBER/, 'unknown unit suffix'
    );
    like(
        dies { parse_quantity('5kb', units => [qw/mb gb/]) },
        qr/expected NUMBER/, 'unit not in caller-supplied set'
    );
};

subtest 'parse_quantity: name in error message' => sub {
    like(
        dies { parse_quantity('abc', units => [qw/s/], name => 'duration') },
        qr/duration/, 'name is duration'
    );
    like(
        dies { parse_quantity('abc', units => [qw/s/], name => 'threshold') },
        qr/threshold/, 'name is threshold'
    );
};

subtest 'parse_byte_size' => sub {
    is(parse_byte_size('1kb'),   1024,               'kb');
    is(parse_byte_size('1mb'),   1024**2,            'mb');
    is(parse_byte_size('1gb'),   1024**3,            'gb');
    is(parse_byte_size('1tb'),   1024**4,            'tb');
    is(parse_byte_size('1.5gb'), int(1.5 * 1024**3), 'fractional gb');
    is(parse_byte_size('1MB'),   1024**2,            'case insensitive');

    is(
        parse_byte_size('5', default_unit => 'mb'), 5 * 1024**2,
        'default_unit=mb on bare number'
    );

    like(dies { parse_byte_size('5') },   qr/unit required/,   'unit required by default');
    like(dies { parse_byte_size('0kb') }, qr/must be > 0/,     'zero rejected');
    like(dies { parse_byte_size('abc') }, qr/expected NUMBER/, 'non-numeric');
};

subtest 'parse_duration' => sub {
    is(parse_duration('1ms'),   0.001, 'ms');
    is(parse_duration('1s'),    1,     's');
    is(parse_duration('2s'),    2,     '2s');
    is(parse_duration('1m'),    60,    'm');
    is(parse_duration('1.5m'),  90,    'fractional m');
    is(parse_duration('500MS'), 0.5,   'case insensitive');

    is(parse_duration('2'), 2, 'bare number = seconds (default)');

    is(
        parse_duration('5', default_unit => 'ms'), 0.005,
        'default_unit override'
    );

    like(dies { parse_duration('0s') },  qr/must be > 0/,     'zero rejected');
    like(dies { parse_duration('') },    qr/required/,        'empty');
    like(dies { parse_duration('abc') }, qr/expected NUMBER/, 'non-numeric');
};

subtest 'parse_count_or_pct' => sub {
    is(parse_count_or_pct('64'),   {kind => 'count', value => 64},  'bare integer = count');
    is(parse_count_or_pct('1'),    {kind => 'count', value => 1},   'count=1');
    is(parse_count_or_pct('10%'),  {kind => 'pct',   value => 10},  '10%');
    is(parse_count_or_pct('99%'),  {kind => 'pct',   value => 99},  '99%');
    is(parse_count_or_pct('0.5%'), {kind => 'pct',   value => 0.5}, 'fractional %');

    like(dies { parse_count_or_pct('0') },    qr/count/,           'count=0 rejected');
    like(dies { parse_count_or_pct('-5') },   qr/expected NUMBER/, 'negative');
    like(dies { parse_count_or_pct('1.5') },  qr/count/,           'fractional count rejected');
    like(dies { parse_count_or_pct('0%') },   qr/pct/,             '0% rejected');
    like(dies { parse_count_or_pct('100%') }, qr/pct/,             '100% rejected');
    like(dies { parse_count_or_pct('5mb') },  qr/expected NUMBER/, 'byte unit rejected');
    like(dies { parse_count_or_pct('') },     qr/required/,        'empty');
};

subtest 'parse_size_or_pct' => sub {
    is(parse_size_or_pct('1kb'),   {kind => 'bytes', value => 1024},          'kb');
    is(parse_size_or_pct('512mb'), {kind => 'bytes', value => 512 * 1024**2}, 'mb');
    is(parse_size_or_pct('1gb'),   {kind => 'bytes', value => 1024**3},       'gb');
    is(parse_size_or_pct('15%'),   {kind => 'pct',   value => 15},            '15%');
    is(parse_size_or_pct('0.5%'),  {kind => 'pct',   value => 0.5},           'fractional %');

    like(dies { parse_size_or_pct('512') },  qr/expected NUMBER/, 'bare number rejected (require unit)');
    like(dies { parse_size_or_pct('0kb') },  qr/must be > 0/,     'zero size');
    like(dies { parse_size_or_pct('0%') },   qr/pct/,             '0% rejected');
    like(dies { parse_size_or_pct('100%') }, qr/pct/,             '100% rejected');
    like(dies { parse_size_or_pct('abc') },  qr/expected NUMBER/, 'non-numeric');
};

subtest 'parse_size_or_pct: default_unit shorthand' => sub {
    # Resource::Disk uses default_unit => '%' so bare numbers parse as percent.
    is(parse_size_or_pct('25',    default_unit => '%'), {kind => 'pct', value => 25},  'bare number = pct');
    is(parse_size_or_pct('0.5',   default_unit => '%'), {kind => 'pct', value => 0.5}, 'fractional pct');
    is(parse_size_or_pct(' 25 %', default_unit => '%'), {kind => 'pct', value => 25},  'whitespace tolerated');
    is(parse_size_or_pct('512kb', default_unit => '%'), {kind => 'bytes', value => 512 * 1024}, 'unit still wins');
    is(parse_size_or_pct('1MB',   default_unit => '%'), {kind => 'bytes', value => 1024**2},    'case insensitive');

    like(dies { parse_size_or_pct('150%', default_unit => '%') }, qr/pct/, '>100% rejected');
    like(dies { parse_size_or_pct('0kb',  default_unit => '%') }, qr/must be > 0/, 'zero bytes');
    like(dies { parse_size_or_pct('5xb',  default_unit => '%') }, qr/expected NUMBER/, 'unknown unit');
    like(dies { parse_size_or_pct('',     default_unit => '%') }, qr/required/, 'empty');
    like(dies { parse_size_or_pct(undef,  default_unit => '%') }, qr/required/, 'undef');
};

done_testing;
