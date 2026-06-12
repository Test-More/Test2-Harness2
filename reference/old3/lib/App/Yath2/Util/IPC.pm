package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use POSIX qw/strftime/;

use App::Yath2();
use File::Spec();
use IPC::Manager::Serializer::JSON();
use Sys::Hostname qw/hostname/;
use Test2::Harness2::Util qw/write_file_atomic_mode/;
use Test2::Harness2::Util::IPC qw/pid_is_running/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    resolve_ipc_filename
    resolve_ipc_dir
    write_ipc_file read_ipc_file unlink_ipc_file
    find_ipc_files
    publish_ipc_file
    resolve_dir_order_paths
    discover_daemons
    assert_daemon_alive
};

# IPC info filename:
#   ${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json
#
# Sortable by stamp; pid disambiguates concurrent same-command runs
# in the same project; the trailing -yath-${pid}-ipc.json segment is
# the regex anchor used by find_ipc_files when scanning a directory.
sub resolve_ipc_filename {
    my %p = @_;

    my $project = $p{project} // croak "'project' is required";
    my $user    = $p{user}    // croak "'user' is required";
    my $command = $p{command} // croak "'command' is required";
    my $stamp   = $p{stamp}   // croak "'stamp' is required";
    my $pid     = $p{pid}     // croak "'pid' is required";

    return "${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json";
}

sub _writable_dir {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    return undef unless -d $d      && -w _;
    return $d;
}

sub _dir_for_symbol {
    my ($sym, $settings) = @_;

    return $settings->yath->cwd if $sym eq 'cwd';

    # 'tempdir' means the *system* tempdir, captured by App::Yath::Script
    # before yath swapped TMPDIR for a per-invocation workdir. Without
    # orig_tmp, File::Spec->tmpdir() in-process returns that workdir-
    # scoped tmp, so each invocation publishes/discovers in a different
    # dir and `yath run` can never find a `yath start` daemon.
    if ($sym eq 'tempdir') {
        my $orig = eval { $settings->yath->orig_tmp };
        return $orig if defined $orig && length $orig;
        return File::Spec->tmpdir();
    }

    if ($sym eq 'user_rc') {
        my $f = $settings->yath->user_config_file or return undef;
        my ($vol, $dirs) = File::Spec->splitpath($f);
        return File::Spec->catdir(File::Spec->splitdir($dirs));
    }

    if ($sym eq 'project_rc') {
        my $f = $settings->yath->config_file or return undef;
        my ($vol, $dirs) = File::Spec->splitpath($f);
        return File::Spec->catdir(File::Spec->splitdir($dirs));
    }

    # Raw path. Caller's responsibility to make sense of it.
    return $sym;
}

sub resolve_ipc_dir {
    my ($settings) = @_;

    my $ipc = $settings->ipc;

    if (my $d = _writable_dir($ipc->dir)) {
        return ($d, 0);
    }

    my $order = $ipc->dir_order || [];
    for my $sym (@$order) {
        my $d = _dir_for_symbol($sym, $settings);
        next unless defined $d;
        next unless _writable_dir($d);
        return ($d, ($sym eq 'tempdir' ? 1 : 0));
    }

    croak "no writable IPC directory found in resolution chain";
}

sub write_ipc_file {
    my ($path, $data) = @_;
    croak "'path' required" unless defined $path && length $path;
    croak "'data' required" unless ref $data eq 'HASH';

    my $json = IPC::Manager::Serializer::JSON->serialize($data);

    # 0600: only the user who ran yath may read or write the file. The
    # ipcm_info string inside is sufficient to dial the harness's IPC
    # bus, so non-owner read access is a credential leak.
    write_file_atomic_mode($path, 0600, $json);

    return $path;
}

# publish_ipc_file is the producer-side entry point: a yath command
# that has just spawned a harness service hands settings + spawn +
# workdir + command, and the helper resolves where to write the IPC
# info file, builds the JSON payload, and writes it atomically with
# owner-only perms. Returns the on-disk path so the caller can
# register a cleanup guard against it.
sub publish_ipc_file {
    my %p = @_;

    my $command  = $p{command}  // croak "'command' is required";
    my $settings = $p{settings} // croak "'settings' is required";
    my $spawn    = $p{spawn}    // croak "'spawn' is required";
    my $workdir  = $p{workdir}  // croak "'workdir' is required";

    my $host    = hostname();
    my $user    = $settings->yath->user // $ENV{USER} // (getpwuid($<))[0] // 'unknown';
    my $project = $settings->yath->project // '__UNKNOWN__';
    my $uuid    = $settings->yath->instance_uuid;
    my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);

    my $path;
    if (my $explicit = $settings->ipc->file) {
        $path = $explicit;
    }
    else {
        my ($dir) = resolve_ipc_dir($settings);
        my $name  = resolve_ipc_filename(
            project => $project,
            user    => $user,
            command => $command,
            stamp   => $stamp,
            pid     => $spawn->pid,
        );
        $path = File::Spec->catfile($dir, $name);
    }

    write_ipc_file(
        $path,
        {
            yath_version => $App::Yath2::VERSION,
            command      => $command,
            hostname     => $host,
            user         => $user,
            project      => $project,
            stamp        => $stamp,
            # pid: harness service pid (not $$ writer); used by
            # find_ipc_files for liveness checks.
            pid          => $spawn->pid,
            uuid         => $uuid,
            created_at   => time(),
            workdir      => $workdir,
            ipcm_info    => $spawn->ipcm_info,
        },
    );

    return $path;
}

sub read_ipc_file {
    my ($path) = @_;
    croak "'path' required" unless defined $path && length $path;

    open(my $fh, '<', $path) or croak "open '$path' for read: $!";
    local $/;
    my $body = <$fh>;
    close $fh or croak "close '$path': $!";

    return IPC::Manager::Serializer::JSON->deserialize($body);
}

sub unlink_ipc_file {
    my ($path, $expect_pid) = @_;
    return unless defined $path && length $path;
    return unless -e $path;

    if (@_ >= 2 && defined $expect_pid && $$ != $expect_pid) {
        # Different process (most likely a forked child) is trying to
        # clean up a file the parent registered. Skip.
        return;
    }

    unlink $path or warn "unlink '$path': $!";
    return;
}

my $FILENAME_RX = qr{
    \A
    (?<project>[^/]+?)
    -(?<user>[^-]+?)
    -(?<command>[^-]+?)
    -(?<stamp>\d{8}-\d{6})
    -yath
    -(?<pid>\d+)
    -ipc\.json
    \z
}x;

sub _scan_dir {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @hits;
    while (defined(my $entry = readdir($dh))) {
        next unless $entry =~ $FILENAME_RX;
        push @hits => File::Spec->catfile($dir, $entry);
    }
    closedir $dh;
    return @hits;
}

sub find_ipc_files {
    my %p = @_;

    my $dirs = $p{dirs}
        or croak "'dirs' is required (caller should pass resolve_ipc_dir result or override)";

    my $self_host = hostname();

    # may be undef on purpose -> no host filter
    my $want_host = exists $p{host} ? $p{host} : $self_host;

    # Filter by command name (e.g. 'test', 'start'). Pass either a
    # scalar or arrayref. undef = no command filter.
    my $want_cmds = $p{command}
        ? {map { ($_ => 1) } (ref($p{command}) ? @{$p{command}} : $p{command})}
        : undef;

    my $live = exists $p{live} ? $p{live} : 1;

    my @records;
    for my $dir (@$dirs) {
        for my $path (_scan_dir($dir)) {
            my $rec;
            my $ok  = eval { $rec = read_ipc_file($path); 1 };
            my $err = $@;
            unless ($ok) {
                # Unreadable / corrupt entry. Leave it on disk for an
                # operator to investigate; we do not unlink here, only
                # liveness cleanup is automatic. Warn so the anomaly is
                # not invisible.
                warn "skipping unreadable IPC info file '$path': $err";
                next;
            }

            $rec->{_path} = $path;
            $rec->{hostname} //= '';

            next if $want_cmds && !$want_cmds->{$rec->{command} // ''};
            next if defined($want_host) && $rec->{hostname} ne $want_host;

            if ($live && $rec->{hostname} eq $self_host) {
                unless (pid_is_running($rec->{pid})) {
                    unlink_ipc_file($path);    # no pid arg = unconditional
                    next;
                }
            }

            push @records => $rec;
        }
    }

    @records = sort { ($b->{created_at} // 0) <=> ($a->{created_at} // 0) } @records;
    return \@records;
}

# Translate the --ipc-dir-order symbol list into concrete directories.
# Mirrors _dir_for_symbol but materialises the full ordered list for
# scan-style consumers (auto-discovery).
sub resolve_dir_order_paths {
    my ($settings, $order) = @_;
    my @dirs;
    for my $sym (@$order) {
        my $d = _dir_for_symbol($sym, $settings);
        push @dirs => $d if defined $d && length $d;
    }
    return @dirs;
}

# discover_daemons: shared resolution for `yath run`, `yath stop`,
# `yath kill`, `yath status`, `yath list`.
#
# Returns either an arrayref of IPC info records or a single record
# (when count='one'), or dies with a user-readable message.
#
# Options:
#   settings    (required) the parsed Getopt::Yath settings
#   workdir     optional workdir to scan
#   ipc_file    optional explicit IPC file
#   command     optional 'start' (default) or 'any' or arrayref of names
#   count       'one'  -> error on 0/many, return single record
#               'all'  -> always return arrayref (may be empty)
#               'any'  -> like 'one' but accepts --latest/--all in opts
#   latest      when true, pick newest when count='any' and >1 match
#   all         when true, return arrayref of every match (count='any')
sub discover_daemons {
    my %p = @_;

    my $settings = $p{settings} or croak "'settings' is required";
    my $count    = $p{count} // 'one';

    if (my $explicit = _discover_by_explicit_ipc_file(\%p, $settings, $count)) {
        return $explicit;
    }

    if ($p{workdir}) {
        return _discover_by_workdir(\%p, $settings, $count);
    }

    return _discover_by_auto(\%p, $settings, $count);
}

sub _discover_by_explicit_ipc_file {
    my ($p, $settings, $count) = @_;

    my $f = $p->{ipc_file} // eval { $settings->ipc->file };
    return undef unless $f;

    my $rec = read_ipc_file($f);
    $rec->{_path} = $f;
    return $count eq 'all' ? [$rec] : $rec;
}

sub _discover_by_workdir {
    my ($p, $settings, $count) = @_;
    my $wd = $p->{workdir};

    my @dirs;
    push @dirs => "$wd/tmp" if -d "$wd/tmp";
    push @dirs => $wd       if -d $wd;
    my ($sys_tmp) = resolve_ipc_dir($settings);
    push @dirs => $sys_tmp if defined $sys_tmp;
    my $dir_order = $settings->ipc->dir_order || [];
    push @dirs => resolve_dir_order_paths($settings, $dir_order);
    my %seen;
    @dirs = grep { defined && length && !$seen{$_}++ && -d } @dirs;

    my $all_records = find_ipc_files(dirs => \@dirs);
    my @matching    = grep { ($_->{workdir} // '') eq $wd } @$all_records;

    croak "no IPC info file matching workdir '$wd' (is the daemon running?)\n"
        unless @matching;
    croak "multiple IPC info files for workdir '$wd'; pass --ipc-file PATH to disambiguate\n"
        if @matching > 1 && $count eq 'one';

    return $count eq 'all' ? \@matching : $matching[0];
}

sub _discover_by_auto {
    my ($p, $settings, $count) = @_;

    my $records    = _scan_ipc_records($p, $settings);
    my @candidates = _filter_by_project_user($p, $settings, $records);

    return \@candidates if $count eq 'all' || $p->{all};

    croak "No running yath daemon found. Run `yath start` or pass --workdir DIR / --ipc-file PATH.\n"
        unless @candidates;

    if (@candidates > 1 && !$p->{latest}) {
        my $list = join "", map { "  $_->{_path}  (pid $_->{pid})\n" } @candidates;
        croak "Multiple running yath daemons matched; pass --latest, --workdir, or --ipc-file:\n$list";
    }

    return $candidates[0];
}

sub _scan_ipc_records {
    my ($p, $settings) = @_;

    my ($primary_dir) = resolve_ipc_dir($settings);
    my $dir_order = $settings->ipc->dir_order || [];
    my @dirs = ($primary_dir, resolve_dir_order_paths($settings, $dir_order));
    my %seen;
    @dirs = grep { defined && length && !$seen{$_}++ && -d } @dirs;

    my $cmd_filter = $p->{command} // 'start';
    my $cmd_arg    = $cmd_filter eq 'any' ? undef : $cmd_filter;

    return find_ipc_files(
        dirs => \@dirs,
        (defined $cmd_arg ? (command => $cmd_arg) : ()),
    );
}

sub _filter_by_project_user {
    my ($p, $settings, $records) = @_;

    # project/user override: pass an explicit value to filter on it,
    # pass '' to skip the filter entirely. Defaults to this settings's
    # project + user.
    my $project = exists $p->{project}
        ? $p->{project}
        : ($settings->yath->project // '');
    my $user = exists $p->{user}
        ? $p->{user}
        : ($settings->yath->user // $ENV{USER} // (getpwuid($<))[0] // '');

    return grep {
        (!defined($project) || $project eq '' || ($_->{project} // '') eq $project)
            && (!defined($user) || $user eq '' || ($_->{user} // '') eq $user)
    } @$records;
}

# Validate that an IPC info record points at a live harness pid.
# Shared by run/status/etc. so the user sees one consistent
# stale-daemon diagnostic regardless of which command tripped it.
sub assert_daemon_alive {
    my ($info) = @_;
    my $path = $info->{_path} // '<unknown>';
    croak "IPC info file '$path' is missing the harness pid\n"
        unless defined $info->{pid};
    croak "harness pid $info->{pid} is no longer running (stale IPC info file '$path')\n"
        unless pid_is_running($info->{pid});
    return;
}

1;

__END__

=pod

=head1 NAME

App::Yath2::Util::IPC - IPC info file helpers

=head1 DESCRIPTION

Helpers for writing, reading, and discovering yath IPC info files.

=head1 METHODS

=over 4

=item $name = resolve_ipc_filename(project => ..., user => ..., command => ..., stamp => ..., pid => ...)

Build the C<${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json>
filename used for IPC info files. All arguments required.

=item ($dir, $is_tempdir) = resolve_ipc_dir($settings)

Pick the first writable directory from the settings' explicit
C<ipc->dir> or, failing that, the C<ipc->dir_order> symbol chain.
Returns the directory and a boolean flag indicating whether the
chosen entry was the system tempdir.

=item @paths = resolve_dir_order_paths($settings, \@symbols)

Materialise the full ordered list of directories implied by the
C<--ipc-dir-order> symbol list (C<cwd>, C<tempdir>, C<user_rc>,
C<project_rc>, or a raw path). Used by scan-style consumers.

=item $path = write_ipc_file($path, \%data)

Atomically serialise C<%data> as JSON and write it at C<$path> with
owner-only (0600) permissions.

=item $path = publish_ipc_file(command => ..., settings => ..., spawn => ..., workdir => ...)

Producer-side entry point used after a yath command spawns a harness
service. Resolves the on-disk path (explicit C<--ipc-file> wins),
builds the JSON payload from the supplied L<Test2::Harness2::Spawn>
handle, and writes it via L</write_ipc_file>. Returns the path so the
caller can register a cleanup guard.

=item \%data = read_ipc_file($path)

Slurp and JSON-decode an IPC info file. Croaks on I/O or parse error.

=item unlink_ipc_file($path, $expect_pid?)

Remove an IPC info file. When C<$expect_pid> is supplied, the unlink
is skipped unless the current process matches (prevents forked
children from cleaning up parent-owned guards).

=item \@records = find_ipc_files(dirs => \@dirs, command => ..., host => ..., live => 1)

Scan each directory for filenames matching the IPC info file regex,
read and filter the records (by command name, hostname, liveness),
prune stale entries whose pid is no longer running on the local
host, and return a list sorted newest-first by C<created_at>.

=item $record_or_arrayref = discover_daemons(settings => ..., %opts)

Shared resolution used by C<yath run> / C<stop> / C<kill> / C<status>
/ C<list>. Dispatches to one of the L</_discover_by_explicit_ipc_file>,
L</_discover_by_workdir>, or L</_discover_by_auto> helpers depending
on the option mix; honors C<count =E<gt> 'one'|'all'|'any'> and the
C<latest> / C<all> flags. Croaks with a user-readable message on
missing or ambiguous matches.

=item assert_daemon_alive(\%info)

Sanity-check an IPC info record: croak when its harness pid is
missing or no longer running. Used by every daemon-targeting command
so users see one consistent stale-daemon diagnostic.

=back

=head2 Private helpers

=over 4

=item _discover_by_explicit_ipc_file

Branch of L</discover_daemons> for an explicit C<--ipc-file> path or
the C<settings->ipc->file> setting.

=item _discover_by_workdir

Branch of L</discover_daemons> for the C<--workdir> case.

=item _discover_by_auto

Branch of L</discover_daemons> for the auto-discovery case (no
explicit file or workdir).

=item _scan_ipc_records

Collect IPC info records from the resolved primary directory plus
the C<--ipc-dir-order> chain, optionally filtered by command.

=item _filter_by_project_user

Filter a record list by project + user, defaulting both from settings
(pass an explicit value to override, pass C<''> to disable a filter).

=back

=cut
