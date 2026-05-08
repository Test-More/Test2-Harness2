package App::Yath2::Log::MariaDB;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'App::Yath2::Log::DB';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase;

# MariaDB-backed Log backend. Inherits the bulk of its behavior from
# App::Yath2::Log::DB; this class only fills in flavor-specific bits:
#
#   - DSN / DBH construction (dsn => ... | dbh => ...).
#   - Schema bootstrap from share/schema/mariadb.sql.
#   - UUID codec: pass-through (MariaDB >= 10.7 native UUID type), but
#     normalize to lowercase since MariaDB returns native UUIDs in
#     lowercase form.
#   - JSON codec: text in / text out (MariaDB JSON columns accept and
#     return JSON text).
#   - Payload compression default = 0 (server-side via PAGE_COMPRESSED=1
#     on the artifacts table; algorithm picked by the server-global
#     innodb_compression_algorithm).
#   - last_insert_id via the standard DBI::last_insert_id (auto-inc).
#
# Connection sets ANSI_QUOTES so the base-class SQL's double-quoted
# identifiers (e.g. "exit") work without backtick rewriting.

sub init {
    my $self = shift;

    croak "MariaDB backend requires one of: dbh, dsn"
        unless defined $self->{App::Yath2::Log::DB::DBH}
        || defined $self->{App::Yath2::Log::DB::DSN};

    $self->dbh;
    $self->_apply_session_state;
    $self->bootstrap_schema;
    $self->_resolve_archive(missing_ok => 1);

    return;
}

sub schema_flavor { 'mariadb' }

sub schema_file {
    my $self = shift;
    my $dev = _dev_schema_path('mariadb');
    return $dev if defined $dev && -e $dev;

    require File::ShareDir;
    my $share = eval { File::ShareDir::dist_dir('Test2-Harness2') };
    if ($share && -e "$share/schema/mariadb.sql") {
        return "$share/schema/mariadb.sql";
    }
    croak "could not locate schema file for mariadb";
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

    my $ok = eval { require DBI; require DBD::MariaDB; 1 };
    my $err = $@;
    croak "install DBD::MariaDB to use the MariaDB backend: $err" unless $ok;

    my $dsn   = $self->{App::Yath2::Log::DB::DSN};
    my $user  = $self->{App::Yath2::Log::DB::USER};
    my $pass  = $self->{App::Yath2::Log::DB::PASS};
    my $attrs = $self->{App::Yath2::Log::DB::ATTRS} || {};

    croak "no dsn provided" unless defined $dsn;

    my $dbh = DBI->connect($dsn, $user, $pass, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        %$attrs,
    }) or croak "DBI->connect $dsn: $DBI::errstr";

    return $dbh;
}

# Enable ANSI_QUOTES so double-quoted identifiers in shared SQL work
# without modification. Run on every fresh connection before bootstrap.
sub _apply_session_state {
    my $self = shift;
    my $dbh = $self->{App::Yath2::Log::DB::DBH} or return;
    $dbh->do(q{SET SESSION sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')});
    return;
}

# MariaDB's native UUID type lowercases on output. Normalize uppercase
# everywhere for parity with gen_uuid() and the other backends.
sub _uuid_to_db   { defined $_[1] ? uc($_[1]) : undef }
sub _uuid_from_db { defined $_[1] ? uc($_[1]) : undef }

sub _json_encode { defined $_[1] ? encode_json($_[1]) : undef }
sub _json_decode {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return decode_json($val);
}

# Server-side PAGE_COMPRESSED=1 on the artifacts table; app stores
# bytes verbatim.
sub _payload_compressed_default { 0 }

# DBD::MariaDB binds string values as text (mariadb_enable_utf8 is on
# by default). For LONGBLOB columns we must bind with SQL_BLOB so the
# server stores the raw bytes verbatim instead of UTF-8 re-encoding.
sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    require DBI;
    $sth->bind_param($idx, $bytes, DBI::SQL_BLOB());
    return;
}

# MariaDB DATETIME(6): accepts 'YYYY-MM-DD HH:MM:SS.fff'. The default
# _now_iso uses ISO 'T'/'Z' which MariaDB rejects.
sub _now_iso {
    my $self = shift;
    my $t  = Time::HiRes::time();
    my @lt = gmtime(int $t);
    my $frac = $t - int $t;
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d.%03d',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
        int($frac * 1000));
}

# Format DateTime for MariaDB DATETIME(6) via DateTime::Format::MySQL.
# The base class's _to_datetime / _normalize_timestamp / _iso_to_db_datetime
# / _db_datetime_to_iso all funnel through this.
sub _format_datetime {
    my ($self, $dt) = @_;
    return undef unless defined $dt;
    require DateTime::Format::MySQL;
    return DateTime::Format::MySQL->format_datetime($dt);
}

# Parse MariaDB DATETIME column values via DateTime::Format::MySQL.
sub _to_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val && eval { $val->isa('DateTime') };
    if (!ref $val && $val =~ /\A\d{4}-\d{2}-\d{2}\s/) {
        require DateTime::Format::MySQL;
        my $dt = eval { DateTime::Format::MySQL->parse_datetime($val) };
        return $dt if defined $dt;
    }
    return $self->SUPER::_to_datetime($val);
}

require Time::HiRes;

# DBI::last_insert_id with a table arg works for MariaDB AUTO_INCREMENT
# (DBD::MariaDB returns the LAST_INSERT_ID() value).
sub _last_insert_id {
    my ($self, $dbh, $table, $col) = @_;
    return $dbh->last_insert_id(undef, undef, $table, $col);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::MariaDB - MariaDB-backed Log reader / writer.

=head1 SYNOPSIS

    my $log = App::Yath2::Log::MariaDB->new(dsn => 'dbi:MariaDB:dbname=yath');
    # OR
    my $log = App::Yath2::Log::MariaDB->new(dbh => $dbh, uuid => $u);

    while (my $event = $log->event(0)) {
        ...;
        last if $log->EOE;
    }

    my $a = $log->artifacts(0, 0);
    my $events_iter = $a->events_iter;

=head1 DESCRIPTION

MariaDB-backed Log backend (MariaDB >= 10.7, for native C<UUID> type).
Subclasses L<App::Yath2::Log::DB> and provides only the MariaDB-
specific bits: connection setup, native C<UUID> column storage,
C<JSON> JSON columns, and C<LONGBLOB> payloads with server-side
C<PAGE_COMPRESSED=1> compression (so the app stores raw bytes and
never client-zstd-compresses).

The session is set to C<ANSI_QUOTES> mode so the base-class SQL's
double-quoted identifiers (e.g. C<"exit">) work unmodified.

C<DBD::MariaDB> is loaded lazily on first connection — Test2::Harness2
has no compile-time dependency on it. Calling the constructor without
C<DBD::MariaDB> installed throws a clear error.

=head1 DEPLOYMENT NOTE

C<innodb_compression_algorithm> is server-global, not per-table.
Best results with C<innodb_compression_algorithm = zstd>. Compression
requires sparse-file support on the underlying filesystem
(ext4/xfs/btrfs).

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
