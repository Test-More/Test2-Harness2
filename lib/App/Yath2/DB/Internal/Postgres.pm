package App::Yath2::DB::Internal::Postgres;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'App::Yath2::DB::Internal';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase;

# PostgreSQL-backed Log backend. Inherits the bulk of its behavior
# from App::Yath2::DB::Internal; this class only fills in flavor-specific
# bits:
#
#   - DSN / DBH construction (dsn => ... | dbh => ...).
#   - Schema bootstrap from share/schema/postgres.sql.
#   - UUID codec: pass-through (native UUID type), but Postgres returns
#     uuids lowercase so we case-fold to uppercase for consistency with
#     the gen_uuid() output.
#   - JSON codec: text in / text out (DBD::Pg can also bind JSON
#     directly, but text round-trips fine and matches what the rest of
#     the backends do).
#   - Payload compression default = 0 (server-side TOAST LZ4 on PG14+).
#   - last_insert_id via DBD::Pg's GENERATED ALWAYS AS IDENTITY hook.

sub init {
    my $self = shift;

    croak "Postgres backend requires one of: dbh, dsn"
        unless defined $self->{App::Yath2::DB::Internal::DBH}
        || defined $self->{App::Yath2::DB::Internal::DSN};

    # Connect (lazily; bootstrap will use $self->dbh).
    $self->dbh;

    $self->bootstrap_schema;
    $self->_resolve_archive(missing_ok => 1);

    return;
}

sub schema_flavor { 'postgres' }

# schema_file resolution comes from App::Yath2::Role::DB::Backend.

sub _connect_dbh {
    my $self = shift;

    my $ok = eval { require DBI; require DBD::Pg; 1 };
    my $err = $@;
    croak "install DBD::Pg to use the Postgres backend: $err" unless $ok;

    my $dsn   = $self->{App::Yath2::DB::Internal::DSN};
    my $user  = $self->{App::Yath2::DB::Internal::USER};
    my $pass  = $self->{App::Yath2::DB::Internal::PASS};
    my $attrs = $self->{App::Yath2::DB::Internal::ATTRS} || {};

    croak "no dsn provided" unless defined $dsn;

    my $dbh = DBI->connect($dsn, $user, $pass, {
        RaiseError     => 1,
        PrintError     => 0,
        AutoCommit     => 1,
        pg_enable_utf8 => 1,
        %$attrs,
    }) or croak "DBI->connect $dsn: $DBI::errstr";

    return $dbh;
}

# Probe which TOAST compression algorithm the server supports. Returns
# one of: 'zstd' (PG15+ built --with-zstd), 'lz4' (PG14+ built
# --with-lz4), or undef (older PG, or build without those algos -- fall
# back to server default, typically pglz). Result cached per-instance.
#
# Probe mechanism: setting the default_toast_compression GUC to a value
# the server doesn't recognise raises an error. The GUC itself was added
# in PG14, so PG13 and older fail every probe and land in the undef
# branch (correct -- the per-column COMPRESSION clause didn't exist
# before PG14 either, so we strip it).
sub _server_compression {
    my $self = shift;
    return $self->{_server_compression} //= do {
        my $dbh = $self->dbh;
        my $probe = sub {
            my ($algo) = @_;
            return eval {
                local $dbh->{RaiseError} = 1;
                local $dbh->{PrintError} = 0;
                $dbh->do(qq{SET default_toast_compression = '$algo'});
                $dbh->do(q{RESET default_toast_compression});
                1;
            };
        };
        $probe->('zstd') ? 'zstd' : $probe->('lz4') ? 'lz4' : undef;
    };
}

# share/schema/postgres.sql defaults to `COMPRESSION zstd`. Rewrite to
# match what the server actually supports:
#   * zstd available -> leave as-is
#   * lz4 available  -> rewrite zstd -> lz4
#   * neither (PG13- or unsupported build) -> strip the clause; the
#     server uses default_toast_compression (pglz on stock builds).
# App-level `compressed=FALSE` semantics are unchanged in every case --
# the server still TOAST-compresses, just with a different algorithm.
#
# Hook name comes from App::Yath2::Role::DB::Backend (no leading
# underscore); bootstrap_schema in the role calls preprocess_schema_sql.
sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    my $algo = $self->_server_compression;
    if (!defined $algo) {
        $sql =~ s/\s+COMPRESSION\s+zstd\b//gi;
    }
    elsif ($algo ne 'zstd') {
        $sql =~ s/(\bCOMPRESSION\s+)zstd\b/$1$algo/gi;
    }
    return $sql;
}

# Postgres' native UUID type returns lowercase. The codebase uses
# gen_uuid() which produces uppercase. Normalize both directions to
# uppercase so equality checks against externally-supplied uuids work.
sub _uuid_to_db   { defined $_[1] ? uc($_[1]) : undef }
sub _uuid_from_db { defined $_[1] ? uc($_[1]) : undef }

# JSONB column: bind as text, fetch as text. encode_json is utf8-bytes
# so it round-trips through the wire without surprise.
sub _json_encode { defined $_[1] ? encode_json($_[1]) : undef }
sub _json_decode {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return decode_json($val);
}

# Postgres BYTEA: the server provides TOAST LZ4 compression (per
# share/schema/postgres.sql `payload BYTEA COMPRESSION lz4`), so the
# application stores bytes verbatim.
sub _payload_compressed_default { 0 }

# DBD::Pg requires explicit BYTEA binding for binary payloads; a plain
# bind otherwise tries to interpret arbitrary bytes as UTF-8 text.
sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    require DBD::Pg;
    $sth->bind_param($idx, $bytes, { pg_type => DBD::Pg::PG_BYTEA() });
    return;
}

# DBD::Pg's last_insert_id: BIGINT GENERATED ALWAYS AS IDENTITY auto-
# names its sequence <table>_<col>_seq; passing the table alone is
# sufficient.
sub _last_insert_id {
    my ($self, $dbh, $table, $col) = @_;
    return $dbh->last_insert_id(undef, undef, $table, undef);
}

# Format DateTime for Postgres TIMESTAMPTZ via DateTime::Format::Pg.
# The base class's _to_datetime / _normalize_timestamp / _iso_to_db_datetime
# / _db_datetime_to_iso all funnel through this.
sub _format_datetime {
    my ($self, $dt) = @_;
    return undef unless defined $dt;
    require DateTime::Format::Pg;
    return DateTime::Format::Pg->format_datetime($dt);
}

# Postgres TIMESTAMPTZ on fetch stringifies as 'YYYY-MM-DD HH:MM:SS+00'.
# Use DateTime::Format::Pg to parse back to a DateTime, then ISO format
# via the base class default. Falls back to the inherited regex-based
# pass-through when the value isn't recognisable.
sub _to_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val && eval { $val->isa('DateTime') };
    if (!ref $val && $val =~ /\A\d{4}-\d{2}-\d{2}\s/) {
        require DateTime::Format::Pg;
        my $dt = eval { DateTime::Format::Pg->parse_datetime($val) };
        return $dt if defined $dt;
    }
    return $self->SUPER::_to_datetime($val);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Internal::Postgres - PostgreSQL-backed Log reader / writer.

=head1 SYNOPSIS

    my $log = App::Yath2::DB::Internal::Postgres->new(dsn => 'dbi:Pg:dbname=yath');
    # OR
    my $log = App::Yath2::DB::Internal::Postgres->new(dbh => $dbh, uuid => $u);

    while (my $event = $log->event(0)) {
        ...;
        last if $log->EOE;
    }

    my $a = $log->artifacts(0, 0);
    my $events_iter = $a->events_iter;

=head1 DESCRIPTION

PostgreSQL-backed Log backend (PostgreSQL >= 14, for column-level
TOAST LZ4 compression). Subclasses L<App::Yath2::DB::Internal> and provides
only the Postgres-specific bits: connection setup, native C<UUID>
column storage, C<JSONB> JSON columns, and BYTEA payloads with
server-side LZ4 compression (so the app stores raw bytes and never
client-zstd-compresses).

C<DBD::Pg> is loaded lazily on first connection — Test2::Harness2 has
no compile-time dependency on it. Calling the constructor without
C<DBD::Pg> installed throws a clear error.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
