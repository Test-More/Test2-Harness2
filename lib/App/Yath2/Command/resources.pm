package App::Yath2::Command::resources;
use strict;
use warnings;

our $VERSION = '2.000011';

use Term::Table();
use File::Spec();
use Time::HiRes qw/sleep/;

# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)
use Test2::Harness2::Util qw/mod2file/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPCAll',
    'App::Yath2::Options::Yath',
);

sub group { 'state' }

sub summary { "View the state info for a test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
A look at the state and resources used by a runner.
    EOT
}

sub run {
    # XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390);
    # reimplment once IPC is restored.
    die "ERROR: 'yath resources' is not yet functional — IPC layer removed (PR #390).\n";

    my $self = shift;

    my $settings = $self->settings;

    my $client = undef; # XXX TODO: App::Yath2::Client->new(settings => $settings);

    return 0 if eval {
        while (1) { $self->render($client); sleep 0.1 }

        1;
    };

    die $@ unless $@ =~ m/Disconnected pipe/;

    print "\n*** Disconnected from harness ***\n\n";

    return 0;
}

sub render {
    my $self = shift;
    my ($client) = @_;

    my @out = (
        "\r\e[2J\r\e[1;1H",
        "\n", $client->ipc_text, "\n",
        "\n==== Resource state ====\n",
    );

    my $resources = $client->resources;

    for my $resource (@$resources) {
        my ($class, $data) = @$resource;
        next unless $data;

        # XXX Maybe need to reimplement render_status_data in App::Yath2::Util?
        push @out => "\nResource: $class\n$data\n";
    }

    print @out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

