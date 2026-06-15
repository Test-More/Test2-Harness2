#!/usr/bin/env plackup
use strict;
use warnings;

# Standalone PSGI entry point for the inlined Test2-Harness2 web UI.
#
# Point it at an ALREADY-POPULATED UI database and serve it with any PSGI
# server (plackup, starman, ...). The app serves its own static assets and
# templates from share/, resolved relative to the current directory, so run
# this from the repository root:
#
#   HARNESS_UI_DSN='dbi:SQLite:dbname=/path/to/ui.db' plackup demo/demo.psgi
#
# The driver is auto-detected from the DSN (sqlite/mysql/mariadb/percona/pg).
# Optional: HARNESS_UI_USER / HARNESS_UI_PASS for the DB credentials.
#
# To create + populate a database from a log file in ONE step instead, use the
# server command (it builds an ephemeral DB, imports the log, and serves it):
#
#   yath server --ephemeral=SQLite demo/simple-fail.jsonl.bz2
#
# See demo/README.md for the full walkthrough.

use lib 'lib';
use App::Yath2::Schema::Config;
use App::Yath2::Server::Plack;

my $dsn = $ENV{HARNESS_UI_DSN}
    or die "Set HARNESS_UI_DSN to a populated Test2-Harness2 UI database DSN\n";

my $config = App::Yath2::Schema::Config->new(
    dbi_dsn  => $dsn,
    dbi_user => $ENV{HARNESS_UI_USER} // '',
    dbi_pass => $ENV{HARNESS_UI_PASS} // '',
);

App::Yath2::Server::Plack->new(
    schema_config => $config,
    single_user   => 1,
)->to_app;
