package App::Yath2::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

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
    my $self = shift;

    my $settings = $self->settings;

    require App::Yath2::Client;
    my $client = App::Yath2::Client->new(settings => $settings);

    print "Requesting reload...\n";
    $client->reload;
    print "Request sent.\n";

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

