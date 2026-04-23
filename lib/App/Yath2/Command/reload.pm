package App::Yath2::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPCAll',
    'App::Yath2::Options::Yath',
);

sub group { 'daemon' }

sub summary { "Reload the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
Reload the persistent test runner.
    EOT
}

sub run {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath reload' is not yet functional — IPC layer removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

