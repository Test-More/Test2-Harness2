package App::Yath2::Streamer::Live;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use parent 'App::Yath2::Streamer::Base';
use Object::HashBase qw{
    <handle
    <log
};

# Live mode: subscribe to a running harness and drain the IPC state
# stream. Per-artifact tailing returns in a later step once the new
# App::Yath2::Log artifact API is wired in.
#
# Required:
#   handle  => $spawn     # must implement subscribe / unsubscribe / handle()
#
# Optional:
#   log     => "$workdir/logs"
#     Reserved for forthcoming on-disk artifact discovery. Currently
#     unused beyond storage.
sub _bootstrap {
    my $self = shift;

    my $handle = $self->{+HANDLE}
        // croak "'handle' is required for " . __PACKAGE__;
    croak "'handle' must be an object that supports subscribe()/unsubscribe()"
        unless blessed($handle) && $handle->can('subscribe');

    my @runs = @{$self->{+RUNS} // []};

    # Subscribe up front so no events get lost after queue_test_run.
    # The harness will push initial snapshots synchronously so we pick
    # them up on the next poll.
    $handle->subscribe(
        ($self->{+GLOBAL} ? (global => 1)       : ()),
        (@runs            ? (runs   => [@runs]) : ()),
        state => 1,
    );

    return;
}

# TODO: replace the Base sleep + non-blocking poll with a blocking
# wait. Cheapest first step: pass a small timeout to $ipc->poll
# here so this method blocks instead of returning instantly. Full
# version: a _wait_for_input($timeout) hook on Base implemented
# here over IO::Select unioning $ipc->select_handles with each
# reader's underlying fh / Linux::Inotify2 fd, refreshing the set
# when _open_event_reader adds a new reader. Non-Linux without
# inotify keeps the sleep fallback. Static stays as-is (finite
# input drains in one tick).
sub _tick {
    my $self = shift;

    my $ipc = $self->{+HANDLE}->handle;  # underlying IPC::Manager::Service::Handle

    # Non-blocking poll. Handle may have messages already; otherwise
    # returns immediately.
    $ipc->poll(0);

    for my $msg ($ipc->messages) {
        my $content = $msg->content;
        next unless ref($content) eq 'HASH';
        $self->_ingest_message($content);
    }

    # Drain any event readers a future on-disk-discovery layer has
    # attached. Stays a no-op until that layer lands.
    $self->_drain_event_readers;

    return;
}

sub _ingest_message {
    my ($self, $content) = @_;

    my $type = $content->{type} or return;

    if ($type eq 'state' && $content->{item} && $content->{item} eq 'run') {
        my $run_id = $content->{run_id};
        my $state  = $content->{state};
        return unless defined $run_id && ref($state) eq 'HASH';
        $self->_apply_run_state($run_id, $state);
        return;
    }

    return;
}

# We intentionally do NOT call unsubscribe from DESTROY: by teardown
# the harness may already be gone and a sync_request to a dead peer
# can raise SIGPIPE at the transport layer. Callers that care
# unsubscribe explicitly; the harness's peer-delta path reaps stale
# registrations either way.
sub DESTROY { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Streamer::Live - Live streamer: subscribe to a running harness.

=head1 SYNOPSIS

    use App::Yath2::Streamer::Live;

    my $s = App::Yath2::Streamer::Live->new(
        handle => $spawn,
        run    => $run_id,
        log    => "$workdir/logs",
    );

    $s->stream(
        callback => sub { print $_[0]->as_json, "\n" },
        exit_if  => sub { $seen_run_end },
    );

=head1 DESCRIPTION

Subscribes to a running L<Test2::Harness2> service via a
L<Test2::Harness2::Spawn> handle, synthesises lifecycle facets
(C<harness_run>, C<harness_job_queued>, C<harness_job_start>,
C<harness_job_end>, C<harness_job_exit>, C<harness_run_end>) from
the service's IPC state updates, and -- when a C<log> directory is
supplied -- also tails the append-style general-event artifacts the
service records so callers get both streams on the same channel.

See L<App::Yath2::Streamer::Base> for the public API (C<stream>,
C<next>, C<request_exit>) and L<App::Yath2::Streamer::Static> for
the offline counterpart.

=head1 CONSTRUCTOR

=over 4

=item handle (required)

An object that implements C<subscribe(%params)>,
C<unsubscribe>, and C<handle> returning the underlying
L<IPC::Manager::Service::Handle>. L<Test2::Harness2::Spawn>
satisfies all three.

=item log (optional)

Path to the harness's log directory (usually C<$workdir/logs>).
Enables general-event tailing. May not exist yet at construction
time.

=item global / run / runs

Subscription scope. See L<App::Yath2::Streamer::Base>.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
