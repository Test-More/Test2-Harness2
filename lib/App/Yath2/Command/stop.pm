package App::Yath2::Command::stop;
use strict;
use warnings;

our $VERSION = '2.000012';

# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

sub group { 'daemon' }

sub summary { "Wait for running tests to complete, then end runner and abort any pending tests" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will kill the active yath runner and any running or pending tests.
    EOT
}

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Yath',
);

sub run {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath stop' is not yet functional — IPC layer removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED


