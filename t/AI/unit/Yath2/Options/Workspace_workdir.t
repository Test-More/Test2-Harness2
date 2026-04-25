use Test2::V0;
use File::Spec();
use App::Yath::Script::V2;

App::Yath::Script::V2->do_begin(script => '/tmp/fake-yath', argv => []);
my $uuid = App::Yath::Script::V2->_test_instance_settings_yath->instance_uuid;

my $sys_tmp = File::Spec->tmpdir();

require App::Yath2::Options::Workspace;
my $default_sub = App::Yath2::Options::Workspace::_workdir_default();

# Build a fake settings object with the populated yath group.
my $fake_settings = App::Yath::Script::V2->_test_instance_settings;
my $workdir       = $default_sub->(undef, $fake_settings);

my $expected = File::Spec->catdir($sys_tmp, "yath-$uuid");
is($workdir, $expected, 'workdir is yath-{instance_uuid} under system tempdir');
ok(-d $workdir, 'workdir was created');

# Cleanup
rmdir $workdir;

done_testing;
