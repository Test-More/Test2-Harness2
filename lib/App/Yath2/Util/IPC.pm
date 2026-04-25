package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use File::Spec();
use IPC::Manager::Serializer::JSON();
use Fcntl qw/O_WRONLY O_CREAT O_EXCL/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    resolve_ipc_filename
    resolve_ipc_dir
    write_ipc_file read_ipc_file unlink_ipc_file
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
    if ($sym eq 'cwd') {
        return $settings->yath->cwd;
    }
    if ($sym eq 'tempdir') {
        return File::Spec->tmpdir();
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

    my $pend = "${path}.pend";

    sysopen(my $fh, $pend, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or croak "open '$pend' for write: $!";

    my $json = IPC::Manager::Serializer::JSON->serialize($data);
    print {$fh} $json;
    close $fh or croak "close '$pend': $!";

    rename($pend, $path) or do {
        my $err = $!;
        unlink $pend;
        croak "rename '$pend' to '$path': $err";
    };

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

    if (defined $expect_pid && $$ != $expect_pid) {
        # Different process (most likely a forked child) is trying to
        # clean up a file the parent registered. Skip.
        return;
    }

    unlink $path or warn "unlink '$path': $!";
    return;
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
