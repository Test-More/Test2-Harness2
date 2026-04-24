package App::Yath2::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000011';

# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)

use Time::HiRes qw/sleep time/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{<settings};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Yath',
);

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary  { "Ping the test runner" }

sub description {
    return <<"    EOT";
This command can be used to test communication with a persistent runner
    EOT
}

sub run {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath ping' is not yet functional — IPC layer removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

