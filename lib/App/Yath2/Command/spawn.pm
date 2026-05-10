package App::Yath2::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep time/;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util qw/parse_exit/;

# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

sub group { 'daemon' }

sub summary { "Launch a perl script from the preloaded environment" }
sub cli_args { "[--] path/to/script.pl [options and args]" }

sub description {
    return <<"    EOT";
This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.
    EOT
}

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

use Getopt::Yath;
option_group {group => 'spawn', category => 'spawn options'} => sub {
    option stage => (
        short => 's',
        type => 'Scalar',
        description => 'Specify the stage to be used for launching the script',
        long_examples => [ ' foo'],
        short_examples => [ ' foo'],
        default => 'BASE',
    );

    option copy_env => (
        short => 'e',
        type => 'List',
        description => "Specify environment variables to pass along with their current values, can also use a regex",
        long_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
        short_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'Map',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables for the spawn',
    );
};

include_options(
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Yath',
);

sub run {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC/preload layer is restored
    die "ERROR: 'yath spawn' is not yet functional — IPC layer removed (PR #390).\n";
}

sub env {
    my $self = shift;

    my $settings = $self->settings;

    my %env;

    for my $var (@{$settings->spawn->copy_env // []}) {
        $env{$var} = $ENV{$var} if exists $ENV{$var};
    }

    if (my $set = $settings->spawn->env_vars) {
        $env{$_} = $set->{$_} for keys %$set;
    }

    return \%env;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

