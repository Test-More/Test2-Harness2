use Test2::V0;
use Role::Tiny ();

use Test2::Harness2::Collector::Role::Parser;

ok(
    Role::Tiny->is_role('Test2::Harness2::Collector::Role::Parser'),
    'is a Role::Tiny role',
);

like(
    dies {
        package T::ParserMissing;
        use Role::Tiny::With;
        with 'Test2::Harness2::Collector::Role::Parser';
    },
    qr/parse_io/,
    'consuming class without parse_io fails',
);

ok(
    do {
        package T::ParserOk;
        sub new { bless {}, shift }
        sub parse_io { return }
        use Role::Tiny::With;
        with 'Test2::Harness2::Collector::Role::Parser';
        T::ParserOk->isa('T::ParserOk');
    },
    'consuming class with parse_io succeeds',
);

done_testing;
