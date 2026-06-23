package App::Yath2::DB::Flavor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use App::Yath2::Util qw/share_dir/;

use Test2::Harness2::Util::HashBase qw{
    <name
    <dialect
    <ddl_file
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
(C<sqlite>, C<postgresql>, C<mysql>, C<mariadb>, C<percona>) to the metadata the
DB layer needs when working with a given database engine: the SQL dialect name
for L<DBIx::QuickORM>, the DDL filename under C<share/schema/>, the DSN prefix
used to detect the engine from a connection string, and the L<DBIx::QuickDB>
driver token for ephemeral databases.

PostgreSQL is the first fully-supported flavor (#46); the per-engine DDL for the
others lands in #47. The registry already lists all five engines so detection /
DSN inference work; only the DDL files are added per chunk.

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
    say $f->ddl_path;    # /path/to/share/schema/PostgreSQL.sql

    my $g = App::Yath2::DB::Flavor->infer_from_dsn('dbi:Pg:dbname=yath');
    say $g->name;        # postgresql

=head1 ATTRIBUTES

=over 4

=item name

Lowercase symbolic key for this flavor: C<sqlite>, C<postgresql>, C<mysql>,
C<mariadb>, or C<percona>.

=item dialect

The dialect string passed to L<DBIx::QuickORM>: C<SQLite>, C<PostgreSQL>,
C<MySQL>, C<MySQL::MariaDB>, or C<MySQL::Percona>.

=item ddl_file

Basename of the DDL file under C<share/schema/> (e.g. C<PostgreSQL.sql>). Use
C<ddl_path> to get the full absolute path.

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

# All registered flavors. All flavors must move together when the DDL changes.
# Only PostgreSQL ships a DDL file today (#46); the others (#47) carry their
# metadata here already so detection/inference work before their DDL lands.
my %REGISTRY = (
    sqlite => {
        name           => 'sqlite',
        dialect        => 'SQLite',
        ddl_file       => 'SQLite.sql',
        dbd_dsn_prefix => 'dbi:SQLite:dbname=',
        quickdb_driver => 'SQLite',
        is_default     => 1,
    },
    postgresql => {
        name           => 'postgresql',
        dialect        => 'PostgreSQL',
        ddl_file       => 'PostgreSQL.sql',
        dbd_dsn_prefix => 'dbi:Pg:',
        quickdb_driver => 'PostgreSQL',
        is_default     => 0,
    },
    mysql => {
        name           => 'mysql',
        dialect        => 'MySQL',
        ddl_file       => 'MySQL.sql',
        dbd_dsn_prefix => 'dbi:mysql:',
        quickdb_driver => 'MySQL',
        is_default     => 0,
    },
    mariadb => {
        # Native uuid requires MariaDB 10.7+ (R8) -- a hard minimum, no fallback.
        name           => 'mariadb',
        dialect        => 'MySQL::MariaDB',
        ddl_file       => 'MariaDB.sql',
        dbd_dsn_prefix => 'dbi:MariaDB:',
        quickdb_driver => 'MariaDB',
        is_default     => 0,
    },
    percona => {
        name           => 'percona',
        dialect        => 'MySQL::Percona',
        ddl_file       => 'Percona.sql',
        dbd_dsn_prefix => 'dbi:mysql:',
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
C<dbi:mysql:> and C<dbi:MariaDB:> both return C<undef> because MySQL, MariaDB,
and Percona share those prefixes; callers that need to distinguish them should
call C<detect_from_dbh> on a live handle.

=cut

sub infer_from_dsn {
    my ($class, $dsn) = @_;
    return undef unless defined $dsn;
    return $class->by_name('postgresql') if $dsn =~ /^dbi:Pg:/i;
    return $class->by_name('sqlite')     if $dsn =~ /^dbi:SQLite:/i;
    return undef;
}

=item $flavor = App::Yath2::DB::Flavor->detect_from_dbh($dbh)

Probe a live MySQL-family database handle and return the matching flavor object
(C<mariadb>, C<percona>, or C<mysql>). Returns C<undef> if none of the well-known
version strings match.

The probe runs C<SELECT VERSION()> and C<SELECT @@version_comment> and looks for
C<MariaDB>, C<Percona>, or C<MySQL> in the concatenated result. This is how the
shared C<dbi:mysql:> DSN prefix is disambiguated (DSN inference cannot).

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

Absolute (or in-repo, during development) path to this flavor's DDL file under
the distribution's C<share/schema/> directory.

=cut

sub ddl_path {
    my ($self) = @_;
    return share_dir('schema') . '/' . $self->{+DDL_FILE};
}

=item $flavor->post_connect($dbh)

Run any flavor-specific setup on a freshly opened database handle. Currently only
C<sqlite> needs work: it enables foreign-key enforcement, WAL journal mode, and a
60-second busy timeout. (PostgreSQL needs none; the hook exists for the #47
SQLite port and the later logger.)

=back

=cut

sub post_connect {
    my ($self, $dbh) = @_;
    return unless $self->{+NAME} eq 'sqlite';
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
