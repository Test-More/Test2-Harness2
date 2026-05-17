package Test2::Harness2::Reloader::INotify;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Cwd qw/abs_path/;
use File::Find ();
use File::Spec ();
use Time::HiRes qw/time/;

use parent 'Test2::Harness2::Reloader::Common';
use Role::Tiny::With;
with 'Test2::Harness2::Role::Reloader';

# Reloader::INotify -- inotify-driven reloader backend.
#
# Watches each directory in watch_paths() recursively via Linux::Inotify2
# for IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO. Each do_reload() tick
# does one non-blocking inotify poll. For every event whose target is
# a .pm/.t file currently live in %INC under project_root we:
#
#   1. Honor debounce_secs() -- skip if the last successful reload
#      was too recent.
#   2. Try _attempt_in_place_reload($file).
#   3. If that fails and the file contains `HARNESS2: churn {` sections,
#      fall back to _attempt_churn_reload($file).
#   4. On reload failure, record last_error.
#
# before_reload / after_reload hooks from Role::Reloader fire around
# each per-file reload attempt.

use Object::HashBase qw{
    <watch_paths
    +inotify
    +_events
};

sub init {
    my $self = shift;
    $self->SUPER::init();

    eval { require Linux::Inotify2; 1 }
        or croak "Linux::Inotify2 is required for the inotify reloader";

    $self->{+WATCH_PATHS} //= [$self->{+PROJECT_ROOT}];

    croak "'watch_paths' must be an arrayref"
        unless ref($self->{+WATCH_PATHS}) eq 'ARRAY';

    my $mask = Linux::Inotify2::IN_MODIFY()
             | Linux::Inotify2::IN_CLOSE_WRITE()
             | Linux::Inotify2::IN_MOVED_TO();

    my $inotify = Linux::Inotify2->new
        or croak "Linux::Inotify2->new failed: $!";
    $inotify->blocking(0);

    # Stash per-tick events here from the poll() callback. do_reload
    # drains this list each call.
    my $events = $self->{+_EVENTS} = [];
    my $cb = sub { push @$events => $_[0] };

    for my $dir (@{$self->{+WATCH_PATHS}}) {
        next unless defined $dir && length $dir && -d $dir;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -d $_;
                    $inotify->watch($_, $mask, $cb)
                        or warn "inotify watch on $_ failed: $!";
                },
            },
            $dir,
        );
    }

    $self->{+INOTIFY} = $inotify;
}

# Too long break it up
sub do_reload {
    my ($self, $svc) = @_;

    my $inotify = $self->{+INOTIFY} or return;

    # Drain the inotify queue (non-blocking). poll() fires our
    # per-watch callback which pushes events into $self->{+_EVENTS}.
    # We still poll even if %INC is empty so the kernel queue does
    # not grow unbounded.
    $inotify->poll;
    my $events = $self->{+_EVENTS} //= [];
    return unless @$events;

    my @batch = splice @$events;

    my %inc_abs;
    for my $entry (@{$self->_filter_inc}) {
        my ($key, $abs) = @$entry;
        $inc_abs{$abs} = 1;
    }
    return unless keys %inc_abs;

    my %seen;
    my @candidates;
    for my $e (@batch) {
        my $file = $e->fullname;
        next unless defined $file && length $file;
        next unless $file =~ /\.(?:pm|t)\z/;
        my $abs = abs_path($file) // $file;
        next unless $inc_abs{$abs};
        next if $seen{$abs}++;
        push @candidates => $abs;
    }
    return unless @candidates;

    my $now      = time;
    my $debounce = $self->debounce_secs;
    my $last     = $self->last_reload_at // 0;

    for my $abs (@candidates) {
        # Debounce: skip if we successfully reloaded too recently.
        if ($last && ($now - $last) < $debounce) {
            next;
        }

        $self->before_reload($svc, $abs);

        my ($ok, $err) = $self->_attempt_in_place_reload($abs);

        if (!$ok) {
            my @churn = $self->find_churn($abs);
            if (@churn) {
                my ($cok, $cerr) = $self->_attempt_churn_reload($abs);
                if ($cok) {
                    $ok  = 1;
                    $err = undef;
                }
                else {
                    $err = $cerr // $err;
                }
            }
        }

        if (!$ok) {
            $self->{+LAST_ERROR} = $err;
        }

        $self->after_reload($svc, $abs, $ok, $err);

        $now  = time;
        $last = $self->last_reload_at // 0;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::INotify - inotify-based reloader backend.

=head1 SYNOPSIS

    use Test2::Harness2::Reloader::INotify;

    my $rel = Test2::Harness2::Reloader::INotify->new(
        project_root => '/path/to/project',
        watch_paths  => ['/path/to/project/lib'],
    );

    # Inside the service's per-interval hook:
    $rel->do_reload($svc);

=head1 DESCRIPTION

An event-driven implementation of L<Test2::Harness2::Role::Reloader>
backed by L<Linux::Inotify2>. At construction every directory under
C<watch_paths> is walked recursively and added to the inotify
descriptor with the mask
C<IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO>. Each C<do_reload> tick
non-blockingly drains the event queue and reloads each affected
C<.pm>/C<.t> file via
L<Test2::Harness2::Reloader::Common>'s C<_attempt_in_place_reload>;
if that fails and the file contains C<HARNESS2: churn {> /
C<HARNESS2: churn }> markers, it falls back to
C<_attempt_churn_reload>.

Reload failures are recorded in C<last_error> and do not throw; the
service deciding whether to flip the affected resource to transient
broken is responsible for inspecting that state.

Constructing this reloader requires L<Linux::Inotify2>; if the module
is unavailable, construction croaks.

=head1 ATTRIBUTES

=over 4

=item watch_paths

Arrayref of directories to monitor recursively. Defaults to
C<[ project_root ]>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Reloader::Common>, L<Test2::Harness2::Role::Reloader>,
L<Test2::Harness2::Reloader::HiResStat>.

=cut
