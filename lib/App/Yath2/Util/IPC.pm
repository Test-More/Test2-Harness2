package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use File::Spec();

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    resolve_ipc_filename
    resolve_ipc_dir
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

1;

__END__

=pod

=head1 NAME

App::Yath2::Util::IPC - IPC info file helpers

=head1 DESCRIPTION

Helpers for writing, reading, and discovering yath IPC info files.

See C<docs/superpowers/specs/2026-04-25-ipc-info-file-design.md>.

=cut
