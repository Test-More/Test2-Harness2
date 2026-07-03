package App::Yath2::DB::Connect;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();

use App::Yath2::DB::Flavor;

use Importer 'Importer' => 'import';

our @EXPORT_OK = qw{
    require_db_modules
    target_to_flavor
    build_connection
    ensure_sqlite_db
    find_or_create
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
"install X" error, and builds the live QuickORM connection (autofill /
reflect-from-DB, via L<App::Yath2::DB::ORM>) for one target.

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

The bootstrap is B<atomic>: the DDL is loaded into a private temp file in
C<$path>'s directory and published with a single C<rename>, so an interrupted
bootstrap never leaves a half-built C<$path> and two processes first-opening a
shared DB never collide on C<CREATE TABLE>. "Already bootstrapped" is decided for
sqlite by a schema marker (a C<schema_meta> row), not merely a non-zero size, so a
partial file left by an older non-atomic run is rebuilt rather than trusted.

=item $pk = find_or_create($con, $table, \%natural, $pk_col)

Get-or-create a natural-key entity on connection C<$con>: return the C<$pk_col>
value of the row matching C<%natural> if it exists, otherwise C<insert> it and
return the new C<$pk_col>. The connection is passed explicitly so both the logger
(writing to its live connection) and the sync engine (writing to its destination)
share one implementation.

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
        my $err = $@;
        croak "DBIx::QuickORM is required for yath logging / the DB commands but is not installed.\n"
            . "Install it (and a DB driver) to enable logging, e.g.: cpanm DBIx::QuickORM $dbd\n"
            . _load_failure_detail('DBIx/QuickORM.pm', $err);
    }

    (my $dbd_file = "$dbd.pm") =~ s{::}{/}g;
    unless (eval { require $dbd_file; 1 }) {
        my $err = $@;
        croak "$dbd is required to log to a '$eng' database but is not installed.\n"
            . "Install it to enable this logging target, e.g.: cpanm $dbd\n"
            . _load_failure_detail($dbd_file, $err);
    }

    return;
}

# A failed `require` has two very different causes and finding 90 was that we
# reported BOTH as "not installed": (a) the module is genuinely absent -- a
# top-level `Can't locate <that module>.pm in @INC` -- which the "install X" hint
# above already covers, so we stay quiet; or (b) the module IS installed but
# BROKEN -- a compile/syntax error, or a `Can't locate` of one of ITS OWN
# dependencies -- which is a real failure the user must see to fix. Surface the
# captured error for (b); return '' for (a) so the clean hint is not cluttered.
sub _load_failure_detail {
    my ($mod_file, $err) = @_;
    return '' unless defined $err && length $err;

    # Case (a): the very module we asked for is not on disk. Only this exact
    # top-level not-found is the "not installed" case -- a `Can't locate` naming a
    # DIFFERENT (dependency) module is a broken install and falls through to (b).
    return '' if $err =~ /^Can't locate \Q$mod_file\E in \@INC/;

    chomp(my $detail = $err);
    return "The actual load error was:\n  $detail\n";
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

    # "Already bootstrapped" is decided by a schema MARKER (a schema_meta row),
    # NOT by non-zero size (finding 89): the old bootstrap wrote CREATE TABLE
    # statements straight into $path under autocommit, so an interrupt after the
    # first committed statement left a partial, non-empty file that `-s` happily
    # accepted -- and then every later open died 'no such table: runs' forever
    # (a zero-byte file self-healed, a partial one did not). The marker probe is
    # sqlite-only: a DuckDB file is process-locked to its single writer, so an
    # extra probe-open could collide with an active logger -- it keeps the size
    # check (and still gains the atomic publish below).
    if (-e $path && -s _) {
        return $path if $flavor->name ne 'sqlite';
        return $path if _sqlite_schema_present($path, $flavor);
        # A partial / foreign file: fall through and rebuild it atomically.
    }

    require DBI;
    require File::Temp;

    # Bootstrap into a PRIVATE temp file in $path's own directory, then publish it
    # with a single atomic rename (finding 89). This closes both races at once:
    #   * an interrupt during the DDL only ever discards a throwaway temp -- $path
    #     is never a half-built file, because rename(2) is the single all-or-nothing
    #     publish (and a clean sqlite close checkpoints WAL back into the temp);
    #   * two processes first-opening a SHARED results DB each build their OWN temp,
    #     so neither runs CREATE TABLE against the other's file -- the old duplicate-
    #     table collision on the shared handle is gone.
    # rename within one directory is atomic on POSIX filesystems; a racer that
    # published a valid DB first is simply replaced by our identical fresh schema
    # (harmless -- neither has written any run data at bootstrap time).
    my ($vol, $dir, $file) = File::Spec->splitpath($path);
    my $dstdir = File::Spec->catpath($vol, $dir, '');
    $dstdir = File::Spec->curdir() unless defined($dstdir) && length($dstdir);

    my ($fh, $tmp) = File::Temp::tempfile(".$file-XXXXXX", DIR => $dstdir, UNLINK => 0);
    close($fh);

    # sqlite treats a 0-byte file as a valid EMPTY database, so we keep the
    # File::Temp file as-is -- its O_EXCL name reservation stays intact, so
    # concurrent bootstrappers that share a PRNG state (e.g. forks) cannot
    # regenerate and collide on the same temp name. DuckDB instead REJECTS a
    # pre-existing non-DuckDB file, so its temp must not exist when the driver
    # opens it: drop the empty reservation and let DuckDB create the file (it is
    # single-writer and its loggers are separate processes, so the momentarily
    # freed name cannot be raced in practice).
    unlink($tmp) if $flavor->name ne 'sqlite';

    my $ok = eval {
        my $dbh = DBI->connect(
            $flavor->dbd_dsn_prefix . $tmp, '', '',
            $flavor->connect_attrs,
        ) or croak "Could not create " . $flavor->name . " DB '$tmp': $DBI::errstr";

        $flavor->post_connect($dbh);
        _load_ddl($dbh, $flavor);
        $dbh->disconnect;
        1;
    };
    my $err = $@;

    unless ($ok) {
        _unlink_db_tempfiles($tmp);
        die $err;
    }

    unless (rename($tmp, $path)) {
        my $rerr = $!;
        _unlink_db_tempfiles($tmp);
        croak "Could not publish bootstrapped " . $flavor->name . " DB into place ('$tmp' -> '$path'): $rerr";
    }

    return $path;
}

# Is this sqlite file a COMPLETE bootstrap, verified by the schema_meta marker row
# (finding 89)? A junk / partial / unreadable file throws on open or on the marker
# query -- caught here and reported as "not bootstrapped" so the caller rebuilds it
# (self-heal). Read-only so the probe never itself mutates the file.
sub _sqlite_schema_present {
    my ($path, $flavor) = @_;

    require DBI;
    my $present = 0;
    my $ok = eval {
        my $dbh = DBI->connect(
            $flavor->dbd_dsn_prefix . $path, '', '',
            $flavor->connect_attrs(read_only => 1),
        ) or die "connect returned undef\n";
        my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM schema_meta");
        $dbh->disconnect;
        $present = $n ? 1 : 0;
        1;
    };

    return $ok && $present ? 1 : 0;
}

# Remove a bootstrap temp DB plus any WAL / journal sidecars it may have left. A
# clean close checkpoints and removes them, but a die MID-DDL (before that close)
# can leave sqlite's -wal / -shm / -journal or duckdb's .wal next to the temp.
sub _unlink_db_tempfiles {
    my ($tmp) = @_;
    unlink($tmp, "$tmp-wal", "$tmp-shm", "$tmp-journal", "$tmp.wal");
    return;
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
    # re-attach a shared singleton). App::Yath2::DB::ORM owns the single autofill
    # definition (JSON/UUID/DateTime autotypes + the dumb autorow) and carries the
    # compile-time `use DBIx::QuickORM`; we require it lazily here (require_db_modules
    # already verified the dep, R11).
    require App::Yath2::DB::ORM;
    my $name = 'yath_logger_' . $flavor->name . '_' . ++$ORM_SEQ . '_' . $$;
    my $con  = App::Yath2::DB::ORM::connection($name, $flavor->dialect, $db_name, $connect_cb);

    return ($con, $flavor);
}

# Get-or-create a natural-key entity on $con, returning its integer PK. Shared by
# the logger (its live connection) and the sync engine (its destination), which is
# why the connection is an explicit argument (ticket #93 -- one implementation).
sub find_or_create {
    my ($con, $table, $natural, $pk_col) = @_;

    my $row = $con->handle($table, where => $natural)->first;
    return $row->field($pk_col) if $row;

    my $new = $con->handle($table)->insert($natural);
    return $new->field($pk_col);
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
