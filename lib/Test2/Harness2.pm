package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use DBI ();
use File::Spec ();
use File::Basename qw/dirname/;
use POSIX ();
use Scalar::Util qw/blessed/;
use Sys::Hostname qw/hostname/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util qw/table_to_db_class load_module read_file write_file_atomic/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Object::HashBase qw{
    <dsn
    <flavor
    <project
    <user
    <name
    <path
    <host
    <cwd
    <started
    <dbh
    <tmpdir
    +_owns_file
    +_schema_dir
    +_sidecar_mode
    +_quickdb
};

my %FLAVOR_FROM_QDB_DRIVER = (
    SQLite     => 'sqlite',
    PostgreSQL => 'postgres',
    MySQL      => 'mysql',
    MariaDB    => 'mariadb',
    Percona    => 'percona',
);

my %FLAVOR_FROM_DSN_SCHEME = (
    SQLite  => 'sqlite',
    Pg      => 'postgres',
    MariaDB => 'mariadb',
    mysql   => 'mysql',
);

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Harness handle: owns the database, the `.t2h2`
file, and the row-object surface.

=head1 DESCRIPTION

The library-side entry point for the harness. A handle owns a database
connection plus a `.t2h2` file in the system temp directory. The file
has two forms:

=over 4

=item Default SQLite mode

The `.t2h2` file B<is> the SQLite database. Opening it directly
through L<DBD::SQLite> is the whole story.

=item Non-default mode

The `.t2h2` file is a small JSON sidecar describing the connection
(DSN, flavor, pid, project, user, host, cwd, started timestamp).
Opening it dispatches to the real database via the DSN. Triggered
either by passing C<dsn> / C<flavor> to point at a caller-managed
database, or by passing C<driver> to spin up an ephemeral database
via L<DBIx::QuickDB>. The QuickDB instance is held on the handle
and torn down on disconnect.

=back

The handle exposes the fetch / fetch_all / insert helpers every
row-object class uses to talk to its table.

=head1 SYNOPSIS

    use Test2::Harness2;

    # Default SQLite mode -- the .t2h2 file IS the database.
    my $h = Test2::Harness2->new(project => 'myproj');

    # Point at a caller-managed external Postgres. The .t2h2 file
    # becomes a JSON sidecar describing how to attach.
    my $h = Test2::Harness2->new(
        project => 'myproj',
        dsn     => 'dbi:Pg:dbname=t2h2;host=db.example;port=5432',
        flavor  => 'postgres',
    );

    # Spin up an ephemeral MariaDB via DBIx::QuickDB. The harness owns
    # and tears down the QuickDB instance on disconnect.
    my $h = Test2::Harness2->new(
        project => 'myproj',
        driver  => 'MariaDB',
    );

    # Reconnect to an existing .t2h2 file (either form).
    my $h2 = Test2::Harness2->connect($t2h2_path);

    my ($user) = $h->insert(users => {name => 'alice'});
    say $user->user_id;

    my @hosts = $h->fetch_all(hosts => name => 'localhost');

    $h->disconnect;

=head1 ATTRIBUTES

=over 4

=item project (required)

Free-form project name used as part of the default `.t2h2` filename.
Must be supplied by the caller; the handle does not detect a project
from the environment or the current working directory. Project
detection lives in the L<App::Yath2> layer.

=item user

The owning user. Defaults to C<$ENV{USER}>; croaks if neither is
provided.

=item name

Filename for the `.t2h2` file. Defaults to
C<"${user}-${project}-${pid}.t2h2">. Callers may override the
pattern in full.

=item tmpdir

System temp directory the `.t2h2` file is placed in. Defaults to
C<< File::Spec->tmpdir >>.

=item path

The full path of the `.t2h2` file. Computed from C<tmpdir> + C<name>
unless the caller passes it in directly.

=item dsn

DBI DSN for the harness database. In default SQLite mode this is
computed from C<path>. Pass a non-SQLite DSN to connect to a
caller-managed external database; the sidecar `.t2h2` file then
records the DSN and metadata for other processes to attach.

=item flavor

Database flavor identifier (C<sqlite>, C<postgres>, C<mysql>,
C<mariadb>, C<percona>). Defaults to C<sqlite> when no DSN is
supplied; otherwise inferred from the DSN scheme. Callers may pass an explicit C<flavor> to
override (necessary when the C<mysql>/C<mariadb>/C<percona> family
share C<dbi:MariaDB:>).

=item driver

Transient construction argument. When set, the handle uses
L<DBIx::QuickDB> to spin up an ephemeral database of that driver
(e.g. C<PostgreSQL>, C<MariaDB>) and uses it as the backing store.
The QuickDB instance is owned by the handle and torn down on
C<disconnect>. Not stored as an attribute on the handle once
init runs.

=item host

Hostname recorded in the JSON sidecar (default
C<< Sys::Hostname::hostname() >>).

=item cwd

Absolute current working directory recorded in the JSON sidecar
(default C<< File::Spec->rel2abs(File::Spec->curdir) >>).

=item started

Hi-res epoch seconds timestamp recorded in the JSON sidecar
(default C<< Time::HiRes::time() >>).

=item dbh

The owned L<DBI> database handle.

=back

=cut

sub init {
    my $self = shift;

    croak "'project' is a required attribute"
        unless defined $self->{+PROJECT} && length $self->{+PROJECT};

    $self->{+USER} //= $ENV{USER};
    croak "'user' is a required attribute (set USER in the environment or pass user => ...)"
        unless defined $self->{+USER} && length $self->{+USER};

    $self->{+HOST}    //= hostname();
    $self->{+CWD}     //= File::Spec->rel2abs(File::Spec->curdir);
    $self->{+STARTED} //= time();
    $self->{+TMPDIR}  //= File::Spec->tmpdir;
    $self->{+NAME}    //= sprintf('%s-%s-%d.t2h2', $self->{+USER}, $self->{+PROJECT}, $$);
    $self->{+PATH}    //= File::Spec->catfile($self->{+TMPDIR}, $self->{+NAME});

    return if $self->{+DBH};

    my $driver = delete $self->{driver};
    $self->_spin_up_ephemeral($driver) if $driver;

    my $existed = -e $self->{+PATH};

    if ($existed && !$self->{+DSN}) {
        $self->_load_existing_discovery;
    }
    elsif (!$self->{+DSN}) {
        $self->{+FLAVOR}      //= 'sqlite';
        $self->{+DSN}           = "dbi:SQLite:dbname=" . $self->{+PATH};
        $self->{+_SIDECAR_MODE} = 'sqlite_file';
    }
    else {
        $self->{+FLAVOR} //= _flavor_from_dsn($self->{+DSN})
            // croak "Cannot detect flavor from dsn '$self->{+DSN}'; pass `flavor => ...`";
        $self->{+_SIDECAR_MODE} //= 'json';
    }

    $self->{+_OWNS_FILE} = !$existed;

    $self->_open_dbh;
    $self->_load_schema if !$existed;

    if ($self->{+_OWNS_FILE} && ($self->{+_SIDECAR_MODE} // '') eq 'json') {
        $self->_write_sidecar;
    }
}

sub _flavor_from_dsn {
    my ($dsn) = @_;
    return undef unless defined $dsn && $dsn =~ /^dbi:([^:]+):/;
    return $FLAVOR_FROM_DSN_SCHEME{$1};
}

sub _spin_up_ephemeral {
    my ($self, $driver) = @_;

    require DBIx::QuickDB;
    my $instance = DBIx::QuickDB->build_db("t2h2-$$", {driver => $driver})
        or croak "Failed to build ephemeral '$driver' database";

    $self->{+_QUICKDB} = $instance;
    $self->{+DSN}      = $instance->connect_string;
    $self->{+FLAVOR}   //= $FLAVOR_FROM_QDB_DRIVER{$driver}
        // croak "Unknown DBIx::QuickDB driver '$driver'";
    $self->{+_SIDECAR_MODE} //= 'json';
    return;
}

sub _load_existing_discovery {
    my $self = shift;

    my $path = $self->{+PATH};
    open(my $fh, '<:raw', $path) or die "Failed to read $path: $!";
    read($fh, my $sniff, 16);
    close($fh);

    if ($sniff =~ /^SQLite format 3\0/) {
        $self->{+FLAVOR}      //= 'sqlite';
        $self->{+DSN}           = "dbi:SQLite:dbname=" . $path;
        $self->{+_SIDECAR_MODE} = 'sqlite_file';
        return;
    }

    if ($sniff =~ /^\s*\{/) {
        open(my $fh2, '<:raw', $path) or die "Failed to read $path: $!";
        local $/;
        my $bytes = <$fh2>;
        close($fh2);

        my $info = decode_json($bytes);
        $self->{+DSN}     //= $info->{dsn};
        $self->{+FLAVOR}  //= $info->{flavor};
        $self->{+PROJECT} //= $info->{project};
        $self->{+USER}    //= $info->{user};
        $self->{+HOST}    //= $info->{host};
        $self->{+CWD}     //= $info->{cwd};
        $self->{+STARTED} //= $info->{started};

        croak "Sidecar at $path missing dsn"    unless $self->{+DSN};
        croak "Sidecar at $path missing flavor" unless $self->{+FLAVOR};

        $self->{+_SIDECAR_MODE} = 'json';
        return;
    }

    croak "Harness file $path is neither a SQLite database nor a JSON sidecar";
}

sub _write_sidecar {
    my $self = shift;

    my %payload = (
        dsn     => $self->{+DSN},
        flavor  => $self->{+FLAVOR},
        pid     => $$,
        project => $self->{+PROJECT},
        user    => $self->{+USER},
        host    => $self->{+HOST},
        cwd     => $self->{+CWD},
        started => $self->{+STARTED},
    );

    write_file_atomic($self->{+PATH}, encode_json(\%payload));
    return;
}

=head1 PUBLIC METHODS

=over 4

=item $h = Test2::Harness2->connect($path)

=item $h = Test2::Harness2->connect(%args)

Connect to an existing `.t2h2` file (or a passed-in DSN). The
single-positional form is treated as C<path>; otherwise accepts the
same named-argument form as C<new>. Croaks if neither C<path> nor
C<dsn> is supplied. Does not run the schema-create step.

=back

=cut

sub connect {
    my $class = shift;
    my (%args) = @_ == 1 ? (path => $_[0]) : @_;

    croak "Missing path or dsn"
        unless $args{path} || $args{dsn};

    return $class->new(%args);
}

=over 4

=item $type = $h->blob_sql_type

Value to pass as the third argument to L<DBI/bind_param> when
binding a binary blob on this handle's flavor. SQLite and the
mysql family return C<DBI::SQL_BLOB()>; postgres returns
C<< { pg_type => DBD::Pg::PG_BYTEA() } >>. C<bind_param> accepts
both scalar and hashref forms, so callers do not need to branch.

=back

=cut

sub blob_sql_type {
    my $self = shift;
    my $flavor = $self->{+FLAVOR};

    return DBI::SQL_BLOB() if $flavor eq 'sqlite';
    return DBI::SQL_BLOB() if $flavor =~ /^(mysql|mariadb|percona)$/;

    if ($flavor eq 'postgres') {
        require DBD::Pg;
        return {pg_type => DBD::Pg::PG_BYTEA()};
    }

    croak "blob_sql_type not configured for flavor '$flavor'";
}

=over 4

=item $row = $h->fetch($table, %where)

=item $row = $h->fetch($table, \%where)

=item $row = $h->fetch($table, \%where, %extras)

=item $row = $h->fetch($table, where => \%where, %extras)

Single row object matching the where clause, or C<undef>. C<$table>
may be a table name (C<'users'>) or a row class name
(C<'Test2::Harness2::DB::User'>). Internally calls C<fetch_all> with
C<limit =E<gt> 2> so a busted query that matches many rows croaks
without dragging the full result set across the wire. Croaks if
more than one row matches.

=back

=cut

sub fetch {
    my $self  = shift;
    my $table = shift;
    my ($where, %extras) = _normalize_where_args(@_);
    $extras{limit} //= 2;
    my @rows = $self->fetch_all($table, $where, %extras);
    croak "fetch returned more than one row for $table" if @rows > 1;
    return $rows[0];
}

=over 4

=item @rows = $h->fetch_all($table, %where)

=item @rows = $h->fetch_all($table, \%where)

=item @rows = $h->fetch_all($table, \%where, %extras)

=item @rows = $h->fetch_all($table, where => \%where, %extras)

All row objects matching the where clause. Where-clause shapes:
flat key/value pairs (legacy), a positional hashref, or an explicit
C<< where =E<gt> \%where >> keyword. Extras (recognised:
C<limit =E<gt> $count>) ride alongside.

=back

=cut

sub fetch_all {
    my $self  = shift;
    my $table = shift;
    my ($where, %extras) = _normalize_where_args(@_);

    my $class = $self->_row_class($table);
    my $tname = $class->TABLE;

    my ($sql, @binds) = $self->_build_select($tname, $where, \%extras);
    my $rows = $self->{+DBH}->selectall_arrayref($sql, {Slice => {}}, @binds);

    return map { $class->new(_handle => $self, %$_) } @$rows;
}

sub _normalize_where_args {
    return ({}) unless @_;

    if (ref($_[0]) eq 'HASH') {
        my $where = shift;
        return ($where, @_);
    }

    my %args = @_;
    if (ref($args{where}) eq 'HASH') {
        my $where = delete $args{where};
        return ($where, %args);
    }

    my %extras;
    for my $key (qw/limit/) {
        $extras{$key} = delete $args{$key} if exists $args{$key};
    }
    return (\%args, %extras);
}

=over 4

=item @rows = $h->insert($table, \%row1, \%row2, ...)

Insert one or more rows in a single multi-VALUES INSERT and return
them as row objects with their primary key filled in. Uses the
per-flavor identifier-range trick to recover the assigned IDs
(SQLite: last_insert_rowid range; MySQL family: LAST_INSERT_ID
range). Any column whose name ends in C<_uuid> is filled with a
freshly generated UUID when the caller leaves it blank.

=back

=cut

sub insert {
    my ($self, $table, @rows) = @_;
    return unless @rows;

    my $class = $self->_row_class($table);
    my $tname = $class->TABLE;
    my $pk    = $class->PRIMARY_KEY;
    my @cols  = $class->COLUMNS;

    @cols = grep { $_ ne $pk } @cols;
    my @uuid_cols = grep { /_uuid$/ } @cols;

    my @inserts = map { $self->_row_to_insertable($class, $_) } @rows;

    my $placeholders = '(' . join(',', ('?') x scalar(@cols)) . ')';
    my $sql          = sprintf(
        "INSERT INTO %s (%s) VALUES %s",
        $tname,
        join(',', @cols),
        join(',', ($placeholders) x scalar(@inserts)),
    );

    my @binds;
    for my $row (@inserts) {
        for my $uc (@uuid_cols) {
            $row->{$uc} //= gen_uuid();
        }
        push @binds => map { $row->{$_} } @cols;
    }

    my @ids;
    if ($self->{+FLAVOR} eq 'postgres') {
        $sql .= " RETURNING $pk";
        my $rows = $self->{+DBH}->selectall_arrayref($sql, undef, @binds);
        @ids = map { $_->[0] } @$rows;
    }
    else {
        my $sth = $self->{+DBH}->prepare($sql);
        $sth->execute(@binds);
        @ids = $self->_recover_ids($tname, $pk, scalar(@inserts));
    }

    my @out;
    for my $i (0 .. $#inserts) {
        my %row = (%{$inserts[$i]}, $pk => $ids[$i]);
        push @out => $class->new(_handle => $self, %row);
    }
    return @out;
}

=over 4

=item $h->disconnect

Close the database handle and remove the `.t2h2` file the handle
created (if any). Idempotent.

=back

=cut

sub disconnect {
    my $self = shift;

    if (my $dbh = delete $self->{+DBH}) {
        $dbh->disconnect;
    }

    if ($self->{+_OWNS_FILE} && $self->{+PATH} && -e $self->{+PATH}) {
        unlink($self->{+PATH});
        if (($self->{+_SIDECAR_MODE} // '') eq 'sqlite_file') {
            my $wal = $self->{+PATH} . '-wal';
            my $shm = $self->{+PATH} . '-shm';
            unlink($wal) if -e $wal;
            unlink($shm) if -e $shm;
        }
    }

    delete $self->{+_QUICKDB};
    return;
}

sub DESTROY {
    my $self = shift;
    $self->disconnect if $self->{+DBH};
}

sub _open_dbh {
    my $self = shift;

    my %opts = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    );
    $opts{sqlite_use_immediate_transaction} = 1 if $self->{+FLAVOR} eq 'sqlite';

    my $dbh = DBI->connect($self->{+DSN}, undef, undef, \%opts);

    if ($self->{+FLAVOR} eq 'sqlite') {
        $dbh->do("PRAGMA foreign_keys = ON");
        $dbh->do("PRAGMA journal_mode = WAL");
        $dbh->do("PRAGMA synchronous = NORMAL");
        $dbh->do("PRAGMA busy_timeout = 5000");
        $dbh->do("PRAGMA temp_store = MEMORY");
    }

    $self->{+DBH} = $dbh;
    return;
}

sub _schema_dir {
    my $self = shift;
    return $self->{+_SCHEMA_DIR} //= $self->_find_schema_dir;
}

sub _find_schema_dir {
    my $self = shift;

    my $here   = $INC{'Test2/Harness2.pm'} or die "Test2::Harness2 not loaded?";
    my $abs    = File::Spec->rel2abs($here);
    my $libdir = dirname(dirname(dirname($abs)));
    my $repo   = File::Spec->catdir($libdir, 'share', 'schema');
    return $repo if -d $repo;

    require File::ShareDir;
    my $share;
    my $ok  = eval { $share = File::ShareDir::dist_dir('Test2-Harness2'); 1 };
    my $err = $@;
    warn "File::ShareDir::dist_dir failed: $err" unless $ok;
    if (defined $share) {
        my $dir = File::Spec->catdir($share, 'schema');
        return $dir if -d $dir;
    }

    die "Cannot locate share/schema (checked '$repo' and File::ShareDir for Test2-Harness2)";
}

sub _load_schema {
    my $self = shift;

    my $path = File::Spec->catfile($self->_schema_dir, "$self->{+FLAVOR}.sql");
    my $sql  = read_file($path);

    $sql =~ s{^\s*--[^\n]*\n}{}mg;
    my @stmts = grep { /\S/ } split /;\s*(?:\n|\z)/, $sql;

    $self->{+DBH}->begin_work;
    my $ok = eval {
        for my $stmt (@stmts) {
            $stmt =~ s/^\s+//;
            $stmt =~ s/\s+$//;
            next unless length $stmt;
            $self->{+DBH}->do($stmt);
        }
        $self->{+DBH}->commit;
        1;
    };
    my $err = $@;
    unless ($ok) {
        warn "schema-load rollback failed: $@"
            unless eval { $self->{+DBH}->rollback; 1 };
        die $err;
    }
    return;
}

sub _row_class {
    my ($self, $table) = @_;

    my $class = $table =~ /::/ ? $table : table_to_db_class($table);

    my $ok = eval { load_module($class); 1 };
    croak "could not load row class '$class' for table '$table': $@" unless $ok;

    return $class;
}

sub _row_to_insertable {
    my ($self, $class, $row) = @_;
    my $obj = blessed($row) ? $row : $class->new(%$row);
    my %h = %{$obj};
    delete $h{_handle};
    delete $h{_orig};
    return \%h;
}

sub _build_select {
    my ($self, $table, $where, $extras) = @_;
    $extras //= {};

    my @binds;
    my $sql = "SELECT * FROM $table";

    if ($where && keys %$where) {
        my @parts;
        for my $k (sort keys %$where) {
            if (!defined $where->{$k}) {
                push @parts => "$k IS NULL";
            }
            else {
                push @parts => "$k = ?";
                push @binds => $where->{$k};
            }
        }
        $sql .= " WHERE " . join(' AND ', @parts);
    }

    if (defined $extras->{limit}) {
        $sql .= " LIMIT " . int($extras->{limit});
    }

    return ($sql, @binds);
}

sub _recover_ids {
    my ($self, $table, $pk, $n) = @_;

    if ($self->{+FLAVOR} eq 'sqlite') {
        my $last = $self->{+DBH}->sqlite_last_insert_rowid;
        return ($last - $n + 1 .. $last);
    }

    if ($self->{+FLAVOR} =~ /^(mysql|mariadb|percona)$/) {
        my ($first) = $self->{+DBH}->selectrow_array("SELECT LAST_INSERT_ID()");
        return ($first .. $first + $n - 1);
    }

    croak "_recover_ids: no id-recovery strategy for flavor '$self->{+FLAVOR}'";
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut
