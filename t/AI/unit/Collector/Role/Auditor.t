use Test2::V0;
use Role::Tiny ();

use Test2::Harness2::Collector::Role::Auditor;

ok(
    Role::Tiny->is_role('Test2::Harness2::Collector::Role::Auditor'),
    'is a Role::Tiny role',
);

like(
    dies {
        package T::AuditorMissing;
        use Role::Tiny::With;
        with 'Test2::Harness2::Collector::Role::Auditor';
    },
    qr/audit_event|fail_count|pass_count/,
    'consuming class without required methods fails',
);

{
    package T::AuditorOk;
    sub new { bless {f => 0, p => 0}, shift }
    sub audit_event { return () }
    sub fail_count  { 0 }
    sub pass_count  { 0 }
    use Role::Tiny::With;
    with 'Test2::Harness2::Collector::Role::Auditor';
}

my $a = T::AuditorOk->new;
ok($a->passing,  'passing default works when fail_count = 0');
ok(!$a->failing, 'failing default works when fail_count = 0');
is([$a->startup],  [], 'startup default returns empty list');
is([$a->shutdown], [], 'shutdown default returns empty list');

done_testing;
