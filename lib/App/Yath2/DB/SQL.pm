package App::Yath2::DB::SQL;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <dsn <user <pass <attrs <dbh <file
    +flavor
    +_is_mariadb
};

use Role::Tiny::With;
with 'App::Yath2::Role::DB::Backend';

# Single-class raw-DBI backend introduced by the DB rebuild
# (AI_DOCS/2026-05-08-yath-db-rebuild.md). Phase 2 fills in the read
# primitives; later phases add write primitives. Flavor differences
# (UUID bind shape, payload binding, MariaDB trigger skip) live inside
# individual methods rather than per-flavor subclasses.
#
# The role's `requires` list still reflects the legacy Internal-shaped
# contract during Phases 2-7; Phase 9 swaps it to the new primitive
# list and removes the stub fillers.

sub init {
    my $self = shift;

    croak "App::Yath2::DB::SQL requires one of: file, dbh, dsn"
        unless defined $self->{+FILE}
        || defined $self->{+DBH}
        || defined $self->{+DSN};

    # Connect (lazily; bootstrap will use $self->dbh).
    $self->dbh;
    $self->_apply_session_state;
    $self->bootstrap_schema;

    return;
}

# -- connection / dbh / flavor -----------------------------------------------

# Always return a live handle. HashBase's read accessor returns the slot
# verbatim; override so callers never hit a stale undef when only one of
# {file,dsn} was supplied.
{
    no warnings 'redefine';
    *dbh = sub {
        my $self = shift;
        return $self->{+DBH} //= $self->_connect_dbh;
    };
}

sub flavor {
    my $self = shift;
    return $self->{+FLAVOR} //= $self->_detect_flavor;
}

sub _detect_flavor {
    my $self = shift;

    if (defined $self->{+DSN}) {
        my $dsn = $self->{+DSN};
        return 'postgres' if $dsn =~ /^dbi:Pg:/i;
        return 'mariadb'  if $dsn =~ /^dbi:MariaDB:/i;
        return 'mysql'    if $dsn =~ /^dbi:mysql:/i;
        return 'sqlite'   if $dsn =~ /^dbi:SQLite:/i;
    }

    if (defined $self->{+DBH}) {
        my $name = $self->{+DBH}{Driver}{Name} // '';
        return 'sqlite'   if $name eq 'SQLite';
        return 'postgres' if $name eq 'Pg';
        return 'mariadb'  if $name eq 'MariaDB';
        return 'mysql'    if $name eq 'mysql';
    }

    return 'sqlite' if defined $self->{+FILE};

    croak "could not detect SQL backend flavor (no file/dsn/dbh hint)";
}

sub _connect_dbh {
    my $self = shift;
    require DBI;

    my $flavor = $self->flavor;

    my $dsn   = $self->{+DSN};
    my $user  = $self->{+USER};
    my $pass  = $self->{+PASS};
    my $attrs = $self->{+ATTRS} || {};

    if (!defined $dsn) {
        my $file = $self->{+FILE};
        croak "no file or dsn provided" unless defined $file;

        # File path implies sqlite. Make the parent dir on the fly so
        # callers can pass a path under a non-existent tempdir.
        if (!-e $file) {
            my $par = dirname($file);
            make_path($par) if length $par && !-d $par;
        }

        $dsn = "dbi:SQLite:dbname=$file";
        $self->{+DSN} = $dsn;
    }

    if ($flavor eq 'sqlite') {
        my $dbh = DBI->connect($dsn, $user, $pass, {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
            %$attrs,
        }) or croak "DBI->connect $dsn: $DBI::errstr";

        # Open-time PRAGMAs (per share/schema/SCHEMA.md §8).
        $dbh->do('PRAGMA journal_mode = WAL');
        $dbh->do('PRAGMA synchronous = NORMAL');
        $dbh->do('PRAGMA busy_timeout = 5000');
        $dbh->do('PRAGMA foreign_keys = ON');
        $dbh->do('PRAGMA temp_store = MEMORY');

        return $dbh;
    }

    if ($flavor eq 'postgres') {
        my $ok = eval { require DBD::Pg; 1 };
        my $err = $@;
        croak "install DBD::Pg to use the postgres backend: $err" unless $ok;

        my $dbh = DBI->connect($dsn, $user, $pass, {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            pg_enable_utf8 => 1,
            %$attrs,
        }) or croak "DBI->connect $dsn: $DBI::errstr";

        return $dbh;
    }

    if ($flavor eq 'mariadb' || $flavor eq 'mysql') {
        my $ok = eval { require DBD::MariaDB; 1 };
        my $err = $@;
        croak "install DBD::MariaDB to use the $flavor backend: $err" unless $ok;

        my $dbh = DBI->connect($dsn, $user, $pass, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            %$attrs,
        }) or croak "DBI->connect $dsn: $DBI::errstr";

        return $dbh;
    }

    croak "unsupported SQL backend flavor: $flavor";
}

# Apply per-flavor session state on a fresh connection. Currently only
# MySQL and MariaDB need this (ANSI_QUOTES so the shared SQL's "user" /
# "exit" double-quoted identifiers parse as identifier quotes, not
# string literals).
sub _apply_session_state {
    my $self = shift;
    my $flavor = $self->flavor;
    return unless $flavor eq 'mariadb' || $flavor eq 'mysql';
    my $dbh = $self->{+DBH} or return;
    $dbh->do(q{SET SESSION sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')});
    return;
}

# Schema-bootstrap hooks (consumed by Role::DB::Backend::bootstrap_schema).

sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    my $flavor = $self->flavor;
    return $sql unless $flavor eq 'postgres';

    # share/schema/postgres.sql defaults to `COMPRESSION zstd`. Probe
    # for what the live server supports and rewrite (or strip) to match.
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

# MySQL/MariaDB drivers both report "MySQL" sqlt_type and DBD::MariaDB
# can talk to either server, so distinguish via SELECT VERSION() once.
# CREATE TRIGGER bodies in mysql.sql call BIN_TO_UUID() which only
# exists on real MySQL; skip them when we are pointed at MariaDB.
sub _server_is_mariadb {
    my $self = shift;
    return $self->{+_IS_MARIADB} //= do {
        my $flavor = $self->flavor;
        if ($flavor eq 'mariadb') { 1 }
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

# -- codec primitives --------------------------------------------------------
#
# All public read primitives speak canonical Perl values; callers never
# see flavor-native blobs/strings. These private helpers translate at
# the bind / fetch boundary.
#
# Canonical UUID form is 36-char lowercase hex.
# Canonical JSON form is decoded Perl hashref / arrayref.
# Canonical payload form is raw bytes (zstd-encoded if compressed=1).

sub _uuid_to_db {
    my ($self, $u) = @_;
    return undef unless defined $u;
    my $flavor = $self->flavor;
    return $u                 if $flavor eq 'sqlite';
    return uc($u)             if $flavor eq 'postgres' || $flavor eq 'mariadb';
    if ($flavor eq 'mysql') {
        (my $h = $u) =~ tr/-//d;
        return pack('H*', $h);
    }
    return $u;
}

sub _uuid_from_db {
    my ($self, $val) = @_;
    return undef unless defined $val;
    my $flavor = $self->flavor;
    if ($flavor eq 'mysql') {
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

# Bind a canonical UUID value at $idx with the right driver-side type
# hint (BINARY for mysql; otherwise plain bind).
sub _bind_uuid {
    my ($self, $sth, $idx, $canon) = @_;
    require DBI;
    my $flavor = $self->flavor;
    my $db_form = $self->_uuid_to_db($canon);
    if ($flavor eq 'mysql') {
        $sth->bind_param($idx, $db_form, DBI::SQL_BINARY());
    }
    else {
        $sth->bind_param($idx, $db_form);
    }
    return;
}

# Bind a payload (raw bytes) at $idx. MySQL/MariaDB need SQL_BLOB so
# DBD::MariaDB does not UTF-8-mangle the bytes; Postgres needs PG_BYTEA;
# SQLite is identity.
sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    my $flavor = $self->flavor;
    if ($flavor eq 'postgres') {
        require DBD::Pg;
        $sth->bind_param($idx, $bytes, { pg_type => DBD::Pg::PG_BYTEA() });
        return;
    }
    if ($flavor eq 'mysql' || $flavor eq 'mariadb') {
        require DBI;
        $sth->bind_param($idx, $bytes, DBI::SQL_BLOB());
        return;
    }
    $sth->bind_param($idx, $bytes);
    return;
}

# DBD::Pg returns BYTEA columns as raw bytes by default on fetch
# (PG_BYTEA bind hint is for the bind side, not fetch). SQLite /
# MariaDB / MySQL hand back the bytes verbatim too. This hook stays
# as identity; future flavors that need a fetch-side decode can
# override.
sub _payload_to_bytes {
    my ($self, $val) = @_;
    return $val;
}

sub _maybe_decode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val;
    return decode_json($val);
}

# UUID bind hint for selectrow lookups. MySQL needs SQL_BINARY; others
# bind the canonical-form result of _uuid_to_db verbatim.
sub _uuid_lookup_bind {
    my ($self, $canon) = @_;
    require DBI;
    my $flavor = $self->flavor;
    my $db_form = $self->_uuid_to_db($canon);
    return ($db_form, $flavor eq 'mysql' ? DBI::SQL_BINARY() : ());
}

# Quote the keyword-clashing 'user' column. Default ANSI double-quote;
# MySQL/MariaDB sessions enabled ANSI_QUOTES on connect so this stays
# valid across all four flavors.
sub _quote_user_col { '"user"' }


# -- archive layer -----------------------------------------------------------

sub archive_rows {
    my $self = shift;
    my $dbh = $self->dbh;

    my $user_col = $self->_quote_user_col;
    my $rows = $dbh->selectall_arrayref(qq{
        SELECT archive_id, archive_uuid, archive_version, sealed_at,
               host, $user_col AS user, git_sha, project, yath_version,
               meta_extras
          FROM archives
         ORDER BY archive_id
    }, { Slice => {} });

    my @out;
    for my $r (@$rows) {
        push @out, {
            archive_id      => $r->{archive_id},
            archive_uuid    => $self->_uuid_from_db($r->{archive_uuid}),
            archive_version => $r->{archive_version},
            sealed_at       => $r->{sealed_at},
            host            => $r->{host},
            user            => $r->{user},
            git_sha         => $r->{git_sha},
            project         => $r->{project},
            yath_version    => $r->{yath_version},
            meta_extras     => $self->_maybe_decode_json($r->{meta_extras}),
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

sub archive_count {
    my $self = shift;
    my ($n) = $self->dbh->selectrow_array(q{SELECT count(*) FROM archives});
    return $n // 0;
}

# -- run / job / try / service rows -----------------------------------------

sub run_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(q{
        SELECT run_id, run_ord, run_uuid, status, aborted, timed_out, project_id
          FROM runs
         WHERE archive_id = ?
         ORDER BY run_ord
    }, { Slice => {} }, $aid);

    my @out;
    for my $r (@$rows) {
        push @out, {
            run_id     => $r->{run_id},
            run_ord    => $r->{run_ord},
            run_uuid   => $self->_uuid_from_db($r->{run_uuid}),
            status     => $r->{status},
            aborted    => $r->{aborted}   ? 1 : 0,
            timed_out  => $r->{timed_out} ? 1 : 0,
            project_id => $r->{project_id},
        };
    }
    return \@out;
}

sub service_rows {
    my ($self, $aid, %filter) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh = $self->dbh;

    my @bind = ($aid);
    my $sql = q{
        SELECT service_id, name, run_id
          FROM services
         WHERE archive_id = ?
    };
    if (exists $filter{run_id}) {
        if (defined $filter{run_id}) {
            $sql .= ' AND run_id = ?';
            push @bind, $filter{run_id};
        }
        else {
            $sql .= ' AND run_id IS NULL';
        }
    }
    $sql .= ' ORDER BY service_id';

    my $rows = $dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    return [ map { +{
        service_id => $_->{service_id},
        name       => $_->{name},
        run_id     => $_->{run_id},
    } } @$rows ];
}

sub job_rows {
    my ($self, $aid, $run_id) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $run_id;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(q{
        SELECT job_id, job_ord, test_file_id
          FROM jobs
         WHERE archive_id = ? AND run_id = ?
         ORDER BY job_ord
    }, { Slice => {} }, $aid, $run_id);
    return [ map { +{
        job_id       => $_->{job_id},
        job_ord      => $_->{job_ord},
        test_file_id => $_->{test_file_id},
    } } @$rows ];
}

sub try_rows {
    my ($self, $jid) = @_;
    croak "job_id required" unless defined $jid;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(q{
        SELECT *
          FROM job_tries
         WHERE job_id = ?
         ORDER BY try_ord
    }, { Slice => {} }, $jid);

    # Decode JSON columns inline so callers see canonical Perl values.
    my @json_cols = qw/exit_decoded plan halt times child_times
                       spec_extras state_extras/;
    for my $r (@$rows) {
        for my $c (@json_cols) {
            $r->{$c} = $self->_maybe_decode_json($r->{$c}) if exists $r->{$c};
        }
    }
    return $rows;
}

# -- existence checks -------------------------------------------------------

sub run_exists {
    my ($self, $aid, $run_ord) = @_;
    return 0 unless defined $aid && defined $run_ord;
    return 0 unless $run_ord =~ /^\d+\z/;
    my ($n) = $self->dbh->selectrow_array(
        q{SELECT count(*) FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    return $n ? 1 : 0;
}

sub job_exists {
    my ($self, $aid, $rid, $job_ord) = @_;
    return 0 unless defined $aid && defined $rid && defined $job_ord;
    return 0 unless $job_ord =~ /^\d+\z/;
    my ($n) = $self->dbh->selectrow_array(
        q{SELECT count(*) FROM jobs
           WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $rid, $job_ord,
    );
    return $n ? 1 : 0;
}

sub try_exists {
    my ($self, $jid, $try_ord) = @_;
    return 0 unless defined $jid && defined $try_ord;
    return 0 unless $try_ord =~ /^\d+\z/;
    my ($n) = $self->dbh->selectrow_array(
        q{SELECT count(*) FROM job_tries WHERE job_id = ? AND try_ord = ?},
        undef, $jid, $try_ord,
    );
    return $n ? 1 : 0;
}

sub service_exists {
    my ($self, $aid, $name, $rid) = @_;
    return 0 unless defined $aid && defined $name;
    my $dbh = $self->dbh;
    if (defined $rid) {
        my ($n) = $dbh->selectrow_array(
            q{SELECT count(*) FROM services
               WHERE archive_id = ? AND run_id = ? AND name = ?},
            undef, $aid, $rid, $name,
        );
        return $n ? 1 : 0;
    }
    my ($n) = $dbh->selectrow_array(
        q{SELECT count(*) FROM services
           WHERE archive_id = ? AND run_id IS NULL AND name = ?},
        undef, $aid, $name,
    );
    return $n ? 1 : 0;
}

# -- id-for-ord lookups -----------------------------------------------------

sub run_id_for_ord {
    my ($self, $aid, $run_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_ord required"    unless defined $run_ord;
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT run_id FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    croak "no run with ord $run_ord" unless defined $id;
    return $id;
}

sub job_id_for_ord {
    my ($self, $aid, $rid, $job_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $rid;
    croak "job_ord required"    unless defined $job_ord;
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT job_id FROM jobs
           WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $rid, $job_ord,
    );
    croak "no job with ord $job_ord in run_id $rid" unless defined $id;
    return $id;
}

sub try_id_for_ord {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required"  unless defined $jid;
    croak "try_ord required" unless defined $try_ord;
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT job_try_id FROM job_tries WHERE job_id = ? AND try_ord = ?},
        undef, $jid, $try_ord,
    );
    croak "no try with ord $try_ord in job_id $jid" unless defined $id;
    return $id;
}

sub service_id_for_name {
    my ($self, $aid, $name, $rid) = @_;
    croak "archive_id required"  unless defined $aid;
    croak "service name required" unless defined $name;
    my $dbh = $self->dbh;
    if (defined $rid) {
        my ($id) = $dbh->selectrow_array(
            q{SELECT service_id FROM services
               WHERE archive_id = ? AND run_id = ? AND name = ?},
            undef, $aid, $rid, $name,
        );
        return $id;
    }
    my ($id) = $dbh->selectrow_array(
        q{SELECT service_id FROM services
           WHERE archive_id = ? AND run_id IS NULL AND name = ?},
        undef, $aid, $name,
    );
    return $id;
}

# -- artifact rows ----------------------------------------------------------

sub artifact_rows_for_archive {
    my ($self, $aid, %opts) = @_;
    croak "archive_id required" unless defined $aid;
    my $with_payload = $opts{with_payload} ? 1 : 0;
    my $dbh = $self->dbh;

    # Postgres needs a typed bytea fetch when payloads are requested;
    # other flavors return bytes verbatim. Build the SELECT with or
    # without the payload column accordingly.
    my $extra = $with_payload ? ', a.payload' : '';
    my $sql = qq{
        SELECT a.artifact_id,
               a.run_id, a.service_id, a.job_try_id,
               a.artifact_kind, a.format, a.name, a.compressed,
               s.name  AS service_name,
               sr.run_ord AS s_run_ord,
               r.run_ord  AS run_ord,
               t.try_ord  AS try_ord,
               j.job_ord  AS job_ord,
               jr.run_ord AS j_run_ord$extra
          FROM artifacts a
          LEFT JOIN services  s  ON a.service_id = s.service_id
          LEFT JOIN runs      sr ON s.run_id     = sr.run_id
          LEFT JOIN runs      r  ON a.run_id     = r.run_id
          LEFT JOIN job_tries t  ON a.job_try_id = t.job_try_id
          LEFT JOIN jobs      j  ON t.job_id     = j.job_id
          LEFT JOIN runs      jr ON j.run_id     = jr.run_id
         WHERE a.archive_id = ?
         ORDER BY a.artifact_id
    };

    my $rows = $dbh->selectall_arrayref($sql, { Slice => {} }, $aid);

    if ($with_payload) {
        for my $r (@$rows) {
            $r->{payload} = $self->_payload_to_bytes($r->{payload});
            $r->{compressed} = $r->{compressed} ? 1 : 0;
        }
    }
    else {
        for my $r (@$rows) {
            $r->{compressed} = $r->{compressed} ? 1 : 0;
        }
    }
    return $rows;
}

sub artifact_row_for_scope {
    my ($self, $aid, $scope_kind, $scope_id, $kind, $name) = @_;
    croak "archive_id required"  unless defined $aid;
    croak "scope_kind required"  unless defined $scope_kind;
    croak "artifact_kind required" unless defined $kind;

    my ($scope_clause, @scope_bind)
        = $self->_scope_where_clause($scope_kind, $scope_id);

    my $sql;
    my @bind;
    if (defined $name) {
        $sql = qq{
            SELECT artifact_id, compressed, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name = ?
        };
        @bind = ($aid, @scope_bind, $kind, $name);
    }
    else {
        $sql = qq{
            SELECT artifact_id, compressed, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name IS NULL
        };
        @bind = ($aid, @scope_bind, $kind);
    }

    my $dbh = $self->dbh;
    my $row = $dbh->selectrow_hashref($sql, undef, @bind);
    return undef unless $row;

    return {
        artifact_id => $row->{artifact_id},
        compressed  => $row->{compressed} ? 1 : 0,
        payload     => $self->_payload_to_bytes($row->{payload}),
        format      => $row->{format},
    };
}

sub artifact_payload {
    my ($self, $artifact_id) = @_;
    croak "artifact_id required" unless defined $artifact_id;
    my $dbh = $self->dbh;
    my ($bytes) = $dbh->selectrow_array(
        q{SELECT payload FROM artifacts WHERE artifact_id = ?},
        undef, $artifact_id,
    );
    return $self->_payload_to_bytes($bytes);
}

# -- spec / report data layer ----------------------------------------------

sub job_spec_rows {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required" unless defined $jid;
    my $dbh = $self->dbh;

    # job_specs has a UNIQUE(job_id) constraint -- one row per job, not
    # per try. The $try_ord arg exists for symmetry with future
    # primitives that want to filter by try; here it is accepted but
    # has no effect on which rows match (job_specs is the per-job
    # spec; per-try spec lives elsewhere).
    my $rows = $dbh->selectall_arrayref(
        q{SELECT * FROM job_specs WHERE job_id = ? ORDER BY job_spec_id},
        { Slice => {} }, $jid,
    );

    my @json_cols = qw/features switches extras/;
    for my $r (@$rows) {
        for my $c (@json_cols) {
            $r->{$c} = $self->_maybe_decode_json($r->{$c}) if exists $r->{$c};
        }
    }
    return $rows;
}

sub service_lifetime_rows {
    my ($self, $sid) = @_;
    croak "service_id required" unless defined $sid;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(q{
        SELECT * FROM service_lifetimes
         WHERE service_id = ?
         ORDER BY lifetime_ord
    }, { Slice => {} }, $sid);

    my @json_cols = qw/exit_decoded times child_times spec_extras state_extras/;
    for my $r (@$rows) {
        for my $c (@json_cols) {
            $r->{$c} = $self->_maybe_decode_json($r->{$c}) if exists $r->{$c};
        }
    }
    return $rows;
}

sub subtest_rows {
    my ($self, $jtid) = @_;
    croak "job_try_id required" unless defined $jtid;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(q{
        SELECT * FROM subtests
         WHERE job_try_id = ?
         ORDER BY ord
    }, { Slice => {} }, $jtid);
    # subtests has no JSON columns at present.
    return $rows;
}

# -- legacy role-required stubs ---------------------------------------------
#
# The role still requires the Internal-shaped Group A/B surface during
# Phases 2-7 (see AI_DOCS/2026-05-08-yath-db-rebuild.md §6 -- Phase 9
# swaps the role). Until then, satisfy the contract with stubs that
# croak. Nothing in the read-primitives test path exercises them; they
# disappear when the role's `requires` list is updated.

sub _archive_id_or_die { croak 'NYI: _archive_id_or_die (Phase 4)' }
sub services           { croak 'NYI: services (Phase 4)' }
sub runs               { croak 'NYI: runs (Phase 4)' }
sub jobs               { croak 'NYI: jobs (Phase 4)' }
sub tries              { croak 'NYI: tries (Phase 4)' }
sub last_try           { croak 'NYI: last_try (Phase 4)' }
sub has_service        { croak 'NYI: has_service (Phase 4)' }
sub has_run            { croak 'NYI: has_run (Phase 4)' }
sub has_job            { croak 'NYI: has_job (Phase 4)' }
sub has_try            { croak 'NYI: has_try (Phase 4)' }
sub event              { croak 'NYI: event (Phase 7)' }
sub events             { croak 'NYI: events (Phase 7)' }
sub end_of_events      { croak 'NYI: end_of_events (Phase 7)' }
sub reset              { croak 'NYI: reset (Phase 7)' }
sub extract            { croak 'NYI: extract (Phase 6)' }
sub archive            { croak 'NYI: archive (Phase 6)' }
sub insert             { croak 'NYI: insert (Phase 6)' }
sub archives           { croak 'NYI: archives (Phase 4)' }
sub has_archive        { croak 'NYI: has_archive (Phase 4)' }
sub scoped             { croak 'NYI: scoped (Phase 4)' }

# Used by the role's list_files orchestration. Keep the legacy name as
# a thin alias to artifact_rows_for_archive so role-level callers that
# still walk through Internal-shaped semantics continue to work during
# the rebuild's intermediate phases.
sub _artifact_rows_for_archive {
    my ($self, $aid) = @_;
    return $self->artifact_rows_for_archive($aid);
}

# -- write primitive stubs (Phase 5) ----------------------------------------

sub archive_create       { croak 'NYI: archive_create (Phase 5)' }
sub mark_sealed          { croak 'NYI: mark_sealed (Phase 5)' }
sub ensure_run_row       { croak 'NYI: ensure_run_row (Phase 5)' }
sub ensure_service_row   { croak 'NYI: ensure_service_row (Phase 5)' }
sub ensure_job_row       { croak 'NYI: ensure_job_row (Phase 5)' }
sub ensure_job_try_row   { croak 'NYI: ensure_job_try_row (Phase 5)' }
sub ensure_test_file_row { croak 'NYI: ensure_test_file_row (Phase 5)' }
sub ensure_project_row   { croak 'NYI: ensure_project_row (Phase 5)' }
sub artifact_create      { croak 'NYI: artifact_create (Phase 5)' }
sub artifact_update      { croak 'NYI: artifact_update (Phase 5)' }
sub job_spec_create         { croak 'NYI: job_spec_create (Phase 5)' }
sub service_lifetime_create { croak 'NYI: service_lifetime_create (Phase 5)' }
sub subtest_create          { croak 'NYI: subtest_create (Phase 5)' }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::SQL - raw-DBI backend for App::Yath2::DB.

=head1 DESCRIPTION

Single-class backend implementing L<App::Yath2::Role::DB::Backend> via
direct DBI calls. Replaces the per-flavor C<App::Yath2::DB::Internal::*>
tree as part of the DB rebuild
(L<AI_DOCS/2026-05-08-yath-db-rebuild.md>). Flavor differences
(UUID bind shape, payload binding, MariaDB trigger skip) are handled
inside individual methods.

=head1 STATUS

Phase 2: read primitives implemented. Write primitives land in Phase 5;
event walker / extract / archive / insert in Phases 6-7.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
