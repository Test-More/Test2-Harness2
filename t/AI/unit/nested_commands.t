use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Nested subcommands (db/importer.pm => App::Yath2::Command::db::importer) must
# be reachable as `yath db importer` (two tokens) and `yath db-importer` (one),
# and must show up in the help listing.

use App::Yath2;
use App::Yath2::Command::help;
use Getopt::Yath::Settings;

subtest load_command_maps_nested => sub {
    is(App::Yath2->load_command('db-importer',    check_only => 1), 'App::Yath2::Command::db::importer', 'db-importer');
    is(App::Yath2->load_command('db/importer',    check_only => 1), 'App::Yath2::Command::db::importer', 'db/importer (slash)');
    is(App::Yath2->load_command('client-publish', check_only => 1), 'App::Yath2::Command::client::publish', 'client-publish');
    is(App::Yath2->load_command('db',             check_only => 1), 'App::Yath2::Command::db', 'top-level db still resolves');
    is(App::Yath2->load_command('test',           check_only => 1), 'App::Yath2::Command::test', 'top-level test still resolves');
    is(App::Yath2->load_command('no-such-thing',  check_only => 1), undef, 'unknown -> undef');
};

subtest two_token_dispatch => sub {
    my $app = App::Yath2->new(
        argv     => [],
        config   => {},
        settings => Getopt::Yath::Settings->new(harness => {}, debug => {version => 0}),
    );

    # `yath db importer --foo` -> the db-importer command, with --foo passed on.
    my ($cmd, $args) = $app->_command_from_argv({remains => ['db', 'importer', '--foo']});
    is($cmd, 'db-importer', '`db importer` resolves to the nested command');
    is($args, ['--foo'], 'both command tokens consumed, remaining args preserved');

    # `yath db` alone (next token is an option) still runs the plain db command.
    my ($cmd2, $args2) = $app->_command_from_argv({remains => ['db', '--ephemeral=SQLite']});
    is($cmd2, 'db', '`db` alone stays the plain db command');
};

subtest help_lists_nested => sub {
    my $h     = App::Yath2::Command::help->new(args => []);
    my %cmds  = map { $_ => 1 } $h->command_list;
    ok($cmds{'db-importer'},    'help lists db-importer');
    ok($cmds{'client-publish'}, 'help lists client-publish');
    ok($cmds{'test'},           'help still lists top-level test');
};

done_testing;
