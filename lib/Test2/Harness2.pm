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

use Object::HashBase qw{
    <dsn
    <flavor
    <project
    <user
    <name
    <discovery_path
    <dbh
    <tmpdir
    +_owns_file
    +_schema_dir
};

sub init {
    my $self = shift;

    $self->{+FLAVOR}   //= 'sqlite';
    $self->{+PROJECT}  //= $ENV{T2H2_PROJECT} // _basename_cwd();
    $self->{+USER}     //= $ENV{USER}        // 'unknown';
    $self->{+TMPDIR}   //= File::Spec->tmpdir;
    $self->{+NAME}     //= sprintf('%s-%s-%d.t2h2', $self->{+USER}, $self->{+PROJECT}, $$);
    $self->{+DISCOVERY_PATH} //= File::Spec->catfile($self->{+TMPDIR}, $self->{+NAME});

    return if $self->{+DBH};

    my $existed = -e $self->{+DISCOVERY_PATH};
    $self->{+_OWNS_FILE} = !$existed;

    $self->{+DSN} //= "dbi:SQLite:dbname=" . $self->{+DISCOVERY_PATH};
    $self->_open_dbh;

    $self->_load_schema if !$existed;
}

sub connect {
    my $class = shift;
    my (%args) = @_ == 1 ? (discovery_path => $_[0]) : @_;

    croak "Missing discovery_path or dsn"
        unless $args{discovery_path} || $args{dsn};

    return $class->new(%args);
}

sub _basename_cwd {
    my @parts = File::Spec->splitdir(File::Spec->rel2abs(File::Spec->curdir));
    return $parts[-1] // 'unknown';
}

sub _open_dbh {
    my $self = shift;
    my $dbh  = DBI->connect(
        $self->{+DSN}, undef, undef,
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            sqlite_use_immediate_transaction => 1,
        },
    );

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
    my $here = $INC{'Test2/Harness2.pm'} or die "Test2::Harness2 not loaded?";
    my $abs  = File::Spec->rel2abs($here);
    my $libdir = dirname(dirname(dirname($abs)));
    my $dir    = File::Spec->catdir($libdir, 'share', 'schema');
    return $dir if -d $dir;
    die "Cannot locate share/schema relative to $here";
}

sub _load_schema {
    my $self = shift;

    my $path = File::Spec->catfile($self->_schema_dir, "$self->{+FLAVOR}.sql");
    open(my $fh, '<', $path) or die "Failed to open $path: $!";
    local $/;
    my $sql = <$fh>;
    close($fh);

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
        eval { $self->{+DBH}->rollback };
        die $err;
    }
    return;
}

sub disconnect {
    my $self = shift;

    if (my $dbh = delete $self->{+DBH}) {
        $dbh->disconnect;
    }

    if ($self->{+_OWNS_FILE} && $self->{+DISCOVERY_PATH} && -e $self->{+DISCOVERY_PATH}) {
        unlink($self->{+DISCOVERY_PATH});
        my $wal = $self->{+DISCOVERY_PATH} . '-wal';
        my $shm = $self->{+DISCOVERY_PATH} . '-shm';
        unlink($wal) if -e $wal;
        unlink($shm) if -e $shm;
    }
    return;
}

sub DESTROY {
    my $self = shift;
    $self->disconnect if $self->{+DBH};
}

my %TABLE_TO_CLASS = (
    users              => 'Test2::Harness2::User',
    hosts              => 'Test2::Harness2::Host',
    projects           => 'Test2::Harness2::Project',
    versions           => 'Test2::Harness2::Project::Version',
    vcs_info           => 'Test2::Harness2::Project::VcsInfo',
    test_files         => 'Test2::Harness2::Project::TestFile',
    instances          => 'Test2::Harness2::Instance',
    runners            => 'Test2::Harness2::Runner',
    collectors         => 'Test2::Harness2::Runner::Collector',
    services           => 'Test2::Harness2::Runner::Service',
    service_state      => 'Test2::Harness2::Runner::Service::State',
    requests           => 'Test2::Harness2::Runner::Service::Request',
    schedulers         => 'Test2::Harness2::Runner::Scheduler',
    resources          => 'Test2::Harness2::Runner::Resource',
    resource_snapshots => 'Test2::Harness2::Runner::Resource::Snapshot',
    runs               => 'Test2::Harness2::Runner::Run',
    jobs               => 'Test2::Harness2::Runner::Run::Job',
    job_tries          => 'Test2::Harness2::Runner::Run::Job::Try',
    artifacts          => 'Test2::Harness2::Runner::Run::Artifact',
    coverage           => 'Test2::Harness2::Runner::Run::Coverage',
    launchers          => 'Test2::Harness2::Launcher',
    launches           => 'Test2::Harness2::Launcher::Launch',
);

sub _row_class {
    my ($self, $table) = @_;

    my $class = $table =~ /::/
        ? $table
        : ($TABLE_TO_CLASS{$table} or croak "unknown table '$table'");

    unless ($class->can('new')) {
        (my $file = $class) =~ s{::}{/}g;
        require "$file.pm";
    }
    return $class;
}

sub fetch {
    my ($self, $table, %where) = @_;
    my @rows = $self->fetch_all($table, %where);
    croak "fetch returned more than one row for $table" if @rows > 1;
    return $rows[0];
}

sub fetch_all {
    my ($self, $table, %where) = @_;
    my $class = $self->_row_class($table);
    my $tname = $class->TABLE;

    my ($sql, @binds) = $self->_build_select($tname, \%where);
    my $rows = $self->{+DBH}->selectall_arrayref($sql, {Slice => {}}, @binds);

    return map {
        my $row_class = $class->class_for_row($_);
        $row_class->new(_handle => $self, %$_);
    } @$rows;
}

sub insert {
    my ($self, $table, @rows) = @_;
    return unless @rows;

    my $class = $self->_row_class($table);
    my $tname = $class->TABLE;
    my $pk    = $class->PRIMARY_KEY;
    my @cols  = $class->COLUMNS;

    @cols = grep { $_ ne $pk } @cols;

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
        push @binds => map { $row->{$_} } @cols;
    }

    my $sth = $self->{+DBH}->prepare($sql);
    $sth->execute(@binds);

    my @ids = $self->_recover_ids($tname, $pk, scalar(@inserts));

    my @out;
    for my $i (0 .. $#inserts) {
        my %row = (%{$inserts[$i]}, $pk => $ids[$i]);
        my $row_class = $class->class_for_row(\%row);
        push @out => $row_class->new(_handle => $self, %row);
    }
    return @out;
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
    my ($self, $table, $where) = @_;
    my @binds;
    my $sql = "SELECT * FROM $table";

    if (keys %$where) {
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

    return ($sql, @binds);
}

sub _recover_ids {
    my ($self, $table, $pk, $n) = @_;

    if ($self->{+FLAVOR} eq 'sqlite') {
        my $last = $self->{+DBH}->sqlite_last_insert_rowid;
        return ($last - $n + 1 .. $last);
    }

    if ($self->{+FLAVOR} eq 'postgres') {
        return;
    }

    if ($self->{+FLAVOR} =~ /^(mysql|mariadb|percona)$/) {
        my ($first) = $self->{+DBH}->selectrow_array("SELECT LAST_INSERT_ID()");
        return ($first .. $first + $n - 1);
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Harness handle: owns the database, the `.t2h2`
discovery file, and the row-object surface.

=head1 DESCRIPTION

The library-side entry point for the harness. Constructing a handle
opens (or creates) the harness's SQLite database, drops a `.t2h2`
discovery file in the system temp directory, and exposes the
fetch / fetch_all / insert helpers that every row-object class uses
to talk to its table.

Stage 5 ships the SQLite-only path. Non-default backends (Postgres,
MySQL, MariaDB, Percona, externally-hosted SQLite) land in a later
stage; the handle is shaped now so those backends slot in without
changing the public API.

=head1 SYNOPSIS

    use Test2::Harness2;

    # Create a fresh harness instance + sqlite db at
    # ${tmpdir}/${user}-${project}-${pid}.t2h2
    my $h = Test2::Harness2->new(project => 'myproj');

    # Reconnect to an existing .t2h2 file
    my $h2 = Test2::Harness2->connect($path);

    my ($user) = $h->insert(users => {name => 'alice'});
    say $user->user_id;

    my @hosts = $h->fetch_all(hosts => name => 'localhost');

    $h->disconnect;

=head1 ATTRIBUTES

=over 4

=item project

Free-form project name used as part of the default `.t2h2` filename.
Callers normally pass this in; otherwise the handle uses
C<$ENV{T2H2_PROJECT}> or, last, the basename of the current
directory.

=item user

The owning user. Defaults to C<$ENV{USER}>.

=item name

Filename for the `.t2h2` discovery file. Defaults to
C<"${user}-${project}-${pid}.t2h2">. Callers may override the
pattern in full.

=item tmpdir

System temp directory the discovery file is placed in. Defaults to
C<< File::Spec->tmpdir >>.

=item discovery_path

The full path of the `.t2h2` file. Computed from C<tmpdir> + C<name>
unless the caller passes it in directly.

=item dsn

DBI DSN for the harness database. In SQLite mode this is computed
from C<discovery_path>; callers may pass a different DSN to connect
to a database that is not the C<discovery_path> file. Non-SQLite
DSNs are reserved for a later stage.

=item flavor

Database flavor identifier (C<sqlite>, C<postgres>, C<mysql>,
C<mariadb>, C<percona>). Used to pick the matching schema file and
to branch flavor-specific SQL (placeholder syntax, ID recovery,
etc.). Defaults to C<sqlite>.

=item dbh

The owned L<DBI> database handle.

=back

=head1 PUBLIC METHODS

=over 4

=item $h = Test2::Harness2->new(%args)

Create a new harness handle and the backing `.t2h2` file. If a
backing file already exists at C<discovery_path> the handle attaches
to it instead of recreating the schema.

=item $h = Test2::Harness2->connect($path_or_args)

Connect to an existing `.t2h2` (or a passed-in DSN). Accepts either
a single positional argument (treated as C<discovery_path>) or the
same named-argument form as L</new>. Does not run the schema-create
step.

=item $row = $h->fetch($table, %where)

Return a single row object matching C<%where>, or C<undef>.
C<$table> can be a table name (C<'users'>) or a row class name
(C<'Test2::Harness2::User'>). Croaks if more than one row
matches.

=item @rows = $h->fetch_all($table, %where)

Return all row objects matching C<%where>.

=item @rows = $h->insert($table, \%row1, \%row2, ...)

Insert one or more rows in a single multi-VALUES INSERT statement,
return them as row objects with their primary key filled in. Uses
the per-flavor identifier-range trick to recover the assigned IDs
(SQLite: last_insert_rowid range; MySQL family: LAST_INSERT_ID
range).

=item $h->disconnect

Close the database handle and remove the `.t2h2` file the handle
created (if any).

=back

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
