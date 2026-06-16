package App::Yath2::Client;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <liveness_check
    +submitter
    +subscriber
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Client - Command-side socket client for a runner: submit a run over
C<runner.socket> and subscribe to the runner's canonical state.

=head1 DESCRIPTION

The transient C<yath test> command talks to its runner over the runner's unix
socket: it submits the run, its tasks, and the queue terminator, and it
subscribes to the runner's canonical state to drive rendering. This object is the
command-side handle for that socket transport. It wraps the two lower-level
clients shipped with the runner --
L<Test2::Harness2::Runner::Client> (one-shot request submission) and
L<Test2::Harness2::Runner::Subscriber> (snapshot-plus-forwarded-transitions
mirror) -- and exposes them to the command as L</submitter> and
L</connect_subscriber>.

This is only the I<socket> transport. The command still chooses which transport
to use: the persistent C<run>/C<spawn> path is gated and submits through the
in-process dispatch state instead, so it overrides the command's submitter and
never constructs this client for submission. Keeping the transport choice in the
command preserves that seam.

The interface is deliberately small: L</connect_subscriber> takes a parameter
hash threaded straight through to the subscriber, so the command can pass a
C<run_id> for a run-scoped subscription (the runner routes each subscriber only
its own run's transitions) or omit it for a global subscription.

=head1 SYNOPSIS

    my $client = App::Yath2::Client->new(
        workdir        => $workdir,
        liveness_check => sub { $ipc->wait(timeout => 0); $ipc->procs->{$pid} ? 1 : 0 },
    );

    # Submission transport (a Test2::Harness2::Runner::Client):
    my $submitter = $client->submitter;
    $submitter->queue_run($run_item);
    $submitter->queue_task($_) for @tasks;
    $submitter->stop_run($run_id);
    $submitter->end_queue;

    # Subscription transport (a Test2::Harness2::Runner::Subscriber):
    my $sub = $client->connect_subscriber or warn "runner never accepted";
    $sub->poll while !$sub->closed;

=head1 PUBLIC METHODS

=over 4

=item $dir = $client->workdir

The working directory holding C<runner.socket>.

=item liveness_check

=item $coderef = $client->liveness_check

The optional caller-supplied check (passed to the submission client) that returns
true while the runner is alive; lets the client stop trying if the runner died
before it ever accepted.

=item submitter

=item $submitter = $client->submitter

The run/task/end-queue submission transport: a (cached)
L<Test2::Harness2::Runner::Client> bound to C<< $workdir/runner.socket >> and
given the L</liveness_check>. Exposes C<queue_run>, C<queue_task>, C<stop_run>,
C<end_queue>, C<halt_run>, and the stage-reporting requests.

=item subscriber

=item $sub = $client->subscriber

The subscription transport, or C<undef> until L</connect_subscriber> has run.

=item connect_subscriber

=item $sub = $client->connect_subscriber(%params)

Build a L<Test2::Harness2::Runner::Subscriber>, attempt the subscription exactly
once, and cache + return it; returns C<undef> (with a warning) if the runner
never bound/accepted the socket (e.g. a broken preload that killed the runner
during startup) so the caller can fall back. C<%params> are threaded into the
subscriber constructor (notably a C<run_id> for a run-scoped subscription).

=back

=cut

sub submitter ($self) {
    return $self->{+SUBMITTER} //= Test2::Harness2::Runner::Client->new(
        workdir        => $self->{+WORKDIR},
        liveness_check => $self->{+LIVENESS_CHECK},
    );
}

sub subscriber ($self) { return $self->{+SUBSCRIBER} }

sub connect_subscriber ($self, %params) {
    my $sub = Test2::Harness2::Runner::Subscriber->new(
        workdir => $self->{+WORKDIR},
        %params,
    );

    my $ok = eval { $sub->subscribe; 1 };
    warn "Could not subscribe to runner socket: $@" unless $ok;

    return $self->{+SUBSCRIBER} = $ok ? $sub : undef;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
