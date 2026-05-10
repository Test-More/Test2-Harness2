package App::Yath2::Command::status;
use strict;
use warnings;

our $VERSION = '2.000013';

use Term::Table();

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPCAll',
    'App::Yath2::Options::Yath',
);

sub group { 'state' }

sub summary { "Status info and process lists for the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will provide health details and a process list for the runner.
    EOT
}

sub run {
    # XXX TODO: App::Yath2::Client depends on App::Yath2::IPC and
    # Test2::Harness2::Client, both removed in PR #390. Reimplment once
    # the IPC layer is restored.
    die "ERROR: 'yath status' is not yet functional — IPC layer removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

