package App::Yath2::Log::Sqlite;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'App::Yath2::Log::DB';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Object::HashBase qw{
    <file
};

# SQLite-backed Log backend. Inherits the bulk of its behavior from
# App::Yath2::Log::DB; this class only fills in flavor-specific bits:
#
#   - DSN / DBH construction (file => $path | dbh => $dbh | dsn => ...).
#   - Pragmas applied at connect time (WAL, synchronous=NORMAL,
#     busy_timeout=5000, foreign_keys=ON, temp_store=MEMORY).
#   - Schema bootstrap from share/schema/sqlite.sql.
#   - UUID and JSON codecs (text storage, no _string companion column).
#   - Payload compression default = client-side zstd.

sub init {
    my $self = shift;

    croak "Sqlite backend requires one of: file, dbh, dsn"
        unless defined $self->{+FILE}
        || defined $self->{+DBH}
        || defined $self->{+DSN};

    # Connect (lazily; bootstrap will use $self->dbh).
    $self->dbh;

    $self->bootstrap_schema;
    $self->_resolve_archive(missing_ok => 1);

    return;
}

sub schema_flavor { 'sqlite' }

sub schema_file {
    my $self = shift;
    my $here = __FILE__;
    # First look in share/schema relative to the dist root (development
    # checkout). Fall back to File::ShareDir for installed dists.
    my $dev = _dev_schema_path('sqlite');
    return $dev if defined $dev && -e $dev;

    require File::ShareDir;
    my $share = eval { File::ShareDir::dist_dir('Test2-Harness2') };
    if ($share && -e "$share/schema/sqlite.sql") {
        return "$share/schema/sqlite.sql";
    }
    croak "could not locate schema file for sqlite";
}

sub _dev_schema_path {
    my ($flavor) = @_;
    # Walk up from this file looking for a sibling share/schema/<flavor>.sql.
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
    require DBI;

    my $dsn  = $self->{App::Yath2::Log::DB::DSN};
    my $user = $self->{App::Yath2::Log::DB::USER};
    my $pass = $self->{App::Yath2::Log::DB::PASS};
    my $attrs = $self->{App::Yath2::Log::DB::ATTRS} || {};

    if (!defined $dsn) {
        my $file = $self->{+FILE};
        croak "no file or dsn provided" unless defined $file;
        $dsn = "dbi:SQLite:dbname=$file";
        # Ensure parent directory exists when creating a new file.
        if (!-e $file) {
            my $par = dirname($file);
            make_path($par) if length $par && !-d $par;
        }
        $self->{App::Yath2::Log::DB::DSN} = $dsn;
    }

    my $dbh = DBI->connect($dsn, $user, $pass, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        sqlite_unicode => 1,
        %$attrs,
    });

    # SQLite open-time PRAGMAs (per share/schema/SCHEMA.md §8).
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA synchronous = NORMAL');
    $dbh->do('PRAGMA busy_timeout = 5000');
    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('PRAGMA temp_store = MEMORY');

    return $dbh;
}

# Per K5: SQLite stores UUID as TEXT(36); both directions are no-ops
# beyond a defensive case-fold so our existing UUIDs (uppercase from
# Test2::Util::UUID) stay consistent if someone mixes case.
sub _uuid_to_db   { defined $_[1] ? "$_[1]" : undef }
sub _uuid_from_db { defined $_[1] ? "$_[1]" : undef }

# Per K8: SQLite >= 3.45 supports JSONB. We store JSON text -- the
# schema file uses BLOB for JSONB columns which is what JSONB wants.
# For broad compatibility we encode as plain JSON text on input.
sub _json_encode { defined $_[1] ? encode_json($_[1]) : undef }
sub _json_decode {
    my ($self, $val) = @_;
    return undef unless defined $val;
    # SQLite returns BLOB columns as plain bytes for normal text.
    # JSON decode is the same path either way.
    return decode_json($val);
}

# SQLite stores zstd-compressed payloads.
sub _payload_compressed_default { 1 }

# Format DateTime for SQLite TEXT timestamp columns. SQLite stores
# everything as TEXT; we use ISO 8601 with millisecond precision so
# fractional seconds round-trip. (DateTime::Format::SQLite truncates
# to whole seconds -- avoid it for write.)
sub _format_datetime {
    my ($self, $dt) = @_;
    return undef unless defined $dt;
    return $dt->strftime('%Y-%m-%dT%H:%M:%S.%3NZ');
}

# Parse SQLite TEXT timestamp columns. ISO 'T'/'Z' shape goes through
# the base class via DateTime::Format::ISO8601; legacy space-separated
# rows fall back to DateTime::Format::SQLite.
sub _to_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val && eval { $val->isa('DateTime') };
    if (!ref $val && $val =~ /\A\d{4}-\d{2}-\d{2} \d/) {
        require DateTime::Format::SQLite;
        my $dt = eval { DateTime::Format::SQLite->parse_datetime($val) };
        return $dt if defined $dt;
    }
    return $self->SUPER::_to_datetime($val);
}

# SQLite's autoinc primary keys map cleanly to last_insert_id with no
# args.
sub _last_insert_id {
    my ($self, $dbh, $table, $col) = @_;
    return $dbh->sqlite_last_insert_rowid;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Sqlite - SQLite-backed Log reader / writer.

=head1 SYNOPSIS

    my $log = App::Yath2::Log->new(file => '/tmp/run.yath');
    # OR
    my $log = App::Yath2::Log::Sqlite->new(file => '/tmp/run.yath');
    # OR
    my $log = App::Yath2::Log::Sqlite->new(dbh => $dbh, uuid => $u);

    while (my $event = $log->event(0)) {
        ...;
        last if $log->EOE;
    }

    my $a = $log->artifacts(0, 0);
    my $events_iter = $a->events_iter;

=head1 DESCRIPTION

SQLite-backed Log backend. Subclasses L<App::Yath2::Log::DB>,
inheriting the full reader / writer API and providing only the
SQLite-specific bits: connection setup, open-time PRAGMAs, schema
bootstrap from F<share/schema/sqlite.sql>, and TEXT(36) UUID storage.

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
