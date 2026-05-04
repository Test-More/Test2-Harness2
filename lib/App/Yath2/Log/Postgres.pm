package App::Yath2::Log::Postgres;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath2::Log::DB';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase;

# PostgreSQL-backed Log backend. Inherits the bulk of its behavior
# from App::Yath2::Log::DB; this class only fills in flavor-specific
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
        unless defined $self->{App::Yath2::Log::DB::DBH}
        || defined $self->{App::Yath2::Log::DB::DSN};

    # Connect (lazily; bootstrap will use $self->dbh).
    $self->dbh;

    $self->bootstrap_schema;
    $self->_resolve_archive(missing_ok => 1);

    return;
}

sub schema_flavor { 'postgres' }

sub schema_file {
    my $self = shift;
    my $dev = _dev_schema_path('postgres');
    return $dev if defined $dev && -e $dev;

    require File::ShareDir;
    my $share = eval { File::ShareDir::dist_dir('Test2-Harness2') };
    if ($share && -e "$share/schema/postgres.sql") {
        return "$share/schema/postgres.sql";
    }
    croak "could not locate schema file for postgres";
}

sub _dev_schema_path {
    my ($flavor) = @_;
    my $here = __FILE__;
    my $dir = $here;
    for (1 .. 10) {
        $dir = dirname($dir);
        my $candidate = File::Spec->catfile($dir, 'share', 'schema', "$flavor.sql");
        return $candidate if -e $candidate;
        last if $dir eq '/' || $dir eq '.';
    }
    return undef;
}

sub _connect_dbh {
    my $self = shift;

    my $ok = eval { require DBI; require DBD::Pg; 1 };
    my $err = $@;
    croak "install DBD::Pg to use the Postgres backend: $err" unless $ok;

    my $dsn   = $self->{App::Yath2::Log::DB::DSN};
    my $user  = $self->{App::Yath2::Log::DB::USER};
    my $pass  = $self->{App::Yath2::Log::DB::PASS};
    my $attrs = $self->{App::Yath2::Log::DB::ATTRS} || {};

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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Postgres - PostgreSQL-backed Log reader / writer.

=head1 SYNOPSIS

    my $log = App::Yath2::Log::Postgres->new(dsn => 'dbi:Pg:dbname=yath');
    # OR
    my $log = App::Yath2::Log::Postgres->new(dbh => $dbh, uuid => $u);

    while (my $event = $log->event(0)) {
        ...;
        last if $log->EOE;
    }

    my $a = $log->artifacts(0, 0);
    my $events_iter = $a->events_iter;

=head1 DESCRIPTION

PostgreSQL-backed Log backend (PostgreSQL >= 14, for column-level
TOAST LZ4 compression). Subclasses L<App::Yath2::Log::DB> and provides
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
