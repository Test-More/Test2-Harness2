package App::Yath2::Role::DB::Backend;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Basename ();
use File::Spec ();
use Time::HiRes ();

use Role::Tiny;

# Required methods. Implementers must provide every one.
#
# This is the row-level primitive contract App::Yath2::DB consumes.
# Backends are skinny: connection / introspection plus typed-row CRUD.
# The Log-shape archive surface (event walker, list_files, artifacts
# factory, extract / archive / insert / save_artifact) lives entirely
# on App::Yath2::DB, which orchestrates over the primitives below.
requires qw{
    dbh flavor

    archive_rows archive_for_uuid archive_count archive_create mark_sealed

    run_rows service_rows job_rows try_rows

    ensure_run_row

    artifact_rows_for_archive artifact_row_for_scope artifact_payload
    artifact_create artifact_update artifact_event_count_for_archive

    job_spec_rows service_lifetime_rows subtest_rows
    job_spec_create service_lifetime_create subtest_create

    _count_rows _find_one_col _ensure_row
};

# share/schema/postgres.sql defaults to `COMPRESSION zstd`. Probe what
# the live server supports and rewrite (or strip) the clause to match.
# Backends inherit the same logic via this role; consumers can still
# override for flavor quirks beyond Postgres compression.
sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    return $sql unless $self->flavor eq 'postgres';

    my $algo = $self->_pg_server_compression;
    if (!defined $algo) {
        $sql =~ s/\s+COMPRESSION\s+zstd\b//gi;
    }
    elsif ($algo ne 'zstd') {
        $sql =~ s/(\bCOMPRESSION\s+)zstd\b/$1$algo/gi;
    }
    return $sql;
}

# Probe Postgres for a working TOAST compression algorithm. Tries zstd
# first, then lz4, returns undef when neither works (the schema's
# COMPRESSION clause is then dropped entirely).
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

# DBD::MariaDB and DBD::mysql both report sqlt_type 'MySQL', and
# DBD::MariaDB can talk to either real server. Distinguish the two via
# SELECT VERSION() once and cache the answer; needed because mysql.sql
# CREATE TRIGGER bodies call BIN_TO_UUID() which only exists on real
# MySQL (MariaDB rejects the dialect).
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

# Per-statement skip hook used during bootstrap. Default: skip MySQL
# CREATE TRIGGER statements when the live server is MariaDB. Consumers
# can override for additional quirks.
sub _should_skip_schema_statement {
    my ($self, $stmt) = @_;
    return 0 unless $self->flavor eq 'mysql';
    return 0 unless $self->_server_is_mariadb;
    return $stmt =~ /^CREATE\s+TRIGGER\b/i ? 1 : 0;
}

# Locate share/schema/$flavor.sql. Resolution order:
#   1. dev tree: walk up from __FILE__ looking for a sibling
#      share/schema/$flavor.sql (development checkout).
#   2. installed: File::ShareDir::dist_dir('Test2-Harness2')
#                 . "/schema/$flavor.sql"
sub schema_file {
    my $self = shift;
    my $flavor = $self->flavor;
    my $name   = "$flavor.sql";

    my @tried;

    my $dir = __FILE__;
    for (1 .. 10) {
        $dir = File::Basename::dirname($dir);
        my $candidate = File::Spec->catfile($dir, 'share', 'schema', $name);
        push @tried, $candidate;
        return $candidate if -e $candidate;
        last if $dir eq '/' || $dir eq '.';
    }

    my $dist_share;
    my $ok = eval {
        require File::ShareDir;
        $dist_share = File::ShareDir::dist_dir('Test2-Harness2');
        1;
    };
    if ($ok && $dist_share) {
        my $candidate = File::Spec->catfile($dist_share, 'schema', $name);
        push @tried, $candidate;
        return $candidate if -e $candidate;
    }

    croak "could not locate schema file for flavor '$flavor'; tried: "
        . join(', ', @tried);
}

# Probe for the archives table. False on any DBI error.
sub _is_bootstrapped {
    my $self = shift;
    my $ok = eval { $self->dbh->selectrow_array(q{SELECT count(*) FROM archives}); 1 };
    return $ok ? 1 : 0;
}

# Read share/schema/$flavor.sql, preprocess, split, execute. Idempotent
# (no-op when archives table already present).
sub bootstrap_schema {
    my $self = shift;
    return if $self->_is_bootstrapped;

    my $path = $self->schema_file;
    open(my $fh, '<', $path) or croak "cannot open schema file '$path': $!";
    my $sql = do { local $/; <$fh> };
    close $fh;

    $sql = $self->preprocess_schema_sql($sql);
    $sql =~ s{--[^\n]*\n}{\n}g;

    my @stmts = grep { /\S/ } split /;\s*\n/, $sql;
    for my $stmt (@stmts) {
        $stmt =~ s/^\s+//;
        $stmt =~ s/\s+$//;
        next unless length $stmt;
        next if $self->_should_skip_schema_statement($stmt);
        $self->dbh->do($stmt) or croak "schema bootstrap failed: " . $self->dbh->errstr;
    }
    return;
}

# ----- datetime helpers (per-flavor via DateTime::Format::*) -----
#
# Bind shape on writes: db_format_datetime turns a hi-res unix epoch
# (Time::HiRes-style float) -- or a DateTime, or a flavor-shaped string
# we can recognize -- into the bind string each driver expects.
#
# Read shape on reads: db_parse_datetime turns whatever the driver
# returns (string, DateTime) into a hi-res unix epoch float so callers
# never see a DateTime object across the App::Yath2::DB boundary.
#
# Per flavor:
#   sqlite    DateTime::Format::SQLite (TEXT column)
#   postgres  DateTime::Format::Pg     (TIMESTAMPTZ column)
#   mysql     DateTime::Format::MySQL  (DATETIME(6) column)
#   mariadb   DateTime::Format::MySQL  (DATETIME(6) column)

sub db_format_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;

    my $dt = $self->_dt_from_value($val);
    # Already a flavor-bind string we cannot turn into a DateTime: pass
    # through so any DB error message points at the bad value.
    return $val unless $dt;

    my $flavor = $self->flavor;

    if ($flavor eq 'postgres') {
        require DateTime::Format::Pg;
        return DateTime::Format::Pg->format_timestamptz($dt);
    }

    if ($flavor eq 'mysql' || $flavor eq 'mariadb') {
        require DateTime::Format::MySQL;
        return DateTime::Format::MySQL->format_datetime($dt);
    }

    # sqlite: DateTime::Format::SQLite drops fractional seconds; append
    # microseconds manually to keep the column round-trippable.
    require DateTime::Format::SQLite;
    my $base = DateTime::Format::SQLite->format_datetime($dt);
    my $ns = $dt->nanosecond;
    return $base unless $ns;
    return sprintf('%s.%06d', $base, int($ns / 1000));
}

sub db_parse_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;

    if (ref $val) {
        return $val->hires_epoch if eval { $val->isa('DateTime') };
        return undef;
    }

    # Numeric input is already a hi-res epoch.
    return $val + 0 if $val =~ /\A-?\d+(?:\.\d+)?\z/;

    my $flavor = $self->flavor;
    my $dt;
    my $ok = eval {
        if ($flavor eq 'postgres') {
            require DateTime::Format::Pg;
            $dt = DateTime::Format::Pg->parse_datetime($val);
        }
        elsif ($flavor eq 'mysql' || $flavor eq 'mariadb') {
            require DateTime::Format::MySQL;
            $dt = DateTime::Format::MySQL->parse_datetime($val);
        }
        else {
            # sqlite TEXT: 'YYYY-MM-DD HH:MM:SS[.frac][Z]' or ISO 'T'.
            require DateTime::Format::SQLite;
            my $tweaked = $val;
            $tweaked =~ s/Z\z//;
            $dt = DateTime::Format::SQLite->parse_datetime($tweaked);
        }
        1;
    };
    return undef unless $ok && $dt;

    # MySQL / SQLite parsers leave the DT in 'floating' time zone; the
    # column is UTC by convention. Relabel without shifting wall clock.
    $dt->set_time_zone('UTC') if $dt->time_zone->is_floating;

    return $dt->hires_epoch;
}

sub db_now {
    my $self = shift;
    return $self->db_format_datetime(Time::HiRes::time());
}

sub _dt_from_value {
    my ($self, $val) = @_;
    return undef unless defined $val;
    if (ref $val) {
        return $val if eval { $val->isa('DateTime') };
        return undef;
    }
    require DateTime;
    if ($val =~ /\A-?\d+(?:\.\d+)?\z/) {
        return DateTime->from_epoch(epoch => $val + 0, time_zone => 'UTC');
    }
    # Fall back through the flavor parser so a re-bound DB value still
    # round-trips correctly.
    my $epoch = eval { $self->db_parse_datetime($val) };
    return DateTime->from_epoch(epoch => $epoch, time_zone => 'UTC')
        if defined $epoch;
    # ISO-8601 'T'-form fallback (e.g. '2025-02-01T00:00:00Z') for inputs
    # that did not match the active flavor's parser.
    require DateTime::Format::ISO8601;
    my $tweaked = $val;
    $tweaked =~ s/Z\z//;
    my $dt = eval { DateTime::Format::ISO8601->parse_datetime($tweaked) };
    return undef unless $dt;
    $dt->set_time_zone('UTC') if $dt->time_zone->is_floating;
    return $dt;
}

# ----- codec helpers (shared by both backends) -----
#
# Canonical UUID form is 36-char lowercase hex. Per-flavor on-disk
# shape: sqlite stores the canonical text; postgres / mariadb store
# upper-case text; mysql stores 16 raw bytes.

sub _uuid_to_db {
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

sub _uuid_from_db {
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

# Canonical JSON form is a decoded Perl ref. _maybe_decode_json passes
# through refs and undef; bare strings get decoded. _maybe_encode_json
# is the symmetric write-side helper.

sub _maybe_decode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val;
    require Test2::Harness2::Util::JSON;
    return Test2::Harness2::Util::JSON::decode_json($val);
}

sub _maybe_encode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val unless ref $val;
    require Test2::Harness2::Util::JSON;
    return Test2::Harness2::Util::JSON::encode_json($val);
}

# Inflate every column listed in @cols in-place across @$rows by routing
# its value through _maybe_decode_json. Used by row-fetch primitives
# that return wide hashrefs with embedded JSON columns.
sub _inflate_json_rows {
    my ($self, $rows, $cols) = @_;
    for my $r (@$rows) {
        for my $c (@$cols) {
            $r->{$c} = $self->_maybe_decode_json($r->{$c}) if exists $r->{$c};
        }
    }
    return $rows;
}

# ----- existence checks (shared) -----
#
# Implementations of _count_rows live on each backend. The wrappers
# below validate inputs identically and delegate to it.

sub run_exists {
    my ($self, $aid, $run_ord) = @_;
    return 0 unless defined $aid && defined $run_ord;
    return 0 unless $run_ord =~ /^\d+\z/;
    return $self->_count_rows(runs => archive_id => $aid, run_ord => $run_ord)
        ? 1 : 0;
}

sub job_exists {
    my ($self, $aid, $rid, $job_ord) = @_;
    return 0 unless defined $aid && defined $rid && defined $job_ord;
    return 0 unless $job_ord =~ /^\d+\z/;
    return $self->_count_rows(jobs =>
        archive_id => $aid, run_id => $rid, job_ord => $job_ord,
    ) ? 1 : 0;
}

sub try_exists {
    my ($self, $jid, $try_ord) = @_;
    return 0 unless defined $jid && defined $try_ord;
    return 0 unless $try_ord =~ /^\d+\z/;
    return $self->_count_rows(job_tries => job_id => $jid, try_ord => $try_ord)
        ? 1 : 0;
}

sub service_exists {
    my ($self, $aid, $name, $rid) = @_;
    return 0 unless defined $aid && defined $name;
    return $self->_count_rows(services =>
        archive_id => $aid, run_id => $rid, name => $name,
    ) ? 1 : 0;
}

# ----- id resolution (shared) -----
#
# Implementations of _find_one_col live on each backend. Each public
# wrapper validates required args and croaks on missing rows.

sub run_id_for_ord {
    my ($self, $aid, $run_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_ord required"    unless defined $run_ord;
    my $id = $self->_find_one_col(runs => 'run_id',
        archive_id => $aid, run_ord => $run_ord);
    croak "no run with ord $run_ord" unless defined $id;
    return $id;
}

sub job_id_for_ord {
    my ($self, $aid, $rid, $job_ord) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $rid;
    croak "job_ord required"    unless defined $job_ord;
    my $id = $self->_find_one_col(jobs => 'job_id',
        archive_id => $aid, run_id => $rid, job_ord => $job_ord);
    croak "no job with ord $job_ord in run_id $rid" unless defined $id;
    return $id;
}

sub try_id_for_ord {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required"  unless defined $jid;
    croak "try_ord required" unless defined $try_ord;
    my $id = $self->_find_one_col(job_tries => 'job_try_id',
        job_id => $jid, try_ord => $try_ord);
    croak "no try with ord $try_ord in job_id $jid" unless defined $id;
    return $id;
}

sub service_id_for_name {
    my ($self, $aid, $name, $rid) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "service name required" unless defined $name;
    return $self->_find_one_col(services => 'service_id',
        archive_id => $aid, run_id => $rid, name => $name);
}

# ----- find-or-create wrappers (shared) -----
#
# Implementations of _ensure_row live on each backend; this role
# provides validation and the public ensure_*_row contract.
#
# ensure_run_row stays on the SQL backend: that path has flavor-specific
# UUID bind handling and the DBIC backend already routes through SQL.

sub ensure_project_row {
    my ($self, $name) = @_;
    croak "project name required" unless defined $name && length $name;
    return $self->_ensure_row(projects =>
        where  => { name => $name },
        fields => { name => $name },
        id_col => 'project_id',
    );
}

sub ensure_test_file_row {
    my ($self, $project_id, $relative) = @_;
    croak "project_id required"    unless defined $project_id;
    croak "relative path required" unless defined $relative && length $relative;
    return $self->_ensure_row(test_files =>
        where  => { project_id => $project_id, relative => $relative },
        fields => { project_id => $project_id, relative => $relative },
        id_col => 'test_file_id',
    );
}

sub ensure_service_row {
    my ($self, $aid, $name, $run_id) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "service name required" unless defined $name && length $name;
    return $self->_ensure_row(services =>
        where  => { archive_id => $aid, run_id => $run_id, name => $name },
        fields => { archive_id => $aid, run_id => $run_id, name => $name },
        id_col => 'service_id',
    );
}

sub ensure_job_row {
    my ($self, $aid, $run_id, $job_ord, $test_file_id) = @_;
    croak "archive_id required"   unless defined $aid;
    croak "run_id required"       unless defined $run_id;
    croak "job_ord required"      unless defined $job_ord;
    croak "test_file_id required" unless defined $test_file_id;
    return $self->_ensure_row(jobs =>
        where  => { archive_id => $aid, run_id => $run_id, job_ord => $job_ord },
        fields => { archive_id => $aid, run_id => $run_id, job_ord => $job_ord,
                    test_file_id => $test_file_id },
        id_col => 'job_id',
    );
}

sub ensure_job_try_row {
    my ($self, $job_id, $try_ord) = @_;
    croak "job_id required"  unless defined $job_id;
    croak "try_ord required" unless defined $try_ord;
    return $self->_ensure_row(job_tries =>
        where  => { job_id => $job_id, try_ord => $try_ord },
        fields => { job_id => $job_id, try_ord => $try_ord },
        id_col => 'job_try_id',
    );
}

# ----- helpers consumed by backend primitives -----

# Compute the on-disk-relative "directory" for an artifact row. The
# row carries the three nullable scope FKs; we infer scope kind by
# which one is set. All three NULL = archive-root scope.
sub _base_for_artifact_row {
    my ($self, $row) = @_;
    if (defined $row->{job_try_id}) {
        my $rord = $row->{j_run_ord};
        return undef unless defined $rord;
        return "runs/$rord/jobs/$row->{job_ord}/$row->{try_ord}";
    }
    if (defined $row->{service_id}) {
        my $name = $row->{service_name};
        return defined $row->{s_run_ord}
            ? "runs/$row->{s_run_ord}/services/$name"
            : "services/$name";
    }
    if (defined $row->{run_id}) {
        return "runs/$row->{run_ord}";
    }
    return '';
}

sub _stem_for_artifact_row {
    my ($self, $row) = @_;
    my $kind = $row->{artifact_kind};
    if ($kind eq 'events' || $kind eq 'spec' || $kind eq 'state' || $kind eq 'report') {
        my $fmt = $row->{format} // 'jsonl';
        return "$kind.$fmt";
    }
    if ($kind eq 'attachment') {
        return "attachments/" . $row->{name};
    }
    if ($kind eq 'arbitrary') {
        return $row->{name};
    }
    return undef;
}

# Translate a logical (scope_kind, scope_id) pair into a SQL WHERE
# fragment over the three nullable FK columns + bind values. The
# fragment never includes "archive_id = ?" -- callers prepend that.
# Used by the row-fetch primitives in the SQL backend.
sub _scope_where_clause {
    my ($self, $scope_kind, $scope_id) = @_;
    if ($scope_kind eq 'run') {
        return ('run_id = ? AND service_id IS NULL AND job_try_id IS NULL', $scope_id);
    }
    if ($scope_kind eq 'service') {
        return ('service_id = ? AND run_id IS NULL AND job_try_id IS NULL', $scope_id);
    }
    if ($scope_kind eq 'job_try') {
        return ('job_try_id = ? AND run_id IS NULL AND service_id IS NULL', $scope_id);
    }
    if ($scope_kind eq 'archive') {
        return ('run_id IS NULL AND service_id IS NULL AND job_try_id IS NULL');
    }
    croak "unknown scope_kind: $scope_kind";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::DB::Backend - Row-primitive contract every yath DB-archive backend implements.

=head1 DESCRIPTION

The L<Role::Tiny> role L<App::Yath2::DB> hands control to. Two
implementations satisfy it:

=over 4

=item L<App::Yath2::DB::SQL>

Single-class raw-DBI backend. Flavor differences (UUID bind shape,
payload binding, MariaDB trigger skip) live inside individual methods
rather than per-flavor subclasses.

=item L<App::Yath2::DB::DBIC>

Single-class L<DBIx::Class>-backed implementation that wraps an
L<App::Yath2::DB::DBIC::Schema>.

=back

Backends are skinny: connection / introspection plus typed-row CRUD.
The Log-shape archive surface (event walker, C<list_files>, the
C<artifacts> factory, C<extract> / C<archive> / C<insert> /
C<save_artifact>) lives entirely on L<App::Yath2::DB>, which
orchestrates over the primitives below. Schema bootstrap is uniform:
the role reads F<share/schema/$flavor.sql>, runs
C<preprocess_schema_sql>, splits on statement boundaries, and
executes. C<DBIC-E<gt>deploy> is never called.

=head1 SYNOPSIS

    package My::Yath::Backend;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'App::Yath2::Role::DB::Backend';

    # ... define every required method (see REQUIRED METHODS) ...

    1;

=head1 REQUIRED METHODS

Each consumer must implement every method below.

=head2 Connection / introspection

=over 4

=item $dbh = $backend->dbh

Return a live DBI handle. The role's bootstrap path uses this directly.

=item $flavor = $backend->flavor

One of C<sqlite>, C<postgres>, C<mysql>, or C<mariadb>. Drives schema
selection and per-flavor SQL fragments.

=back

=head2 Archive rows

=over 4

=item $rows = $backend->archive_rows

Every C<archives> row, each as a hashref with the typed columns plus a
decoded C<meta_extras>.

=item $row = $backend->archive_for_uuid($canon)

Lookup by canonical-hex archive uuid; C<undef> when absent.

=item $count = $backend->archive_count

Number of archive rows in this DB.

=item $aid = $backend->archive_create(\%fields)

Insert a new C<archives> row; return its primary key.

=item $backend->mark_sealed($archive_id, $when)

Update C<sealed_at> on an archive row to mark it sealed.

=back

=head2 Per-archive row primitives

Each takes the integer C<$archive_id> resolved by L<App::Yath2::DB> and
returns an arrayref of row hashes (or, for the existence checks, a
boolean).

=over 4

=item $rows = $backend->run_rows($aid)

=item $rows = $backend->service_rows($aid, %filter)

=item $rows = $backend->job_rows($aid, $run_id)

=item $rows = $backend->try_rows($job_id)

=item $bool = $backend->run_exists($aid, $run_ord)

=item $bool = $backend->job_exists($aid, $rid, $job_ord)

=item $bool = $backend->try_exists($jid, $try_ord)

=item $bool = $backend->service_exists($aid, $name, $rid_or_undef)

=item $id = $backend->run_id_for_ord($aid, $run_ord)

=item $id = $backend->job_id_for_ord($aid, $rid, $job_ord)

=item $id = $backend->try_id_for_ord($jid, $try_ord)

=item $id = $backend->service_id_for_name($aid, $name, $rid_or_undef)

=back

=head2 Find-or-create primitives

Idempotent; return the existing row id when present, otherwise insert
and return the new id.

=over 4

=item $id = $backend->ensure_project_row($name)

=item $id = $backend->ensure_test_file_row($project_id, $relative)

=item $id = $backend->ensure_run_row($aid, $run_ord, $project_id)

=item $id = $backend->ensure_service_row($aid, $name, $rid_or_undef)

=item $id = $backend->ensure_job_row($aid, $rid, $job_ord, $test_file_id)

=item $id = $backend->ensure_job_try_row($jid, $try_ord)

=back

=head2 Artifact rows

=over 4

=item $rows = $backend->artifact_rows_for_archive($aid, %opts)

Every artifact row for the archive, joined to the scope tables so the
row-to-path helpers in this role can build on-disk-relative paths.
C<with_payload =E<gt> 1> includes the C<payload> blob.

=item $row = $backend->artifact_row_for_scope($aid, $scope_kind, $scope_id, $artifact_kind, $name)

Lookup a single artifact row by its scope tuple.

=item $bytes = $backend->artifact_payload($artifact_id)

Read just the payload bytes for one artifact.

=item $id = $backend->artifact_create(\%fields)

=item $backend->artifact_update($artifact_id, \%fields)

=item $sum = $backend->artifact_event_count_for_archive($aid)

Sum C<row_count> across every events artifact in the archive.

=back

=head2 Spec / report data layer

=over 4

=item $rows = $backend->job_spec_rows($jid, $try_ord_or_undef)

=item $rows = $backend->service_lifetime_rows($service_id)

=item $rows = $backend->subtest_rows($job_try_id)

=item $id = $backend->job_spec_create($job_id, \%fields)

=item $id = $backend->service_lifetime_create($service_id, \%fields)

=item $id = $backend->subtest_create($job_try_id, \%fields)

=back

=head1 PROVIDED METHODS

Defaults installed by this role. Consumers may override for flavor
quirks.

=head2 Schema bootstrap

=over 4

=item $backend->bootstrap_schema

Read C<share/schema/$flavor.sql>, preprocess, split, execute.
Idempotent (no-op when the C<archives> table already exists).

=item $sql = $backend->preprocess_schema_sql($sql)

Identity by default. Consumers override to massage the schema text for
live-server quirks (e.g. stripping C<COMPRESSION lz4> when the Postgres
build lacks LZ4).

=item $bool = $backend->_should_skip_schema_statement($stmt)

False by default. Consumers override to elide individual schema
statements at bootstrap time (e.g. C<CREATE TRIGGER> bodies that use
MySQL-only builtins on a MariaDB target).

=item $path = $backend->schema_file

Locate C<share/schema/$flavor.sql> in the dev tree first, then the
installed share directory.

=back

=head2 Artifact-row helpers

Used by C<App::Yath2::DB::list_files> and the SQL backend's row-fetch
primitives.

=over 4

=item $base = $backend->_base_for_artifact_row($row)

On-disk-relative directory for an artifact row.

=item $stem = $backend->_stem_for_artifact_row($row)

On-disk-relative filename stem for an artifact row.

=item ($where, @bind) = $backend->_scope_where_clause($scope_kind, $scope_id)

SQL WHERE fragment + bind values for a logical scope tuple. Used by the
SQL backend's C<artifact_row_for_scope>.

=back

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
