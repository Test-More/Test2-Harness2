package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

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
};

my %VALID_TYPE = (nonce => 1, persistent => 1);

sub resolve_ipc_filename {
    my %p = @_;

    my $type = $p{type} // croak "'type' is required";
    croak "Unknown type '$type'" unless $VALID_TYPE{$type};

    my $pid     = $p{pid}     // croak "'pid' is required";
    my $uuid    = $p{uuid}    // croak "'uuid' is required";
    my $tempdir = $p{tempdir} // 0;

    my $disambig;
    if ($tempdir) {
        $disambig = $p{user} // croak "'user' is required for tempdir filename";
        return "yath-${type}-${disambig}-${pid}-${uuid}";
    }

    $disambig = $p{host} // croak "'host' is required for non-tempdir filename";
    return ".yath-${type}-${disambig}-${pid}-${uuid}";
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
    return File::Spec->tmpdir() if $sym eq 'tempdir';

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
# workdir + type, and the helper resolves where to write the IPC info
# file, builds the JSON payload, and writes it atomically with
# owner-only perms. Returns the on-disk path so the caller can
# register a cleanup guard against it. Both `yath test` (type
# 'nonce') and the future `yath start` (type 'persistent') share this
# code path.
sub publish_ipc_file {
    my %p = @_;

    my $type     = $p{type}     // croak "'type' is required";
    my $settings = $p{settings} // croak "'settings' is required";
    my $spawn    = $p{spawn}    // croak "'spawn' is required";
    my $workdir  = $p{workdir}  // croak "'workdir' is required";

    croak "Unknown type '$type'" unless $VALID_TYPE{$type};

    my $host = hostname();
    my $user = $ENV{USER} // (getpwuid($<))[0] // 'unknown';
    my $uuid = $settings->yath->instance_uuid;

    my $path;
    if (my $explicit = $settings->ipc->file) {
        $path = $explicit;
    }
    else {
        my ($dir, $is_tmp) = resolve_ipc_dir($settings);
        my $name = resolve_ipc_filename(
            type    => $type,
            host    => $host,
            user    => $user,
            pid     => $spawn->pid,
            uuid    => $uuid,
            tempdir => $is_tmp,
        );
        $path = File::Spec->catfile($dir, $name);
    }

    write_ipc_file(
        $path,
        {
            yath_version => $App::Yath2::VERSION,
            type         => $type,
            hostname     => $host,
            user         => $user,
            # pid: harness service pid (not $$ writer); used by
            # find_ipc_files for liveness checks.
            pid          => $spawn->pid,
            uuid         => $uuid,
            created_at   => time(),
            workdir      => $workdir,
            project      => $settings->yath->base_dir,
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
    \.?yath
    -(?<type>nonce|persistent)
    -(?<disambig>.+)
    -(?<pid>\d+)
    -(?<uuid>[0-9a-f]{8})
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

    # May not want any specific type.
    my $want_types = $p{type} ? {map { ($_ => 1) } (ref($p{type}) ? @{$p{type}} : $p{type})} : undef;

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

            next if $want_types && !$want_types->{$rec->{type} // ''};
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

1;

__END__

=pod

=head1 NAME

App::Yath2::Util::IPC - IPC info file helpers

=head1 DESCRIPTION

Helpers for writing, reading, and discovering yath IPC info files.

See C<docs/superpowers/specs/2026-04-25-ipc-info-file-design.md>.

=cut
