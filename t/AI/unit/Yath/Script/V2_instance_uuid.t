use Test2::V0;
use App::Yath::Script::V2;

# do_begin populates a global $INSTANCE; we inspect the settings it stored.
App::Yath::Script::V2->do_begin(
    script => '/tmp/fake-yath',
    argv   => [],
);

my $yath_settings = App::Yath::Script::V2->_test_instance_settings_yath;

ok(defined $yath_settings->instance_uuid, 'instance_uuid is set');
like(
    $yath_settings->instance_uuid,
    qr/^[0-9a-f]{8}$/,
    'instance_uuid is 8 lowercase hex chars',
);

done_testing;
