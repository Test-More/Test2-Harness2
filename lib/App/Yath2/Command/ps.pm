package App::Yath2::Command::ps;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/time/;
# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)
use Term::Table();

use Test2::Util::Times qw/render_duration/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

sub group { 'daemon' }

sub summary { "Process list for the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
List all running processes and runner stages.
    EOT
}

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Yath',
);

sub run {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath ps' is not yet functional — IPC layer removed (PR #390).\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

