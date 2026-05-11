use strict;
use warnings;

use Test2::V0;

use App::Yath2::Options::Preload qw/classify_preload_modules/;

# --- empty / undef input ---
is([classify_preload_modules()],   [], 'empty input returns nothing');
is([classify_preload_modules([])], [], 'empty arrayref returns nothing');

# --- bare modules collect into one 'default' group ---
{
    my @out = classify_preload_modules([qw/strict warnings/]);
    is(\@out, [
        {name => 'default', modules => [qw/strict warnings/], is_role_consumer => 0},
    ], 'bare modules collect into a single default group');
}

# --- role consumers get their own named group + a separate default ---
{
    package T2::Test::FakePreload::A;
    use Role::Tiny::With;
    sub name { 'fake-a' }
    sub modules { ['strict'] }
    with 'Test2::Harness2::Role::Preload';
    $INC{'T2/Test/FakePreload/A.pm'} = __FILE__;
}
{
    package T2::Test::FakePreload::B;
    use Role::Tiny::With;
    sub name { 'fake-b' }
    sub modules { ['warnings'] }
    with 'Test2::Harness2::Role::Preload';
    $INC{'T2/Test/FakePreload/B.pm'} = __FILE__;
}

{
    my @out = classify_preload_modules([
        'strict', 'T2::Test::FakePreload::A', 'warnings', 'T2::Test::FakePreload::B',
    ]);
    is(\@out, [
        {name => 'default', modules => [qw/strict warnings/], is_role_consumer => 0},
        {name => 'fake-a',  modules => ['T2::Test::FakePreload::A'], is_role_consumer => 1},
        {name => 'fake-b',  modules => ['T2::Test::FakePreload::B'], is_role_consumer => 1},
    ], 'role consumers get their own named groups, bare modules stay in default');
}

# --- two role consumers with the same name() collide ---
{
    package T2::Test::FakePreload::Dup1;
    use Role::Tiny::With;
    sub name { 'dup' }
    sub modules { [] }
    with 'Test2::Harness2::Role::Preload';
    $INC{'T2/Test/FakePreload/Dup1.pm'} = __FILE__;
}
{
    package T2::Test::FakePreload::Dup2;
    use Role::Tiny::With;
    sub name { 'dup' }
    sub modules { [] }
    with 'Test2::Harness2::Role::Preload';
    $INC{'T2/Test/FakePreload/Dup2.pm'} = __FILE__;
}
like(
    dies { classify_preload_modules(['T2::Test::FakePreload::Dup1', 'T2::Test::FakePreload::Dup2']) },
    qr/name 'dup' which collides/,
    'duplicate role-consumer names error out',
);

# --- missing module errors out with a helpful message ---
like(
    dies { classify_preload_modules(['This::Will::Not::Load::EVER']) },
    qr/Failed to load -P module 'This::Will::Not::Load::EVER'/,
    'missing module surfaces the load error',
);

done_testing;
