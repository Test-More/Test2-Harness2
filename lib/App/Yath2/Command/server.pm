package App::Yath2::Command::server;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub summary     { "Start a yath web server (temporarily unavailable)" }
sub description { "Starts a web server that can be used to view test runs in a web browser. NOTE: the DB/web layer is being rewritten; this command is temporarily unavailable." }
sub group       { "server" }

sub cli_args { "[log1.jsonl[.gz|.bz2] [log2.jsonl[.gz|.bz2]]]" }

# Stub: the old DBIx::Class DB/web layer moved to reference/old_db (ticket TODO-45)
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
