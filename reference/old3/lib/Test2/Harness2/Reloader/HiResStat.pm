package Test2::Harness2::Reloader::HiResStat;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Cwd qw/abs_path/;
use File::Find ();
use File::Spec ();
use Time::HiRes qw/stat time/;

use parent 'Test2::Harness2::Reloader::Common';
use Role::Tiny::With;
with 'Test2::Harness2::Role::Reloader';

# Reloader::HiResStat -- poll-based reloader backend.
#
# On each do_reload() tick we walk watch_paths(), find .pm/.t files
# whose absolute path is also live in %INC and under project_root,
# stat() each, and compare against a cached mtime. On change:
#
#   1. Honor debounce_secs() -- skip if the last successful reload
#      was too recent.
#   2. Try _attempt_in_place_reload($file).
#   3. If that fails and the file contains `HARNESS2: churn {` sections,
#      fall back to _attempt_churn_reload($file).
#   4. On reload failure, record last_error and return without
#      restarting; the caller decides whether to flip the resource
#      to transient broken.
#
# before_reload / after_reload hooks from Role::Reloader fire around
# each per-file reload attempt.

use Object::HashBase qw{
    <watch_paths
    <poll_interval_secs
    +mtimes
    +_initialized
};

sub init {
    my $self = shift;
    $self->SUPER::init();

    $self->{+WATCH_PATHS}        //= [$self->{+PROJECT_ROOT}];
    $self->{+POLL_INTERVAL_SECS} //= 0.25;
    $self->{+MTIMES}             //= {};
    $self->{+_INITIALIZED}       //= 0;

    croak "'watch_paths' must be an arrayref"
        unless ref($self->{+WATCH_PATHS}) eq 'ARRAY';
}

sub do_reload {
    my ($self, $svc) = @_;

    my @candidates = $self->_scan_candidates;
    return unless @candidates;

    if (!$self->{+_INITIALIZED}) {
        $self->_snapshot_mtimes(\@candidates);
        $self->{+_INITIALIZED} = 1;
        return;
    }

    $self->_reload_changed($svc, \@candidates);
    return;
}

sub _scan_candidates {
    my ($self) = @_;

    my %inc_abs;
    for my $entry (@{$self->_filter_inc}) {
        my (undef, $abs) = @$entry;
        $inc_abs{$abs} = 1;
    }
    return () unless keys %inc_abs;

    my @candidates;
    for my $dir (@{$self->{+WATCH_PATHS}}) {
        next unless defined $dir && length $dir && -d $dir;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_;
                    return unless /\.(?:pm|t)\z/;
                    my $abs = abs_path($_) // $_;
                    return unless $inc_abs{$abs};
                    push @candidates => $abs;
                },
            },
            $dir,
        );
    }
    return @candidates;
}

sub _snapshot_mtimes {
    my ($self, $files) = @_;
    for my $abs (@$files) {
        my @s = stat($abs);
        $self->{+MTIMES}{$abs} = $s[9] if @s;
    }
}

sub _reload_changed {
    my ($self, $svc, $files) = @_;

    my $now      = time;
    my $debounce = $self->debounce_secs;
    my $last     = $self->last_reload_at // 0;

    for my $abs (@$files) {
        my @s = stat($abs);
        next unless @s;
        my $mtime = $s[9];

        my $prev = $self->{+MTIMES}{$abs};
        if (!defined $prev) {
            $self->{+MTIMES}{$abs} = $mtime;
            next;
        }
        next if $mtime == $prev;

        # Debounce: skip if we successfully reloaded too recently.
        # Re-check mtime next tick.
        next if $last && ($now - $last) < $debounce;

        $self->_reload_one($svc, $abs, $mtime);

        # Refresh "now" / "last" in case multiple files changed in
        # the same tick; we still honor debounce for the next file.
        $now  = time;
        $last = $self->last_reload_at // 0;
    }
}

sub _reload_one {
    my ($self, $svc, $abs, $mtime) = @_;

    $self->before_reload($svc, $abs);

    my ($ok, $err) = $self->_attempt_in_place_reload($abs);

    if (!$ok && $self->find_churn($abs)) {
        my ($cok, $cerr) = $self->_attempt_churn_reload($abs);
        if ($cok) { ($ok, $err) = (1, undef) }
        else      { $err = $cerr // $err }
    }

    if ($ok) {
        $self->{+MTIMES}{$abs} = $mtime;
    }
    else {
        # Keep prior mtime so a subsequent fix (still differing
        # from the cached value) triggers another attempt.
        $self->{+LAST_ERROR} = $err;
    }

    $self->after_reload($svc, $abs, $ok, $err);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::HiResStat - Poll-based reloader backend.

=head1 SYNOPSIS

    use Test2::Harness2::Reloader::HiResStat;

    my $rel = Test2::Harness2::Reloader::HiResStat->new(
        project_root       => '/path/to/project',
        watch_paths        => ['/path/to/project/lib'],
        poll_interval_secs => 0.25,
    );

    # Inside the service's per-interval hook:
    $rel->do_reload($svc);

=head1 DESCRIPTION

A poll-based implementation of L<Test2::Harness2::Role::Reloader>.
Each C<do_reload> tick walks C<watch_paths>, restricts to
C<.pm>/C<.t> files that are both under C<project_root> and currently
loaded in C<%INC>, and stats each one. Files whose mtime has changed
since the previous tick are reloaded via
L<Test2::Harness2::Reloader::Common>'s C<_attempt_in_place_reload>;
if that fails and the file contains C<HARNESS2: churn {> /
C<HARNESS2: churn }> markers, it falls back to
C<_attempt_churn_reload>.

Reload failures are recorded in C<last_error> and do not throw; the
service deciding whether to flip the affected resource to transient
broken is responsible for inspecting that state.

=head1 ATTRIBUTES

=over 4

=item watch_paths

Arrayref of directories to monitor. Defaults to C<[ project_root ]>.

=item poll_interval_secs

Suggested interval between two C<do_reload> calls. Defaults to
C<0.25>. The reloader itself does not sleep; the surrounding service
is expected to call C<do_reload> on this cadence.

=back

=head1 METHODS

=over 4

=item $rel->init

L<Object::HashBase> hook: chains C<SUPER::init>, defaults
C<watch_paths> to C<[ project_root ]>, sets C<poll_interval_secs> to
C<0.25>, and validates C<watch_paths> is an arrayref.

=item $rel->do_reload($svc)

One reloader tick. Walks C<watch_paths>, snapshots mtimes on the first
call, and on subsequent calls reloads each candidate whose mtime has
moved. Satisfies L<Test2::Harness2::Role::Reloader>.

=item @abs = $rel->_scan_candidates

Private. Walks C<watch_paths> for C<.pm>/C<.t> files whose absolute
path is also live in C<%INC> under C<project_root>.

=item $rel->_snapshot_mtimes(\@files)

Private. Caches the current mtime for each file (used to seed state on
the first tick).

=item $rel->_reload_changed($svc, \@files)

=item $rel->_reload_one($svc, $abs, $mtime)

Private. C<_reload_changed> stats each candidate, honors
L<debounce_secs|Test2::Harness2::Role::Reloader/debounce_secs>, and
delegates per-file work to C<_reload_one>, which calls
C<before_reload>, attempts
L<_attempt_in_place_reload|Test2::Harness2::Reloader::Common>
with a churn fallback, and fires C<after_reload>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Reloader::Common>, L<Test2::Harness2::Role::Reloader>.

=cut
