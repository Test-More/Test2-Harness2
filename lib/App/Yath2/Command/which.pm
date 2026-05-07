package App::Yath2::Command::which;
use strict;
use warnings;

our $VERSION = '2.000012';

# XXX TODO: App::Yath2::IPC removed (PR #390) — this command is non-functional

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

sub group { 'daemon' }

sub summary  { "Locate the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This will tell you about any persistent runners it can find.
    EOT
}

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPC',
);

sub run {
    # XXX TODO: App::Yath2::IPC is gone (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath which' is not yet functional — App::Yath2::IPC has been removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

