#!/usr/bin/perl
# HARNESS-NO-FORK

use strict;
use warnings;

use Test2::V0;

@ARGV = ();

# Load the modules under test before we chdir into the fixture tree, so the
# relative @INC entries (e.g. -Ilib) still resolve.
require App::Yath::Script::V2;
require App::Yath2;
my $CLASS = 'App::Yath::Script::V2';

{
    my ($tdir) = grep { -d $_ } 't/yath_script', 'yath_script';
    die "Could not find the t/yath_script directory" unless $tdir;
    chdir("$tdir/nested") or die "Could not change directory: $!";
}

subtest parse_config_files => sub {
    my $config_file      = './../.yath.rc';
    my $user_config_file = './.yath.user.rc';

    local @ARGV = ('START', 'END');

    my ($config_args, $config, $to_clean) = $CLASS->_parse_config_files($config_file, $user_config_file);

    # The setup() caller prepends the pre-args; replicate that so we can check
    # the resulting @ARGV the way the script does.
    unshift @ARGV => @$config_args;

    is(
        $config_args,
        [
            '-Dpre_lib',
            '-D=./../pre/xxx/lib',
            '-D=./../pre/yyy/lib',
            '-D=SPLIT',
            '--no-scan-plugins',
            '-Dpre_user_lib',
            '-D=./pre/xxx/user/lib',
            '-D=./pre/yyy/user/lib',
        ],
        "Got pre-args from all config files"
    );

    is(
        [@ARGV],
        [
            '-Dpre_lib',
            '-D=./../pre/xxx/lib',
            '-D=./../pre/yyy/lib',
            '-D=SPLIT',
            '--no-scan-plugins',
            '-Dpre_user_lib',
            '-D=./pre/xxx/user/lib',
            '-D=./pre/yyy/user/lib',
            'START',
            'END',
        ],
        "Prepended args to \@ARGV"
    );

    is(
        $config,
        {
            '~' => [
                '-pXXX',
                '-p' => 'YYY',
                '-pUSER_XXX',
                '-p' => 'USER_YYY',
            ],
            test => [
                '-Itest_lib',
                '-I=./../test/xxx/lib',
                '-I' => './../test/yyy/lib',
                (map {('--default-search' => $_)} glob('./../../*.t')),
                '-xxxx',
                'foo',
                'bar',
                'baz' => 'bat',
                '-Itest_user_lib',
                '-I=./test/xxx/user/lib',
                '-I' => './test/yyy/user/lib',
                '-user_xxxx',
                'user_foo',
                'user_bar',
                'user_baz' => 'user_bat',
            ],
            run => [
                '-Irun_lib',
                '-I=./../run/xxx/lib',
                '-I' => './../run/yyy/lib',
                '-xxxx',
                'foo',
                'bar',
                '-Irun_user_lib',
                '-I=./run/xxx/user/lib',
                '-I' => './run/yyy/user/lib',
                '-user_xxxx',
                'user_foo',
                'user_bar',
            ],
        },
        "Parsed all command args properly"
    );

    is(
        $to_clean,
        [
            ['test', T, '-I', '=', './../test/xxx/lib'],
            ['test', T, '-I', ' ', './../test/yyy/lib'],

            (map { ['test', T, '--default-search', ' ', $_] } glob('./../../*.t')),

            ['run', T, '-I', '=', './../run/xxx/lib'],
            ['run', T, '-I', ' ', './../run/yyy/lib'],

            ['test', T, '-I', '=', './test/xxx/user/lib'],
            ['test', T, '-I', ' ', './test/yyy/user/lib'],

            ['run', T, '-I', '=', './run/xxx/user/lib'],
            ['run', T, '-I', ' ', './run/yyy/user/lib'],
        ],
        "Will come back and clean these later"
    );
};

subtest pre_parse_dev_libs => sub {
    {
        local @INC = ('START', 'END');
        local @ARGV = ('START', '-D=aaa', '-Dbbb', '--no-scan-plugins', '--no-dev-lib', '-D', '--dev-lib', '-Dxxx', '-Dxxx', '--dev-lib=foo', '-Dbbb', '::', '-Doops', 'END');

        my ($libs, $no_plugins) = $CLASS->_pre_parse_dev_libs();

        # The setup() caller prepends the dev-libs to @INC; replicate that.
        unshift @INC => @$libs;

        is(
            [@ARGV],
            ['START', '::', '-Doops', 'END'],
            "Modified \@ARGV"
        );

        is(
            $libs,
            ['lib', 'blib/lib', 'blib/arch', 'xxx', 'foo', 'bbb'],
            "Got expected libs (with the --no-dev-lib reset midway wiping previously seen entries)"
        );

        is(
            [@INC],
            ['lib', 'blib/lib', 'blib/arch', 'xxx', 'foo', 'bbb', 'START', 'END'],
            "prepended libs to \@INC"
        );

        is($no_plugins, 1, "Set no plugins");
    }

    {
        local @INC = ('START', 'END');
        local @ARGV = ('START', '-Dbbb', '--', '-Doops', 'END');

        my ($libs, $no_plugins) = $CLASS->_pre_parse_dev_libs();
        unshift @INC => @$libs;

        is(
            [@ARGV],
            ['START', '--', '-Doops', 'END'],
            "Modified \@ARGV"
        );

        is($libs, ['bbb'], "Got expected libs");

        is(
            [@INC],
            ['bbb', 'START', 'END'],
            "prepended libs to \@INC"
        );

        is($no_plugins, undef, "Did not set no plugins");
    }
};

subtest realpath_paths => sub {
    require Cwd;
    require File::Spec;

    my @libs     = ('../../lib', './', '../');
    my @dev_libs = @libs;
    local @INC   = (@libs, 'START', 'END');
    my %config   = (
        test => [
            '-I' => '../../lib',
            '-I=../../lib',
        ],
    );

    my @to_clean = (
        ['test', 1, '-I', ' ', '../../lib'],
        ['test', 2, '-I', '=', '../../lib'],
    );

    $CLASS->_realpath_paths(\@dev_libs, \%config, \@to_clean);

    is(
        \@INC,
        [(map { Cwd::realpath($_) } @libs), 'START', 'END'],
        "Cleaned up \@INC"
    );

    is(
        \@dev_libs,
        [(map { Cwd::realpath($_) } @libs)],
        "Cleaned up dev-libs"
    );

    is(
        \%config,
        {
            test => [
                '-I' => Cwd::realpath('../../lib'),
                '-I=' . Cwd::realpath('../../lib'),
            ],
        },
        "Cleaned up \%config"
    );
};

subtest build_app => sub {
    my $args;
    my $control = mock(
        'App::Yath2' => (
            override => {
                generate_run_sub => sub { $args = [@_] },
            },
        )
    );

    my %ORIG_SIG  = (INT => 'DEFAULT');
    my @ORIG_ARGV = ('foo', 'bar');
    my @ORIG_INC  = @INC;
    my @dev_libs  = ('lib');

    local @ARGV = ('cmd', 'arg');

    my %config = (test => ['-Ifoo']);

    my $app = $CLASS->_build_app(
        script          => 'foobar',
        config          => \%config,
        orig_tmp        => '/tmp',
        orig_tmp_perms  => 0700,
        orig_sig        => \%ORIG_SIG,
        orig_argv       => \@ORIG_ARGV,
        orig_inc        => \@ORIG_INC,
        dev_libs        => \@dev_libs,
        no_scan_plugins => 2,
    );

    isa_ok($app, ['App::Yath2'], "Built an App::Yath2 instance");

    my ($got_app, $symbol) = @$args;
    ref_is($got_app, $app, "generate_run_sub called on the app");
    is($symbol, 'App::Yath::Script::V2::_run', "Got correct run-sub symbol");

    ref_is($app->_argv, \@ARGV, "Used \@ARGV");
    ref_is($app->config, \%config, "Used \%config");

    is(
        $app->settings,
        {
            harness => {
                orig_tmp         => '/tmp',
                orig_tmp_perms   => 0700,
                orig_sig         => exact_ref(\%ORIG_SIG),
                orig_argv        => exact_ref(\@ORIG_ARGV),
                orig_inc         => exact_ref(\@ORIG_INC),
                dev_libs         => exact_ref(\@dev_libs),
                script           => 'foobar',
                no_scan_plugins  => 2,
                config_file      => '',
                user_config_file => '',
                start            => T(),
                version          => T(),
                cwd              => T(),
            },
        },
        "Got settings"
    );
};

done_testing();
