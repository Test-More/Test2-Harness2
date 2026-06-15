package App::Yath2::Command::client::recent;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command::recent';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;

include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Recent',
    'App::Yath2::Options::WebClient',
);

sub name { "client-recent" }

sub summary { "Show a list of recent runs on a yath web server" }

sub group { "web client" }

sub description {
    return <<"    EOT";
This command will find the last several runs from a yath web server
    EOT
}

sub get_data {
    my $self = shift;
    my ($project, $count, $user) = @_;

    return $self->get_from_http($project, $count, $user) // die "Could not get data from the server.\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED
