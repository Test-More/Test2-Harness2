package App::Yath2::Command::recent;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub summary { "Show a list of recent runs (temporarily unavailable)" }
sub group   { 'history' }
sub cli_args { "" }

sub description {
    return <<"    EOT";
Show a list of recent runs. NOTE: the DB/web layer is being rewritten; this
command is temporarily unavailable.
    EOT
}

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
