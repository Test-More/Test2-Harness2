package Test2::Harness2::Util::FileMonitor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/stat time sleep/;

use Object::HashBase qw{
    <file
    <delegate
    <static
    +_state
    +_have_state
    +_static_seen
    +_inotify
    +_inotify_watch
    +_inotify_broken
};

use constant HAS_INOTIFY => !!eval { require Linux::Inotify2; 1 };

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::FileMonitor - Watch a file for changes.

=head1 DESCRIPTION

Watches a single file for changes. The class is path-oriented (it
holds the path, not a filehandle) and uses hi-res C<mtime> together
with C<dev>/C<inode>/C<size> to detect appends, atomic
rename-into-place rewrites, truncations, and relocations. Where
L<Linux::Inotify2> is available it is used as an early-out signal in
addition to the stat tuple; callers do not need to opt in.

The monitor carries an optional B<delegate> object. When set, the
truthy return value of L</changed> and L</await_change> is the
delegate itself, so callers can write the idiomatic loop in the
SYNOPSIS without holding a separate variable. Without a delegate the
truthy return value is a plain C<1>.

=head2 Race window

Between the moment L</changed> reports a change and the moment the
delegate reads, a writer may have written nothing new and the
delegate may return zero items. This is intentional: treat the
returned delegate as "the file changed, look at it" rather than "the
file has new content for you right now."

=head1 SYNOPSIS

    use Test2::Harness2::Util::FileMonitor;
    use Test2::Harness2::Util::JSONL::Reader;

    my $delegate = Test2::Harness2::Util::JSONL::Reader->new(path => $path);
    my $monitor  = Test2::Harness2::Util::FileMonitor->new(
        file     => $path,
        delegate => $delegate,
    );

    while (my $d = $monitor->changed) {
        push @lines => $d->read_lines;
    }

    if (my $d = $monitor->await_change(1.0)) {
        ... handle delegate ...
    }

=head1 ATTRIBUTES

=over 4

=item file

=item file (required when C<static> is false)

The absolute path to the file being monitored.

=item delegate

=item delegate (optional)

An arbitrary object returned in place of C<1> on every truthy
L</changed> / L</await_change> result.

=item static

=item static (optional, default false)

When true, bypass change detection entirely: the first
L</changed> / L</peek_changed> / L</await_change> call returns the
truthy result and every subsequent call returns C<0>.

=back

=cut

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+STATIC} || defined $self->{+FILE};

    $self->{+_HAVE_STATE}  = 0;
    $self->{+_STATIC_SEEN} = 0;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item changed

=item $delegate_or_bool = $f->changed

Returns C<$delegate> when the file has changed since the previous
call (or this is the first call) and a delegate was set, C<1> when
no delegate was set, and C<0> when the file has not changed. Never
blocks. The initial call always reports a change.

=back

=cut

sub changed {
    my $self = shift;
    return $self->_static_check(record => 1) if $self->{+STATIC};
    return $self->_check(record => 1);
}

=over 4

=item peek_changed

=item $delegate_or_bool = $f->peek_changed

Same shape as L</changed>, but does B<not> ack a pending change.
Repeated C<peek_changed> calls return the same truthy value until a
real L</changed> call acks it.

=back

=cut

sub peek_changed {
    my $self = shift;
    return $self->_static_check(record => 0) if $self->{+STATIC};
    return $self->_check(record => 0);
}

=over 4

=item await_change

=item $delegate_or_bool = $f->await_change

=item $delegate_or_bool = $f->await_change($timeout)

Blocks until L</changed> would return truthy, or the optional
C<$timeout> (seconds) elapses. Returns the same shape as L</changed>
on a change; returns C<0> on timeout. Uses L<Linux::Inotify2> when
available, otherwise a small-sleep poll via
L<Time::HiRes/sleep>, which returns early on signal interruption so
SIGCHLD / SIGTERM break the wait promptly.

=back

=cut

sub await_change {
    my $self = shift;
    my ($timeout) = @_;

    return $self->_static_check(record => 1) if $self->{+STATIC};

    my $deadline = defined $timeout ? time() + $timeout : undef;

    if (my $fh = $self->_inotify_fh) {
        return $self->_await_change_inotify($fh, $deadline);
    }

    return $self->_await_change_poll($deadline);
}

=over 4

=item delegate

=item $delegate = $f->delegate

Returns the delegate object passed to the constructor, or C<undef>.

=back

=cut

sub _await_change_inotify {
    my ($self, $fh, $deadline) = @_;

    require IO::Select;
    my $sel = IO::Select->new($fh);
    while (1) {
        if (my $rv = $self->changed) {
            return $rv;
        }

        my $remaining;
        if (defined $deadline) {
            $remaining = $deadline - time();
            return 0 if $remaining <= 0;
        }
        $sel->can_read($remaining);
    }
}

sub _await_change_poll {
    my ($self, $deadline) = @_;

    while (1) {
        if (my $rv = $self->changed) {
            return $rv;
        }
        if (defined $deadline) {
            my $remaining = $deadline - time();
            return 0 if $remaining <= 0;
        }
        Time::HiRes::sleep(0.05);
    }
}

sub _static_check {
    my $self   = shift;
    my %params = @_;
    return 0                   if $self->{+_STATIC_SEEN};
    $self->{+_STATIC_SEEN} = 1 if $params{record};
    return $self->_changed_result;
}

sub _check {
    my $self   = shift;
    my %params = @_;
    my $record = $params{record};

    my $inotify_event = $self->_inotify_has_events;
    my $cur           = $self->_current_state;

    if (!$self->{+_HAVE_STATE}) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    my $prior = $self->{+_STATE};

    if (!defined $cur && !defined $prior) {
        return 0                   if !$inotify_event;
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    if (!defined($cur) || !defined($prior)) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    for my $k (qw/dev inode size mtime/) {
        next                       if ($cur->{$k} // -1) == ($prior->{$k} // -1);
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    if ($inotify_event) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    return 0;
}

sub _changed_result {
    my $self = shift;
    return $self->{+DELEGATE} // 1;
}

sub _current_state {
    my $self = shift;
    my @st   = stat($self->{+FILE});
    return undef unless @st;
    return {
        dev   => $st[0],
        inode => $st[1],
        size  => $st[7],
        mtime => $st[9],
    };
}

sub _record_state {
    my $self = shift;
    my ($state) = @_;
    $self->{+_STATE}      = $state;
    $self->{+_HAVE_STATE} = 1;
    return;
}

sub _inotify_fh {
    my $self = shift;

    return undef unless HAS_INOTIFY;
    return undef if $self->{+_INOTIFY_BROKEN};

    return $self->{+_INOTIFY}->fileno
        if $self->{+_INOTIFY} && $self->{+_INOTIFY_WATCH};

    my $inot;
    my $ok = eval {
        $inot = Linux::Inotify2->new;
        $inot->blocking(0);
        1;
    };
    unless ($ok) {
        $self->{+_INOTIFY_BROKEN} = 1;
        return undef;
    }

    my $path = $self->{+FILE};
    return undef unless -e $path;

    my $watch;
    $ok = eval { $watch = $inot->watch($path, $self->_inotify_watch_mask); 1 };
    unless ($ok && $watch) {
        $self->{+_INOTIFY_BROKEN} = 1;
        return undef;
    }

    $self->{+_INOTIFY}       = $inot;
    $self->{+_INOTIFY_WATCH} = $watch;
    return $inot->fileno;
}

sub _inotify_watch_mask {
    my $self = shift;
    return Linux::Inotify2::IN_MODIFY() | Linux::Inotify2::IN_CREATE() | Linux::Inotify2::IN_MOVED_TO() | Linux::Inotify2::IN_DELETE_SELF() | Linux::Inotify2::IN_MOVE_SELF() | Linux::Inotify2::IN_ATTRIB();
}

sub _inotify_has_events {
    my $self = shift;

    $self->_inotify_fh;

    my $inot   = $self->{+_INOTIFY} or return 0;
    my @events = $inot->read;
    return scalar(@events) ? 1 : 0;
}

1;

__END__

=pod

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
