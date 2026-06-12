package App::Yath2::Test::DBIC::Database;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/ephemeral_server/;

use App::Yath2UI::Schema::Config;
use App::Yath2UI::Server;

# Spin up an ephemeral DB and return (config, server, dsn).
sub ephemeral_server {
    my (%args) = @_;
    my $driver = $args{driver} or die "driver required\n";

    my $config = App::Yath2UI::Schema::Config->new(ephemeral => $driver);
    my $server = App::Yath2UI::Server->new(schema_config => $config);
    my $db     = $server->start_ephemeral_db;
    my $dsn    = $db->connect_string('harness_ui');

    return ($config, $server, $dsn);
}

1;
