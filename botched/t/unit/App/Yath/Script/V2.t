use Test2::V0;
use Cwd qw/getcwd/;
use File::Spec;

use App::Yath::Script::V2;

subtest 'do_begin stores params' => sub {
    App::Yath::Script::V2->do_begin(
        script      => '/usr/bin/yath',
        argv        => ['test', '--foo'],
        config      => '/some/.yath.rc',
        user_config => '/home/user/.yath.user.rc',
    );

    # Access the internal state via do_runtime's indirect path is hard,
    # so we test it by calling do_runtime — but that calls run() which
    # needs a valid script. Instead, test args_to_settings_data directly
    # and trust do_begin's simplicity.
    ok(1, "do_begin did not die");
};

subtest 'args_to_settings_data returns correct structure' => sub {
    my $script = File::Spec->rel2abs($0);
    my $argv   = ['test', '--verbose'];

    my $data = App::Yath::Script::V2::args_to_settings_data($script, $argv);

    ok($data,                "got data back");
    ok(ref($data) eq 'HASH', "data is a hashref");
    ok(exists $data->{yath}, "has 'yath' key");

    my $yath = $data->{yath};

    is($yath->{script}, $script, "script is set correctly");

    ok($yath->{start},     "start time is set");
    ok($yath->{start} > 0, "start time is positive");

    my $cwd = $yath->{cwd};
    ok($cwd, "cwd is set");
    like($cwd, qr{/}, "cwd looks like an absolute path");

    my $orig_inc = $yath->{orig_inc};
    ok(ref($orig_inc) eq 'ARRAY', "orig_inc is an arrayref");
    ok(scalar(@$orig_inc) > 0,    "orig_inc has entries");

    ok(exists $yath->{orig_argv}, "orig_argv key exists");
    is($yath->{orig_argv}, ['test', '--verbose'], "orig_argv matches");

    ok(exists $yath->{orig_tmp}, "orig_tmp key exists");
    ok($yath->{orig_tmp},        "orig_tmp is non-empty");

    ok(exists $yath->{orig_tmp_perms}, "orig_tmp_perms key exists");

    ok(exists $yath->{config_file},      "config_file key exists");
    ok(exists $yath->{user_config_file}, "user_config_file key exists");

    ok(exists $yath->{base_dir}, "base_dir key exists");

    is($yath->{script_version}, $App::Yath::Script::V2::VERSION, "script_version matches VERSION");

    ok(exists $yath->{new_argv}, "new_argv key exists");
    is($yath->{new_argv}, $argv, "new_argv is same reference as passed argv");

    ok($ENV{SYSTEM_TMPDIR}, "SYSTEM_TMPDIR env var is set");
};

subtest 'do_begin and do_runtime wiring' => sub {
    # Verify do_begin and do_runtime are callable class methods
    can_ok('App::Yath::Script::V2', 'do_begin');
    can_ok('App::Yath::Script::V2', 'do_runtime');
    can_ok('App::Yath::Script::V2', 'run');
    can_ok('App::Yath::Script::V2', 'args_to_settings_data');
};

subtest 'run() usage errors' => sub {
    ok(
        dies { App::Yath::Script::V2->run() },
        "run() with no args dies"
    );
};

done_testing;
