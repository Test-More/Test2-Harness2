package App::Yath2::Discovery;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Errno qw/EACCES EPERM ECONNREFUSED/;

use Test2::Collector::Util::Socket qw/connect_unix/;

use App::Yath2::Util qw/find_runner_link find_runner_links/;
use Test2::Harness2::Util qw/clean_path open_file/;

use Test2::Harness2::Util::HashBase qw{
    <link
    +socket
    +workdir
    +pid
};

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

Resolve the well-known symlink for C<$settings> and, if it points at a B<live>
runner socket, return a C<Discovery> instance; otherwise return nothing. C<live>
means the symlink resolves to an existing socket that accepts a connection.

A dangling symlink, or one whose target is missing or refuses a connect, is
treated as no runner: the stale symlink is unlinked and nothing is returned. Pass
C<< no_clean => 1 >> to skip removing a stale symlink (used by code that only
wants to know whether a path is published, not to mutate it).

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

    my $no_clean = delete $params{no_clean};

    my $link = find_runner_link($settings, %params) or return;
    return unless -l $link || -e $link;

    my $self = $class->new(link => $link);

    return $self if $self->resolves;

    $self->clean unless $no_clean;
    return;
}

=item @records = App::Yath2::Discovery->list($settings, %params)

Enumerate B<all> candidate discovery symlinks (via
L<App::Yath2::Util/find_runner_links>, which reuses C<find_runner_link>'s
directory/name rules), probe each for liveness, and return one record hashref per
symlink that is either B<live> or B<inaccessible> (another user's runner we lack
permission to connect to). Dangling symlinks -- a crashed runner that left a link
pointing at a dead socket -- are dropped, and (unless C<< no_clean => 1 >>) cleaned
up B<only> when the link is owned by the current UID (multi-user safety: never
unlink another user's stale link).

Each record is:

    {
        link    => $symlink_path,
        state   => 'live' | 'inaccessible',
        disco   => $discovery_instance,   # for a 'live' record
        socket  => $socket_path,          # the link's target
        workdir => $workdir,              # 'live' only (the dir is reachable)
        pid     => $pid,                  # 'live' only (read from the PID file)
    }

This never throws on an unreadable directory or a connect that fails with
C<EACCES>/C<EPERM> (those become C<inaccessible> records); a C<ECONNREFUSED> or
missing target is a dead runner (dropped/cleaned).

=cut

sub list ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    my $no_clean = delete $params{no_clean};

    my @records;
    for my $link (find_runner_links($settings, %params)) {
        my $self = $class->new(link => $link);
        my $rec  = $self->probe;

        if ($rec->{state} eq 'live' || $rec->{state} eq 'inaccessible') {
            push @records => $rec;
            next;
        }

        # 'dead' / 'dangling': clean the stale link, but only when WE own it
        # (multi-user safety -- never unlink another user's link).
        $self->clean_if_owned unless $no_clean;
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

sub pid ($self) {
    return $self->{+PID} if defined $self->{+PID};

    my $pidfile = File::Spec->catfile($self->workdir, 'PID');
    return undef unless -f $pidfile;

    my $ok = eval {
        my $fh  = open_file($pidfile, '<');
        my $pid = <$fh>;
        close($fh);
        chomp($pid) if defined $pid;
        $self->{+PID} = $pid if defined($pid) && $pid =~ /^\d+$/;
        1;
    };
    warn "Could not read runner PID file '$pidfile': $@" unless $ok;

    return $self->{+PID};
}

=item $bool = $disco->resolves

True when the symlink resolves to a socket that accepts a connection (a live
runner). False for a dangling symlink, a missing/non-socket target, or a target
that refuses the connect (a wedged runner whose socket is gone). The connection is
opened only to probe liveness and is closed immediately.

=cut

sub resolves ($self) {
    my $target = readlink($self->{+LINK}) // return 0;
    $target = clean_path($target);

    return 0 unless -S $target;

    my $sock = eval { connect_unix($target) } or return 0;
    close($sock);

    return 1;
}

=item $rec = $disco->probe

Classify this one symlink for L</list> without dying. Resolves the link, attempts a
connect, and returns a record hashref whose C<state> is:

=over 4

=item C<live>

The link resolves to a socket that accepts a connection. The record carries the
C<disco> (this instance), C<socket>, C<workdir>, and C<pid>.

=item C<inaccessible>

The socket exists but the connect failed with C<EACCES>/C<EPERM> -- another user's
runner we lack permission to reach. The record carries C<socket> only (the workdir
and pid may not be readable either).

=item C<dead>

A dangling link, a missing/non-socket target, or a connect refused with
C<ECONNREFUSED> -- there is no live runner here.

=back

=cut

sub probe ($self) {
    my $link = $self->{+LINK};

    my $target = readlink($link);
    return {link => $link, state => 'dead'} unless defined $target;
    $target = clean_path($target);

    # A link whose target is gone or is not a socket is a dead/crashed runner.
    return {link => $link, state => 'dead'} unless -S $target;

    # Probe liveness with a connect. Classify the failure by errno so another
    # user's runner (EACCES/EPERM on the socket) is reported as inaccessible rather
    # than mistaken for dead -- and never cleaned.
    my $sock = eval { connect_unix($target) };
    if ($sock) {
        close($sock);
        return {
            link    => $link,
            state   => 'live',
            disco   => $self,
            socket  => $target,
            workdir => $self->workdir,
            pid     => $self->pid,
        };
    }

    my $errno = $!;
    if ($errno == EACCES || $errno == EPERM) {
        return {link => $link, state => 'inaccessible', socket => $target};
    }

    # ECONNREFUSED (no listener) or anything else: the runner is gone.
    return {link => $link, state => 'dead', socket => $target};
}

=item $disco->clean_if_owned

Remove the symlink, but B<only> when it is a symlink owned by the current effective
UID (multi-user safety: L</list> must never unlink another user's stale link). A
no-op for a non-symlink, an other-user-owned link, or one whose ownership cannot be
read.

=cut

sub clean_if_owned ($self) {
    my $link = $self->{+LINK};
    return unless -l $link;

    # lstat the LINK itself (not its target) to read the symlink's own owner.
    my $uid = (lstat($link))[4];
    return unless defined $uid;
    return unless $uid == $>;

    unlink($link);
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

    # Replace any existing symlink so a stale one from a crashed runner does not
    # block publishing. A non-symlink at the path is a caller mistake -- refuse to
    # clobber a real file the way open_unix_listen refuses a non-socket.
    if (-e $link || -l $link) {
        croak "Discovery path '$link' exists and is not a symlink" unless -l $link;
        unlink($link) or die "Could not remove stale discovery symlink '$link': $!";
    }

    symlink($target, $link) or die "Could not create discovery symlink '$link' -> '$target': $!";

    return;
}

=item $disco->clean

Remove the symlink (only if it is a symlink). Used when discovery found a stale or
dangling symlink for a runner that is gone.

=cut

sub clean ($self) {
    my $link = $self->{+LINK};
    return unless -l $link;
    unlink($link);
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
