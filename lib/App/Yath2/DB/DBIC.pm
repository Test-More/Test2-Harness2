package App::Yath2::DB::DBIC;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <file <dsn <user <pass <attrs <dbh
    <schema
    <uuid <archive_id
    <sealed
    <flavor_override
    +_internal
};

use Role::Tiny::With;

# Forward the heavier Group-A methods to the Internal helper. The role's
# `requires` list is checked at compile time when `with` runs, so the
# subs must exist before the `with` call -- a runtime `for ... no strict
# refs *{$m} = sub {...}` would fail the role check. A BEGIN block
# installs them ahead of `with`.
BEGIN {
    for my $m (qw{
        artifacts event events end_of_events EOE reset
        extract archive insert
    }) {
        no strict 'refs';
        *{ __PACKAGE__ . "::$m" } = sub {
            my $self = shift;
            my $i = $self->_internal;
            $i->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $self->{+ARCHIVE_ID}
                if defined $self->{+ARCHIVE_ID}
                && !defined $i->{App::Yath2::DB::Internal::ARCHIVE_ID()};
            $i->{App::Yath2::DB::Internal::UUID()} //= $self->{+UUID}
                if defined $self->{+UUID};
            # Honor list / scalar context the caller invoked us in;
            # events() in particular returns a list and the caller
            # captures it into an array.
            my $wantarray = wantarray;
            my @rv;
            my $rv;
            if ($wantarray) {
                @rv = $i->$m(@_);
            } elsif (defined $wantarray) {
                $rv = $i->$m(@_);
            } else {
                $i->$m(@_);
            }
            # Mirror state changes back. insert() in particular sets
            # ARCHIVE_ID + UUID + SEALED on the Internal helper; without
            # mirroring, callers reading $self->uuid / $self->archive_id
            # / $self->sealed after insert() get undef on the DBIC outer.
            $self->{+ARCHIVE_ID} = $i->{App::Yath2::DB::Internal::ARCHIVE_ID()}
                if defined $i->{App::Yath2::DB::Internal::ARCHIVE_ID()};
            $self->{+UUID} = $i->{App::Yath2::DB::Internal::UUID()}
                if defined $i->{App::Yath2::DB::Internal::UUID()};
            $self->{+SEALED} = $i->{App::Yath2::DB::Internal::SEALED()}
                if $i->{App::Yath2::DB::Internal::SEALED()};
            return @rv if $wantarray;
            return $rv if defined $wantarray;
            return;
        };
    }
}

with 'App::Yath2::Role::DB::Backend';

# Single-class DBIx::Class backend for yath log archives.
#
# This class consumes App::Yath2::Role::DB::Backend. Schema bootstrap
# remains share/schema/$flavor.sql-driven via the role; $schema->deploy
# is never called.
#
# The Group-A reader/writer surface is broad and tightly coupled to
# flavor-specific UUID, JSON, datetime, and binary-payload handling.
# To keep this class focused on the DBIC layer (Result classes,
# ResultSet-shaped reads), the heavier methods delegate to a shared
# App::Yath2::DB::Internal::* instance bound to the same DBI handle.
# Both objects use the same underlying dbh, so transactional state
# stays consistent; the DBIC schema and the Internal helper are two
# views over one connection.

sub init {
    my $self = shift;
    require App::Yath2::DB::DBIC::Schema;

    if (defined $self->{+SCHEMA}) {
        # Caller passed a connected DBIx::Class::Schema. Keep it.
    }
    elsif (defined $self->{+DBH}) {
        my $dbh = $self->{+DBH};
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(sub { $dbh });
    }
    elsif (defined $self->{+DSN}) {
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(
            $self->{+DSN},
            $self->{+USER},
            $self->{+PASS},
            $self->{+ATTRS} // { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
        );
    }
    elsif (defined $self->{+FILE}) {
        my $file = $self->{+FILE};
        if (!-e $file) {
            require File::Basename;
            require File::Path;
            my $par = File::Basename::dirname($file);
            File::Path::make_path($par) if length $par && !-d $par;
        }
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(
            "dbi:SQLite:dbname=$file", '', '',
            {
                RaiseError     => 1,
                PrintError     => 0,
                AutoCommit     => 1,
                sqlite_unicode => 1,
            },
        );
        # Apply the same SQLite pragmas the Internal::Sqlite backend
        # uses (per share/schema/SCHEMA.md §8). Doing it here rather
        # than in the Internal helper keeps the DBIC-only code path
        # functional even when nothing has triggered _internal yet.
        my $dbh = $self->{+SCHEMA}->storage->dbh;
        $dbh->do('PRAGMA journal_mode = WAL');
        $dbh->do('PRAGMA synchronous = NORMAL');
        $dbh->do('PRAGMA busy_timeout = 5000');
        $dbh->do('PRAGMA foreign_keys = ON');
        $dbh->do('PRAGMA temp_store = MEMORY');
    }
    else {
        croak "DBIC backend requires one of: schema, dbh, dsn, file";
    }

    # Bootstrap goes through the Internal helper so DBIC's
    # preprocess_schema_sql (which delegates to Internal) doesn't
    # cause recursive bootstrap. Internal's init runs bootstrap_schema
    # itself, so just instantiating _internal here suffices.
    $self->_internal;

    return;
}

# ----- core role-required methods -----

sub flavor {
    my $self = shift;
    # Caller-supplied flavor wins (caller knows whether they're talking
    # to MySQL or MariaDB through DBD::MariaDB).
    return $self->{+FLAVOR_OVERRIDE} if defined $self->{+FLAVOR_OVERRIDE};
    # sqlt_type doesn't distinguish MariaDB from MySQL when DBD::MariaDB
    # is the underlying driver (both come back as 'MySQL'). Sniff the
    # actual server first, fall back to sqlt_type.
    my $driver;
    my $ok = eval { $driver = $self->{+SCHEMA}->storage->dbh->{Driver}{Name}; 1 };
    my $err = $@;
    $driver //= '';
    return 'mariadb' if $driver eq 'MariaDB';
    return 'mysql'   if $driver eq 'mysql';
    my $t = $self->{+SCHEMA}->storage->sqlt_type;
    my $f = {
        SQLite     => 'sqlite',
        PostgreSQL => 'postgres',
        MySQL      => 'mysql',
        MariaDB    => 'mariadb',
    }->{$t // ''};
    croak "unsupported flavor '" . ($t // '<undef>') . "' (DBIC sqlt_type)"
        unless $f;
    return $f;
}

# UUID codec: route through the lazy Internal helper so DBIC.pm doesn't
# duplicate the per-flavor UUID conversion logic. Internal::Sqlite is
# identity, Internal::Postgres / ::MariaDB upper-case, ::MySQL packs
# canonical-string <-> BINARY(16). All read paths returning archive_uuid
# values must run through _uuid_from_db; all bind/find paths taking a
# caller-supplied uuid must run through _uuid_to_db.
sub _uuid_to_db   { $_[0]->_internal->_uuid_to_db($_[1])   }
sub _uuid_from_db { $_[0]->_internal->_uuid_from_db($_[1]) }

# Always return a live handle (DBIC's storage reconnects as needed).
# Override the slot accessor HashBase generated for `<dbh` so callers
# never hit a stale handle if storage reconnected under us.
{
    no warnings 'redefine';
    *dbh = sub { $_[0]->{+SCHEMA}->storage->dbh };
}

# Reuse the Internal flavor's preprocess_schema_sql override (postgres
# strips the COMPRESSION zstd clause when the server build lacks it).
sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    my $flavor = $self->flavor;
    return $sql unless $flavor eq 'postgres';
    return $self->_internal->preprocess_schema_sql($sql);
}

# ----- internal-helper bridge -----
#
# Lazily create an App::Yath2::DB::Internal::* instance bound to the
# same dbh. The Internal class houses ~3000 LoC of flavor-aware helpers
# (UUID codecs, JSON codecs, datetime, binary payload binding, the
# event walker, populate-summary-rows, reconstruction). Re-implementing
# all of that in DBIC ResultSet vocabulary would duplicate the file
# verbatim with no behavior gain. Sharing the dbh is the standard DBIC
# escape hatch (see DBIx::Class::Storage::DBI documentation on
# storage->dbh and dbh_do); the two views over one handle stay
# transactionally consistent.
sub _internal {
    my $self = shift;
    return $self->{+_INTERNAL} //= do {
        require App::Yath2::DB;
        my $flavor = $self->flavor;
        my $class = App::Yath2::DB::internal_class_for_flavor($flavor);

        require Test2::Harness2::Util;
        my $file = Test2::Harness2::Util::mod2file($class);
        require $file;

        my $dbh = $self->dbh;
        my %extra;
        $extra{uuid} = $self->{+UUID} if defined $self->{+UUID};
        # The Sqlite Internal helper uses {file} for seal => 1 path
        # resolution. Forward it from the DBIC outer when present so
        # insert(seal => 1) works on the DBIC backend too.
        $extra{file} = $self->{+FILE} if $flavor eq 'sqlite' && defined $self->{+FILE};
        my $obj = $class->new(dbh => $dbh, %extra);
        # Mirror archive_id resolution if we already resolved one.
        $obj->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $self->{+ARCHIVE_ID}
            if defined $self->{+ARCHIVE_ID};
        $obj;
    };
}

# Resolve archive_id lazily from uuid via the Archive ResultSet.
# Group-A methods that operate per-archive call this first.
sub _archive_id_or_die {
    my $self = shift;
    return $self->{+ARCHIVE_ID} if defined $self->{+ARCHIVE_ID};

    my $u = $self->{+UUID};
    if (defined $u) {
        # Caller-supplied uuid is canonical hex; convert to the DB-native
        # form before binding (BINARY(16) on MySQL, uppercase on
        # Postgres / MariaDB, identity on SQLite).
        my $row = $self->{+SCHEMA}->resultset('Archive')
            ->find({ archive_uuid => $self->_uuid_to_db($u) });
        croak "no archive '$u' in this DB" unless $row;
        $self->_internal->_check_archive_version($u, $row->archive_version);
        $self->{+ARCHIVE_ID} = $row->archive_id;
        $self->_internal->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $row->archive_id;
        $self->_internal->{App::Yath2::DB::Internal::UUID()} //= $u;
        return $self->{+ARCHIVE_ID};
    }

    # Single-archive convenience: if exactly one archive exists, use it.
    my @rows = $self->{+SCHEMA}->resultset('Archive')->all;
    if (@rows == 1) {
        # archive_uuid coming back from DBIC is in DB-native form; stash
        # the canonical (decoded) form in $self->{+UUID} so external
        # callers see a normal hex uuid rather than packed bytes /
        # uppercase strings.
        my $canon = $self->_uuid_from_db($rows[0]->archive_uuid);
        $self->_internal->_check_archive_version($canon, $rows[0]->archive_version);
        $self->{+ARCHIVE_ID} = $rows[0]->archive_id;
        $self->{+UUID}       = $canon;
        $self->_internal->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $self->{+ARCHIVE_ID};
        $self->_internal->{App::Yath2::DB::Internal::UUID()}       = $canon;
        return $self->{+ARCHIVE_ID};
    }

    croak "no archives in this DB" unless @rows;
    croak "ambiguous; specify uuid => ... (this DB holds " . scalar(@rows) . " archives)";
}

# ----- Group B: multi-archive surface -----

sub archives {
    my $self = shift;
    # archive_uuid columns come back in DB-native form (BINARY(16) on
    # MySQL, uppercase strings on Postgres / MariaDB). Round-trip every
    # row through _uuid_from_db so callers always see canonical hex.
    return map { $self->_uuid_from_db($_->archive_uuid) }
           $self->{+SCHEMA}->resultset('Archive')
                ->search(undef, { order_by => 'archive_id' })->all;
}

sub archive_count {
    my $self = shift;
    return scalar $self->{+SCHEMA}->resultset('Archive')->count;
}

sub has_archive {
    my ($self, $uuid) = @_;
    return 0 unless defined $uuid;
    for my $u ($self->archives) {
        return 1 if lc($u) eq lc($uuid);
    }
    return 0;
}

sub scoped {
    my ($self, $uuid) = @_;
    croak "scoped() requires a uuid" unless defined $uuid;
    # Propagate flavor_override to the new instance. The DBD::MariaDB
    # driver speaks both MySQL and MariaDB, so flavor() cannot reliably
    # distinguish them from the driver name alone — the caller-supplied
    # override is the only source of truth, and dropping it here would
    # cause the new instance to silently misclassify (e.g. choose the
    # MariaDB Internal helper's text-uuid codec for a MySQL BINARY(16)
    # column, breaking _resolve_archive's uuid match).
    return ref($self)->new(
        schema => $self->{+SCHEMA},
        uuid   => $uuid,
        (defined $self->{+FLAVOR_OVERRIDE}
            ? (flavor_override => $self->{+FLAVOR_OVERRIDE})
            : ()),
    );
}

# ----- Group A: native DBIC translations -----

sub services {
    my ($self, $run_id) = @_;
    my $aid = $self->_archive_id_or_die;
    my $rs  = $self->{+SCHEMA}->resultset('Service');

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        my $rid = $self->_run_db_id($run_id);
        return map { $_->name } $rs->search(
            { archive_id => $aid, run_id => $rid },
            { order_by   => 'name' },
        )->all;
    }
    return map { $_->name } $rs->search(
        { archive_id => $aid, run_id => undef },
        { order_by   => 'name' },
    )->all;
}

sub runs {
    my $self = shift;
    my $aid = $self->_archive_id_or_die;
    return map { $_->run_ord }
        $self->{+SCHEMA}->resultset('Run')->search(
            { archive_id => $aid },
            { order_by   => 'run_ord' },
        )->all;
}

sub jobs {
    my ($self, $run_id) = @_;
    croak "run_id is required" unless defined $run_id;
    croak "no such run: $run_id" unless $self->has_run($run_id);
    my $aid = $self->_archive_id_or_die;
    my $rid = $self->_run_db_id($run_id);
    return map { $_->job_ord }
        $self->{+SCHEMA}->resultset('Job')->search(
            { archive_id => $aid, run_id => $rid },
            { order_by   => 'job_ord' },
        )->all;
}

sub tries {
    my ($self, $run_id, $job_id) = @_;
    croak "run_id is required" unless defined $run_id;
    croak "job_id is required" unless defined $job_id;
    croak "no such run: $run_id"             unless $self->has_run($run_id);
    croak "no such job: $run_id/$job_id"     unless $self->has_job($run_id, $job_id);
    my $jid = $self->_job_db_id($run_id, $job_id);
    return map { $_->try_ord }
        $self->{+SCHEMA}->resultset('JobTry')->search(
            { job_id => $jid },
            { order_by => 'try_ord' },
        )->all;
}

sub last_try {
    my ($self, $run_id, $job_id) = @_;
    my @t = $self->tries($run_id, $job_id);
    return undef unless @t;
    return $t[-1];
}

sub has_service {
    my ($self, $name, $run_id) = @_;
    croak "service name is required" unless defined $name && length $name;
    my $aid = $self->_archive_id_or_die;
    my $rs  = $self->{+SCHEMA}->resultset('Service');

    if (defined $run_id) {
        return 0 unless $self->has_run($run_id);
        my $rid = $self->_run_db_id($run_id);
        return $rs->search(
            { archive_id => $aid, run_id => $rid, name => $name }
        )->count ? 1 : 0;
    }
    return $rs->search(
        { archive_id => $aid, run_id => undef, name => $name }
    )->count ? 1 : 0;
}

sub has_run {
    my ($self, $run_id) = @_;
    return 0 unless defined $run_id && length $run_id;
    return 0 unless $run_id =~ /^\d+\z/;
    my $aid = $self->_archive_id_or_die;
    return $self->{+SCHEMA}->resultset('Run')->search(
        { archive_id => $aid, run_ord => $run_id }
    )->count ? 1 : 0;
}

sub has_job {
    my ($self, $run_id, $job_id) = @_;
    return 0 unless $self->has_run($run_id);
    return 0 unless defined $job_id && length $job_id;
    return 0 unless $job_id =~ /^\d+\z/;
    my $rid = $self->_run_db_id($run_id);
    my $aid = $self->_archive_id_or_die;
    return $self->{+SCHEMA}->resultset('Job')->search(
        { archive_id => $aid, run_id => $rid, job_ord => $job_id }
    )->count ? 1 : 0;
}

sub has_try {
    my ($self, $run_id, $job_id, $job_try) = @_;
    return 0 unless $self->has_job($run_id, $job_id);
    return 0 unless defined $job_try && length $job_try;
    return 0 unless $job_try =~ /^\d+\z/;
    my $jid = $self->_job_db_id($run_id, $job_id);
    return $self->{+SCHEMA}->resultset('JobTry')->search(
        { job_id => $jid, try_ord => $job_try }
    )->count ? 1 : 0;
}

# DB-id translators (run/job/try ord -> primary key id) via DBIC.
sub _run_db_id {
    my ($self, $run_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $row = $self->{+SCHEMA}->resultset('Run')->find(
        { archive_id => $aid, run_ord => $run_ord }
    );
    croak "no run with ord $run_ord" unless $row;
    return $row->run_id;
}

sub _job_db_id {
    my ($self, $run_ord, $job_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $rid = $self->_run_db_id($run_ord);
    my $row = $self->{+SCHEMA}->resultset('Job')->find(
        { archive_id => $aid, run_id => $rid, job_ord => $job_ord }
    );
    croak "no job with ord $job_ord in run $run_ord" unless $row;
    return $row->job_id;
}

# ----- Group A: native DBIC primitives feeding role helpers -----

# DB primitive consumed by App::Yath2::Role::DB::Backend::list_files.
# Returns an arrayref of hashrefs, one per artifacts row in the given
# archive_id, with the scope FKs and joined ord/name fields the role
# helpers need to compute on-disk paths. Shape parity with the
# Internal raw-SQL implementation.
sub _artifact_rows_for_archive {
    my ($self, $aid) = @_;
    my $rs = $self->{+SCHEMA}->resultset('Artifact')->search(
        { 'me.archive_id' => $aid },
        { prefetch => [
            'run',
            { service => 'run' },
            { job_try => { job => 'run' } },
        ] },
    );

    my @rows;
    while (my $a = $rs->next) {
        my %r = (
            artifact_id   => $a->artifact_id,
            run_id        => $a->run_id,
            service_id    => $a->service_id,
            job_try_id    => $a->job_try_id,
            artifact_kind => $a->artifact_kind,
            format        => $a->format,
            name          => $a->name,
            compressed    => $a->compressed,
        );
        if (my $svc = $a->service) {
            $r{service_name} = $svc->name;
            if (my $sr = $svc->run) { $r{s_run_ord} = $sr->run_ord }
        }
        if (my $rn = $a->run) {
            $r{run_ord} = $rn->run_ord;
        }
        if (my $jt = $a->job_try) {
            $r{try_ord} = $jt->try_ord;
            if (my $j = $jt->job) {
                $r{job_ord} = $j->job_ord;
                if (my $jr = $j->run) { $r{j_run_ord} = $jr->run_ord }
            }
        }
        push @rows, \%r;
    }
    return \@rows;
}

# ----- Group A: delegated to Internal helper -----
#
# These methods carry deeply-coupled flavor-specific behavior (UUID
# bind shapes, JSON column codecs, datetime parsing, binary payload
# bind types, the depth-first event walker, and the spec/report
# reconstruction layer). The Internal helper provides them all over
# the same dbh; we forward verbatim. Return shapes match Internal
# exactly so the parameterised cross-backend tests Layer 1 introduces
# can compare both backends side-by-side.
#
# As primitives (e.g. _artifact_rows_for_archive) get extracted to the
# role and the role's defaults move up in scope, this delegation list
# shrinks; eventually the BEGIN forwarder above can be retired.

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::DBIC - DBIx::Class backend for yath DB-archive storage.

=head1 SYNOPSIS

    use App::Yath2::DB;

    my $db = App::Yath2::DB->open(
        file    => '/tmp/run.yath',
        backend => 'dbic',
    );

    my $scoped = $db->scoped($uuid);
    my @runs   = $scoped->runs;

=head1 DESCRIPTION

Single-class implementation of L<App::Yath2::Role::DB::Backend>.
Wraps an L<App::Yath2::DB::DBIC::Schema> instance and exposes the
role's reader / writer surface.

Schema bootstrap is driven by F<share/schema/$flavor.sql> via
L<App::Yath2::Role::DB::Backend>; C<deploy()> is never called.

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
