use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Unit coverage for App::Yath2::Options::Logger post-processing (the -L / DB
# logger option machinery):
#   * a bare -L resolves to a default .sqlite file;
#   * sqlite paths and dbi:... DSN targets are accepted;
#   * a DuckDB target (a .duckdb/.ddb path OR a dbi:DuckDB: DSN) is REJECTED --
#     DuckDB is single-writer and a live logger does insert-then-update on
#     referenced rows, which DuckDB forbids. DuckDB is a sync/read target only.

use strict;
use warnings;

use App::Yath2::Options::Logger;

# Parse argv through the Logger option module WITH post-processing (the default;
# skip_posts is NOT passed) so the default-path resolution + reject guard run.
sub parse {
    my (@argv) = @_;
    my $res = App::Yath2::Options::Logger->options->process_args([@argv]);
    return $res->{settings};
}

# Parse and capture a die from post-processing (undef on success).
sub parse_dies {
    my (@argv) = @_;
    my $ok = eval { App::Yath2::Options::Logger->options->process_args([@argv]); 1 };
    return $ok ? undef : ($@ || 'died');
}

subtest accepted_targets => sub {
    my $bare = parse('-L');
    like($bare->logger->targets->[0], qr/\.sqlite\z/, "bare -L defaults to a .sqlite file");

    ok(!parse_dies('-L=/tmp/yath-x.sqlite'),     "an explicit .sqlite path is accepted");
    ok(!parse_dies('-L=dbi:Pg:dbname=yath'),     "a postgres DSN is accepted");
    ok(!parse_dies('-L=dbi:MariaDB:database=y'), "a mariadb DSN is accepted");

    my $two = parse('-L=/tmp/a.sqlite', '-L=/tmp/b.sqlite');
    is(scalar(@{$two->logger->targets}), 2, "multiple sqlite targets are kept (N loggers -> N DBs)");
};

subtest duckdb_targets_rejected => sub {
    for my $t ('/tmp/log.duckdb', '/tmp/log.ddb', 'dbi:DuckDB:dbname=/tmp/log') {
        my $err = parse_dies("-L=$t");
        ok($err, "a DuckDB -L target ($t) is rejected");
        like($err, qr/not a valid live-logging target/, "  ... with the single-writer/sync-only explanation");
    }

    # A DuckDB target mixed in with a valid sqlite one is still rejected.
    my $mixed = parse_dies('-L=/tmp/ok.sqlite', '-L=/tmp/bad.duckdb');
    ok($mixed, "a DuckDB target rejects the whole -L set even alongside a valid sqlite target");
};

done_testing;
