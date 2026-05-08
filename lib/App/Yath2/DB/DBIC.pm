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
};

use Role::Tiny::With;

# Walker / write methods route through the data-layer wrapper
# (App::Yath2::DB), which carries every transformation, codec, and
# walker-state slot. The role's `requires` list is checked at compile
# time when `with` runs, so each method must be defined before that
# point.
sub event         { my $s = shift; my $db = $s->_walker_db; $db->event($db->uuid, @_) }
sub events        { my $s = shift; my $db = $s->_walker_db; $db->events($db->uuid, @_) }
sub end_of_events { my $s = shift; my $db = $s->_walker_db; $db->end_of_events($db->uuid) }
sub EOE           { my $s = shift; my $db = $s->_walker_db; $db->end_of_events($db->uuid) }
sub reset         { my $s = shift; my $db = $s->_walker_db; $db->reset($db->uuid) }

sub _walker_db {
    my $self = shift;
    return $self->{__walker_db} //= do {
        require App::Yath2::DB;
        my $u = $self->_implicit_uuid_for_op('event');
        App::Yath2::DB->_wrap_backend($self, uuid => $u);
    };
}

with 'App::Yath2::Role::DB::Backend';

# Single-class DBIx::Class backend for yath log archives.
#
# This class consumes App::Yath2::Role::DB::Backend. Schema bootstrap
# remains share/schema/$flavor.sql-driven via the role; $schema->deploy
# is never called.

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
        # Apply the SQLite pragmas defined in
        # share/schema/SCHEMA.md §8.
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

    # Bootstrap (idempotent): role-provided bootstrap_schema runs
    # share/schema/$flavor.sql against $self->dbh. Skipped on already-
    # populated DBs via _is_bootstrapped.
    $self->bootstrap_schema;

    # Single-archive shortcut + archive_version validation. Only run
    # for top-level callers (file / dsn entry points) so a sub-component
    # (caller passing a raw dbh / schema) doesn't get surprised by an
    # archive lookup at construction time.
    if ($self->{+FILE} || $self->{+DSN}) {
        $self->_eager_resolve_single_archive;
    }

    return;
}

sub _eager_resolve_single_archive {
    my $self = shift;
    my @rows = $self->{+SCHEMA}->resultset('Archive')->all;
    return unless @rows == 1;
    # _check_archive_version croaks on out-of-range; let it propagate.
    my $canon = $self->_uuid_from_db($rows[0]->archive_uuid);
    $self->_check_archive_version($canon, $rows[0]->archive_version);
    $self->{+ARCHIVE_ID} = $rows[0]->archive_id;
    $self->{+UUID}       = $canon;
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

# UUID codec aliases: callers (including the legacy archive_id
# resolver below) refer to these names. _flavor_uuid_to_db /
# _flavor_uuid_from_db are the canonical native bodies defined further
# down.
sub _uuid_to_db   { my ($self, $u)   = @_; $self->_flavor_uuid_to_db($u)   }
sub _uuid_from_db { my ($self, $val) = @_; $self->_flavor_uuid_from_db($val) }

# Always return a live handle (DBIC's storage reconnects as needed).
# Override the slot accessor HashBase generated for `<dbh` so callers
# never hit a stale handle if storage reconnected under us.
{
    no warnings 'redefine';
    *dbh = sub { $_[0]->{+SCHEMA}->storage->dbh };
}

# Postgres-only schema preprocessing: rewrite COMPRESSION zstd clause
# to whatever the live server actually supports (zstd / lz4 / drop).
# Same logic as App::Yath2::DB::SQL::preprocess_schema_sql.
sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    my $flavor = $self->flavor;
    return $sql unless $flavor eq 'postgres';

    my $algo = $self->_pg_server_compression;
    if (!defined $algo) {
        $sql =~ s/\s+COMPRESSION\s+zstd\b//gi;
    }
    elsif ($algo ne 'zstd') {
        $sql =~ s/(\bCOMPRESSION\s+)zstd\b/$1$algo/gi;
    }
    return $sql;
}

sub _pg_server_compression {
    my $self = shift;
    return $self->{_pg_server_compression} //= do {
        my $dbh = $self->dbh;
        my $probe = sub {
            my ($algo) = @_;
            return eval {
                local $dbh->{RaiseError} = 1;
                local $dbh->{PrintError} = 0;
                $dbh->do(qq{SET default_toast_compression = '$algo'});
                $dbh->do(q{RESET default_toast_compression});
                1;
            };
        };
        $probe->('zstd') ? 'zstd' : $probe->('lz4') ? 'lz4' : undef;
    };
}

# DBD::MariaDB reports the same sqlt_type as MySQL, but MariaDB lacks
# BIN_TO_UUID() (used in mysql.sql CREATE TRIGGER bodies). Detect via
# SELECT VERSION() and skip CREATE TRIGGER statements when targeting
# MariaDB.
sub _server_is_mariadb {
    my $self = shift;
    return $self->{_is_mariadb} //= do {
        my $flavor = $self->flavor;
        if    ($flavor eq 'mariadb') { 1 }
        elsif ($flavor eq 'mysql') {
            my ($v) = $self->dbh->selectrow_array('SELECT VERSION()');
            (defined $v && $v =~ /MariaDB/i) ? 1 : 0;
        }
        else { 0 }
    };
}

sub _should_skip_schema_statement {
    my ($self, $stmt) = @_;
    return 0 unless $self->flavor eq 'mysql';
    return 0 unless $self->_server_is_mariadb;
    return $stmt =~ /^CREATE\s+TRIGGER\b/i ? 1 : 0;
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
        $self->_check_archive_version($u, $row->archive_version);
        $self->{+ARCHIVE_ID} = $row->archive_id;
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
        $self->_check_archive_version($canon, $rows[0]->archive_version);
        $self->{+ARCHIVE_ID} = $rows[0]->archive_id;
        $self->{+UUID}       = $canon;
        return $self->{+ARCHIVE_ID};
    }

    croak "no archives in this DB" unless @rows;
    croak "ambiguous; specify uuid => ... (this DB holds " . scalar(@rows) . " archives)";
}

# Enforce the archive_version floor (refuses archives older than
# App::Yath2::Log->last_breaking_version). Mirrors App::Yath2::DB's
# _check_archive_version body (kept here so the resolver above can
# operate without bouncing back through the data-layer wrapper).
sub _check_archive_version {
    my ($self, $uuid, $archive_version) = @_;
    require App::Yath2::Log;
    my $floor = App::Yath2::Log->last_breaking_version;
    croak "archive '$uuid' has no archive_version stamp; refusing to read"
        unless defined $archive_version && length $archive_version;
    require version;
    return if version->parse($archive_version) >= version->parse($floor);
    croak "archive '$uuid' was written by yath $archive_version; "
        . "this dist requires >= $floor; refusing to read";
}

# ----- Group B: multi-archive surface -----

sub archives {
    my $self = shift;
    # archive_uuid columns come back in DB-native form (BINARY(16) on
    # MySQL, uppercase strings on Postgres / MariaDB). Round-trip every
    # row through _flavor_uuid_from_db so callers always see canonical
    # lowercase hex (matches App::Yath2::DB::SQL's archive_rows shape).
    return map { $self->_flavor_uuid_from_db($_->archive_uuid) }
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
    # cause the new instance to silently misclassify (e.g. pick the
    # MariaDB text-uuid codec for a MySQL BINARY(16) column, breaking
    # the archive_uuid bind in _archive_id_or_die).
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

# ----- Native read primitives + local codecs -----
#
# Codec helpers (UUID per-flavor encode/decode, JSON inflate) live
# here so DBIC speaks the Role::DB::Backend canonical-Perl-values
# contract. Walker / write methods route through the data-layer
# wrapper App::Yath2::DB (see _walker_db / _wrap_self_in_db above).

sub _flavor_uuid_to_db {
    my ($self, $u) = @_;
    return undef unless defined $u;
    my $f = $self->flavor;
    return $u                 if $f eq 'sqlite';
    return uc($u)             if $f eq 'postgres' || $f eq 'mariadb';
    if ($f eq 'mysql') {
        (my $h = $u) =~ tr/-//d;
        return pack('H*', $h);
    }
    return $u;
}

sub _flavor_uuid_from_db {
    my ($self, $val) = @_;
    return undef unless defined $val;
    my $f = $self->flavor;
    if ($f eq 'mysql') {
        return undef unless length($val) == 16;
        my $hex = lc unpack('H*', $val);
        return join '-',
            substr($hex,  0, 8),
            substr($hex,  8, 4),
            substr($hex, 12, 4),
            substr($hex, 16, 4),
            substr($hex, 20);
    }
    return lc("$val");
}

sub _maybe_decode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val;
    require Test2::Harness2::Util::JSON;
    return Test2::Harness2::Util::JSON::decode_json($val);
}

# -- archive layer ----------------------------------------------------------

sub archive_rows {
    my $self = shift;
    my @out;
    for my $row ($self->{+SCHEMA}->resultset('Archive')->search(
        undef, { order_by => 'archive_id' },
    )->all)
    {
        push @out, {
            archive_id      => $row->archive_id,
            archive_uuid    => $self->_flavor_uuid_from_db($row->archive_uuid),
            archive_version => $row->archive_version,
            sealed_at       => $row->sealed_at,
            host            => $row->host,
            user            => $row->archive_user,
            git_sha         => $row->git_sha,
            project         => $row->project,
            yath_version    => $row->yath_version,
            meta_extras     => $self->_maybe_decode_json($row->meta_extras),
        };
    }
    return \@out;
}

sub archive_for_uuid {
    my ($self, $canon) = @_;
    return undef unless defined $canon;
    for my $row (@{ $self->archive_rows }) {
        return $row if lc($row->{archive_uuid}) eq lc($canon);
    }
    return undef;
}

# archive_count is already provided above via ResultSet->count.

# -- run / job / try / service rows ----------------------------------------

sub run_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('Run')->search(
        { archive_id => $aid },
        { order_by   => 'run_ord' },
    )->all)
    {
        push @out, {
            run_id     => $r->run_id,
            run_ord    => $r->run_ord,
            run_uuid   => $self->_flavor_uuid_from_db($r->run_uuid),
            status     => $r->status,
            aborted    => $r->aborted   ? 1 : 0,
            timed_out  => $r->timed_out ? 1 : 0,
            project_id => $r->project_id,
        };
    }
    return \@out;
}

sub service_rows {
    my ($self, $aid, %filter) = @_;
    croak "archive_id required" unless defined $aid;
    my %where = (archive_id => $aid);
    if (exists $filter{run_id}) {
        $where{run_id} = $filter{run_id};
    }
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('Service')->search(
        \%where, { order_by => 'service_id' },
    )->all)
    {
        push @out, {
            service_id => $r->service_id,
            name       => $r->name,
            run_id     => $r->run_id,
        };
    }
    return \@out;
}

sub job_rows {
    my ($self, $aid, $rid) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $rid;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('Job')->search(
        { archive_id => $aid, run_id => $rid },
        { order_by   => 'job_ord' },
    )->all)
    {
        push @out, {
            job_id       => $r->job_id,
            job_ord      => $r->job_ord,
            test_file_id => $r->test_file_id,
        };
    }
    return \@out;
}

sub try_rows {
    my ($self, $jid) = @_;
    croak "job_id required" unless defined $jid;
    my @json_cols = qw/exit_decoded plan halt times child_times
                       spec_extras state_extras/;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('JobTry')->search(
        { job_id => $jid },
        { order_by => 'try_ord' },
    )->all)
    {
        my %h = $r->get_columns;
        for my $c (@json_cols) {
            $h{$c} = $self->_maybe_decode_json($h{$c}) if exists $h{$c};
        }
        push @out, \%h;
    }
    return \@out;
}

# -- existence checks -------------------------------------------------------

sub run_exists {
    my ($self, $aid, $run_ord) = @_;
    return 0 unless defined $aid && defined $run_ord;
    return 0 unless $run_ord =~ /^\d+\z/;
    return $self->{+SCHEMA}->resultset('Run')->search(
        { archive_id => $aid, run_ord => $run_ord }
    )->count ? 1 : 0;
}

sub job_exists {
    my ($self, $aid, $rid, $job_ord) = @_;
    return 0 unless defined $aid && defined $rid && defined $job_ord;
    return 0 unless $job_ord =~ /^\d+\z/;
    return $self->{+SCHEMA}->resultset('Job')->search(
        { archive_id => $aid, run_id => $rid, job_ord => $job_ord }
    )->count ? 1 : 0;
}

sub try_exists {
    my ($self, $jid, $try_ord) = @_;
    return 0 unless defined $jid && defined $try_ord;
    return 0 unless $try_ord =~ /^\d+\z/;
    return $self->{+SCHEMA}->resultset('JobTry')->search(
        { job_id => $jid, try_ord => $try_ord }
    )->count ? 1 : 0;
}

sub service_exists {
    my ($self, $aid, $name, $rid) = @_;
    return 0 unless defined $aid && defined $name;
    my %where = (archive_id => $aid, name => $name);
    $where{run_id} = $rid; # undef binds to NULL in DBIC SQL::Abstract
    return $self->{+SCHEMA}->resultset('Service')->search(\%where)->count ? 1 : 0;
}

# -- id-for-ord lookups -----------------------------------------------------

sub run_id_for_ord {
    my ($self, $aid, $run_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_ord required"    unless defined $run_ord;
    my $row = $self->{+SCHEMA}->resultset('Run')->find(
        { archive_id => $aid, run_ord => $run_ord }
    );
    croak "no run with ord $run_ord" unless $row;
    return $row->run_id;
}

sub job_id_for_ord {
    my ($self, $aid, $rid, $job_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $rid;
    croak "job_ord required"    unless defined $job_ord;
    my $row = $self->{+SCHEMA}->resultset('Job')->find(
        { archive_id => $aid, run_id => $rid, job_ord => $job_ord }
    );
    croak "no job with ord $job_ord in run_id $rid" unless $row;
    return $row->job_id;
}

sub try_id_for_ord {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required"  unless defined $jid;
    croak "try_ord required" unless defined $try_ord;
    my $row = $self->{+SCHEMA}->resultset('JobTry')->find(
        { job_id => $jid, try_ord => $try_ord }
    );
    croak "no try with ord $try_ord in job_id $jid" unless $row;
    return $row->job_try_id;
}

sub service_id_for_name {
    my ($self, $aid, $name, $rid) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "service name required" unless defined $name;
    my %where = (archive_id => $aid, name => $name);
    $where{run_id} = $rid;
    my $row = $self->{+SCHEMA}->resultset('Service')->search(\%where)->first;
    return $row ? $row->service_id : undef;
}

# -- artifact rows ----------------------------------------------------------

sub artifact_rows_for_archive {
    my ($self, $aid, %opts) = @_;
    croak "archive_id required" unless defined $aid;
    my $with_payload = $opts{with_payload} ? 1 : 0;

    my $rs = $self->{+SCHEMA}->resultset('Artifact')->search(
        { 'me.archive_id' => $aid },
        { prefetch => [
            'run',
            { service => 'run' },
            { job_try => { job => 'run' } },
        ],
          order_by => 'me.artifact_id',
        },
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
            compressed    => $a->compressed ? 1 : 0,
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
        $r{payload} = $a->payload if $with_payload;
        push @rows, \%r;
    }
    return \@rows;
}

sub artifact_row_for_scope {
    my ($self, $aid, $scope_kind, $scope_id, $kind, $name) = @_;
    croak "archive_id required"  unless defined $aid;
    croak "scope_kind required"  unless defined $scope_kind;
    croak "artifact_kind required" unless defined $kind;

    my %where = (archive_id => $aid, artifact_kind => $kind);
    if ($scope_kind eq 'run') {
        $where{run_id}     = $scope_id;
        $where{service_id} = undef;
        $where{job_try_id} = undef;
    }
    elsif ($scope_kind eq 'service') {
        $where{service_id} = $scope_id;
        $where{run_id}     = undef;
        $where{job_try_id} = undef;
    }
    elsif ($scope_kind eq 'job_try') {
        $where{job_try_id} = $scope_id;
        $where{run_id}     = undef;
        $where{service_id} = undef;
    }
    elsif ($scope_kind eq 'archive') {
        $where{run_id}     = undef;
        $where{service_id} = undef;
        $where{job_try_id} = undef;
    }
    else {
        croak "unknown scope_kind: $scope_kind";
    }
    $where{name} = defined $name ? $name : undef;

    my $row = $self->{+SCHEMA}->resultset('Artifact')->search(\%where)->first;
    return undef unless $row;

    return {
        artifact_id => $row->artifact_id,
        compressed  => $row->compressed ? 1 : 0,
        payload     => $row->payload,
        format      => $row->format,
    };
}

sub artifact_payload {
    my ($self, $artifact_id) = @_;
    croak "artifact_id required" unless defined $artifact_id;
    my $row = $self->{+SCHEMA}->resultset('Artifact')->find($artifact_id);
    return undef unless $row;
    return $row->payload;
}

# -- spec / report data layer ----------------------------------------------

sub job_spec_rows {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required" unless defined $jid;
    my @json_cols = qw/features switches extras/;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('JobSpec')->search(
        { job_id => $jid },
        { order_by => 'job_spec_id' },
    )->all)
    {
        my %h = $r->get_columns;
        for my $c (@json_cols) {
            $h{$c} = $self->_maybe_decode_json($h{$c}) if exists $h{$c};
        }
        push @out, \%h;
    }
    return \@out;
}

sub service_lifetime_rows {
    my ($self, $sid) = @_;
    croak "service_id required" unless defined $sid;
    my @json_cols = qw/exit_decoded times child_times spec_extras state_extras/;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('ServiceLifetime')->search(
        { service_id => $sid },
        { order_by => 'lifetime_ord' },
    )->all)
    {
        my %h = $r->get_columns;
        for my $c (@json_cols) {
            $h{$c} = $self->_maybe_decode_json($h{$c}) if exists $h{$c};
        }
        push @out, \%h;
    }
    return \@out;
}

sub subtest_rows {
    my ($self, $jtid) = @_;
    croak "job_try_id required" unless defined $jtid;
    my @out;
    for my $r ($self->{+SCHEMA}->resultset('Subtest')->search(
        { job_try_id => $jtid },
        { order_by => 'ord' },
    )->all)
    {
        my %h = $r->get_columns;
        push @out, \%h;
    }
    return \@out;
}

# -- write primitives (Phase 5) ---------------------------------------------
#
# Mirrors App::Yath2::DB::SQL's write API on the DBIC layer. All input
# args are canonical Perl values (UUIDs as 36-char lowercase hex; JSON
# columns as decoded refs; datetimes as ISO-8601 strings; payloads as
# raw bytes). Per-flavor bind concerns: UUID columns route through
# _flavor_uuid_to_db; payload (BYTEA on Postgres / LONGBLOB on MySQL /
# BLOB on SQLite) is bound via $schema->storage->dbh_do for the row
# UPDATE / INSERT to ensure DBD::Pg / DBD::MariaDB get the correct type
# hints (DBIC's create()/update() does not always set the right bind
# type when the Result column is declared 'blob' but the underlying
# column is BYTEA / BINARY). Because DBIC and the SQL backend both
# share the same dbh shape, we delegate the actual DB call through a
# parallel SQL backend instance so flavor-specific bind code lives in
# exactly one place. The shared App::Yath2::DB::SQL instance is bound
# to the same dbh as our DBIC schema, so transactional state stays
# consistent.

sub _shared_sql_backend {
    my $self = shift;
    return $self->{__shared_sql} //= do {
        require App::Yath2::DB::SQL;
        # Cannot pass `flavor => ...` to App::Yath2::DB::SQL->new because
        # SQL.pm's HashBase declares it as a +flavor (reader, no
        # constructor accept). Set it manually after construction.
        my $obj = App::Yath2::DB::SQL->new(dbh => $self->dbh);
        $obj->{App::Yath2::DB::SQL::FLAVOR()} = $self->flavor;
        $obj;
    };
}

sub archive_create {
    my ($self, $fields) = @_;
    return $self->_shared_sql_backend->archive_create($fields);
}

sub mark_sealed {
    my ($self, $aid, $when) = @_;
    croak "archive_id required" unless defined $aid;
    $self->{+SCHEMA}->resultset('Archive')->search({ archive_id => $aid })
        ->update({ sealed_at => $when });
    return;
}

sub ensure_project_row {
    my ($self, $name) = @_;
    croak "project name required" unless defined $name && length $name;
    my $row = $self->{+SCHEMA}->resultset('Project')->find_or_create(
        { name => $name },
        { key => 'projects_name_uk' },
    );
    return $row->project_id;
}

sub ensure_test_file_row {
    my ($self, $project_id, $relative) = @_;
    croak "project_id required"    unless defined $project_id;
    croak "relative path required" unless defined $relative && length $relative;
    my $row = $self->{+SCHEMA}->resultset('TestFile')->find_or_create(
        { project_id => $project_id, relative => $relative },
        { key => 'test_files_project_relative_uk' },
    );
    return $row->test_file_id;
}

sub ensure_run_row {
    my ($self, $aid, $run_ord, $project_id) = @_;
    # Routed through the shared SQL backend so the per-flavor UUID bind
    # stays in one place. Once routed, the row is visible to subsequent
    # DBIC reads through the same dbh.
    return $self->_shared_sql_backend->ensure_run_row($aid, $run_ord, $project_id);
}

sub ensure_service_row {
    my ($self, $aid, $name, $run_id) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "service name required" unless defined $name && length $name;

    my %where = (archive_id => $aid, name => $name);
    $where{run_id} = $run_id; # undef binds to NULL in SQL::Abstract

    my $rs = $self->{+SCHEMA}->resultset('Service');
    my $existing = $rs->search(\%where)->first;
    return $existing->service_id if $existing;

    my $row = $rs->create({
        archive_id => $aid,
        run_id     => $run_id,
        name       => $name,
    });
    return $row->service_id;
}

sub ensure_job_row {
    my ($self, $aid, $run_id, $job_ord, $test_file_id) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "run_id required"       unless defined $run_id;
    croak "job_ord required"      unless defined $job_ord;
    croak "test_file_id required" unless defined $test_file_id;

    my $rs = $self->{+SCHEMA}->resultset('Job');
    my $existing = $rs->search({
        archive_id => $aid, run_id => $run_id, job_ord => $job_ord,
    })->first;
    return $existing->job_id if $existing;

    my $row = $rs->create({
        archive_id   => $aid,
        run_id       => $run_id,
        job_ord      => $job_ord,
        test_file_id => $test_file_id,
    });
    return $row->job_id;
}

sub ensure_job_try_row {
    my ($self, $job_id, $try_ord) = @_;
    croak "job_id required"  unless defined $job_id;
    croak "try_ord required" unless defined $try_ord;

    my $rs = $self->{+SCHEMA}->resultset('JobTry');
    my $existing = $rs->search({ job_id => $job_id, try_ord => $try_ord })->first;
    return $existing->job_try_id if $existing;

    my $row = $rs->create({
        job_id  => $job_id,
        try_ord => $try_ord,
    });
    return $row->job_try_id;
}

sub artifact_create {
    my ($self, $fields) = @_;
    # The artifact INSERT is the most flavor-sensitive write (UUID +
    # BYTEA + datetime). Route through the shared SQL backend so all
    # flavor-specific bind logic lives in one place and DBIC consumers
    # don't have to second-guess Result column data_type declarations.
    return $self->_shared_sql_backend->artifact_create($fields);
}

sub artifact_update {
    my ($self, $artifact_id, $fields) = @_;
    return $self->_shared_sql_backend->artifact_update($artifact_id, $fields);
}

sub job_spec_create {
    my ($self, $job_id, $fields) = @_;
    # Route through the shared SQL backend; same Postgres jsonb-cast
    # reason as service_lifetime_create.
    return $self->_shared_sql_backend->job_spec_create($job_id, $fields);
}

sub service_lifetime_create {
    my ($self, $service_id, $fields) = @_;
    # Route through the shared SQL backend so JSON column binds (jsonb
    # on Postgres) get the correct cast hint at execute time. DBIC's
    # generic create() binds 'blob'-declared columns as bytea, which
    # the server refuses to coerce into jsonb on Postgres.
    return $self->_shared_sql_backend->service_lifetime_create($service_id, $fields);
}

sub subtest_create {
    my ($self, $job_try_id, $fields) = @_;
    croak "job_try_id required"     unless defined $job_try_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';
    croak "name required"           unless defined $fields->{name};
    croak "ord required"            unless defined $fields->{ord};

    my %row = (
        job_try_id => $job_try_id,
        name       => $fields->{name},
        pass       => $fields->{pass} ? 1 : 0,
        ord        => $fields->{ord},
    );
    for my $c (qw/count_pass count_fail/) {
        $row{$c} = $fields->{$c} if exists $fields->{$c};
    }
    my $obj = $self->{+SCHEMA}->resultset('Subtest')->create(\%row);
    return $obj->subtest_id;
}

# ----- Write methods routed through App::Yath2::DB -----
#
# insert / extract / archive / _artifact_save all route through the
# data-layer wrapper, which orchestrates over the DBIC backend's own
# write primitives (defined further up).

sub _wrap_self_in_db {
    my $self = shift;
    require App::Yath2::DB;
    return $self->{__db_wrapper} //= App::Yath2::DB->_wrap_backend($self);
}

sub insert {
    my ($self, $source, %opts) = @_;
    my $rv = $self->_wrap_self_in_db->insert($source, %opts);
    if (my $u = $self->{__db_wrapper}{_last_insert_uuid}) {
        # Mirror onto the DBIC backend's HashBase UUID slot so
        # post-insert $backend->uuid returns the new archive's uuid.
        $self->{+UUID} = $u;
    }
    return $rv;
}

sub extract {
    my ($self, $dir, %opts) = @_;
    my $uuid = $self->_implicit_uuid_for_op('extract');
    return $self->_wrap_self_in_db->extract($uuid, $dir, %opts);
}

sub archive {
    my ($self, $out, %opts) = @_;
    my $uuid = $self->_implicit_uuid_for_op('archive');
    return $self->_wrap_self_in_db->archive_to($uuid, $out, %opts);
}

sub _artifact_save {
    my ($self, %p) = @_;
    my $uuid = $self->_implicit_uuid_for_op('_artifact_save');
    return $self->_wrap_self_in_db->save_artifact($uuid, %p);
}

# Artifact-handle private methods. The role's artifacts() factory binds
# Log::Artifact handles with log => $self (the backend itself); those
# handles dispatch the underscore-prefixed family back. Route through
# the data-layer wrapper so the canonical bytes paths are exercised.
sub _artifact_exists {
    my ($self, $rel) = @_;
    my $uuid = eval { $self->_implicit_uuid_for_op('_artifact_exists') };
    return (0, 0) if $@;
    return $self->_wrap_self_in_db->artifact_exists($uuid, $rel);
}

sub _artifact_read {
    my ($self, $rel) = @_;
    my $uuid = $self->_implicit_uuid_for_op('_artifact_read');
    return $self->_wrap_self_in_db->artifact_read($uuid, $rel);
}

sub _artifact_iter_records {
    my ($self, $base, $stem) = @_;
    my $uuid = $self->_implicit_uuid_for_op('_artifact_iter_records');
    return $self->_wrap_self_in_db->artifact_iter_records($uuid, $base, $stem);
}

sub _artifact_list_dir {
    my ($self, $rel) = @_;
    my $uuid = $self->_implicit_uuid_for_op('_artifact_list_dir');
    return $self->_wrap_self_in_db->artifact_list_dir($uuid, $rel);
}

sub _artifact_open_fh {
    my ($self, $rel) = @_;
    my $uuid = $self->_implicit_uuid_for_op('_artifact_open_fh');
    return $self->_wrap_self_in_db->artifact_open_fh($uuid, $rel);
}

# Single-archive shortcut: when DBIC was scoped to a uuid via ->scoped,
# use that; otherwise fall back to the only archive. UUID slot is the
# HashBase-declared accessor.
sub _implicit_uuid_for_op {
    my ($self, $op) = @_;
    return $self->{+UUID} if defined $self->{+UUID};
    my $db = $self->_wrap_self_in_db;
    my @uuids = $db->archives;
    croak "no archives in this DB" unless @uuids;
    croak "ambiguous; specify uuid => ... (this DB holds " . scalar(@uuids) . " archives)"
        if @uuids > 1;
    return $uuids[0];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::DBIC - DBIx::Class backend for yath DB-archive storage.

=head1 SYNOPSIS

    use App::Yath2::DB;

    my $db = App::Yath2::DB->new(
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
