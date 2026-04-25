package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    resolve_ipc_filename
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

1;

__END__

=pod

=head1 NAME

App::Yath2::Util::IPC - IPC info file helpers

=head1 DESCRIPTION

Helpers for writing, reading, and discovering yath IPC info files.

See C<docs/superpowers/specs/2026-04-25-ipc-info-file-design.md>.

=cut
