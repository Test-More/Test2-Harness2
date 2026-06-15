use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD
#
# Coverage for the inlined UI option modules:
#   App::Yath2::Options::{DB,WebServer,Server,WebClient,Publish,Yath}
#
# For each module we assert the expected option group/fields exist with the
# expected defaults, and that a representative flag parses into the right place.
# We also guard against a regression where loading ALL the UI option modules
# together (plus App::Yath2) produced a duplicate-option-form crash (the recent
# '--project' collision between Options::Yath and Options::PreCommand).

use strict;
use warnings;

use App::Yath2::Options::DB;
use App::Yath2::Options::WebServer;
use App::Yath2::Options::Server;
use App::Yath2::Options::WebClient;
use App::Yath2::Options::Publish;
use App::Yath2::Options::Yath;

# Parse argv through a single option module and return the resulting settings.
sub parse {
    my ($mod, @argv) = @_;
    my $res = $mod->options->process_args([@argv], skip_posts => 1);
    return $res->{settings};
}

subtest DB => sub {
    my $s = parse('App::Yath2::Options::DB', '--db-driver', 'SQLite', '--db-name', 'mydb');
    ok($s->check_group('db'), "db group exists");
    is($s->db->driver, 'SQLite', "--db-driver lands in db.driver");
    is($s->db->name,   'mydb',   "--db-name lands in db.name");

    # Fields that exist with no value default to undef.
    my $bare = parse('App::Yath2::Options::DB');
    is($bare->db->driver, undef, "driver undef by default");
    is($bare->db->dsn,    undef, "dsn undef by default");

    my $dsn = parse('App::Yath2::Options::DB', '--db-dsn', 'dbi:SQLite:dbname=/tmp/x.db');
    is($dsn->db->dsn, 'dbi:SQLite:dbname=/tmp/x.db', "--db-dsn captured");
};

subtest WebServer => sub {
    my $s = parse('App::Yath2::Options::WebServer', '--port', '9191');
    ok($s->check_group('webserver'), "webserver group exists");
    is($s->webserver->port, 9191, "--port lands in webserver.port");

    # WebServer include_options() DB, so the db group must be present too.
    ok($s->check_group('db'), "WebServer pulls in the db group via include_options");

    my $d = parse('App::Yath2::Options::WebServer');
    is($d->webserver->host,      'localhost', "host defaults to localhost");
    is($d->webserver->port,      8080,        "port defaults to 8080 (no port_command)");
    is($d->webserver->importers, 2,           "importers defaults to 2");
    is($d->webserver->launcher_args, [],      "launcher_args initializes to empty list");

    my $h = parse('App::Yath2::Options::WebServer', '--host', '0.0.0.0');
    is($h->webserver->host, '0.0.0.0', "--host overrides default");
};

subtest Server => sub {
    my $s = parse('App::Yath2::Options::Server', '--ephemeral=SQLite');
    ok($s->check_group('server'), "server group exists");
    is($s->server->ephemeral, 'SQLite', "--ephemeral=SQLite allowed value lands in server.ephemeral");

    my $d = parse('App::Yath2::Options::Server');
    is($d->server->shell,       0, "shell defaults to 0");
    is($d->server->daemon,      0, "daemon defaults to 0");
    is($d->server->single_user, 0, "single_user defaults to 0");

    my $b = parse('App::Yath2::Options::Server', '--daemon');
    is($b->server->daemon, 1, "--daemon sets the bool");

    # A disallowed ephemeral value must be rejected.
    my $ok = eval {
        App::Yath2::Options::Server->options->process_args(['--ephemeral=Bogus'], skip_posts => 1);
        1;
    };
    ok(!$ok, "--ephemeral=Bogus (not in allowed_values) is rejected");
};

subtest WebClient => sub {
    my $s = parse('App::Yath2::Options::WebClient', '--url', 'http://example.com');
    ok($s->check_group('webclient'), "webclient group exists");
    is($s->webclient->url, 'http://example.com', "--url lands in webclient.url");

    # 'uri' is registered as an alt for url.
    my $alt = parse('App::Yath2::Options::WebClient', '--uri', 'http://alt.example.com');
    is($alt->webclient->url, 'http://alt.example.com', "--uri alt also sets url");

    my $d = parse('App::Yath2::Options::WebClient');
    is($d->webclient->grace, 0, "grace defaults to 0");
    is($d->webclient->request_retry, 0, "request_retry defaults to 0");

    my $k = parse('App::Yath2::Options::WebClient', '--api-key', 'abc123');
    is($k->webclient->api_key, 'abc123', "--api-key captured");
};

subtest Publish => sub {
    my $d = parse('App::Yath2::Options::Publish');
    ok($d->check_group('publish'), "publish group exists");
    is($d->publish->mode,        'qvfd', "mode defaults to qvfd");
    is($d->publish->buffer_size, 100,    "buffer_size defaults to 100");
    is($d->publish->retry,       0,      "retry defaults to 0");
    is($d->publish->force,       0,      "force defaults to 0");

    my $s = parse('App::Yath2::Options::Publish', '--publish-mode', 'summary', '--publish-buffer-size', '50');
    is($s->publish->mode,        'summary', "--publish-mode override");
    is($s->publish->buffer_size, 50,        "--publish-buffer-size override");
};

subtest Yath => sub {
    my $s = parse('App::Yath2::Options::Yath', '--user', 'bob');
    ok($s->check_group('yath'), "yath group exists");
    is($s->yath->user, 'bob', "--user lands in yath.user");

    # NOTE: Options::Yath deliberately does NOT own '--project' (it mirrors the
    # harness group's project via post-process) to avoid a duplicate option
    # form. Confirm it does not register a 'project' CLI flag of its own.
    my $has_project_opt = grep { $_->field eq 'project' } @{App::Yath2::Options::Yath->options->options};
    ok(!$has_project_opt, "Options::Yath does not define its own --project flag");
};

subtest 'no duplicate-option-form crash when all UI options load together' => sub {
    # Regression guard for the '--project' collision. Loading App::Yath2 plus
    # all of the UI option modules and then parsing a small argv (that uses
    # --project, which lives in the harness group) must not die.
    local $ENV{YATH_SELF_TEST} = 1;

    require App::Yath2;
    require Getopt::Yath::Settings;

    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['server', '--project', 'CollisionGuard'],
        config   => {},
        settings => $settings,
    );

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $app->process_argv;
        1;
    };
    my $err = $@;
    ok($ok, "process_argv with all UI options loaded did not crash") or diag($err);

    is($settings->harness->project, 'CollisionGuard', "--project parsed into the harness group");
};

done_testing;
