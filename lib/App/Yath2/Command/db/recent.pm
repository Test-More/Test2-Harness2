package App::Yath2::Command::db::recent;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub name    { "db-recent" }
sub group   { "database" }
sub summary { "Show a list of recent runs in the database (temporarily unavailable)" }

sub description {
    return <<"    EOT";
Show a list of recent runs in the database. NOTE: the DB/web layer is being
rewritten; this command is temporarily unavailable.
    EOT
}

# Stub: the old DBIx::Class DB/web layer moved to reference/old_db (ticket #45)
# and is being rewritten on QuickORM. Keep the command visible in `yath help`
# but error clearly if anyone tries to run it.
sub run {
    die <<"    EOT";

The DB/web layer is being rewritten; this command is temporarily unavailable.

    EOT
}

1;

__END__

=head1 POD IS AUTO-GENERATED
