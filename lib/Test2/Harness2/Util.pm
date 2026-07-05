package Test2::Harness2::Util;
use strict;
use warnings;

use Carp qw/confess croak/;
use Cwd qw/realpath/;
use Test2::Util qw/try_sig_mask do_rename/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB SEEK_SET F_GETFL F_SETFL O_NONBLOCK :mode/;
use File::Spec;
use Socket qw/PF_UNIX SOCK_STREAM SOL_SOCKET SO_ERROR sockaddr_un/;
use Errno qw/EAGAIN EINPROGRESS EINTR EWOULDBLOCK/;
use Time::HiRes();

our $VERSION = '2.000000';

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    find_libraries
    clean_path

    parse_exit
    collector_exit_code
    runner_events_file
    stage_events_file
    mod2file
    file2mod
    fqmod

    maybe_open_file
    maybe_read_file
    open_file
    read_file
    write_file
    write_file_atomic
    write_link_atomic
    publish_discovery_link
    lock_file
    unlock_file

    hub_truth

    apply_encoding

    process_includes

    chmod_tmp

    looks_like_uuid
    is_same_file

    socket_reporter
    connect_unix_nb

    read_available

    mono_time
};

# Monotonic-clock shim for interval math (deadlines, elapsed-since). Uses
# CLOCK_MONOTONIC where available so suspend/resume or an NTP step cannot warp a
# daemon deadline the way wall-clock Time::HiRes::time can (a wall step could
# mass-abort dispatched jobs as "collector did not connect", or freeze a
# timeout). Degrades to Time::HiRes::time -- the historical behavior -- when
# CLOCK_MONOTONIC is unavailable.
#
# RULES (TODO-134 finding 104): NEVER compare a mono_time() value against a
# wall-clock time, and NEVER persist or report a mono_time() value as a
# timestamp. It is an opaque, process-local, monotonically-non-decreasing count
# of seconds with an arbitrary epoch -- meaningful only in differences. Event
# stamps that go on the wire or into stored records stay on wall-clock time.
BEGIN {
    my $ok = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 };
    if ($ok) {
        *mono_time = sub () { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) };
    }
    else {
        *mono_time = \&Time::HiRes::time;
    }
}

# Shared bounded, NON-BLOCKING unix-domain connect: the single connect primitive
# behind discovery liveness probing (App::Yath2::Discovery::_probe_connect) and
# every runner dialer (Runner::Client / Runner::Subscriber). A plain BLOCKING
# connect() to a unix SOCK_STREAM socket blocks in the kernel's unix_wait_for_peer
# once the listener's accept backlog is full (a wedged / uninterruptibly-asleep
# runner that has bound but stopped accept()ing), so no wall-clock connect timeout
# could ever fire and the dialer hangs forever (ticket TODO-157). This does the
# non-blocking dance instead: connect -> EINPROGRESS -> select-for-writable with a
# bounded deadline -> getsockopt(SO_ERROR).
#
# Returns a two-element list:
#   ($sock, 0)       success -- a connected socket, left NON-BLOCKING (the caller
#                    sets its own blocking mode / wraps it).
#   (undef, $errno)  failure -- the numeric errno ($! + 0) captured at the failing
#                    syscall, or EINPROGRESS when the connect was still pending at
#                    the deadline (a live listen fd whose accept loop is wedged /
#                    backlog is full), or EINTR when interrupted past its retries,
#                    or 0 when the path could not be packed into a sockaddr.
# The errno is captured with `$! + 0` immediately at the failing syscall, never
# after a close (which clobbers $!). The caller classifies the errno for its own
# needs (discovery's not-live taxonomy vs a dialer's retry/deadline loop).
sub connect_unix_nb {
    my ($path, $timeout) = @_;

    my $addr = eval { sockaddr_un($path) };
    return (undef, 0) unless defined $addr;

    socket(my $sock, PF_UNIX, SOCK_STREAM, 0) or return (undef, $! + 0);

    my $flags = fcntl($sock, F_GETFL, 0);
    fcntl($sock, F_SETFL, ($flags // 0) | O_NONBLOCK);

    my $deadline = mono_time() + $timeout;

    my $tries = 0;
    while (1) {
        return ($sock, 0) if connect($sock, $addr);

        my $errno = $! + 0;

        if ($errno == EINPROGRESS) {
            my $remaining = $deadline - mono_time();
            $remaining = 0 if $remaining < 0;

            my $wbits = '';
            vec($wbits, fileno($sock), 1) = 1;
            my $n = select(undef, my $wout = $wbits, undef, $remaining);

            if ($n && vec($wout, fileno($sock), 1)) {
                my $packed = getsockopt($sock, SOL_SOCKET, SO_ERROR);
                my $soerr  = defined($packed) ? unpack('i', $packed) : 0;
                return ($sock, 0) unless $soerr;
                close($sock);
                return (undef, $soerr);
            }

            # Timed out with the connect still pending: a live listen fd whose
            # accept loop is wedged / its backlog is full.
            close($sock);
            return (undef, EINPROGRESS);
        }

        if ($errno == EINTR) {
            next if $tries++ < 5;
            close($sock);
            return (undef, EINTR);
        }

        close($sock);
        return (undef, $errno);
    }
}

# One sysread with errno classification, shared by the framed Connection
# transport and the FdPass control channel (the wire-format buffering lives on
# top of it, per protocol). Returns the bytes read plus a status:
#   'ok'    -- bytes were read (never empty).
#   'again' -- retryable (EAGAIN/EWOULDBLOCK/EINTR): nothing available right now.
#   'eof'   -- the peer closed the connection.
#   'fatal' -- a hard read error (e.g. ECONNRESET).
# The caller owns the close decision; this never touches the handle's state.
sub read_available {
    my ($fh) = @_;

    my $buf = '';
    my $n   = sysread($fh, $buf, 65536);

    unless (defined $n) {
        return ('', 'again') if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        return ('', 'fatal');
    }

    return ('', 'eof') if $n == 0;

    return ($buf, 'ok');
}

# Build the Test2::Collector::Recorder::Socket that streams a collector's
# transitions to runner.socket, or undef when the socket cannot be located or the
# connection fails (so the file recorder still produces a complete stream and the
# collector is never blocked on the transition channel). $identity is the
# preamble identity name (e.g. "collector:job:<id>"); $socket is the runner.socket
# path. %params accepts:
#   identity => { ... }  extra identity fields folded into the preamble alongside
#                        name/no_reply/pid (a test collector carries job_id /
#                        job_try / run_id so the runner can map this connection's
#                        EOF back to the job it ran -- ARCHITECTURE.md §5.4).
#   read_control => 1    build the connection BIDIRECTIONAL so the collector reads
#                        the runner's inbound terminate control (bail/abort), sent
#                        via send_control (which no_reply does not gate).
# Shared by every collector reporter site (the preload-root, per-job, per-stage,
# and plugin-aux collectors).
#
# The reporter ALWAYS sets no_reply so the runner does NOT echo its identity back.
# Two reasons: (1) an unread echo would, on a one-way reporter's close, turn into
# a TCP-RST that discards in-flight transitions; (2) writing the echo back to a
# collector that is busy draining its test child (and only opportunistically reads
# this socket) can stall the runner's single-threaded service loop under load --
# the cause of a 60s collector silence-timeout flake. no_reply and read_control
# are orthogonal: no_reply suppresses only the identity echo, while read_control
# keeps the connection bidirectional so the collector still reads the runner's
# terminate control (send_control is not gated by no_reply). pid => $$ carries the
# reporter process's real pid in the identity handshake.
sub socket_reporter {
    my ($identity, $socket, %params) = @_;

    return undef unless $socket && -S $socket;

    require Test2::Collector::Recorder::Socket;

    my $read_control  = $params{read_control} ? 1 : 0;
    my $extra         = $params{identity}     // {};

    my %ident = (name => $identity, pid => $$, %$extra);
    $ident{no_reply} = 1;

    my $reporter;
    my $ok = eval {
        $reporter = Test2::Collector::Recorder::Socket->new(
            paths        => [$socket],
            preamble     => {identity => \%ident},
            drain_input  => 1,
            ($read_control ? (read_control => 1) : ()),
        );
        1;
    };
    my $err = $@;

    # The file recorder still captures the full stream, so a failed socket
    # reporter loses only the live transition forward -- but surface it so a
    # silently-non-connecting reporter (a real socket problem) is visible.
    unless ($ok) {
        warn "$$ $0 could not open socket reporter '$identity' on '$socket': $err";
        return undef;
    }

    return $reporter;
}

sub is_same_file {
    my ($file1, $file2) = @_;

    return 0 unless defined $file1;
    return 0 unless defined $file2;

    return 1 if "$file1" eq "$file2";
    return 1 if clean_path($file1) eq clean_path($file2);

    return 0 unless -e $file1;
    return 0 unless -e $file2;

    my ($dev1, $inode1) = stat($file1);
    my ($dev2, $inode2) = stat($file2);

    return 0 unless $dev1 == $dev2;
    return 0 unless $inode1 == $inode2;
    return 1;
}

sub looks_like_uuid {
    my ($in) = @_;

    return undef unless defined $in;
    return undef unless length($in) == 36;
    return undef unless $in =~ m/^[0-9A-F\-]+$/i;
    return $in;
}

sub chmod_tmp {
    my $file = shift;

    my $mode = S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO;

    chmod($mode, $file);
}

sub process_includes {
    my %params = @_;

    my @start = @{delete $params{list} // []};

    my @list;
    my %seen = ('.' => 1);

    if (my $ch_dir = delete $params{ch_dir}) {
        for my $path (@start) {
            # '.' is special.
            $seen{'.'}++ and next if $path eq '.';

            if (File::Spec->file_name_is_absolute($path)) {
                push @list => $path;
            }
            else {
                push @list => File::Spec->catdir($ch_dir, $path);
            }
        }
    }
    else {
        @list = @start;
    }

    push @list => @INC if delete $params{include_current};

    @list = map { $_ eq '.' ? $_ : clean_path($_) || $_ } @list if delete $params{clean};

    @list = grep { !$seen{$_}++ } @list;

    # If we ask for dot add it to the end.
    push @list => '.' if delete($params{include_dot});

    confess "Invalid parameters: " . join(', ' => sort keys %params) if keys %params;

    return @list;
}

sub apply_encoding {
    my ($fh, $enc) = @_;
    return unless $enc;

    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    binmode($fh, ":encoding($enc)");
}

sub parse_exit {
    my ($exit) = @_;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

# The stable path of the events file recorded by the non-test collector that
# wraps the `yath test` runner. The producer (App::Yath2::Command::test
# start_runner) and the consumer (Test2::Harness2::Renderer::Driver, via
# Test2::Harness2::RunnerReader) must agree on it, so it lives here as a single
# shared accessor next to the workdir.
sub runner_events_file {
    my ($workdir) = @_;
    return File::Spec->catfile($workdir, 'runner-events.jsonl.zst');
}

# The stable path of the events file recorded by the non-test collector that
# wraps a single preload stage process. The producer (the stage's collector,
# launched from Test2::Harness2::Runner::Preloader::launch_stage) and the
# consumer (Test2::Harness2::Renderer::Driver, which discovers these by globbing
# the workdir) must agree on it, so it lives here next to runner_events_file. One
# file per stage name; stage names are simple identifiers, used verbatim.
sub stage_events_file {
    my ($workdir, $stage) = @_;
    return File::Spec->catfile($workdir, "stage-${stage}-events.jsonl.zst");
}

# Map a Test2::Collector::collect() info hash to the exit code the collector
# PARENT should _exit() with, so the process that reaps it (the runner reaping a
# job, or the harness IPC reaping the runner) observes the CHILD's verdict, not
# merely the collector's own health:
#   - collector itself failed -> 255 (a harness/collector error; non-zero is
#     treated as failure, which is correct).
#   - otherwise               -> the child's exit status: WEXITSTATUS (err) when
#     non-zero, or 1 if the child died by signal. Zero only on a clean exit.
# This is the numeric core shared by the three collector-wrapper _exit paths that
# reap a child through a collector: the runner's job wrap
# (Test2::Harness2::Runner), the preload stage wrap
# (Test2::Harness2::Runner::Preloader), and the plugin-aux wrap
# (Test2::Harness2::Plugin). Keeping it in one place guarantees exit-status
# fidelity does not diverge between those paths.
sub collector_exit_code {
    my ($info) = @_;

    unless ($info && $info->{collector} && $info->{collector}{ok}) {
        if ($info && $info->{collector} && @{$info->{collector}{errors} // []}) {
            warn "$_\n" for @{$info->{collector}{errors}};
        }
        return 255;
    }

    my $exit = $info->{exit} // {};
    return $exit->{err} || ($exit->{sig} ? 1 : 0);
}

sub fqmod {
    my ($prefix, $input) = @_;
    return $1 if $input =~ m/^\+(.*)$/;
    return "$prefix\::$input";
}

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace} if $f->{trace};
    return {};
}

sub maybe_read_file {
    my ($file) = @_;

    my $fh = maybe_open_file($file) or return undef;
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

sub read_file {
    my ($file, @args) = @_;

    my $fh = open_file($file, '<', @args);
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

sub write_file {
    my ($file, @content) = @_;

    my $fh = open_file($file, '>');
    print $fh @content;
    close_file($fh, $file);

    return @content;
};

my %COMPRESSION = (
    bz2 => {module => 'IO::Uncompress::Bunzip2', errors => \$IO::Uncompress::Bunzip2::Bunzip2Error},
    gz  => {module => 'IO::Uncompress::Gunzip',  errors => \$IO::Uncompress::Gunzip::GunzipError},
);
sub open_file {
    my ($file, $mode, %opts) = @_;
    $mode ||= '<';

    unless ($opts{no_decompress}) {
        if ($file =~ m/\.(gz|bz2)$/i) {
            my $ext = lc($1);
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($mode eq '<' && $opts{compression}) {
            my $spec = $opts{compression};
            my $mod  = $spec->{module};
            require(mod2file($mod));

            my $fh = $mod->new($file) or die "Could not open file '$file' ($mode): ${$spec->{errors}}";
            return $fh;
        }
    }

    open(my $fh, $mode, $file) or confess "Could not open file '$file' ($mode): $!";
    return $fh;
}

sub maybe_open_file {
    my ($file, $mode) = @_;
    $mode ||= '<';

    # Non-read modes: a writer is not a teardown-racing poller, so keep the
    # historical -f-then-open (and never create a file that is missing).
    if ($mode ne '<') {
        return undef unless -f $file;
        return open_file($file, $mode);
    }

    # Compressed read: IO::Uncompress reports failure as a message string, not a
    # trustworthy errno, so keep the -f pre-check. Should the file vanish in the
    # race between that check and the open (ENOENT/ESTALE) return undef; re-throw
    # anything else.
    if ($file =~ m/\.(gz|bz2)$/i) {
        return undef unless -f $file;

        my $fh;
        my $ok  = eval { $fh = open_file($file, $mode); 1 };
        my $err = $@;
        return $fh if $ok;
        return undef if $!{ENOENT} || $!{ESTALE};
        die $err;
    }

    # Plain read: open directly (no stat window) so a file unlinked between a
    # decision and this open cannot confess -- ENOENT (unlinked) and ESTALE (an
    # NFS handle that vanished) become undef, killing a teardown-racing poller
    # gracefully. Any other error (EACCES, EMFILE, EISDIR, ELOOP, ENOTDIR, ...)
    # still confesses. On success, fstat the open handle so a directory/device
    # still yields undef (the old -f contract) without a TOCTOU window.
    if (open(my $fh, $mode, $file)) {
        unless (-f $fh) {
            close($fh);
            return undef;
        }
        return $fh;
    }

    return undef if $!{ENOENT} || $!{ESTALE};
    confess "Could not open file '$file' ($mode): $!";
}

sub close_file {
    my ($fh, $name) = @_;
    return if close($fh);
    confess "Could not close file: $!" unless $name;
    confess "Could not close file '$name': $!";
}

sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        write_file($pend, @content);
        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    die $err unless $ok;

    return @content;
}

# Publish a symlink atomically: symlink to a per-pid temp name, then rename(2) it
# onto $link. rename(2) replaces the destination name in a single step, so a
# concurrent reader ever sees the OLD target or the NEW target -- never a missing
# or half-written link. The sibling of write_file_atomic for the discovery symlink
# (App::Yath2::Discovery). Refuses to clobber a NON-symlink at $link the way
# open_unix_listen refuses a non-socket (a real file the caller pointed us at by
# mistake); an existing SYMLINK is replaced by the rename.
sub write_link_atomic {
    my ($target, $link) = @_;

    if (-e $link || -l $link) {
        croak "path '$link' exists and is not a symlink" unless -l $link;
    }

    my $tmp = "$link.$$.tmp";
    unlink($tmp) if -l $tmp || -e $tmp;

    symlink($target, $tmp)
        or confess "Could not create discovery symlink '$tmp' -> '$target': $!";

    unless (rename($tmp, $link)) {
        my $err = $!;
        unlink($tmp);
        confess "Could not publish discovery symlink '$tmp' -> '$link': $err";
    }

    return $link;
}

# Publish the discovery symlink under the shared publisher/cleaner lock so it
# serializes against a concurrent cleaner (App::Yath2::Discovery's clean_if_owned /
# clean_if_mine take the same "$link.lock" with LOCK_NB). Ordering-invariant for the
# TODO-145 race closure: a cleaner that decides a link is dead re-checks liveness while
# holding this lock, so a publish landing before that re-check flips it to keep, and
# a publish landing after a cleaner's unlink simply recreates the link.
#
# The lock is best-effort: a squatted lockfile in a sticky shared tempdir must never
# block a runner from becoming discoverable, so on lock timeout we publish ANYWAY
# (the fail-safe side is a racing cleaner skipping its clean, never a lost runner).
sub publish_discovery_link {
    my ($target, $link) = @_;

    my $lockfile = "$link.lock";
    my $lfh;
    if (open($lfh, '>>', $lockfile)) {
        my $deadline = Time::HiRes::time() + 2;
        my $got      = 0;
        while (1) {
            last if $got = flock($lfh, LOCK_EX | LOCK_NB);
            last if Time::HiRes::time() >= $deadline;
            Time::HiRes::sleep(0.05);
        }
    }

    my $ok  = eval { write_link_atomic($target, $link); 1 };
    my $err = $@;

    if ($lfh) {
        eval { flock($lfh, LOCK_UN); 1 };
        close($lfh);
    }

    die $err unless $ok;
    return $link;
}

sub lock_file {
    my ($file, $mode) = @_;

    my $fh;
    if (ref $file) {
        $fh = $file;
    }
    else {
        open($fh, $mode // '>>', $file) or die "Could not open file '$file': $!";
    }

    for (1 .. 21) {
        flock($fh, LOCK_EX) and last;
        die "Could not lock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not lock file: $!";
    }

    return $fh;
}

sub unlock_file {
    my ($fh) = @_;
    for (1 .. 21) {
        flock($fh, LOCK_UN) and last;
        die "Could not unlock file (try $_): $!" if $_ >= 20;
        next if $!{EINTR} || $!{ERESTART};
        die "Could not unlock file: $!";
    }

    return $fh;
}

sub clean_path {
    my ( $path, $absolute ) = @_;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub file2mod {
    my $file = shift;
    my $mod  = $file;
    $mod =~ s{/}{::}g;
    $mod =~ s/\..*$//;
    return $mod;
}


sub find_libraries {
    my ($search, @paths) = @_;
    my @parts = grep $_, split /::(\*)?/, $search;

    @paths = @INC unless @paths;

    @paths = map { File::Spec->canonpath($_) } @paths;

    my %prefixes = map {$_ => 1} @paths;

    my @found;
    my @bases = ([map { [$_ => length($_)] } @paths]);
    while (my $set = shift @bases) {
        my $new_base = [];
        my $part      = shift @parts;

        for my $base (@$set) {
            my ($dir, $prefix) = @$base;
            if ($part ne '*') {
                my $path = File::Spec->catdir($dir, $part);
                if (@parts) {
                    push @$new_base => [$path, $prefix] if -d $path;
                }
                elsif (-f "$path.pm") {
                    push @found => ["$path.pm", $prefix];
                }

                next;
            }

            opendir(my $dh, $dir) or next;
            for my $item (readdir($dh)) {
                next if $item =~ m/^\./;
                my $path = File::Spec->catdir($dir, $item);
                if (@parts) {
                    # Sometimes @INC dirs are nested in eachother.
                    next if $prefixes{$path};

                    push @$new_base => [$path, $prefix] if -d $path;
                    next;
                }

                next unless -f $path && $path =~ m/\.pm$/;
                push @found => [$path, $prefix];
            }
        }

        push @bases => $new_base if @$new_base;
    }

    my %out;
    for my $found (@found) {
        my ($path, $prefix) = @$found;

        my @file_parts = File::Spec->splitdir(substr($path, $prefix));
        shift @file_parts if $file_parts[0] eq '';

        my $file = join '/' => @file_parts;
        $file_parts[-1] = substr($file_parts[-1], 0, -3);
        my $module = join '::' => @file_parts;

        $out{$module} //= $file;
    }

    return \%out;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util - General utiliy functions.

=head1 DESCRIPTION

A grab-bag of general-purpose utility functions used across Test2::Harness2.

=head1 METHODS

=head2 MISC

=over 4

=item apply_encoding($fh, $enc)

Apply the specified encoding to the filehandle.

B<Justification>:
L<PERLBUG 31923|https://rt.perl.org/Public/Bug/Display.html?id=31923>
If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
order to avoid the thread segfault.

This is a reusable implementation of this:

    sub apply_encoding {
        my ($fh, $enc) = @_;
        return unless $enc;
        return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
        binmode($fh, ":encoding($enc)");
    }

=item $clean = clean_path($path)

Take a file path and clean it up to a minimal absolute path if possible. Always
returns a path, but if it cannot be cleaned up it is unchanged.

=item ($sock, $errno) = connect_unix_nb($path, $timeout)

Bounded, non-blocking connect to the unix-domain socket at C<$path>. The shared
connect primitive behind discovery liveness probing and the runner dialers
(C<Runner::Client> / C<Runner::Subscriber>): a plain blocking connect to a
C<SOCK_STREAM> unix socket blocks in the kernel once the listener's accept backlog
is full (a bound-but-wedged runner), so it can never honor a connect timeout --
this does C<connect> E<rarr> C<EINPROGRESS> E<rarr> select-for-writable with a
deadline E<rarr> C<getsockopt(SO_ERROR)> instead.

On success returns C<($sock, 0)> with a connected socket left B<non-blocking> (the
caller wraps it / sets blocking mode). On failure returns C<(undef, $errno)> with
the numeric errno at the failing syscall -- C<EINPROGRESS> when the connect was
still pending at the C<$timeout> deadline (a live listen fd whose accept loop is
wedged / backlog full), C<EINTR> when interrupted past its internal retries, or
C<0> when C<$path> could not be packed into a C<sockaddr_un>.

=item $hashref = find_libraries($search)

=item $hashref = find_libraries($search, @paths)

C<@INC> is used if no C<@paths> are provided.

C<$search> should be a module name with C<*> wildcards replacing sections.

    find_libraries('Foo::*::Baz')
    find_libraries('*::Bar::Baz')
    find_libraries('Foo::Bar::*')

These all look for modules matching the search, this is a good way to find
plugins, or similar patterns.

The result is a hashref of C<< { $module => $path } >>. If a module exists in
more than 1 search path the first is used.

=item $mod = fqmod($prefix, $mod)

This will automatically add C<$prefix> to C<$mod> with C<'::'> to join them. If
C<$mod> starts with the C<'+'> character the character will be removed and the
result returned without prepending C<$prefix>.

=item hub_truth

This is an internal implementation detail, do not use it.

=item $reporter = socket_reporter($identity, $socket)

=item $reporter = socket_reporter($identity, $socket, %params)

Build the L<Test2::Collector::Recorder::Socket> that streams a collector's
transitions to the runner's C<runner.socket>. C<$identity> is the preamble
identity name (for example C<"collector:job:$id">), and C<$socket> is the path to
C<runner.socket>.

Returns C<undef> when C<$socket> is unset, is not a socket, or the connection
cannot be made -- callers fall back to the file recorder so a missing or
not-yet-accepting socket only costs the reporter, never the events file.

The reporter identifies first (preamble) like every connection and always sets
C<no_reply> so the runner does not echo its identity back: the echo is noise to a
reporter, and writing it back to a busy collector can stall the runner's
single-threaded loop under load. It still drains and discards any input
defensively. Its preamble carries C<< pid => $$ >> so the reporter process's real
pid is part of the identity handshake.

C<%params> may carry:

=over 4

=item identity => \%extra

Extra identity fields folded into the preamble alongside C<name>/C<pid> (a test
collector adds C<job_id>, C<job_try>, and C<run_id> so the runner can map the
connection -- and its EOF -- back to the job).

=item read_control => 1

Build the connection bidirectional so the collector reads the runner's inbound
terminate control (the bail/abort message), which the runner sends with
C<send_control>. This is orthogonal to C<no_reply> (which suppresses only the
runner's identity echo): a C<read_control> reporter still sets C<no_reply>.

=back

=item $hashref = parse_exit($?)

This parses the exit value as typically stored in C<$?>.

Resulting hash:

    {
        sig => ($? & 127), # Signal value if the exit was caused by a signal
        err => ($? >> 8),  # Actual exit code, if any.
        dmp => ($? & 128), # Was there a core dump?
        all => $?,         # Original exit value, unchanged
    }


=item @list = process_includes(%PARAMS)

This method will build up a list of include dirs fit for C<@INC>. The returned
list should contain only unique values, in proper order.

Params:

=over 4

=item list => \@START

Paths to start the new list.

Optional.

=item ch_dir => $path

Prefix to prepend to all paths in the C<list> param. No effect without an
initial list.

=item include_current => $bool

This will add all paths from C<@INC> to the output, after the initial list.
Note that '.', if in C<@INC> will be moved to the end of the final output.

=item clean => $bool

If included all paths except C<'.'> will be cleaned using C<clean_path()>.

=item include_dot => $bool

If true C<'.'> will be appended to the end of the output.

B<Note> even if this is set to false C<'.'> may still be included if it was in
the initial list, or if it was in C<@INC> and C<@INC> was included using the
C<include_current> parameter.

=back

=back

=head2 FOR DEALING WITH MODULE <-> FILE CONVERSION

These convert between module names like C<Foo::Bar> and filenames like
C<Foo/Bar.pm>.

=over 4

=item $file = mod2file($mod)

=item $mod = file2mod($file)

=back

=head2 FOR READING/WRITING FILES

=over 4

=item $fh = open_file($path, $mode)

=item $fh = open_file($path)

If no mode is provided C<< '<' >> is assumed.

This will open the file at C<$path> and return a filehandle.

An exception will be thrown if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $text = read_file($file)

This will open the file at C<$path> and return all its contents.

An exception will be thrown if the file cannot be opened.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $fh = maybe_open_file($path)

=item $fh = maybe_open_file($path, $mode)

If no mode is provided C<< '<' >> is assumed.

This will open the file at C<$path> and return a filehandle.

C<undef> is returned when the file does not exist, or vanishes in the race
between the decision to open it and the open itself (C<ENOENT>/C<ESTALE>) -- so a
teardown-racing poller whose file is unlinked mid-open degrades gracefully rather
than dying. Opening a directory/device likewise returns C<undef>. Any other
failure (for example C<EACCES>, C<EMFILE>) throws an exception.

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item $text = maybe_read_file($path)

This will open the file at C<$path> and return all its contents.

This will return C<undef> when the file does not exist or vanishes in the race
(C<ENOENT>/C<ESTALE>); any other open failure throws an exception (same contract
as C<maybe_open_file>, on which it is built).

B<NOTE:> This will automatically use L<IO::Uncompress::Bunzip2> or
L<IO::Uncompress::Gunzip> to uncompress the file if it has a .bz2 or .gz
extension.

=item @content = write_file($path, @content)

Write content to the specified file. This will open the file with mode
C<< '>' >>, write the content, then close the file.

An exception will be thrown if any part fails.

=item @content = write_file_atomic($path, @content)

This will open a temporary file, write the content, close the file, then rename
the file to the desired C<$path>. This is essentially an atomic write in that
C<$file> will not exist until all content is written, preventing other
processes from doing a partial read while C<@content> is being written.

=item $link = write_link_atomic($target, $link)

Publish a symlink at C<$link> pointing at C<$target>, atomically. This creates the
symlink under a per-pid temporary name and then C<rename(2)>s it onto C<$link>, so
a concurrent reader always observes either the previous target or the new one --
never a missing or half-published link. The sibling of L</write_file_atomic> for
the persistent-runner discovery symlink.

Refuses (croaks) to clobber a path that exists and is B<not> a symlink (mirroring
C<open_unix_listen>'s refusal of a non-socket); an existing symlink at C<$link> is
replaced by the atomic rename.

=item $link = publish_discovery_link($target, $link)

Publish the persistent-runner discovery symlink (via L</write_link_atomic>) while
holding the shared C<"$link.lock"> exclusive lock, so the publish serializes against
a concurrent discovery-side cleaner (which takes the same lock before it unlinks a
link it probed as dead). The lock is best-effort with a short bounded wait: if it
cannot be acquired in time the link is published anyway (a squatted lockfile must
never keep a live runner from becoming discoverable -- the fail-safe side is a
racing cleaner skipping its clean, never a lost runner).

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
