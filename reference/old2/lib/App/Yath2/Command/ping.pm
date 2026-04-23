package App::Yath2::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000011';

use App::Yath2::Client;

use Time::HiRes qw/sleep time/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

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
    my $self = shift;

    my $client = App::Yath2::Client->new(settings => $self->{+SETTINGS});

    while (1) {
        my $start = time;
        print "\n=== ping ===\n";
        my $res = $client->ping();

        print "=== $res ===\n";
        print "=== " . sprintf("%-02.4f", time - $start) . " ===\n";

        sleep 4;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

