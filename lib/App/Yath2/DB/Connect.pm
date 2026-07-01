package App::Yath2::DB::Connect;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use App::Yath2::DB::Flavor;

use Importer 'Importer' => 'import';

our @EXPORT_OK = qw{
    require_db_modules
    target_to_flavor
    build_connection
    ensure_sqlite_db
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Connect - Lazy DB-dependency loading + a QuickORM connection
builder for the DB logger / commands.

=head1 DESCRIPTION

The DB layer is B<optional> (spec R11): core C<yath test> without logging needs
B<zero> DB modules. This module is the single place that C<require>s
L<DBIx::QuickORM> + the per-engine C<DBD::*> driver lazily, with an actionable
"install X" error, and builds the live L<App::Yath2::Schema> connection (autofill
/ reflect-from-DB) for one target.

A B<target> is the polymorphic C<-L> value (spec R16):

=over 4

=item a filesystem path (or the default temp path)

An embedded-file database; bootstrapped from the flavor DDL the first time it is
opened. A C<.duckdb>/C<.ddb> extension selects DuckDB
(C<share/schema/DuckDB/log.sql>); any other path is SQLite
(C<share/schema/SQLite/log.sql>).

=item a C<dbi:...> DSN

A remote/other database (postgres/mariadb/duckdb/...); the flavor is inferred
from the DSN prefix (MySQL-family is probed on a live handle).

=back

DuckDB is single-writer: a C<.duckdb> file allows only one read-write process at
a time, so a reader must open it read-only (C<< build_connection($t, read_only =E<gt> 1) >>)
and only after the writing logger has detached.

Nothing here is loaded at compile time by the always-loaded command path; the
logger process and the DB commands C<require> this module at runtime.

=head1 EXPORTS

=over 4

=item require_db_modules($flavor)

Lazily C<require> L<DBIx::QuickORM> and the flavor's C<DBD::*> driver, throwing a
clear "install ..." exception when either is missing. Returns nothing.

=item ($flavor, $kind, $spec) = target_to_flavor($target)

Classify a C<-L> target string. C<$kind> is C<'sqlite'> or C<'duckdb'> (an
embedded-file path, distinguished by extension) or C<'dsn'> (a C<dbi:...>
string); C<$spec> is the file path or the DSN; C<$flavor> is the matching
L<App::Yath2::DB::Flavor>.

=item ($con, $flavor) = build_connection($target, %opts)

Build (and bootstrap, for a fresh embedded-file database) the live QuickORM
connection for C<$target>. Croaks with an actionable error if a required DB
module is missing. With C<< read_only =E<gt> 1 >> the handle is opened read-only
(engine-specific, see L<App::Yath2::DB::Flavor/connect_attrs>): no bootstrap is
done and the file must already exist. Use it for reader call sites (import / db
sync source); it is mandatory for reading a DuckDB file (its read-write lock is
process-exclusive).

=item ensure_sqlite_db($path, $flavor)

Create the embedded-file DB (sqlite or duckdb, per C<$flavor>) at C<$path> from
the flavor DDL if it does not already exist (idempotent). Returns the path. (The
name is historical; it serves both file engines.)

=back

=cut

# Human-facing install hint for each flavor's DBD driver. The whole MySQL family
# (mysql/mariadb/percona) is driven through DBD::MariaDB, never DBD::mysql.
my %DBD_FOR = (
    sqlite     => 'DBD::SQLite',
    duckdb     => 'DBD::DuckDB',
    postgresql => 'DBD::Pg',
    mysql      => 'DBD::MariaDB',
    mariadb    => 'DBD::MariaDB',
    percona    => 'DBD::MariaDB',
);

sub require_db_modules {
    my ($flavor) = @_;

    my $eng = $flavor ? $flavor->name : 'sqlite';
    my $dbd = $DBD_FOR{$eng} // 'DBD::SQLite';

    unless (eval { require DBIx::QuickORM; 1 }) {
        croak "DBIx::QuickORM is required for yath logging / the DB commands but is not installed.\n"
            . "Install it (and a DB driver) to enable logging, e.g.: cpanm DBIx::QuickORM $dbd\n";
    }

    (my $dbd_file = "$dbd.pm") =~ s{::}{/}g;
    unless (eval { require $dbd_file; 1 }) {
        croak "$dbd is required to log to a '$eng' database but is not installed.\n"
            . "Install it to enable this logging target, e.g.: cpanm $dbd\n";
    }

    return;
}

sub target_to_flavor {
    my ($target) = @_;

    croak "a logging target is required" unless defined $target && length $target;

    if ($target =~ /^dbi:/i) {
        # The harness drives the whole MySQL family through DBD::MariaDB, never
        # DBD::mysql. Normalize a legacy dbi:mysql: DSN onto dbi:MariaDB: (and its
        # local-socket attribute) so one driver serves mysql/mariadb/percona.
        if ($target =~ /^dbi:mysql:/i) {
            $target =~ s/^dbi:mysql:/dbi:MariaDB:/i;
            $target =~ s/\bmysql_socket=/mariadb_socket=/g;
        }

        my $flavor = App::Yath2::DB::Flavor->infer_from_dsn($target);

        # dbi:MariaDB: is shared by mysql/mariadb/percona; the prefix alone cannot
        # disambiguate. Default to mariadb here -- detect_from_dbh refines it after
        # a live handle is open (build_connection probes it).
        $flavor //= App::Yath2::DB::Flavor->by_name('mariadb') if $target =~ /^dbi:MariaDB:/i;

        croak "Could not determine a database flavor from DSN '$target'" unless $flavor;
        return ($flavor, 'dsn', $target);
    }

    # A file path. A .duckdb/.ddb extension selects the DuckDB embedded engine;
    # anything else is a sqlite file. (The extension is the ONLY signal here -- a
    # bare path with no recognized extension stays sqlite, the historical default.)
    if ($target =~ /\.(?:duckdb|ddb)\z/i) {
        return (App::Yath2::DB::Flavor->by_name('duckdb'), 'duckdb', $target);
    }

    return (App::Yath2::DB::Flavor->by_name('sqlite'), 'sqlite', $target);
}

# Apply a flavor DDL file to a live handle, statement by statement. The DDL files
# are plain top-level statements separated by ";\n" (mirrors the schema test).
sub _load_ddl {
    my ($dbh, $flavor) = @_;

    my $path = $flavor->ddl_path;
    open my $fh, '<', $path or croak "Could not open DDL '$path': $!";
    my $ddl = do { local $/; <$fh> };
    close($fh);

    # Split on ";\n" into top-level statements. A fragment that is only SQL line
    # comments + whitespace -- e.g. a comment line that itself ends in ";" -- is a
    # no-op: skip it. Strict drivers (DBD::DuckDB) reject a comment-only "statement"
    # with "No statement to prepare!"; DBD::Pg/SQLite silently tolerate it. The
    # comment-strip is only for the emptiness test; the ORIGINAL $stmt is executed.
    for my $stmt (split /;\s*\n/, $ddl) {
        (my $code = $stmt) =~ s/--[^\n]*//g;
        next unless $code =~ /\S/;
        local $SIG{__WARN__} = sub { };
        $dbh->do($stmt);
    }

    return;
}

# Bootstrap a fresh embedded-file DB (sqlite or duckdb) from its flavor DDL. The
# body is flavor-generic -- it keys off $flavor->dbd_dsn_prefix + $flavor->ddl_path
# -- so it serves both file engines; the name is kept for back-compat (it is an
# exported symbol used by the DB tests). The bootstrap handle is always read-write.
sub ensure_sqlite_db {
    my ($path, $flavor) = @_;

    $flavor //= App::Yath2::DB::Flavor->by_name('sqlite');

    return $path if -e $path && -s _;

    require DBI;
    my $dbh = DBI->connect(
        $flavor->dbd_dsn_prefix . $path, '', '',
        $flavor->connect_attrs,
    ) or croak "Could not create " . $flavor->name . " DB '$path': $DBI::errstr";

    $flavor->post_connect($dbh);
    _load_ddl($dbh, $flavor);
    $dbh->disconnect;

    return $path;
}

my $ORM_SEQ = 0;

sub build_connection {
    my ($target, %opts) = @_;

    my $read_only = $opts{read_only} ? 1 : 0;

    my ($flavor, $kind, $spec) = target_to_flavor($target);

    require_db_modules($flavor);

    my ($dsn, $db_name);
    if ($kind eq 'dsn') {
        $dsn = $spec;
        # QuickORM uses db_name to scope its reflection (e.g. the MySQL-family
        # information_schema filter), so it must match the DSN's ACTUAL database;
        # derive it from the DSN rather than assuming a fixed name (a remote DB
        # whose database is not 'yath' would otherwise autofill zero tables).
        ($db_name) = $spec =~ /\b(?:dbname|database)=([^;]+)/i;
        $db_name //= 'yath';
    }
    else {
        # An embedded-file flavor (sqlite or duckdb). A WRITER bootstraps a fresh
        # file from the DDL before the ORM autofills; a READER must NOT create a DB
        # it only intends to read -- the file must already exist (and for DuckDB the
        # writing logger must have detached, since its lock is process-exclusive).
        if ($read_only) {
            croak "Cannot open '$spec' read-only: the database file does not exist"
                unless -e $spec && -s _;
        }
        else {
            ensure_sqlite_db($spec, $flavor);
        }
        $dsn     = $flavor->dbd_dsn_prefix . $spec;
        $db_name = $spec;
    }

    require DBI;
    my $connect_cb = sub {
        my $dbh = DBI->connect($dsn, '', '', $flavor->connect_attrs(read_only => $read_only))
            or croak "Could not connect to '$dsn': $DBI::errstr";
        $flavor->post_connect($dbh, read_only => $read_only);
        return $dbh;
    };

    # For a shared dbi:MariaDB: DSN, refine the flavor on a live handle.
    if ($kind eq 'dsn' && $flavor->is_mysql_family) {
        my $probe = $connect_cb->();
        my $refined = App::Yath2::DB::Flavor->detect_from_dbh($probe);
        $flavor = $refined if $refined;
        $probe->disconnect;
    }

    # Build a FRESH ORM (a DBIx::QuickORM::ORM's `db` is write-once, so we never
    # re-attach the App::Yath2::Schema `yath` singleton). The autofill block is kept
    # in sync with App::Yath2::Schema (JSON/UUID/DateTime autotypes + the dumb
    # autorow). App::Yath2::DB::ORM carries the compile-time `use DBIx::QuickORM`;
    # we require it lazily here (require_db_modules already verified the dep, R11).
    require App::Yath2::DB::ORM;
    my $name = 'yath_logger_' . $flavor->name . '_' . ++$ORM_SEQ . '_' . $$;
    my $con  = App::Yath2::DB::ORM::connection($name, $flavor->dialect, $db_name, $connect_cb);

    return ($con, $flavor);
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
