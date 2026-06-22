use Test2::V0 -target => 'App::Yath2';
use Data::Dumper;
use Carp;

use App::Yath2;

use Test2::Harness2::Util qw/clean_path/;

$ENV{'YATH_SELF_TEST'} = 1;

subtest init => sub {
    my $one = $CLASS->new(argv => [foo => 'bar']);
    isa_ok($one, $CLASS);

    isa_ok($one->settings, 'Getopt::Yath::Settings');

    is($one->settings->harness->script, clean_path(__FILE__), "Yath script set to this test file");

    is($one->_argv, [foo => 'bar'], "Grabbed argv");

    is($one->config, {}, "Default empty config");

    my $two = App::Yath2->new();
    is($two->_argv, [], "default to empty argv");
};

{
    require App::Yath2::Command;
    $INC{'App/Yath2/Command/NOGEN.pm'} = __FILE__;
    $INC{'App/Yath2/Command/GEN.pm'} = __FILE__;

    package App::Yath2::Command::NOGEN;
    use Getopt::Yath;

    option_group {group => 'foo', category => 'Foo Options'} => sub {
        option 'verbose' => (
            type       => 'Count',
            short      => 'v',
            initialize => 0,
        );
    };
    option_post_process sub { $main::POST++ };

    use Test2::Harness2::Util::HashBase qw/settings argv/;
    our @ISA = ('App::Yath2::Command');

    sub run { 123 }

    package App::Yath2::Command::GEN;

    our @ISA = ('App::Yath2::Command::NOGEN');

    sub generate_run_sub { ('ran gen_run_sub', @_) }
}

subtest generate_run_sub => sub {
    my $one = $CLASS->new(argv => ['GEN']);

    my @out = $one->generate_run_sub('main::RUNSUB');
    is(
        \@out,
        [
            'ran gen_run_sub',
            'App::Yath2::Command::GEN',
            'main::RUNSUB',
            [],
            exact_ref($one->settings),
            ['GEN'],
        ],
        "Ran command generate_run_sub with correct args"
    );

    my $two = $CLASS->new(argv => ['NOGEN', '-vv']);

    $two->generate_run_sub('main::RUNSUB');
    is($two->settings->foo->verbose, 2, "Set verbose with CLI args");
    ok(defined(&main::RUNSUB), "Added the runsub to the provided symbol");
    is(main::RUNSUB(), 123, "runsub does what we expect (runs the command run method) and we get the exit value");

    # Post-process callbacks now fire during process_argv (once per parse).
    # Both the GEN parse above and this NOGEN parse run the inherited post,
    # so it has fired twice by now.
    is($main::POST, 2, "Ran post-process callbacks (once per command parse)");
};

subtest run_command => sub {
    my $one = $CLASS->new();

    my $cmd = mock {run => undef, name => 'acmd'};

    is(
        dies { $one->run_command($cmd) },
        "Command 'acmd' did not return an exit value.\n",
        "Command must return an exit value"
    );

    $cmd->{run} = 12;

    is($one->run_command($cmd), 12, "Returned the proper exit code");
};

subtest command_class => sub {
    my $one = $CLASS->new(argv => ['GEN']);
    is($one->command_class, 'App::Yath2::Command::GEN', "Got command class from args");

    $one->{_command_class} = 'foo';

    is($one->command_class, "foo", "A cache is used");
};

subtest load_command => sub {
    my $one = $CLASS->new();

    is($one->load_command('GEN'), 'App::Yath2::Command::GEN', "Works for valid command (inline)");
    is($one->load_command('test'), 'App::Yath2::Command::test', "Works for valid command (real)");

    is($one->load_command('gsdfgsdfgsd', check_only => 1), undef, "Missing module is ok in 'check_only' mode");

    is(
        dies { $one->load_command('dgfsdfgsdf') },
        "yath command 'dgfsdfgsdf' not found. (did you forget to install App::Yath2::Command::dgfsdfgsdf?)\n",
        "Correct message for missing command"
    );

    is(
        dies {
            local @INC = (sub { die "module failed\n" });
            $one->load_command('jgjgjfdfk');
        },
        "module failed\n",
        "If a module load throws an exception we pass it along"
    );
};

subtest options => sub {
    local @INC = (@INC, 't/lib');
    my $one = $CLASS->new();

    $one->settings->harness->create_option(no_scan_plugins => 1);

    my $options = $one->options();
    isa_ok($options, ['Getopt::Yath::Instance'], "options() returns a Getopt::Yath::Instance");

    my $groups = $options->option_groups;
    is($groups->{debug}, 1, "Has the debug option group (from Debug)");
    is($groups->{harness}, 1, "Has the harness option group (from PreCommand)");

    ref_is($options, $one->options, "Cached options result");

    # With plugin scanning enabled the instance also gains plugin/resource
    # groups discovered on disk.
    my $two = $CLASS->new();
    $two->settings->harness->create_option(no_scan_plugins => 0);

    my $scanned;
    my @ignore = warns { $scanned = $two->options() };
    isa_ok($scanned, ['Getopt::Yath::Instance'], "scanned options() returns a Getopt::Yath::Instance");

    my $sgroups = $scanned->option_groups;
    is($sgroups->{debug}, 1, "Scanned: still has the debug group");
    is($sgroups->{harness}, 1, "Scanned: still has the harness group");
};

subtest process_argv => sub {
    local @INC = (@INC, 't/lib');

    my $one = $CLASS->new(
        argv   => [qw/-Dfoo -Dbar fake -x -y blah uhg/],
        config => {fake => [qw/-Dbaz -z/], other => [qw/-noop/]},
    );

    my @ignore = warns { is($one->process_argv(), $one->_argv, "remaining args are returned") };

    is($one->command_class, 'App::Yath2::Command::fake', "Set command class");
    is(
        {$one->settings->fake->all},
        {
            x         => 1,
            y         => 1,
            z         => 1,
        },
        "Added 'fake' command settings"
    );

    like(
        $one->settings->harness->dev_libs,
        bag {
            item qr/foo$/;
            item qr/bar$/;
            item qr/baz$/;
        },
        "Added the dev libs"
    );

    is($one->_argv, [qw/blah uhg/], "Remaining args");

    no warnings 'once';
    # The fake command's option_post_process hook now fires during the
    # stage-2 command parse inside process_argv.
    is($main::POST_HOOK, 1, "Ran the command's post-process hook during process_argv");
};

subtest command_from_argv => sub {
    # _command_from_argv now consumes the state hash produced by the stage-1
    # global parse (it reads $state->{stop} + $state->{remains}) and returns
    # ($command_name, \@trailing_args). Leading global/unknown options are
    # pulled into $state->{skipped} by the parse and are NOT passed along.
    my $resolve = sub {
        my ($argv) = @_;
        my $one = $CLASS->new(argv => [@$argv]);
        $one->settings->harness->option_ref('persist_file', 1);
        $one->settings->harness->option_ref('project',      1);
        $one->settings->harness->option_ref('persist_dir',  1);

        my $state = $one->_process_global_args([@$argv]);
        my ($cmd, $tail) = $one->_command_from_argv($state);
        return ($cmd, $tail);
    };

    like(
        warning { my ($cmd) = $resolve->([]); is($cmd, 'test', "Default to test") },
        qr/Defaulting to the 'test' command/,
        "Warning about default"
    );

    {
        # A live persistent runner is now detected via App::Yath2::Discovery->find
        # (the well-known symlink resolving to an accepting socket), so mock that.
        my $control = mock 'App::Yath2::Discovery' => (override => [find => sub { bless {}, 'App::Yath2::Discovery' }]);
        like(
            warning { my ($cmd) = $resolve->([]); is($cmd, 'run', "Default to run if a persistent runner is detected") },
            qr/Persistent runner detected, defaulting to the 'run' command/,
            "Warning about default"
        );
    }

    my ($cmd, $tail);

    ($cmd, $tail) = $resolve->(['-f', '--foo', 'test', '-b', '--bar']);
    is($cmd, "test", "Found 'test' command");
    is($tail, ['-b', '--bar'], "Trailing args after the command are returned");

    ($cmd, $tail) = $resolve->(['-f', '--foo', 'hfajhdajshfj', '-b', '--bar']);
    is($cmd, "hfajhdajshfj", "Found 'hfajhdajshfj' command");
    is($tail, ['-b', '--bar'], "Trailing args after the command are returned");

    # A separated value for an unknown (command-scoped) option must not be
    # mistaken for the command. 'Test2'/'90' are not registered commands, so the
    # real 'test' command wins and the leftover value rides along to stage 2.
    ($cmd, $tail) = $resolve->(['--formatter', 'Test2', 'test', 't/foo.t']);
    is($cmd, "test", "Separated option value before command not taken as command");
    is($tail, ['Test2', 't/foo.t'], "Skipped option value rides along to the stage-2 parse");

    ($cmd, $tail) = $resolve->(['--term-width', '90', 'test', 't/foo.t']);
    is($cmd, "test", "Found 'test' past a separated numeric option value");
    is($tail, ['90', 't/foo.t'], "Numeric option value preserved for stage 2");

    ($cmd, $tail) = $resolve->(['-f', '--foo', '--help', '-b', '--bar']);
    is($cmd, "help", "Found 'help' command");

    ($cmd, $tail) = $resolve->(['-f', '--foo', '-h', '-b', '--bar']);
    is($cmd, "help", "Found 'help' command");

    my @ignore = warns { ($cmd, $tail) = $resolve->(['-f', '--foo', 'foo.jsonl.bz2', '-b', '--bar']) };
    is($cmd, "replay", "Found 'replay' command because we got a log");

    @ignore = warns { ($cmd, $tail) = $resolve->(['-f', '--foo', __FILE__, '-b', '--bar']) };
    is($cmd, "test", "Found 'test' command because we got a path");
};

subtest used_plugin_registration => sub {
    # Setting a plugin's option (Cover's --cover-write) must auto-register that
    # plugin into harness->plugins without an explicit -p, restoring the 1.0
    # "used_plugins" behavior. Modules whose options merely default must NOT.
    my $with = $CLASS->new(argv => ['test', '--cover-write=/tmp/yath-selftest-cov.jsonl']);
    my @ignore = warns { $with->process_argv };
    my @cover = grep { $_->isa('App::Yath2::Plugin::Cover') } @{$with->settings->harness->plugins};
    is(scalar(@cover), 1, "Cover auto-registered from --cover-write without -pCover");

    my $without = $CLASS->new(argv => ['test']);
    @ignore = warns { $without->process_argv };
    is($without->settings->harness->plugins, [], "No plugins registered when none of their options are set");
};

done_testing;
