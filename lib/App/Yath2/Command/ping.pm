package App::Yath2::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;

use App::Yath2::Pfile();
use App::Yath2::Client();

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary  { "Ping the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
Continuously ping a discovered persistent runner over its socket and print the
round-trip latency of each reply. Useful for confirming the runner is alive and
responsive. Press Ctrl-C (SIGINT) to stop.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    # Discover the persistent runner for the current path (the same single-runner
    # discovery `which`/`run`/`abort` use). No live runner -> nothing to ping.
    my $pfile = App::Yath2::Pfile->find($settings, no_fatal => 1);
    unless ($pfile) {
        print "\nNo persistent harness was found for the current path.\n\n";
        return 1;
    }

    print $pfile->describe;

    # Attach a client to the discovered runner (kill(0) liveness, never reaped) and
    # bind it to the runner's socket for the ping round-trips.
    my $client = App::Yath2::Client->new(
        workdir  => $pfile->workdir,
        settings => $settings,
        mode     => 'attach',
    );
    $client->attach_runner($pfile->pid);

    # Exit cleanly on an interrupt: flip a flag the loop checks (so the in-flight
    # ping completes / the sleep returns) rather than dying mid-request.
    my $stop = 0;
    local $SIG{INT}  = sub { $stop = 1 };
    local $SIG{TERM} = sub { $stop = 1 };

    $| = 1;
    while (!$stop) {
        my $start = time;
        my $reply = eval { $client->ping };
        my $err   = $@;
        my $rtt   = time - $start;

        if ($stop) {
            # An interrupt landed during the request; stop without printing a
            # half-finished line.
            last;
        }

        if (!$reply) {
            # No reply means the runner is dead/unresponsive -- exit non-zero so
            # `yath ping && ...` health checks do NOT proceed on a dead runner, and
            # do not print the clean-stop "Stopped." banner (#146). This is distinct
            # from the SIGINT/TERM `$stop` paths below, which are a clean user stop.
            my $why = $err ? " ($err)" : '';
            print "ping: no response from runner -- it may have stopped$why\n";
            return 1;
        }

        my $rpid = $reply->{pid} // 'unknown';
        printf("pong from pid %s: %.4fs\n", $rpid, $rtt);

        # Interruptible sleep: wake early if a signal flips $stop.
        my $deadline = time + 1;
        while (!$stop && time < $deadline) {
            Time::HiRes::sleep(0.05);
        }
    }

    print "\nStopped.\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::ping - Ping the persistent test runner

=head1 DESCRIPTION

Continuously ping a discovered persistent runner over its socket and print the
round-trip latency of each reply. Press Ctrl-C to stop.

=head1 USAGE

    $ yath [YATH OPTIONS] ping

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
