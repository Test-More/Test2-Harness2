package App::Yath2::Command::ps;
use strict;
use warnings;

our $VERSION = '2.000011';

use Time::HiRes qw/time/;
use App::Yath2::Client;
use Term::Table();

use Test2::Util::Times qw/render_duration/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

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
    my $self = shift;

    my $settings = $self->settings;
    my $client = App::Yath2::Client->new(settings => $settings);

    my $procs = $client->process_list();

    my @rows;
    my %seen;
    for my $proc (sort { $a->{stamp} <=> $b->{stamp} } @$procs) {
        next if $seen{$proc->{pid}}++;
        push @rows => [@{$proc}{qw/pid type name/}, render_duration(time - $proc->{stamp})];
    }

    my $process_table = Term::Table->new(
        collapse => 1,
        header => [qw/pid type name age/],
        rows => \@rows,
    );

    print "\n**** Running Processes ****\n";
    print "$_\n" for $process_table->render;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

