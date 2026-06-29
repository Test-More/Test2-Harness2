package App::Yath2::DB::Flavor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use App::Yath2::Util qw/share_dir/;

use Test2::Harness2::Util::HashBase qw{
    <name
    <dialect
    <schema_dir
    <dbd_dsn_prefix
    <quickdb_driver
    <is_default
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Flavor - Registry of supported database flavors.

=head1 DESCRIPTION

C<App::Yath2::DB::Flavor> is a small registry that maps symbolic flavor names
(C<sqlite>, C<duckdb>, C<postgresql>, C<mysql>, C<mariadb>, C<percona>) to the
metadata the DB layer needs when working with a given database engine: the SQL
dialect name for L<DBIx::QuickORM>, the per-flavor DDL directory under
C<share/schema/>, the DSN prefix used to detect the engine from a connection
string, and the L<DBIx::QuickDB> driver token for ephemeral databases.

Every flavor ships hand-written DDL under C<share/schema/E<lt>schema_dirE<gt>/>:
C<log.sql> is the run-data schema (the only one today); a per-flavor C<web.sql>
(session / user / web-server tables) is a later addition. C<sqlite> and C<duckdb>
are embedded I<file> engines (a path is bootstrapped on first open); the rest are
server DSNs.

Each flavor is a singleton instance. Look one up by name with C<by_name>, infer
one from a DSN with C<infer_from_dsn>, or probe a live MySQL-family handle with
C<detect_from_dbh>.

B<MariaDB 10.7+ is a hard minimum> (R8): the native C<uuid> column type is
MariaDB 10.7+ only (10.5/10.6 LTS lack it), and the schema uses native C<uuid>
with no binary fallback for MariaDB.

=head1 SYNOPSIS

    use App::Yath2::DB::Flavor;

    my $f = App::Yath2::DB::Flavor->by_name('postgresql');
    say $f->dialect;     # PostgreSQL
    say $f->ddl_path;    # /path/to/share/schema/PostgreSQL/log.sql

    my $g = App::Yath2::DB::Flavor->infer_from_dsn('dbi:Pg:dbname=yath');
    say $g->name;        # postgresql

=head1 ATTRIBUTES

=over 4

=item name

Lowercase symbolic key for this flavor: C<sqlite>, C<duckdb>, C<postgresql>,
C<mysql>, C<mariadb>, or C<percona>.

=item dialect

The dialect string passed to L<DBIx::QuickORM>: C<SQLite>, C<DuckDB>,
C<PostgreSQL>, C<MySQL>, C<MySQL::MariaDB>, or C<MySQL::Percona>.

=item schema_dir

This flavor's DDL directory name under C<share/schema/> (e.g. C<PostgreSQL>). The
DDL files live at C<share/schema/E<lt>schema_dirE<gt>/log.sql> (and a future
C<web.sql>); use C<ddl_path> to get the full absolute path.

=item dbd_dsn_prefix

The DSN prefix string that identifies this flavor (e.g. C<dbi:Pg:>). Used
internally for DSN inference.

=item quickdb_driver

The L<DBIx::QuickDB> driver token (e.g. C<SQLite>, C<PostgreSQL>) for ephemeral
databases.

=item is_default

True only for the C<sqlite> flavor, which is the default backend when no
explicit flavor is configured (logging is still opt-in -- spec R11).

=back

=cut

# All registered flavors. All flavors must move together when the DDL changes;
# each ships a hand-written DDL under share/schema/. sqlite + duckdb are embedded
# file engines; the rest are server DSNs.
my %REGISTRY = (
    sqlite => {
        name           => 'sqlite',
        dialect        => 'SQLite',
        schema_dir     => 'SQLite',
        dbd_dsn_prefix => 'dbi:SQLite:dbname=',
        quickdb_driver => 'SQLite',
        is_default     => 1,
    },
    duckdb => {
        # DuckDB is an embedded file engine (like sqlite) but with native uuid /
        # json / blob, so its DDL ports from PostgreSQL/log.sql, not SQLite/log.sql. Only
        # ONE process may hold a .duckdb file read-write at a time; readers open
        # it read-only (see connect_attrs) once the writer has detached.
        name           => 'duckdb',
        dialect        => 'DuckDB',
        schema_dir     => 'DuckDB',
        dbd_dsn_prefix => 'dbi:DuckDB:dbname=',
        quickdb_driver => 'DuckDB',
        is_default     => 0,
    },
    postgresql => {
        name           => 'postgresql',
        dialect        => 'PostgreSQL',
        schema_dir     => 'PostgreSQL',
        dbd_dsn_prefix => 'dbi:Pg:',
        quickdb_driver => 'PostgreSQL',
        is_default     => 0,
    },
    mysql => {
        # The harness drives the whole MySQL family (mysql/mariadb/percona) through
        # DBD::MariaDB, never DBD::mysql -- so the DSN prefix is dbi:MariaDB:.
        name           => 'mysql',
        dialect        => 'MySQL',
        schema_dir     => 'MySQL',
        dbd_dsn_prefix => 'dbi:MariaDB:',
        quickdb_driver => 'MySQL',
        is_default     => 0,
    },
    mariadb => {
        # Native uuid requires MariaDB 10.7+ (R8) -- a hard minimum, no fallback.
        name           => 'mariadb',
        dialect        => 'MySQL::MariaDB',
        schema_dir     => 'MariaDB',
        dbd_dsn_prefix => 'dbi:MariaDB:',
        quickdb_driver => 'MariaDB',
        is_default     => 0,
    },
    percona => {
        # Driven through DBD::MariaDB like the rest of the MySQL family (dbi:MariaDB:).
        name           => 'percona',
        dialect        => 'MySQL::Percona',
        schema_dir     => 'Percona',
        dbd_dsn_prefix => 'dbi:MariaDB:',
        quickdb_driver => 'Percona',
        is_default     => 0,
    },
);

my %SINGLETONS;

=head1 PUBLIC METHODS

=over 4

=item $flavor = App::Yath2::DB::Flavor->by_name($name)

Return the singleton flavor object for C<$name>. Croaks with a list of known
names when C<$name> is not registered.

=cut

sub by_name {
    my ($class, $name) = @_;
    my $spec = $REGISTRY{$name // ''}
        or croak "unknown flavor '" . ($name // '<undef>') . "' (known: " . join(', ', sort keys %REGISTRY) . ")";
    return $SINGLETONS{$name} //= $class->new(%$spec);
}

=item $flavor = App::Yath2::DB::Flavor->infer_from_dsn($dsn)

Return the flavor whose DSN prefix unambiguously matches C<$dsn>, or C<undef>
when no unambiguous match exists.

C<dbi:Pg:> resolves to C<postgresql>. C<dbi:SQLite:> resolves to C<sqlite>.
A C<dbi:MariaDB:> DSN returns C<undef> because MySQL, MariaDB, and Percona are
all driven through C<DBD::MariaDB> and share that prefix; callers that need to
distinguish them should call C<detect_from_dbh> on a live handle. (A legacy
C<dbi:mysql:> DSN also returns C<undef>; the harness itself never builds one.)

=cut

sub infer_from_dsn {
    my ($class, $dsn) = @_;
    return undef unless defined $dsn;
    return $class->by_name('postgresql') if $dsn =~ /^dbi:Pg:/i;
    return $class->by_name('sqlite')     if $dsn =~ /^dbi:SQLite:/i;
    return $class->by_name('duckdb')     if $dsn =~ /^dbi:DuckDB:/i;
    return undef;
}

=item $flavor = App::Yath2::DB::Flavor->detect_from_dbh($dbh)

Probe a live MySQL-family database handle and return the matching flavor object
(C<mariadb>, C<percona>, or C<mysql>). Returns C<undef> if none of the well-known
version strings match.

The probe runs C<SELECT VERSION()> and C<SELECT @@version_comment> and looks for
C<MariaDB>, C<Percona>, or C<MySQL> in the concatenated result. This is how the
shared C<dbi:MariaDB:> DSN prefix is disambiguated (DSN inference cannot).

=cut

sub detect_from_dbh {
    my ($class, $dbh) = @_;

    my ($version) = $dbh->selectrow_array('SELECT VERSION()');
    my ($comment) = eval { $dbh->selectrow_array('SELECT @@version_comment') };
    my $blob      = join(' ', grep { defined } $version, $comment);

    return $class->by_name('mariadb') if $blob =~ /MariaDB/i;
    return $class->by_name('percona') if $blob =~ /Percona/i;
    return $class->by_name('mysql')   if $blob =~ /MySQL/i;
    return undef;
}

=item $bool = $flavor->is_mysql_family

Returns true when this flavor's dialect starts with C<MySQL> (i.e. C<mysql>,
C<mariadb>, C<percona>). False for C<sqlite> and C<postgresql>.

=cut

sub is_mysql_family {
    my ($self) = @_;
    return $self->{+DIALECT} =~ /^MySQL/ ? 1 : 0;
}

=item $path = $flavor->ddl_path

=item $path = $flavor->ddl_path($kind)

Absolute (or in-repo, during development) path to one of this flavor's DDL files
under C<share/schema/E<lt>schema_dirE<gt>/>. C<$kind> defaults to C<'log'> (the
run-data schema, C<.../log.sql>); the per-flavor C<web.sql> -- the session / user
/ web-server tables -- is a later addition (no C<web.sql> for DuckDB, which is
single-writer).

=cut

sub ddl_path {
    my ($self, $kind) = @_;
    $kind //= 'log';
    return share_dir('schema') . '/' . $self->{+SCHEMA_DIR} . '/' . $kind . '.sql';
}

=item \%attrs = $flavor->connect_attrs(%opts)

Return the C<DBI-E<gt>connect> attribute hashref for this flavor. The base attrs
(C<AutoCommit>/C<RaiseError>/C<PrintError>) are the same for every engine; the
C<read_only> option layers on the per-engine knob needed to open a handle that
B<cannot write>:

=over 4

=item C<duckdb>

C<< duckdb_config =E<gt> { access_mode =E<gt> 'read_only' } >> plus
C<< duckdb_checkpoint_on_disconnect =E<gt> 0 >>. This is an B<open-time> engine
config -- it is NOT a DSN attribute and cannot be applied in C<post_connect>.
A DuckDB file permits exactly one read-write process but many concurrent
read-only readers, so reader connections B<must> use this.

=item C<sqlite>

C<< sqlite_open_flags =E<gt> DBD::SQLite::OPEN_READONLY() >>.

=item server flavors (postgresql / mysql-family)

No open-time read-only attribute; the source connection is simply never written.

=back

=cut

sub connect_attrs {
    my ($self, %opts) = @_;

    my %attrs = (AutoCommit => 1, RaiseError => 1, PrintError => 0);

    if ($opts{read_only}) {
        my $name = $self->{+NAME};
        if ($name eq 'duckdb') {
            $attrs{duckdb_config}                   = {access_mode => 'read_only'};
            $attrs{duckdb_checkpoint_on_disconnect} = 0;
        }
        elsif ($name eq 'sqlite') {
            require DBD::SQLite;
            $attrs{sqlite_open_flags} = DBD::SQLite::OPEN_READONLY();
        }
    }

    return \%attrs;
}

=item $flavor->post_connect($dbh, %opts)

Run any flavor-specific setup on a freshly opened database handle. Currently only
C<sqlite> needs work: it enables foreign-key enforcement, WAL journal mode, and a
60-second busy timeout. Those are B<write> pragmas, so they are skipped when
C<read_only> is true (a read-only sqlite handle cannot run them and does not need
them). DuckDB's read-only mode is an open-time attr (see C<connect_attrs>), so
C<post_connect> is a no-op for it. (PostgreSQL/MySQL-family need none.)

=back

=cut

sub post_connect {
    my ($self, $dbh, %opts) = @_;
    return unless $self->{+NAME} eq 'sqlite';
    return if $opts{read_only};
    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA busy_timeout = 60000');
    return;
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
