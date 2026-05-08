package App::Yath2::LogDB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <file
    <dbh
    <dsn
    <user
    <pass
    <attrs
    <flavor
    +_handle
};

# {{{ Multi-archive DB container.
#
# `App::Yath2::LogDB` wraps a DB connection (sqlite, postgres, mariadb,
# or mysql) that may hold one or more archives. Where
# `App::Yath2::Log->new(file => $path)` returns a Log scoped to a
# single archive (and throws when a multi-archive sqlite file is
# opened without a uuid), LogDB explicitly enumerates the archives in
# the DB and hands back a per-archive Log object on demand.
#
# Constructors:
#
#   App::Yath2::LogDB->new(file => $sqlite_path)
#   App::Yath2::LogDB->new(dbh  => $dbh)
#   App::Yath2::LogDB->new(dsn  => $dsn, user => $u, pass => $p,
#                          attrs => \%a)
#
# Internally LogDB holds a single backend Log::DB-derived handle whose
# `archive_uuid` slot is left undef. That handle exposes the shared
# DBI handle, schema bootstrap, and the archives-table read methods we
# need. Per-archive operations (events / artifacts / iterators) flow
# through fresh Log objects returned from `log($uuid)`, all of which
# share the same DBI handle so we never reconnect.
#
# Future work: metadata, status, run-count summaries on archive
# listings. For now the listing is just a flat list of UUIDs.

sub init {
    my $self = shift;

    croak "App::Yath2::LogDB->new requires one of: file, dbh, dsn"
        unless defined $self->{+FILE}
        || defined $self->{+DBH}
        || defined $self->{+DSN};

    $self->_build_handle;
    return;
}

sub _build_handle {
    my $self = shift;

    my $flavor = $self->_detect_flavor;
    $self->{+FLAVOR} = $flavor;

    my $class = _backend_class_for($flavor);
    my $ok = eval "require $class; 1";
    croak "could not load backend '$class': $@" unless $ok;

    # Construct the backend handle WITHOUT going through init() — the
    # standard init calls _resolve_archive which throws on
    # multi-archive DBs (which is exactly the shape we want to
    # support). We populate the slots manually, connect the dbh
    # lazily, and bootstrap the schema explicitly.
    my %slots;
    $slots{App::Yath2::Log::DB::DBH()}   = $self->{+DBH}   if defined $self->{+DBH};
    $slots{App::Yath2::Log::DB::DSN()}   = $self->{+DSN}   if defined $self->{+DSN};
    $slots{App::Yath2::Log::DB::USER()}  = $self->{+USER}  if defined $self->{+USER};
    $slots{App::Yath2::Log::DB::PASS()}  = $self->{+PASS}  if defined $self->{+PASS};
    $slots{App::Yath2::Log::DB::ATTRS()} = $self->{+ATTRS} if defined $self->{+ATTRS};
    if ($flavor eq 'sqlite' && defined $self->{+FILE}) {
        # Sqlite-specific slot.
        $slots{'file'} = $self->{+FILE};
    }

    my $h = bless { %slots }, $class;
    $h->bootstrap_schema;

    # Expose the live dbh on our own slot so callers can grab it
    # without an indirection. Also memoizes the connection.
    $self->{+DBH} = $h->dbh;

    $self->{+_HANDLE} = $h;
    return;
}

sub _detect_flavor {
    my $self = shift;

    if (defined $self->{+DSN}) {
        my $dsn = $self->{+DSN};
        return 'postgres' if $dsn =~ /^dbi:Pg:/i;
        return 'mariadb'  if $dsn =~ /^dbi:MariaDB:/i;
        return 'mysql'    if $dsn =~ /^dbi:mysql:/i;
        return 'sqlite'   if $dsn =~ /^dbi:SQLite:/i;
        croak "could not detect flavor from DSN: $dsn";
    }

    if (defined $self->{+DBH}) {
        my $name = $self->{+DBH}->{Driver}{Name} // '';
        return 'sqlite'   if $name eq 'SQLite';
        return 'postgres' if $name eq 'Pg';
        return 'mariadb'  if $name eq 'MariaDB';
        return 'mysql'    if $name eq 'mysql';
        croak "could not detect flavor from dbh (DBI driver: $name)";
    }

    if (defined $self->{+FILE}) {
        # File path: only sqlite is supported as a single-file flavor.
        # For a brand-new file (does not yet exist) we assume sqlite;
        # that matches the App::Yath2::Log::DB::Sqlite "open with file =>
        # creates the DB" behavior.
        my $f = $self->{+FILE};
        return 'sqlite' unless -e $f;

        require App::Yath2::Log;
        my $kind = App::Yath2::Log->_detect_file_kind($f);
        return 'sqlite' if $kind eq 'sqlite';
        croak "file '$f' is not a SQLite database "
            . "(LogDB requires a multi-archive-capable DB)";
    }

    croak "no flavor source available (no file/dbh/dsn)";
}

sub _backend_class_for {
    my ($flavor) = @_;
    return 'App::Yath2::Log::DB::Sqlite'   if $flavor eq 'sqlite';
    return 'App::Yath2::Log::DB::Postgres' if $flavor eq 'postgres';
    return 'App::Yath2::Log::DB::MariaDB'  if $flavor eq 'mariadb';
    return 'App::Yath2::Log::DB::MySQL'    if $flavor eq 'mysql';
    croak "unknown flavor: $flavor";
}

# }}}

# {{{ Public API

# Returns a fresh list of archive UUIDs ordered by archive_id.
sub archives {
    my $self = shift;
    my $h = $self->{+_HANDLE};
    my $dbh = $self->{+DBH};
    my $rows = $dbh->selectall_arrayref(
        q{SELECT archive_uuid FROM archives ORDER BY archive_id},
        { Slice => {} },
    );
    return map { $h->_uuid_from_db($_->{archive_uuid}) } @$rows;
}

sub archive_count {
    my $self = shift;
    return scalar $self->archives;
}

sub has_archive {
    my ($self, $uuid) = @_;
    return 0 unless defined $uuid;
    for my $u ($self->archives) {
        return 1 if lc($u) eq lc($uuid);
    }
    return 0;
}

# Return a fresh Log object scoped to $uuid. The returned object
# shares the DBI handle with this LogDB so reads do not require a
# reconnect.
sub log {
    my ($self, $uuid) = @_;
    croak "log() requires an archive uuid" unless defined $uuid && length $uuid;
    croak "no such archive in this DB: $uuid"
        unless $self->has_archive($uuid);

    my $flavor = $self->{+FLAVOR};
    my $class  = _backend_class_for($flavor);
    my $ok = eval "require $class; 1";
    croak "could not load backend '$class': $@" unless $ok;

    # Hand it the shared dbh + the requested uuid. The backend's init
    # calls _resolve_archive which will pick the matching row.
    return $class->new(dbh => $self->{+DBH}, uuid => $uuid);
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogDB - multi-archive DB container for yath log archives.

=head1 SYNOPSIS

    use App::Yath2::LogDB;

    # SQLite-as-yath, possibly multi-archive.
    my $ldb = App::Yath2::LogDB->new(file => '/tmp/runs.yath');

    # Server-shaped DBs.
    my $ldb = App::Yath2::LogDB->new(
        dsn  => 'dbi:Pg:dbname=yath',
        user => 'yath',
        pass => 'yath',
    );

    # Pre-existing dbh.
    my $ldb = App::Yath2::LogDB->new(dbh => $dbh);

    # List archives + open one.
    for my $uuid ($ldb->archives) {
        my $log = $ldb->log($uuid);
        ...;
    }

=head1 DESCRIPTION

C<App::Yath2::LogDB> wraps a DB connection (SQLite file, PostgreSQL,
MariaDB, or MySQL) that may hold one or more archives.

Where C<< App::Yath2::Log->new(file => $path) >> assumes a
single-archive log and throws on a multi-archive SQLite file unless
C<< uuid => $u >> is supplied, C<LogDB> deliberately speaks the
multi-archive shape. C<< $ldb->archives >> enumerates the contained
archive UUIDs; C<< $ldb->log($uuid) >> returns a fresh
L<App::Yath2::Log> object scoped to that archive, sharing the
underlying DBI handle so subsequent reads do not reconnect.

C<< App::Yath2::Log->new(file => $sqlite_with_2_archives) >> still
throws on ambiguity; a caller wanting to enumerate uses C<LogDB>
instead.

=head1 CONSTRUCTORS

=over 4

=item App::Yath2::LogDB->new(file => $path)

Open a SQLite C<.yath> file. The file's magic bytes are checked; if
the file is not a SQLite database, the constructor throws.

=item App::Yath2::LogDB->new(dbh => $dbh)

Wrap an existing DBI handle. Flavor is detected from
C<< $dbh->{Driver}{Name} >>.

=item App::Yath2::LogDB->new(dsn => $dsn, user => $u, pass => $p, attrs => \%a)

Open a server-shaped DB by DSN. The C<dbi:Pg:...>, C<dbi:MariaDB:...>,
C<dbi:mysql:...>, or C<dbi:SQLite:...> prefix selects the flavor.

=back

=head1 METHODS

=over 4

=item @uuids = $ldb->archives

Returns the archive UUIDs in C<archive_id> order. Per the F11 carry-
over, today this is just the list of UUIDs; future work will attach
metadata (run count, project, host, git_sha, ...) and possibly return
hashref rows instead.

=item $n = $ldb->archive_count

Convenience for C<< scalar $ldb->archives >>.

=item $bool = $ldb->has_archive($uuid)

Returns true if the DB holds an archive with the given UUID.

=item $log = $ldb->log($uuid)

Returns an L<App::Yath2::Log> object scoped to C<$uuid>, sharing the
DBI handle owned by this LogDB. The returned object supports the full
reader API documented in L<App::Yath2::Log>.

=item $flavor = $ldb->flavor

Returns the detected flavor: C<sqlite>, C<postgres>, C<mariadb>, or
C<mysql>.

=item $dbh = $ldb->dbh

Returns the shared L<DBI> handle.

=back

=head1 SEE ALSO

L<App::Yath2::Log>, L<App::Yath2::Log::DB>, L<App::Yath2::Log::DB::Sqlite>,
L<App::Yath2::Log::DB::Postgres>, L<App::Yath2::Log::DB::MariaDB>,
L<App::Yath2::Log::DB::MySQL>.

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
