package App::Yath2::Command::which;
use strict;
use warnings;

our $VERSION = '2.000011';

use App::Yath2::IPC;

use parent 'App::Yath2::Command';
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
    my $self = shift;

    my $ipc = App::Yath2::IPC->new(settings => $self->settings);
    my ($found) = $ipc->find('daemon');

    unless ($found) {
        print "\nNo persistent harness was found for the current project.\n\n";
        return 0;
    }

    print "\nFound a persistent runner:\n";
    print "  $_: $found->{$_}\n" for reverse sort grep { defined $found->{$_} } keys %$found;
    print "\n";

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

