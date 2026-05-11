use Test2::V0;

use Test2::Harness2::Util::Units qw/parse_quantity/;

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

done_testing;
