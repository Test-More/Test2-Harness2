package App::Yath2::Command::list;
use strict;
use warnings;

our $VERSION = '2.000013';

use Term::Table();
use File::Spec();

use List::Util qw/max/;
use Time::HiRes qw/sleep/;

# XXX TODO: App::Yath2::IPC removed (PR #390) — this command is non-functional

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPCAll',
    'App::Yath2::Options::Yath',
);

sub group { 'state' }

sub summary { "List all active local runners, persistent or otherwise" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
List all active local runners, persistent or otherwise.
    EOT
}

sub run {
    # XXX TODO: App::Yath2::IPC is gone (PR #390); reimplment once IPC layer is restored
    die "ERROR: 'yath list' is not yet functional — App::Yath2::IPC has been removed (PR #390).\n";
}

sub render_ipc {
    my $self = shift;
    my ($ipc) = @_;

    $ipc = {%$ipc};

    $ipc->{address} = File::Spec->abs2rel($ipc->{address}) if $ipc->{address} && -e $ipc->{address};
    $ipc->{file}    = File::Spec->abs2rel($ipc->{file})    if $ipc->{file}    && -e $ipc->{file};

    delete $ipc->{address} if $ipc->{address} && $ipc->{file} && $ipc->{address} eq $ipc->{file};
    $ipc->{ipc_file} //= delete $ipc->{file};

    my $length = 0;
    my @keys;
    my %seen;
    for my $key (qw/ipc_file peer_pid protocol address port/, sort keys %$ipc) {
        next if $seen{$key}++;
        next if $key eq 'type';
        next unless defined $ipc->{$key};
        push @keys => $key;
        $length = max($length, length($key));
    }

    printf("  \%${length}s: %s\n", $_, $ipc->{$_}) for @keys;
    print "\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

