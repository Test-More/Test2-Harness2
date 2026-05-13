package App::Yath2::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep time/;

use Test2::Harness2::Spawn;
use App::Yath2::Util::IPC qw/discover_daemons assert_daemon_alive/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

use Object::HashBase qw{
    <args
    <settings
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::IPC',
);

option_group {group => 'ping', category => "Ping Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to ping.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, ping the most recently started.',
    );

    option count => (
        type          => 'Scalar',
        default       => 0,
        long_examples => [' N'],
        description   => 'Number of pings to send. 0 (default) = forever until SIGINT.',
    );

    option interval => (
        type          => 'Scalar',
        default       => 1,
        long_examples => [' SECS'],
        description   => 'Seconds between pings. Decimal allowed. 0 means no delay.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Send round-trip pings to a running yath daemon" }

sub description {
    return <<"    EOT";
Send a cheap no-op request to a running yath daemon and print the
round-trip time. Useful for confirming the daemon is responsive and
not just alive at the pid level.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $ping     = $settings->ping;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $ping->workdir,
        latest   => $ping->latest,
    );
    assert_daemon_alive($info);

    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $info->{workdir},
        terminate_on_destroy => 0,
    );

    my $sig = 0;
    local $SIG{INT} = sub { $sig++ };

    my $count    = $ping->count    // 0;
    my $interval = $ping->interval // 1;

    my $i = 0;
    while (!$sig) {
        $i++;
        my $t0 = time;
        my $res;
        my $ok  = eval { $res = $spawn->has_pending_messages; 1 };
        my $err = $@;
        my $dt  = time - $t0;
        if (!$ok) {
            chomp $err;
            printf("%d: %.4fs  error: %s\n", $i, $dt, $err);
            return 1;
        }
        printf("%d: %.4fs  pending=%d running=%d queued=%d\n",
            $i, $dt,
            ($res->{pending} // 0),
            ($res->{running} // 0),
            ($res->{queued}  // 0),
        );
        last if $count && $i >= $count;
        sleep($interval) if $interval > 0;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut
