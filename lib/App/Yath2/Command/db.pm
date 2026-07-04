package App::Yath2::Command::db;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub summary     { "Database commands (see `yath db sync`); the `db` server itself is temporarily unavailable" }
sub group       { "database" }

sub description {
    return <<"    EOT";
The `db` command groups the database subcommands. The DB->DB sync subcommand is
available:

    yath db sync --from <SRC> --to <DEST>      # sync runs between databases

(`yath db sync` dispatches to App::Yath2::Command::db::sync via the nested
"<command> <subcommand>" resolution in App::Yath2's command loader -- no explicit
dispatcher is needed here.) See also the top-level `import` command for the
single-run sqlite-log -> DB convenience path.

The bare `db` command (the old ephemeral database SERVER) is still part of the
DB/web layer being rewritten on QuickORM and is temporarily unavailable; the
remaining db subcommands (db importer / db publish / db sweeper / db recent) are
likewise still stubs until the rewrite lands.
    EOT
}

sub cli_args { "" }

# Stub: the bare `db` SERVER command is part of the old DBIx::Class DB/web layer
# moved to reference/old_db (ticket TODO-45) and is being rewritten on QuickORM. Keep
# it visible in `yath help` but error clearly if anyone runs it. NOTE: this is NOT
# a dispatcher -- `yath db sync` is dispatched to App::Yath2::Command::db::sync by
# App::Yath2::_command_from_argv (the "<cmd>-<subcmd>" nested-command form), so it
# never reaches this run().
sub run {
    die <<"    EOT";

The `db` server command is being rewritten and is temporarily unavailable.
Available now: `yath db sync` (DB->DB sync) and `import` (sqlite-log -> DB).

    EOT
}

1;

__END__

=head1 POD IS AUTO-GENERATED
