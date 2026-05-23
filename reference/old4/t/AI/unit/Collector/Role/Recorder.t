use Test2::V0;
use Role::Tiny ();

use Test2::Harness2::Collector::Role::Recorder;

ok(
    Role::Tiny->is_role('Test2::Harness2::Collector::Role::Recorder'),
    'is a Role::Tiny role',
);

like(
    dies {
        package T::RecorderMissing;
        use Role::Tiny::With;
        with 'Test2::Harness2::Collector::Role::Recorder';
    },
    qr/record_event|record_state|record_exit|record_artifact|finalize/,
    'consuming class without required methods fails',
);

{
    package T::RecorderOk;
    sub new             { bless {}, shift }
    sub record_event    { 1 }
    sub record_state    { 1 }
    sub record_exit     { 1 }
    sub record_artifact { 1 }
    sub finalize        { 1 }
    use Role::Tiny::With;
    with 'Test2::Harness2::Collector::Role::Recorder';
}

ok(T::RecorderOk->new, 'consuming class with all required methods succeeds');

done_testing;
