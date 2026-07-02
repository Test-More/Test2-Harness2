package App::Yath2::Discovery;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes();
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK LOCK_EX LOCK_UN LOCK_NB/;
use Socket qw/PF_UNIX SOCK_STREAM SOL_SOCKET SO_ERROR sockaddr_un/;
use Errno qw{
    EACCES EPERM ECONNREFUSED EAGAIN EWOULDBLOCK EINPROGRESS EINTR
    EMFILE ENFILE ENOMEM ENOBUFS ESRCH ENOENT
};

use App::Yath2::Util qw/find_runner_link find_runner_links/;
use Test2::Harness2::Util qw/clean_path open_file publish_discovery_link/;

use Test2::Harness2::Util::HashBase qw{
    <link
    +socket
    +workdir
    +pid
    <state
    <reason
    <pid_live
    +pid_file
};

# Bounded wait (seconds) for a non-blocking connect that reports EINPROGRESS, so a
# full-backlog / wedged listener can NEVER hang discovery (the whole point of the
# non-blocking probe -- a blocking unix connect blocks in unix_wait_for_peer once
# the accept queue is full; see open_unix_listen in Test2::Collector::Util::Socket).
sub PROBE_CONNECT_TIMEOUT() { 0.5 }

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Discovery - Locate a persistent runner via a well-known symlink to its
C<runner.socket>, with a workdir C<PID>-file fallback for signalling a wedged
runner.

=head1 DESCRIPTION

A persistent harness publishes a well-known B<symlink> pointing at its
C<runner.socket> (in the runner's workdir). A client follows the symlink to reach
the socket, and follows it to the socket's directory to locate the B<workdir>
(and from there the per-stage C<preload-E<lt>stageE<gt>.socket>s). This replaces
the old C<yath-persist.json> metadata file.

Normal liveness is a socket connect; for signalling a B<wedged> runner whose
socket no longer accepts or responds, the client resolves the workdir via the
symlink and reads the flat C<PID> file the runner writes there. A dangling
symlink (or one whose connect fails) means there is no live runner: the harness
is treated as absent and the stale symlink is cleaned up.

The symlink itself carries no metadata. Liveness, version, and ownership are not
read from a discovery file anymore: liveness is the socket connect, the runner's
own C<settings.json> in the workdir carries its configuration, and access is
governed by the workdir + socket permissions (the symlink's own mode is not
meaningful and is left at the process umask). The symlink path is chosen by the
same project-prefix / tempdir-vs-cwd rules the old pfile used (see
L<App::Yath2::Util/find_runner_link>), so the multiple-harness-per-project story
is preserved: each distinct project prefix gets its own symlink.

=head1 SYNOPSIS

    use App::Yath2::Discovery;

    # Publish (yath start): point the well-known symlink at the runner socket.
    my $disco = App::Yath2::Discovery->publish($settings, workdir => $workdir);

    # Discover (yath run / which / status / ...): follow the symlink to a LIVE
    # runner, or get nothing back (and the stale symlink cleaned) if it is gone.
    my $disco = App::Yath2::Discovery->find($settings)
        or die "No persistent harness was found for the current path.\n";

    my $sock_path = $disco->socket;     # the runner.socket the symlink points at
    my $dir       = $disco->workdir;    # the runner's workdir
    my $pid       = $disco->pid;        # the runner pid (workdir PID file)

=head1 ATTRIBUTES

=over 4

=item $path = $disco->link

The well-known symlink path.

=item $path = $disco->socket

The C<runner.socket> path the symlink resolves to.

=item $dir = $disco->workdir

The runner's workdir (the directory containing C<runner.socket>).

=item $pid = $disco->pid

The runner's process id, read from the workdir C<PID> file. Used as the
signal-based-termination fallback when the socket is unresponsive. C<undef> if
the file is missing or unreadable.

=item $state = $disco->state

The L</probe> classification: C<'live'>, C<'not_live'>, or C<'dead'>. Populated by
the C<probe> that L</find> runs.

=item $reason = $disco->reason

The not-live subcode (C<boot>/C<wedged>/C<backlog>/C<inaccessible>/C<foreign>/
C<unknown>), or C<undef> for a live/dead link.

=item $bool = $disco->pid_live

C<1> when the workdir C<PID> names a running process, C<0> when it is confirmed
dead (kill-0 C<ESRCH>), C<undef> when it cannot be determined (C<EPERM> or no pid).

=item $path = $disco->pid_file

The workdir C<PID> file path (C<< workdir/PID >>) -- pure path math off the link
target, so it is available with the socket dead (this is what feeds the
signal-based escalation).

=back

=cut

sub init ($self) {
    croak "'link' is a required attribute" unless defined $self->{+LINK};
    return;
}

=head1 PUBLIC METHODS

=over 4

=item find

=item $disco = App::Yath2::Discovery->find($settings, %params)

Resolve the well-known symlink for C<$settings>, classify it with L</probe>, and by
default return a C<Discovery> instance only when it points at a B<live> runner
socket (one that accepts a connection); otherwise return nothing. This keeps the
historical live-or-nothing contract for C<run>/C<spawn> and command selection.

The symlink is auto-cleaned B<only> when C<probe> classifies it as unambiguously
C<dead> (a dangling link whose workdir is gone, or a refused/absent socket whose
workdir C<PID> names a confirmed-dead process), and then only through the locked
owned protocol (see L</clean_if_owned>). Every B<not-live> outcome -- the boot
window, a wedged runner, a full accept backlog, another user's runner -- B<keeps>
the link so a still-alive-but-unresponsive runner stays discoverable for
signal-based termination. Pass C<< no_clean => 1 >> to skip cleaning even a dead
link (a read-only probe, e.g. for command selection).

Pass C<< any_state => 1 >> to get the C<Discovery> instance back in B<every> state
(C<live>/C<not_live>/C<dead>) rather than only when live -- used by C<stop>/C<kill>
so they can reach the workdir C<PID> file (via L</workdir>/L</pid_file>) with the
socket dead. The C<state>/C<reason>/C<pid>/C<pid_live>/C<pid_file>/C<workdir>
accessors are all populated by the C<probe> that C<find> ran.

C<%params> select the symlink path the same way the old pfile lookup did
(C<persist_file> / C<pfile>, C<persist_dir>, project prefix, tempdir-vs-cwd); they
are passed through to L<App::Yath2::Util/find_runner_link>.

=item publish

=item $disco = App::Yath2::Discovery->publish($settings, workdir => $workdir, %params)

Create (or refresh) the well-known symlink so it points at C<< $workdir/runner.socket >>
and return a C<Discovery> instance bound to it. Replaces any existing symlink at
that path. The workdir is recorded; the runner writes its own C<PID> file there as
it boots.

=cut

sub publish ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    my $workdir = delete $params{workdir} or croak "'workdir' is a required argument";
    $workdir = clean_path($workdir);

    my $link = find_runner_link($settings, %params, vivify => 1)
        or croak "Could not determine a discovery symlink path for the current settings";

    my $self = $class->new(link => $link, workdir => $workdir);
    $self->write_link;

    return $self;
}

sub find ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    my $any_state = delete $params{any_state};
    my $no_clean  = delete $params{no_clean};

    my $link = find_runner_link($settings, %params) or return;
    return unless -l $link || -e $link;

    my $self  = $class->new(link => $link);
    my $probe = $self->probe;
    my $state = $probe->{state};

    return $self if $state eq 'live';

    # Auto-clean ONLY on unambiguous DEAD, and only through the locked owned
    # protocol (flock + readlink-compare + PID-liveness re-check). Every NOT-LIVE
    # outcome -- boot window, wedged, full accept backlog, another user's runner --
    # KEEPS the link so a still-alive-but-unresponsive runner stays discoverable for
    # #121's signal-based escalation.
    $self->clean_if_owned($probe) if $state eq 'dead' && !$no_clean;

    # any_state callers (stop/kill escalation, start's already-running guard) get the
    # Discovery object in EVERY state so they can reach the workdir PID file with the
    # socket dead; the default contract stays live-or-nothing.
    return $self if $any_state;

    return;
}

=item @records = App::Yath2::Discovery->list($settings, %params)

Enumerate B<all> candidate discovery symlinks (via
L<App::Yath2::Util/find_runner_links>, which reuses C<find_runner_link>'s
directory/name rules), L</probe> each, and return one record hashref per symlink
that is either B<live> or B<not-live> (a wedged / full-backlog / another-user's
runner). Only an unambiguously C<dead> link is dropped, and (unless
C<< no_clean => 1 >>) cleaned via the locked owned protocol (L</clean_if_owned>) --
never another user's link.

Each record is the L</probe> record hashref:

    {
        link     => $symlink_path,
        state    => 'live' | 'not_live',
        reason   => $reason,              # not-live subcode (see probe); undef for live
        disco    => $discovery_instance,
        socket   => $socket_path,         # the link's target
        workdir  => $workdir,             # pure path math off the target
        pid      => $pid,                 # from the workdir PID file
        pid_live => $bool,                # 1 alive / 0 dead / undef unknown
    }

This never throws on an unreadable directory or a connect that fails with
C<EACCES>/C<EPERM> (those become C<not_live>/C<inaccessible> records).

=cut

sub list ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    my $no_clean = delete $params{no_clean};

    my @records;
    for my $link (find_runner_links($settings, %params)) {
        my $self = $class->new(link => $link);
        my $rec  = $self->probe;

        # Keep every live OR not-live runner: a wedged / full-backlog / other-user
        # runner must NEVER be cleaned (only an unambiguously DEAD link is, and only
        # when WE own it, via the locked protocol).
        if ($rec->{state} eq 'live' || $rec->{state} eq 'not_live') {
            push @records => $rec;
            next;
        }

        $self->clean_if_owned($rec) unless $no_clean;
    }

    return @records;
}

=item $path = $disco->socket

The runner socket the symlink points at (its readlink target). Built from the
symlink target on first use.

=item $dir = $disco->workdir

The directory holding C<runner.socket> -- the runner's workdir. Derived from the
socket path.

=cut

sub socket ($self) {
    return $self->{+SOCKET} //= clean_path(readlink($self->{+LINK}) // croak "Discovery symlink '$self->{+LINK}' is not a symlink");
}

sub workdir ($self) {
    return $self->{+WORKDIR} //= do {
        my ($vol, $dir, undef) = File::Spec->splitpath($self->socket);
        clean_path(File::Spec->catpath($vol, $dir, ''));
    };
}

=item $pid = $disco->pid

The runner pid, read from C<< $workdir/PID >> (the runner writes it there as it
boots; it survives the exec across a reload-respawn). The signal fallback for a
wedged runner. C<undef> if the file is missing or does not hold a pid.

=cut

sub pid_file ($self) {
    return $self->{+PID_FILE} //= File::Spec->catfile($self->workdir, 'PID');
}

sub pid ($self) {
    return $self->{+PID} if defined $self->{+PID};

    $self->{+PID} = _read_pid($self->pid_file);

    return $self->{+PID};
}

# Read a numeric pid out of a flat PID file, without dying and without caching.
# Returns the pid (a string of digits) or undef when the file is missing, empty,
# unreadable, or does not hold a bare pid.
sub _read_pid ($pidfile) {
    return undef unless defined $pidfile && -f $pidfile;

    my $pid;
    my $ok = eval {
        my $fh = open_file($pidfile, '<');
        $pid = <$fh>;
        close($fh);
        1;
    };
    return undef unless $ok;

    chomp($pid) if defined $pid;
    return undef unless defined($pid) && $pid =~ /^\d+$/;
    return $pid;
}

=item $bool = $disco->resolves

True when L</probe> classifies the link as C<live> (a socket that accepts a
connection). Folds #96 step 2: this is exactly C<< $self->probe->{state} eq 'live' >>.

=cut

sub resolves ($self) {
    return $self->probe->{state} eq 'live' ? 1 : 0;
}

=item $rec = $disco->probe

Classify this one symlink without dying, and stamp C<state>/C<reason> (and the
cached C<pid>/C<pid_live>/C<socket>/C<workdir>/C<pid_file>) onto C<$self>. Liveness
is a B<non-blocking> connect with a bounded wait, so a wedged runner with a full
accept backlog can never hang discovery. The errno at each failing syscall is
captured immediately. Returns a record hashref (also used by L</list>) whose
C<state> is one of:

=over 4

=item C<live>

The link resolves to a socket that accepted a connection.

=item C<not_live>

A runner that is (or may be) alive but is not currently answering: the boot window
(C<reason> C<boot>), a wedged runner or bind/shutdown microgap (C<wedged>), a live
listen fd with a stalled/full accept loop (C<backlog>), another user's runner
(C<inaccessible>), a real non-symlink file at the link path (C<foreign>), or an
ambiguous case (C<unknown>). B<Never> cleaned -- the link is kept so the runner
stays reachable for signal-based termination.

=item C<dead>

Unambiguously gone: a dangling link whose workdir is missing, or a
refused/absent socket whose workdir C<PID> names a confirmed-dead (kill-0 C<ESRCH>)
or absent process. The only state L</find>/L</list> will clean.

=back

The record carries C<link>, C<state>, C<reason>, C<disco>, C<socket>, C<workdir>,
C<pid>, and C<pid_live>.

=cut

sub probe ($self) {
    my $link = $self->{+LINK};

    my $target = readlink($link);

    # Not a symlink at all.
    unless (defined $target) {
        # A real file (not a link) the user or another tool owns -- NEVER unlink it
        # (mirrors write_link's refusal to clobber a non-symlink).
        return $self->_verdict('not_live', 'foreign') if -e $link;

        # Nothing published here at all; find() already gated on -l/-e, so this is
        # only reached by a direct probe of an absent path. Nothing to clean.
        return $self->_verdict('dead', undef);
    }

    $target = clean_path($target);
    $self->{+SOCKET} = $target;

    # Pure path math off the link target: available with the socket dead, no connect
    # required (this is what feeds #121's PID-file fallback).
    my ($vol, $dir, undef) = File::Spec->splitpath($target);
    my $workdir = $self->{+WORKDIR} //= clean_path(File::Spec->catpath($vol, $dir, ''));
    $self->{+PID_FILE} //= File::Spec->catfile($workdir, 'PID');

    # A bound socket file at the target: probe liveness with a NON-BLOCKING connect.
    if (-S $target) {
        my ($verdict, $errno) = $self->_probe_connect($target);

        return $self->_verdict('live', undef) if $verdict eq 'live';

        if ($verdict eq 'refused') {
            # ECONNREFUSED: a socket file with no listener. Only an unambiguously
            # dead (or absent) pid makes this DEAD; a live/inaccessible pid means a
            # shutdown-in-flight or bind->listen microgap -- keep the link for #121.
            my ($pstate) = $self->_pid_status;
            return $self->_verdict('dead', undef) if $pstate eq 'dead' || $pstate eq 'absent';
            return $self->_verdict('not_live', 'wedged');
        }

        # A TOCTOU: the socket file was unlinked between the -S check and connect.
        # Fall through to the target-missing rows (which consult the pid).
        return $self->_probe_target_missing($workdir) if $verdict eq 'gone';

        return $self->_verdict('not_live', 'backlog')      if $verdict eq 'backlog';
        return $self->_verdict('not_live', 'inaccessible') if $verdict eq 'inaccessible';

        # Client-side resource exhaustion / any other errno says nothing about the
        # runner: DEAD is a closed enumeration, so the default is keep-the-link.
        return $self->_verdict('not_live', 'unknown');
    }

    # The target exists but is not (yet) a socket: the boot window (PID written
    # before bind) or a wedged runner whose socket file was unlinked. NEVER proof of
    # death -- keep the link.
    return $self->_verdict('not_live', 'boot') if -e $target;

    # The target is missing entirely.
    return $self->_probe_target_missing($workdir);
}

# The socket target (T) is missing. Classify by whether the workdir (W) is gone
# (an unambiguously dead / dangling link) and, when W survives, by the pid.
sub _probe_target_missing ($self, $workdir) {
    # W itself missing: a booting runner writes its PID into an existing workdir
    # BEFORE binding, so no workdir means no boot in progress and no PID fallback to
    # lose -- DEAD.
    return $self->_verdict('dead', undef) unless -d $workdir;

    my ($pstate) = $self->_pid_status;

    # A live pid with the socket gone is the bug itself: the boot window, or a wedged
    # runner whose socket file was removed. Keep the link.
    return $self->_verdict('not_live', 'boot')         if $pstate eq 'alive';
    return $self->_verdict('dead', undef)              if $pstate eq 'dead';
    return $self->_verdict('not_live', 'inaccessible') if $pstate eq 'inaccessible';

    # PID file absent/garbled (the spawn window before the PID write): ambiguous, and
    # stance A only cleans on unambiguous death. A fresh start republishes over it.
    return $self->_verdict('not_live', 'unknown');
}

# Stamp state/reason (and cached pid/pid_live) onto $self and return the record
# hashref shared by find()/list(). The record carries the full not-live interface
# #121 consumes.
sub _verdict ($self, $state, $reason) {
    $self->{+STATE}  = $state;
    $self->{+REASON} = $reason;

    my ($pstate, $pid) = $self->_pid_status;
    $self->{+PID} //= $pid if defined $pid;
    $self->{+PID_LIVE}
        = $pstate eq 'alive' ? 1
        : $pstate eq 'dead'  ? 0
        :                      undef;

    return {
        link     => $self->{+LINK},
        state    => $state,
        reason   => $reason,
        disco    => $self,
        socket   => $self->{+SOCKET},
        workdir  => $self->{+WORKDIR},
        pid      => $self->{+PID},
        pid_live => $self->{+PID_LIVE},
    };
}

# Read the workdir PID file and check the process. Returns ($status, $pid):
#   'alive'        kill(0) succeeded (or an ambiguous errno -- fail safe: keep)
#   'dead'         kill(0) => ESRCH (confirmed dead)
#   'inaccessible' kill(0) => EPERM (a process exists but is not ours to verify)
#   'absent'       no PID file, or it does not hold a bare pid
sub _pid_status ($self) {
    my $pid = _read_pid($self->{+PID_FILE});
    return ('absent', undef) unless defined $pid;

    return ('alive', $pid) if kill(0, $pid);

    my $errno = $! + 0;
    return ('dead', $pid)         if $errno == ESRCH;
    return ('inaccessible', $pid) if $errno == EPERM;

    # Any other errno: assume alive so we never clean on ambiguity.
    return ('alive', $pid);
}

# A bounded, NON-BLOCKING unix connect used ONLY as a liveness probe (never for
# real I/O). Returns ($verdict, $errno) where $verdict is one of: 'live', 'refused'
# (ECONNREFUSED), 'backlog' (EAGAIN/EWOULDBLOCK or an EINPROGRESS that never
# completes within the bounded window -- a live listen fd with a full/stalled accept
# loop), 'inaccessible' (EACCES/EPERM), 'gone' (ENOENT: the target vanished after
# the -S check), or 'unknown' (client-side resource exhaustion / any other errno).
# The errno is captured with `$! + 0` immediately at each failing syscall, never
# after a croak/close (which clobber $!).
sub _probe_connect ($self, $target) {
    my $addr = eval { sockaddr_un($target) };
    return ('unknown', undef) unless defined $addr;

    # CORE::socket -- this package defines a socket() accessor, so the bareword is
    # ambiguous.
    CORE::socket(my $sock, PF_UNIX, SOCK_STREAM, 0) or return ('unknown', $! + 0);

    my $flags = fcntl($sock, F_GETFL, 0);
    fcntl($sock, F_SETFL, ($flags // 0) | O_NONBLOCK);

    my $deadline = Time::HiRes::time() + PROBE_CONNECT_TIMEOUT;

    my $tries = 0;
    while (1) {
        if (connect($sock, $addr)) {
            close($sock);
            return ('live', undef);
        }

        my $errno = $! + 0;

        if ($errno == EINPROGRESS) {
            my $remaining = $deadline - Time::HiRes::time();
            $remaining = 0 if $remaining < 0;

            my $wbits = '';
            vec($wbits, fileno($sock), 1) = 1;
            my $n = select(undef, my $wout = $wbits, undef, $remaining);

            if ($n && vec($wout, fileno($sock), 1)) {
                my $packed = getsockopt($sock, SOL_SOCKET, SO_ERROR);
                my $soerr  = defined($packed) ? unpack('i', $packed) : 0;
                close($sock);
                return ('live', undef) if !$soerr;
                return $self->_classify_connect_errno($soerr);
            }

            # Timed out with the connect still pending: a live listen fd whose accept
            # loop is wedged / its backlog is full.
            close($sock);
            return ('backlog', $errno);
        }

        if ($errno == EINTR) {
            next if $tries++ < 5;
            close($sock);
            return ('backlog', $errno);
        }

        close($sock);
        return $self->_classify_connect_errno($errno);
    }
}

sub _classify_connect_errno ($self, $errno) {
    return ('live', undef)          if !$errno;
    return ('refused', $errno)      if $errno == ECONNREFUSED;
    return ('backlog', $errno)      if $errno == EAGAIN || $errno == EWOULDBLOCK;
    return ('inaccessible', $errno) if $errno == EACCES || $errno == EPERM;
    return ('gone', $errno)         if $errno == ENOENT;
    return ('unknown', $errno)
        if $errno == EMFILE || $errno == ENFILE || $errno == ENOMEM || $errno == ENOBUFS;
    return ('unknown', $errno);
}

=item $disco->clean_if_owned

=item $disco->clean_if_owned($probe)

Remove a B<dead> discovery link through the shared mutator protocol (the crux of
ticket #145's race closure): (1) take the C<"$link.lock"> exclusive lock
non-blocking -- on failure SKIP entirely (fail-safe: a skipped clean costs
tidiness, never a runner); (2) re-C<readlink> and abort unless it still points at
the target this caller probed as dead (a republish to a different target aborts);
(3) re-run L</probe> under the lock and abort unless it is B<still> C<dead> (a
runner that (re)published in the meantime wrote its live PID first, so a
pinned-workdir restart with the IDENTICAL target still flips this to not-live and
aborts); (4) verify we own the symlink (C<lstat> uid == C<< $> >>, multi-user
safety); (5) C<unlink>; (6) release. A no-op for a non-symlink or another user's
link.

=cut

sub clean_if_owned ($self, $probe = undef) {
    my $link = $self->{+LINK};

    # The target this caller probed as DEAD; only a link still pointing there (and
    # still dead, and still ours) may be removed.
    my $probed_target = $probe ? $probe->{socket} : $self->{+SOCKET};

    $self->_locked_unlink(sub {
        my $now = readlink($link);

        # (2) re-readlink: gone already (another cleaner won), or republished at a
        # DIFFERENT target -- either way, not ours to remove.
        return 0 unless defined $now;
        return 0 if defined($probed_target) && clean_path($now) ne $probed_target;

        # (3) re-run the deadness check on a FRESH probe under the lock: a runner that
        # (re)published between our probe and here writes its live PID first, so this
        # flips to not-live and we abort -- even when the republished target string is
        # identical (a pinned-workdir restart).
        return 0 unless (ref($self))->new(link => $link)->probe->{state} eq 'dead';

        return 1;
    });

    return;
}

=item $disco->clean_if_mine($own_socket)

=item $disco->clean_if_mine($own_socket, $own_pid)

Owner-side removal used by a runner's exit guard and by C<stop>/C<kill>: remove the
discovery link B<only> when it still points at C<$own_socket> (this caller's own
C<runner.socket>) and no successor runner has claimed the workdir -- i.e. the
workdir C<PID> file does not name a live process other than C<$own_pid>. Serialized
against the publisher by the same C<"$link.lock">, so a just-republished link (a new
runner in the same pinned workdir) is never clobbered.

=cut

sub clean_if_mine ($self, $own_socket = undef, $own_pid = undef) {
    my $link = $self->{+LINK};

    $self->_locked_unlink(sub {
        my $now = readlink($link);

        # (2) still ours? A successor that republished elsewhere -- leave it.
        return 0 unless defined $now;
        return 0 unless defined($own_socket) && clean_path($now) eq clean_path($own_socket);

        # (3) a successor that claimed the SAME (pinned) workdir writes its own live
        # PID; never remove a link a live successor now owns.
        my $wpid = _read_pid($self->{+PID_FILE} //= File::Spec->catfile($self->workdir, 'PID'));
        my $successor = defined($wpid)
            && (!defined($own_pid) || $wpid != $own_pid)
            && kill(0, $wpid);
        return 0 if $successor;

        return 1;
    });

    return;
}

# Shared mutator protocol for every link-removal path: (1) take the "$link.lock"
# exclusive lock NON-blocking -- on failure SKIP the clean entirely (fail-safe: a
# skipped clean costs tidiness, never a runner); run the caller's guard ($decide,
# which performs the re-readlink + deadness/identity re-checks under the lock);
# (4) verify WE own the symlink (lstat uid == $>); (5) unlink; (6) release.
sub _locked_unlink ($self, $decide) {
    my $link = $self->{+LINK};

    my $lockfile = "$link.lock";
    my $lfh;
    return unless open($lfh, '>>', $lockfile);
    unless (flock($lfh, LOCK_EX | LOCK_NB)) {
        close($lfh);
        return;
    }

    my $ok = eval {
        if ($decide->()) {
            # (4) ownership: lstat the LINK itself (not its target).
            my $uid = (lstat($link))[4];
            unlink($link) if defined($uid) && $uid == $>;
        }
        1;
    };
    my $err = $@;

    eval { flock($lfh, LOCK_UN); 1 };
    close($lfh);

    warn "Error while cleaning discovery link '$link': $err" unless $ok;

    return;
}

=item $disco->write_link

Create (or replace) the symlink so it points at C<< $workdir/runner.socket >>.
Used by L</publish>.

=cut

sub write_link ($self) {
    my $link   = $self->{+LINK};
    my $target = File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
    $self->{+SOCKET} = clean_path($target);

    # Publish atomically (symlink-to-temp + rename) under the shared publisher lock,
    # so a concurrent cleaner never clobbers a fresh link. A non-symlink at the path
    # is a caller mistake -- publish_discovery_link croaks rather than clobbering it
    # (the way open_unix_listen refuses a non-socket).
    publish_discovery_link($target, $link);

    return;
}

=item $banner = $disco->describe

The "Found / PID / Dir" banner string used by the C<which> / C<watch> commands.

=back

=cut

sub describe ($self) {
    my $pid = $self->pid // 'unknown';
    my $dir = $self->workdir;

    return "\nFound: $self->{+LINK}\n"
        . "  PID: $pid\n"
        . "  Dir: $dir\n"
        . "\n";
}

1;

__END__

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
