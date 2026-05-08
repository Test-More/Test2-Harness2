package App::Yath2::DB::Internal;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Spec ();
use Time::HiRes qw/time/;
use version 0.77 ();

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::LogLayout qw/
    run_dir
    job_dir
    services_global_dir
    service_global_dir
    service_run_dir
    services_run_dir
/;

use App::Yath2::Log;
use App::Yath2::Log::Artifact;
use App::Yath2::Log::Iterator::JSONL;

use Object::HashBase qw{
    <dsn
    <dbh
    <user
    <pass
    <attrs
    <uuid
    <archive_id
    <project_id
    <sealed
    <flavor
    +_walk
    +_seen_starts
    +_closed_starts
    +_insert_source
};

use Role::Tiny::With;
with 'App::Yath2::Role::DB::Backend';

# {{{ Abstract base class for DB-backed Log readers / writers.
#
# Concrete subclasses (App::Yath2::DB::Internal::{Sqlite,Postgres,
# MariaDB,MySQL}) provide the small number of flavor-specific bits:
#
#   - schema_file()              -- path to the bootstrap .sql
#   - schema_flavor()            -- short name ('sqlite', 'postgres', ...)
#   - _connect_dbh()             -- driver-specific DBI connect + pragmas
#   - _payload_compressed_default() -- 1 = client-side zstd, 0 = server compresses
#   - _uuid_to_db / _uuid_from_db   -- UUID bind / fetch hooks
#   - _json_encode / _json_decode   -- JSON column codec
#   - _bootstrap_schema_sql      -- parse + execute schema.sql
#
# Everything else lives here so the four backends share one body of
# code.

sub init {
    my $self = shift;
    croak "DB backend requires one of: dbh, dsn"
        unless defined $self->{+DBH} || defined $self->{+DSN};
    return;
}

sub is_live { 0 }
sub static  { 1 }

# Subclasses provide schema_flavor (returns 'sqlite' / 'postgres' /
# 'mariadb' / 'mysql'). schema_file resolution comes from the role,
# which calls $self->flavor (which lazily falls back to schema_flavor).
sub schema_flavor { croak "subclass must implement schema_flavor()" }

sub _payload_compressed_default { 1 }   # default: client zstd
sub _uuid_to_db                 { $_[1] }
sub _uuid_from_db               { $_[1] }
sub _json_encode                { encode_json($_[1]) }
sub _json_decode                { my ($self, $val) = @_; defined $val ? decode_json($val) : undef }

# True for SQLite which has no 'now()' function returning ISO timestamps.
# Subclasses may override; default uses strftime in app code.
sub _now_iso {
    my $self = shift;
    my $t = time;
    my @lt = gmtime(int $t);
    my $frac = $t - int $t;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
        int($frac * 1000));
}

# Lazy DBH: subclass _connect_dbh applies pragmas etc. We override the
# accessor that HashBase generated so that callers always get a live
# handle (HashBase's read accessor returns the slot verbatim).
{
    no warnings 'redefine';
    *dbh = sub {
        my $self = shift;
        return $self->{+DBH} //= $self->_connect_dbh;
    };
}

sub _connect_dbh { croak "subclass must implement _connect_dbh()" }

# bootstrap_schema, _is_bootstrapped, schema_file, and the
# preprocess_schema_sql identity default come from
# App::Yath2::Role::DB::Backend. Concrete flavors override
# preprocess_schema_sql when needed (e.g. Postgres' lz4 strip).

# }}}

# {{{ Group-B: multi-archive container methods. Backends expose them
# directly so this class can be used as the multi-archive entry point
# without a separate handle.

# HashBase generated a flavor accessor that returns the slot verbatim.
# Override so callers always get a defined string (we lazily fall back
# to schema_flavor when the slot is undef).
{
    no warnings 'redefine';
    *flavor = sub {
        my $self = shift;
        return $self->{+FLAVOR} //= $self->schema_flavor;
    };
}

sub archives {
    my $self = shift;
    my $rows = $self->dbh->selectall_arrayref(
        q{SELECT archive_uuid FROM archives ORDER BY archive_id},
        { Slice => {} },
    );
    return map { $self->_uuid_from_db($_->{archive_uuid}) } @$rows;
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

sub scoped {
    my ($self, $uuid) = @_;
    croak "scoped() requires a uuid" unless defined $uuid;
    return ref($self)->new(
        dbh    => $self->dbh,
        flavor => $self->{+FLAVOR},
        uuid   => $uuid,
    );
}

# }}}

# {{{ Archive resolution
#
# After bootstrap (or on read), pick the archive row this Log instance
# operates against. Rules:
#
#   - 0 archives + read access -> throw "no archives in this DB".
#   - 1 archive + uuid omitted -> use the singleton.
#   - 1 archive + uuid present -> must match.
#   - N>1 archives + uuid omitted -> throw "ambiguous; specify uuid => ...".
#   - N>1 archives + uuid present -> select that archive (or throw if missing).

sub _resolve_archive {
    my ($self, %p) = @_;
    my $missing_ok = $p{missing_ok};

    my $dbh = $self->dbh;
    my $uuid = $self->{+UUID};

    my $rows = $dbh->selectall_arrayref(
        q{SELECT archive_id, archive_uuid, archive_version FROM archives ORDER BY archive_id},
        { Slice => {} },
    );
    my $count = scalar @$rows;

    if ($count == 0) {
        return undef if $missing_ok;
        croak "no archives in this DB";
    }

    if ($count == 1 && !defined $uuid) {
        my $u = $self->_uuid_from_db($rows->[0]{archive_uuid});
        $self->_check_archive_version($u, $rows->[0]{archive_version});
        $self->{+ARCHIVE_ID} = $rows->[0]{archive_id};
        $self->{+UUID} = $u;
        return $self->{+ARCHIVE_ID};
    }

    if (!defined $uuid) {
        # missing_ok in the multi-archive case: leave unresolved. Group-A
        # operations will fail later via _archive_id_or_die when they
        # actually need a uuid; that's the right place to error since
        # the caller may legitimately want to enumerate archives()
        # before scoping into a specific one.
        return undef if $missing_ok;
        croak "ambiguous; specify uuid => ... (this DB holds $count archives)";
    }

    for my $r (@$rows) {
        my $u = $self->_uuid_from_db($r->{archive_uuid});
        if (lc($u) eq lc($uuid)) {
            $self->_check_archive_version($u, $r->{archive_version});
            $self->{+ARCHIVE_ID} = $r->{archive_id};
            $self->{+UUID} = $u;
            return $self->{+ARCHIVE_ID};
        }
    }

    croak "no archive with uuid '$uuid' in this DB";
}

# Refuse archives whose archive_version is older than the floor
# returned by App::Yath2::Log->last_breaking_version. No auto-migration:
# the user must re-archive with a newer yath, or open the archive with
# an older yath that still groks it.
sub _check_archive_version {
    my ($self, $uuid, $archive_version) = @_;
    my $floor = App::Yath2::Log->last_breaking_version;
    croak "archive '$uuid' has no archive_version stamp; refusing to read"
        unless defined $archive_version && length $archive_version;
    return if version->parse($archive_version) >= version->parse($floor);
    croak "archive '$uuid' was written by yath $archive_version; "
        . "this dist requires >= $floor; refusing to read";
}

sub _create_archive {
    my ($self, $meta) = @_;
    croak "_create_archive requires a meta hashref"
        unless ref($meta) eq 'HASH';
    my $uuid = $meta->{archive_uuid} // gen_uuid();
    my $dbh = $self->dbh;

    my ($extras_json, undef) = $self->_split_meta_extras($meta);

    my $user_col = $self->_quote_user_col;
    my $sth = $dbh->prepare(qq{
        INSERT INTO archives
            (archive_uuid, archive_version, sealed_at,
             host, $user_col, git_sha, project, yath_version, meta_extras)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute(
        $self->_uuid_to_db($uuid),
        $App::Yath2::Log::VERSION,
        $self->_iso_to_db_datetime($meta->{created_at}),
        $meta->{host},
        $meta->{user},
        $meta->{git_sha},
        $meta->{project},
        $meta->{yath_version},
        $extras_json,
    );

    my $id = $self->_last_insert_id($dbh, 'archives', 'archive_id');
    $self->{+ARCHIVE_ID} = $id;
    $self->{+UUID} = $uuid;
    return $id;
}

# Build a DateTime object from a producer-emitted timestamp. Accepts:
#   * undef                    -> undef
#   * DateTime object          -> as-is
#   * Numeric epoch (any frac) -> DateTime::from_epoch UTC
#   * ISO-8601-ish string      -> DateTime::Format::ISO8601->parse
#   * any other string         -> undef (caller should pass through)
sub _to_datetime {
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
    if ($val =~ /\A\d{4}-\d{2}-\d{2}/) {
        require DateTime::Format::ISO8601;
        # ISO8601 parser is lenient; tolerates 'T' or ' ' separator,
        # optional 'Z' or offset, and fractional seconds.
        my $tweaked = $val;
        $tweaked =~ s/ /T/;     # space -> T for the parser
        return eval { DateTime::Format::ISO8601->parse_datetime($tweaked) };
    }
    return undef;
}

# Format a DateTime for the active flavor's DATETIME / TIMESTAMPTZ
# column. Default: ISO-8601 with Z (sqlite + postgres tolerate it).
# Per-flavor subclasses use DateTime::Format::Pg / MySQL / SQLite.
sub _format_datetime {
    my ($self, $dt) = @_;
    return undef unless defined $dt;
    return $dt->iso8601 . 'Z';
}

# Producer-side: turn whatever the producer emitted into a flavor-
# acceptable string. Falls back to passing through unparseable strings
# so the DB error message points at the bad value.
sub _normalize_timestamp {
    my ($self, $val) = @_;
    return undef unless defined $val;
    my $dt = $self->_to_datetime($val);
    return defined $dt ? $self->_format_datetime($dt) : $val;
}

# Meta.json's created_at -> flavor DATETIME column. Single producer-
# style entry point so the carry-over path in _create_archive works
# the same way as live producer values.
sub _iso_to_db_datetime {
    my ($self, $iso) = @_;
    return $self->_normalize_timestamp($iso);
}

# Reverse: column value -> ISO-8601 for meta.json reconstruction.
# strftime keeps fractional seconds; $dt->iso8601 drops them.
sub _db_datetime_to_iso {
    my ($self, $val) = @_;
    return undef unless defined $val;
    my $dt = $self->_to_datetime($val);
    return $val unless defined $dt;
    my $ns = $dt->nanosecond;
    return $dt->strftime('%Y-%m-%dT%H:%M:%SZ') if $ns == 0;
    return $dt->strftime('%Y-%m-%dT%H:%M:%S.%3NZ');
}

# Split a meta hash into (extras_json, promoted_hash). Anything in
# META_PROMOTED_KEYS goes to typed columns; everything else is encoded
# as JSON for archives.meta_extras. Returns (undef, $promoted) when
# there are no extra keys so we don't burn an empty '{}' blob.
sub _split_meta_extras {
    my ($self, $meta) = @_;
    my %promoted = map { $_ => 1 } App::Yath2::Log->META_PROMOTED_KEYS;
    my (%extras, %prom);
    for my $k (keys %$meta) {
        if ($promoted{$k}) {
            $prom{$k} = $meta->{$k};
        }
        else {
            $extras{$k} = $meta->{$k};
        }
    }
    my $json = %extras ? $self->_encode_json_or_undef(\%extras) : undef;
    return ($json, \%prom);
}

# SQL fragment for the keyword-clashing 'user' column. Default uses
# ANSI double-quote (sqlite + postgres + mariadb in ANSI_QUOTES);
# MySQL/MariaDB classes override to backticks.
sub _quote_user_col { '"user"' }

# Subclasses may override (Postgres needs RETURNING).
sub _last_insert_id {
    my ($self, $dbh, $table, $col) = @_;
    return $dbh->last_insert_id(undef, undef, $table, $col);
}

# Keys from a (post-A2 flattened) spec row that get promoted to typed
# job_specs columns. Anything else lands in job_specs.extras (as JSON).
# Column name == spec key name (no renames). 'relative' is promoted to
# test_files.relative (identity row), NOT duplicated in job_specs.
our @JOB_SPECS_PROMOTED_KEYS = qw(
    absolute category duration stage features switches
    retry retry_isolated smoke isolation non_perl is_binary
    event_timeout post_exit_timeout min_slots max_slots ch_dir
);

# Keys that are consumed structurally (not dumped into extras).
my %_JOB_SPECS_CONSUMED = map { $_ => 1 } (
    @JOB_SPECS_PROMOTED_KEYS,
    qw(relative),    # goes to test_files.relative
);

# Find or create a projects row by name. Returns project_id. Idempotent.
sub _resolve_or_create_project {
    my ($self, $name) = @_;
    croak "project name required" unless defined $name && length $name;

    my $dbh = $self->dbh;
    my ($id) = $dbh->selectrow_array(
        q{SELECT project_id FROM projects WHERE name = ?},
        undef, $name,
    );
    return $id if defined $id;

    $dbh->do(q{INSERT INTO projects (name) VALUES (?)}, undef, $name);
    return $self->_last_insert_id($dbh, 'projects', 'project_id');
}

# Find or create a test_files row for (project_id, relative).
# Returns test_file_id. Idempotent.
sub _resolve_or_create_test_file {
    my ($self, $project_id, $relative) = @_;
    croak "project_id required" unless defined $project_id;
    croak "relative path required" unless defined $relative && length $relative;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare(q{
        SELECT test_file_id FROM test_files WHERE project_id = ? AND relative = ?
    });
    $sth->execute($project_id, $relative);
    my ($id) = $sth->fetchrow_array;
    return $id if defined $id;

    $dbh->do(q{INSERT INTO test_files (project_id, relative) VALUES (?, ?)},
             undef, $project_id, $relative);
    return $self->_last_insert_id($dbh, 'test_files', 'test_file_id');
}

# archive_id accessor comes from HashBase (`<archive_id`).

# }}}

# {{{ Listing API

sub _archive_id_or_die {
    my $self = shift;
    my $aid = $self->{+ARCHIVE_ID};
    return $aid if defined $aid;

    # ARCHIVE_ID is unset because init's _resolve_archive(missing_ok => 1)
    # didn't pick a singleton. Re-query so we can report a precise error
    # (zero archives vs. ambiguous multi-archive without uuid).
    my $count = $self->dbh->selectrow_array(q{SELECT count(*) FROM archives});
    croak "no archives in this DB" if !$count;
    croak "ambiguous; specify uuid => ... (this DB holds $count archives)";
}

# Numeric-aware sort that mirrors Directory's behavior.
sub _smart_sort {
    my @ids = @_;
    return () unless @ids;
    if (!grep { !/^\d+\z/ } @ids) {
        return sort { $a <=> $b } @ids;
    }
    return sort @ids;
}

sub services {
    my ($self, $run_id) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        my $rid = $self->_run_db_id($run_id);
        my $rows = $dbh->selectall_arrayref(
            q{SELECT name FROM services WHERE archive_id = ? AND run_id = ? ORDER BY name},
            undef, $aid, $rid,
        );
        return map { $_->[0] } @$rows;
    }

    my $rows = $dbh->selectall_arrayref(
        q{SELECT name FROM services WHERE archive_id = ? AND run_id IS NULL ORDER BY name},
        undef, $aid,
    );
    return map { $_->[0] } @$rows;
}

sub runs {
    my $self = shift;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{SELECT run_ord FROM runs WHERE archive_id = ? ORDER BY run_ord},
        undef, $aid,
    );
    return map { $_->[0] } @$rows;
}

sub jobs {
    my ($self, $run_id) = @_;
    croak "run_id is required" unless defined $run_id;
    croak "no such run: $run_id" unless $self->has_run($run_id);
    my $aid = $self->_archive_id_or_die;
    my $rid = $self->_run_db_id($run_id);
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{SELECT job_ord FROM jobs WHERE archive_id = ? AND run_id = ? ORDER BY job_ord},
        undef, $aid, $rid,
    );
    return map { $_->[0] } @$rows;
}

sub tries {
    my ($self, $run_id, $job_id) = @_;
    croak "run_id is required" unless defined $run_id;
    croak "job_id is required" unless defined $job_id;
    croak "no such run: $run_id"            unless $self->has_run($run_id);
    croak "no such job: $run_id/$job_id"    unless $self->has_job($run_id, $job_id);
    my $jid = $self->_job_db_id($run_id, $job_id);
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{SELECT try_ord FROM job_tries WHERE job_id = ? ORDER BY try_ord},
        undef, $jid,
    );
    return map { $_->[0] } @$rows;
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
    my $dbh = $self->dbh;

    if (defined $run_id) {
        return 0 unless $self->has_run($run_id);
        my $rid = $self->_run_db_id($run_id);
        my ($n) = $dbh->selectrow_array(
            q{SELECT count(*) FROM services WHERE archive_id = ? AND run_id = ? AND name = ?},
            undef, $aid, $rid, $name,
        );
        return $n ? 1 : 0;
    }
    my ($n) = $dbh->selectrow_array(
        q{SELECT count(*) FROM services WHERE archive_id = ? AND run_id IS NULL AND name = ?},
        undef, $aid, $name,
    );
    return $n ? 1 : 0;
}

sub has_run {
    my ($self, $run_id) = @_;
    return 0 unless defined $run_id && length $run_id;
    return 0 unless $run_id =~ /^\d+\z/;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my ($n) = $dbh->selectrow_array(
        q{SELECT count(*) FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_id,
    );
    return $n ? 1 : 0;
}

sub has_job {
    my ($self, $run_id, $job_id) = @_;
    return 0 unless $self->has_run($run_id);
    return 0 unless defined $job_id && length $job_id;
    return 0 unless $job_id =~ /^\d+\z/;
    my $rid = $self->_run_db_id($run_id);
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my ($n) = $dbh->selectrow_array(
        q{SELECT count(*) FROM jobs WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $rid, $job_id,
    );
    return $n ? 1 : 0;
}

sub has_try {
    my ($self, $run_id, $job_id, $job_try) = @_;
    return 0 unless $self->has_job($run_id, $job_id);
    return 0 unless defined $job_try && length $job_try;
    return 0 unless $job_try =~ /^\d+\z/;
    my $jid = $self->_job_db_id($run_id, $job_id);
    my $dbh = $self->dbh;
    my ($n) = $dbh->selectrow_array(
        q{SELECT count(*) FROM job_tries WHERE job_id = ? AND try_ord = ?},
        undef, $jid, $job_try,
    );
    return $n ? 1 : 0;
}

# DB-id helpers (cache run/job rows lookup -- tests rarely need this
# to be fast, so a simple selectrow per call is fine).
sub _run_db_id {
    my ($self, $run_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT run_id FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    croak "no run with ord $run_ord" unless defined $id;
    return $id;
}

sub _job_db_id {
    my ($self, $run_ord, $job_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $rid = $self->_run_db_id($run_ord);
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT job_id FROM jobs WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $rid, $job_ord,
    );
    croak "no job with ord $job_ord in run $run_ord" unless defined $id;
    return $id;
}

sub _job_try_db_id {
    my ($self, $run_ord, $job_ord, $try_ord) = @_;
    my $jid = $self->_job_db_id($run_ord, $job_ord);
    my ($id) = $self->dbh->selectrow_array(
        q{SELECT job_try_id FROM job_tries WHERE job_id = ? AND try_ord = ?},
        undef, $jid, $try_ord,
    );
    croak "no try with ord $try_ord" unless defined $id;
    return $id;
}

sub _service_db_id {
    my ($self, $name, $run_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    if (defined $run_ord) {
        my $rid = $self->_run_db_id($run_ord);
        my ($id) = $dbh->selectrow_array(
            q{SELECT service_id FROM services WHERE archive_id = ? AND run_id = ? AND name = ?},
            undef, $aid, $rid, $name,
        );
        return $id;
    }
    my ($id) = $dbh->selectrow_array(
        q{SELECT service_id FROM services WHERE archive_id = ? AND run_id IS NULL AND name = ?},
        undef, $aid, $name,
    );
    return $id;
}

# }}}

# {{{ Artifacts handle factory (mirrors Directory)

# artifacts() / _artifacts_from_args() / _artifacts_root() / _make_artifact()
# now live on App::Yath2::Role::DB::Backend; both Internal and DBIC inherit
# the same orchestration. The role calls back into the consumer's native
# has_*, last_try, etc., so behavior is unchanged.

# }}}

# {{{ Path-to-scope translation
#
# The Artifact handle is filesystem-shaped: it speaks paths like
# 'runs/0/jobs/2/0/events.jsonl.zst'. The DB backend translates
# those paths into (scope_kind, scope_id, artifact_kind, format,
# name) tuples for storage. Translation is purely syntactic; the
# resulting scope_id is looked up against the live archive_id.

# Parse a relative path into a scope tuple. Returns a hashref with
# keys: scope_kind, scope_id (DB id), scope_ords {run_ord/job_ord/
# try_ord/service}, artifact_kind, format, name. Returns undef if
# the path is not parseable as a known artifact.
#
# The 'create' flag, when true, will create missing scope rows so
# that a save() against e.g. runs/3/services/foo/events.jsonl.zst
# auto-vivifies the run, the service, etc.
sub _parse_artifact_path {
    my ($self, $rel, %opts) = @_;
    my $create = $opts{create} ? 1 : 0;

    return undef unless defined $rel && length $rel;

    my @parts = split m{/}, $rel;
    return undef unless @parts;

    my ($scope_kind, $scope_id);
    my ($run_ord, $job_ord, $try_ord, $service_name);

    # services/<name>/...
    if ($parts[0] eq 'services') {
        return undef unless @parts >= 2;
        $service_name = $parts[1];
        $scope_kind = 'service';
        $scope_id = $create
            ? $self->_ensure_service_row(name => $service_name, run_ord => undef)
            : $self->_service_db_id($service_name);
        return undef unless defined $scope_id;
        splice(@parts, 0, 2);
    }
    # runs/<run_ord>/...
    elsif ($parts[0] eq 'runs') {
        return undef unless @parts >= 2;
        $run_ord = $parts[1];
        return undef unless $run_ord =~ /^\d+\z/;

        if (@parts == 2) {
            # runs/<rid>/ alone -> scope is the run itself.
            $scope_kind = 'run';
            $scope_id = $create
                ? $self->_ensure_run_row($run_ord)
                : ($self->has_run($run_ord) ? $self->_run_db_id($run_ord) : undef);
            return undef unless defined $scope_id;
            splice(@parts, 0, 2);
        }
        elsif ($parts[2] eq 'services') {
            return undef unless @parts >= 4;
            $service_name = $parts[3];
            $scope_kind = 'service';
            $scope_id = $create
                ? $self->_ensure_service_row(name => $service_name, run_ord => $run_ord)
                : $self->_service_db_id($service_name, $run_ord);
            return undef unless defined $scope_id;
            splice(@parts, 0, 4);
        }
        elsif ($parts[2] eq 'jobs') {
            return undef unless @parts >= 5;
            $job_ord = $parts[3];
            $try_ord = $parts[4];
            return undef unless $job_ord =~ /^\d+\z/ && $try_ord =~ /^\d+\z/;
            $scope_kind = 'job_try';
            $scope_id = $create
                ? $self->_ensure_job_try_row($run_ord, $job_ord, $try_ord)
                : ($self->has_try($run_ord, $job_ord, $try_ord)
                    ? $self->_job_try_db_id($run_ord, $job_ord, $try_ord)
                    : undef);
            return undef unless defined $scope_id;
            splice(@parts, 0, 5);
        }
        else {
            # runs/<rid>/<file> -- treat as run scope
            $scope_kind = 'run';
            $scope_id = $create
                ? $self->_ensure_run_row($run_ord)
                : ($self->has_run($run_ord) ? $self->_run_db_id($run_ord) : undef);
            return undef unless defined $scope_id;
            splice(@parts, 0, 2);
        }
    }
    else {
        # Archive-root artifact (e.g. meta.json).
        $scope_kind = 'archive';
        $scope_id = $self->_archive_id_or_die;
    }

    return undef unless @parts;

    # parts now describes the artifact_kind / file / format.
    my $remaining = join('/', @parts);

    # Standard streams: <kind>.jsonl(.zst)
    if ($remaining =~ m{^(events|spec|state|report)\.jsonl(\.zst)?\z}) {
        return {
            scope_kind => $scope_kind,
            scope_id   => $scope_id,
            artifact_kind => $1,
            format        => 'jsonl',
            name          => undef,
            is_zst        => $2 ? 1 : 0,
            scope_ords    => {
                run_ord => $run_ord, job_ord => $job_ord, try_ord => $try_ord,
                service => $service_name,
            },
        };
    }

    # Attachments: attachments/<name>(.zst)
    if ($remaining =~ m{^attachments/(.+?)(\.zst)?\z}) {
        return {
            scope_kind => $scope_kind,
            scope_id   => $scope_id,
            artifact_kind => 'attachment',
            format        => _format_for_name($1),
            name          => $1,
            is_zst        => $2 ? 1 : 0,
            scope_ords    => {
                run_ord => $run_ord, job_ord => $job_ord, try_ord => $try_ord,
                service => $service_name,
            },
        };
    }

    # Anything else: arbitrary file at this scope. The compressed
    # variant has a .zst suffix; the underlying name keeps the source
    # form (without .zst) so reads can find it from either probe.
    my ($base_name, $is_zst) = $remaining =~ /\.zst\z/
        ? (do { (my $b = $remaining) =~ s/\.zst\z//; $b }, 1)
        : ($remaining, 0);

    return {
        scope_kind => $scope_kind,
        scope_id   => $scope_id,
        artifact_kind => 'arbitrary',
        format        => _format_for_name($base_name),
        name          => $base_name,
        is_zst        => $is_zst,
        scope_ords    => {
            run_ord => $run_ord, job_ord => $job_ord, try_ord => $try_ord,
            service => $service_name,
        },
    };
}

# Light heuristics matching what the schema's `format` column expects.
sub _format_for_name {
    my ($name) = @_;
    return 'json'  if $name =~ /\.json\z/i;
    return 'jsonl' if $name =~ /\.jsonl\z/i;
    return 'csv'   if $name =~ /\.csv\z/i;
    return 'html'  if $name =~ /\.html?\z/i;
    return 'txt'   if $name =~ /\.txt\z/i;
    return 'bin';
}

# }}}

# {{{ Artifact backend primitives (called by Artifact handle)

# Returns ($exists, $is_zst). The Artifact handle probes both the .zst
# and plain variants of every path; we report each variant against the
# stored row's compression so the handle can pick consistently.
#
# For attachments and arbitrary files, we report "exists" only for the
# variant matching how the row was stored. (Directory works the same
# way -- it has one file on disk; only the matching path probe says
# yes.) Standard streams (events/spec/state/report) live in one row
# regardless of the .zst suffix; the .zst probe always wins so we
# return a zst-shaped exist for both forms only when stored compressed,
# and a plain-shaped exist only when stored plain.
#
# spec.jsonl / report.jsonl on run/service/job_try scopes are
# reconstructed from typed columns + extras at read time (see the
# Reconstruction API). For those paths "exists" is decided by the
# presence of the entity row itself, not the artifact row: spec/report
# artifact rows are not stored. We always advertise the .zst form for
# reconstructed bodies (read returns compressed bytes for the .zst
# probe, plaintext for the plain probe -- callers pick one).
sub _artifact_exists {
    my ($self, $rel) = @_;

    # Archive-root meta.json is reconstructed from the archives row
    # (AI_DOCS/2026-05-07-schema-redesign.md §D9: meta promotion).
    # Exists when we have an archive at all.
    if (defined $rel && ($rel eq 'meta.json' || $rel eq 'meta.json.zst')) {
        my $aid = eval { $self->_archive_id_or_die };
        return (0, 0) unless defined $aid;
        return (1, $rel =~ /\.zst\z/ ? 1 : 0);
    }

    my $info = $self->_parse_artifact_path($rel) or return (0, 0);

    if ($self->_is_reconstruct_target($info)) {
        return (0, 0) unless $self->_entity_exists_for_scope(
            $info->{scope_kind}, $info->{scope_id});
        return (1, $info->{is_zst} ? 1 : 0);
    }

    my $row = $self->_select_artifact_row($info);
    return (0, 0) unless $row;

    my $stored_compressed = $row->{compressed} ? 1 : 0;
    my $probed_zst        = $info->{is_zst}    ? 1 : 0;

    # Match Directory's "one path per file on disk" semantics: a row
    # stored compressed lives at the .zst path; a row stored plain
    # lives at the plain path. The caller probes both forms in turn
    # to find which one is real.
    return (0, 0) if $stored_compressed != $probed_zst;

    return (1, $probed_zst);
}

# True when the parsed path is a spec.jsonl or report.jsonl on a
# run/service/job_try scope -- the cases reconstructed from typed
# columns + extras at read time.
sub _is_reconstruct_target {
    my ($self, $info) = @_;
    return 0 unless ref($info) eq 'HASH';
    my $kind = $info->{artifact_kind} // '';
    return 0 unless $kind eq 'spec' || $kind eq 'report';
    my $scope = $info->{scope_kind} // '';
    return 0 if $scope eq 'archive';
    return 1;
}

# True when the entity referenced by ($scope_kind, $scope_id) exists.
# scope_id is already a DB id (from _parse_artifact_path), but a
# defensive existence check still keeps us safe against stale ids.
sub _entity_exists_for_scope {
    my ($self, $scope_kind, $scope_id) = @_;
    return 0 unless defined $scope_id;
    my $dbh = $self->dbh;
    my $aid = $self->_archive_id_or_die;
    if ($scope_kind eq 'run') {
        my ($n) = $dbh->selectrow_array(
            q{SELECT count(*) FROM runs WHERE archive_id = ? AND run_id = ?},
            undef, $aid, $scope_id,
        );
        return $n ? 1 : 0;
    }
    if ($scope_kind eq 'service') {
        my ($n) = $dbh->selectrow_array(
            q{SELECT count(*) FROM services WHERE archive_id = ? AND service_id = ?},
            undef, $aid, $scope_id,
        );
        return $n ? 1 : 0;
    }
    if ($scope_kind eq 'job_try') {
        my ($n) = $dbh->selectrow_array(
            q{SELECT count(*) FROM job_tries WHERE job_try_id = ?},
            undef, $scope_id,
        );
        return $n ? 1 : 0;
    }
    return 0;
}

sub _select_artifact_row {
    my ($self, $info) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    my ($scope_clause, @scope_bind) = $self->_scope_where_clause(
        $info->{scope_kind}, $info->{scope_id});

    my ($sql, @bind);
    if (defined $info->{name}) {
        $sql = qq{
            SELECT artifact_id, compressed, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name = ?
        };
        @bind = ($aid, @scope_bind, $info->{artifact_kind}, $info->{name});
    }
    else {
        $sql = qq{
            SELECT artifact_id, compressed, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name IS NULL
        };
        @bind = ($aid, @scope_bind, $info->{artifact_kind});
    }

    my $row = $dbh->selectrow_hashref($sql, undef, @bind);
    return $row;
}

# Translate a logical (scope_kind, scope_id) pair into a SQL WHERE
# fragment over the three nullable FK columns + bind values. The
# fragment never includes "archive_id = ?" — callers prepend that.
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

# For INSERT: returns a hashref { run_id => ..., service_id => ...,
# job_try_id => ... }, with exactly zero or one set based on the
# scope_kind/scope_id pair. Used to pick FK column values.
sub _scope_fk_values {
    my ($self, $scope_kind, $scope_id) = @_;
    my %v = (run_id => undef, service_id => undef, job_try_id => undef);
    if ($scope_kind eq 'run')      { $v{run_id}     = $scope_id }
    elsif ($scope_kind eq 'service') { $v{service_id} = $scope_id }
    elsif ($scope_kind eq 'job_try') { $v{job_try_id} = $scope_id }
    elsif ($scope_kind eq 'archive') { }
    else { croak "unknown scope_kind: $scope_kind" }
    return \%v;
}

# Read raw bytes for $rel. The Artifact handle calls this only after
# _artifact_exists confirmed which form is real, so the bytes we
# return match the storage shape directly. We still tolerate a
# mismatch (caller probed the wrong form) by re-shaping on the fly.
sub _artifact_read {
    my ($self, $rel) = @_;

    # Archive-root meta.json is reconstructed from the archives row.
    if (defined $rel && ($rel eq 'meta.json' || $rel eq 'meta.json.zst')) {
        my $rec = $self->_reconstruct_meta_record
            or croak "no meta in DB for archive";
        my $bytes = App::Yath2::Log->encode_archive_meta($rec);
        return $bytes unless $rel =~ /\.zst\z/;
        require Test2::Harness2::Util::Zstd;
        return Test2::Harness2::Util::Zstd::compress_blob($bytes);
    }

    my $info = $self->_parse_artifact_path($rel)
        or croak "cannot parse artifact path: $rel";

    if ($self->_is_reconstruct_target($info)) {
        return $self->_artifact_read_reconstructed($info);
    }

    my $row = $self->_select_artifact_row($info)
        or croak "no such artifact in DB: $rel";

    my $payload = $self->_payload_to_bytes($row->{payload});
    my $stored_compressed = $row->{compressed} ? 1 : 0;

    require Test2::Harness2::Util::Zstd;

    if ($info->{is_zst}) {
        return $payload if $stored_compressed;
        return Test2::Harness2::Util::Zstd::compress_blob($payload);
    }

    return $payload unless $stored_compressed;
    # Multi-frame jsonl streams need streaming decompress; single-frame
    # blobs (json snapshots) decompress fine via decompress_blob, but
    # _decompress_jsonl_bytes handles both shapes.
    return $self->_decompress_jsonl_bytes($payload);
}

# Reconstruct spec.jsonl / report.jsonl bytes from typed columns +
# extras for a run / service / job_try scope. Returns plaintext bytes
# unless $info->{is_zst} is set (then zstd-compressed bytes).
sub _artifact_read_reconstructed {
    my ($self, $info) = @_;
    my $records = $info->{artifact_kind} eq 'spec'
        ? $self->_reconstruct_spec_records($info->{scope_kind}, $info->{scope_id})
        : $self->_reconstruct_report_records($info->{scope_kind}, $info->{scope_id});
    $records ||= [];

    my $plain = '';
    for my $rec (@$records) {
        $plain .= encode_json($rec) . "\n";
    }

    return $plain unless $info->{is_zst};

    require Test2::Harness2::Util::Zstd;
    return Test2::Harness2::Util::Zstd::compress_blob($plain);
}

# Subclasses override for binary payload handling (Postgres BYTEA bind
# / fetch). Default: bytes pass-through.
sub _payload_to_bytes {
    my ($self, $val) = @_;
    return $val;
}

sub _payload_from_bytes {
    my ($self, $bytes) = @_;
    return $bytes;
}

# Open a scalar-backed filehandle for $rel. Returns whatever
# _artifact_read returns for that path -- the Artifact handle picks
# the right path before calling us.
sub _artifact_open_fh {
    my ($self, $rel) = @_;
    my $bytes = $self->_artifact_read($rel);
    open(my $sfh, '<', \$bytes) or croak "open scalar fh: $!";
    return $sfh;
}

# Records-backed iterator: returns an arrayref of decoded JSON objects,
# or undef when the artifact does not exist.
sub _artifact_iter_records {
    my ($self, $base, $stem) = @_;
    return undef unless defined $stem && length $stem;
    my $rel = defined $base && length $base ? "$base/$stem" : $stem;

    my $info = $self->_parse_artifact_path($rel) or return undef;

    if ($self->_is_reconstruct_target($info)) {
        return undef unless $self->_entity_exists_for_scope(
            $info->{scope_kind}, $info->{scope_id});
        my $records = $info->{artifact_kind} eq 'spec'
            ? $self->_reconstruct_spec_records($info->{scope_kind}, $info->{scope_id})
            : $self->_reconstruct_report_records($info->{scope_kind}, $info->{scope_id});
        return $records || [];
    }

    my $row = $self->_select_artifact_row($info) or return undef;

    my $payload = $self->_payload_to_bytes($row->{payload});
    my $stored_compressed = $row->{compressed} ? 1 : 0;

    my $plain;
    if ($stored_compressed) {
        $plain = $self->_decompress_jsonl_bytes($payload);
    }
    else {
        $plain = $payload;
    }

    my @records;
    for my $line (split /\n/, $plain) {
        next unless length $line;
        my $decoded;
        my $ok = eval { $decoded = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            chomp $err;
            warn "Skipping JSONL line that failed to decode in DB artifact '$rel': $err\n";
            next;
        }
        push @records => $decoded;
    }
    return \@records;
}

# List basenames of $rel (a "directory"). For DB scopes this maps to
# "list every attachment / arbitrary artifact at the parsed scope".
# Used for Artifact->attachments and Artifact->exists checks of
# directory listings.
sub _artifact_list_dir {
    my ($self, $rel, $artifact_kind) = @_;

    # Two cases:
    #   <base>/attachments  -> list all attachments at <base>
    #   <base>              -> list arbitrary files at <base>
    my $info;
    my $kind;
    if ($rel =~ m{/attachments\z} || $rel eq 'attachments') {
        (my $scope_rel = $rel) =~ s{/?attachments\z}{};
        # Resolve scope by re-parsing scope_rel + a synthetic placeholder.
        $info = $self->_parse_artifact_path("$scope_rel/_dummy_") if length $scope_rel;
        $info //= $self->_parse_artifact_path('_dummy_');
        $kind = 'attachment';
    }
    else {
        $info = $self->_parse_artifact_path("$rel/_dummy_");
        $kind = 'arbitrary';
    }
    return () unless $info;

    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    my ($scope_clause, @scope_bind) = $self->_scope_where_clause(
        $info->{scope_kind}, $info->{scope_id});

    my $rows = $dbh->selectall_arrayref(qq{
        SELECT name FROM artifacts
         WHERE archive_id = ? AND $scope_clause
           AND artifact_kind = ? AND name IS NOT NULL
         ORDER BY name
    }, undef, $aid, @scope_bind, $kind);

    return map { $_->[0] } @$rows;
}

sub _decompress_jsonl_bytes {
    my ($self, $bytes) = @_;
    require Test2::Harness2::Util::Zstd;
    require Compress::Zstd;

    my $out = '';
    my $offset = 0;
    while ($offset < length $bytes) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size(substr($bytes, $offset));
        croak "incomplete zstd frame in jsonl bytes" unless defined $size;
        my $frame = substr($bytes, $offset, $size);
        $offset += $size;
        my $plain = Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in jsonl bytes" unless defined $plain;
        $out .= $plain;
    }
    return $out;
}

sub absolute_path {
    my ($self, $rel) = @_;
    croak "absolute_path is unavailable for the DB backend; "
        . "extract first or read via the Log API ($rel)";
}

# Save artifact bytes. Args mirror the Artifact contract:
#   rel                full target relative path (with .zst suffix when compressed)
#   rel_alt            same path without .zst (for cleanup)
#   rel_alt_zst        same path with .zst (for cleanup)
#   bytes              raw plaintext bytes
#   compress           boolean -- caller wants compressed storage
#   force_no_overwrite boolean
sub _artifact_save {
    my ($self, %p) = @_;
    require Test2::Harness2::Util::Zstd;

    my $rel = $p{rel};
    my $info = $self->_parse_artifact_path($rel, create => 1)
        or croak "cannot parse artifact path: $rel";

    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    if ($p{force_no_overwrite}) {
        if ($self->_select_artifact_row($info)) {
            croak "artifact already exists: $rel";
        }
        # Also probe the alt form (with/without .zst).
        my $info_alt = { %$info, is_zst => $info->{is_zst} ? 0 : 1 };
        # Whether the row exists is independent of the .zst suffix on
        # the path; same row covers both the plain and .zst probes.
        # No additional check needed.
    }

    # Decide stored compression: respect caller's compress flag, but
    # also subclass default (e.g. Postgres always stores raw).
    my $client_compress = $self->_payload_compressed_default;
    my $stored_compressed;
    my $stored_bytes;
    if ($p{compress} && $client_compress) {
        $stored_compressed = 1;
        $stored_bytes = Test2::Harness2::Util::Zstd::compress_blob($p{bytes});
    }
    else {
        $stored_compressed = 0;
        $stored_bytes = $p{bytes};
    }

    my $now = $self->_now_iso;
    my $artifact_uuid = gen_uuid();

    # UPSERT semantics: replace existing row (matching the Directory
    # backend's "overwrite if exists" save behavior).
    my $existing = $self->_select_artifact_row($info);
    if ($existing) {
        my $sth = $dbh->prepare(q{
            UPDATE artifacts
               SET compressed = ?, payload = ?, format = ?, created_at = ?
             WHERE artifact_id = ?
        });
        $sth->bind_param(1, $stored_compressed);
        $self->_bind_payload($sth, 2, $self->_payload_from_bytes($stored_bytes));
        $sth->bind_param(3, $info->{format});
        $sth->bind_param(4, $now);
        $sth->bind_param(5, $existing->{artifact_id});
        $sth->execute;
        return "db:archive=$aid:artifact=$existing->{artifact_id}";
    }

    my $fk = $self->_scope_fk_values($info->{scope_kind}, $info->{scope_id});

    my $sth = $dbh->prepare(q{
        INSERT INTO artifacts
            (archive_id, artifact_uuid, run_id, service_id, job_try_id,
             artifact_kind, format, name, compressed, payload, created_at, sealed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->bind_param(1, $aid);
    $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid));
    $sth->bind_param(3, $fk->{run_id});
    $sth->bind_param(4, $fk->{service_id});
    $sth->bind_param(5, $fk->{job_try_id});
    $sth->bind_param(6, $info->{artifact_kind});
    $sth->bind_param(7, $info->{format});
    $sth->bind_param(8, $info->{name});
    $sth->bind_param(9, $stored_compressed);
    $self->_bind_payload($sth, 10, $self->_payload_from_bytes($stored_bytes));
    $sth->bind_param(11, $now);
    $sth->bind_param(12, 1);
    $sth->execute;

    my $id = $self->_last_insert_id($dbh, 'artifacts', 'artifact_id');
    return "db:archive=$aid:artifact=$id";
}

# Default payload binder. Subclasses may override to set a flavor-
# specific bind type (DBD::Pg's PG_BYTEA, DBI's SQL_BLOB, etc.).
sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    $sth->bind_param($idx, $bytes);
    return;
}

# }}}

# {{{ Scope-row autovivification (used during writes / inserts)

sub _ensure_run_row {
    my ($self, $run_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my ($id) = $dbh->selectrow_array(
        q{SELECT run_id FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    return $id if defined $id;

    my $run_uuid   = gen_uuid();
    my $project_id = $self->{+PROJECT_ID}
        // croak "project_id not set on DB object before _ensure_run_row";
    my $sth = $dbh->prepare(q{
        INSERT INTO runs (archive_id, project_id, run_ord, run_uuid, status, aborted, timed_out)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute($aid, $project_id, $run_ord, $self->_uuid_to_db($run_uuid), 'unknown', 0, 0);
    return $self->_last_insert_id($dbh, 'runs', 'run_id');
}

sub _ensure_service_row {
    my ($self, %p) = @_;
    my $name    = $p{name};
    my $run_ord = $p{run_ord};

    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my $rid = defined $run_ord ? $self->_ensure_run_row($run_ord) : undef;

    my ($id) = defined $rid
        ? $dbh->selectrow_array(
            q{SELECT service_id FROM services WHERE archive_id = ? AND run_id = ? AND name = ?},
            undef, $aid, $rid, $name)
        : $dbh->selectrow_array(
            q{SELECT service_id FROM services WHERE archive_id = ? AND run_id IS NULL AND name = ?},
            undef, $aid, $name);
    return $id if defined $id;

    my $sth = $dbh->prepare(q{
        INSERT INTO services (archive_id, run_id, name) VALUES (?, ?, ?)
    });
    $sth->execute($aid, $rid, $name);
    return $self->_last_insert_id($dbh, 'services', 'service_id');
}

sub _ensure_job_row {
    my ($self, $run_ord, $job_ord) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my $rid = $self->_ensure_run_row($run_ord);

    my ($id) = $dbh->selectrow_array(
        q{SELECT job_id FROM jobs WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $rid, $job_ord,
    );
    return $id if defined $id;

    # Resolve test_file_id from the source's spec.jsonl for this job before
    # INSERT: the schema requires jobs.test_file_id NOT NULL.
    my $test_file_id = $self->_resolve_test_file_for_job($run_ord, $job_ord);
    croak "could not resolve test_file_id for job ($run_ord, $job_ord) -- "
        . "source must carry a spec.jsonl with a 'relative' key for every job"
        unless defined $test_file_id;

    my $sth = $dbh->prepare(q{
        INSERT INTO jobs (archive_id, run_id, job_ord, test_file_id) VALUES (?, ?, ?, ?)
    });
    $sth->execute($aid, $rid, $job_ord, $test_file_id);
    return $self->_last_insert_id($dbh, 'jobs', 'job_id');
}

# Walk the source's tries for (run_ord, job_ord), reading spec.jsonl from
# each until we find a 'relative' key. Resolves (or creates) the test_files
# row and returns test_file_id. Returns undef if no spec with 'relative' is
# found. Requires $self->{+_INSERT_SOURCE} to be set (done by insert()).
sub _resolve_test_file_for_job {
    my ($self, $run_ord, $job_ord) = @_;

    my $source = $self->{+_INSERT_SOURCE};
    return undef unless defined $source;

    my $project_id = $self->{+PROJECT_ID};
    return undef unless defined $project_id;

    my @tries = $source->can('tries')
        ? eval { $source->tries($run_ord, $job_ord) }
        : ();
    return undef unless @tries;

    for my $try_ord (@tries) {
        my $artifact = eval { $source->artifacts($run_ord, $job_ord, $try_ord) }
            or next;
        my $spec = $self->_read_first_jsonl_row($artifact, 'spec.jsonl')
            or next;
        my $relative = $spec->{relative};
        next unless defined $relative && length $relative;
        return $self->_resolve_or_create_test_file($project_id, $relative);
    }

    return undef;
}

sub _ensure_job_try_row {
    my ($self, $run_ord, $job_ord, $try_ord) = @_;
    my $jid = $self->_ensure_job_row($run_ord, $job_ord);
    my $dbh = $self->dbh;

    my ($id) = $dbh->selectrow_array(
        q{SELECT job_try_id FROM job_tries WHERE job_id = ? AND try_ord = ?},
        undef, $jid, $try_ord,
    );
    return $id if defined $id;

    my $sth = $dbh->prepare(q{
        INSERT INTO job_tries (job_id, try_ord) VALUES (?, ?)
    });
    $sth->execute($jid, $try_ord);
    return $self->_last_insert_id($dbh, 'job_tries', 'job_try_id');
}

# }}}

# {{{ Iterator (depth-first walk over collector trees)

sub _walk_state {
    my $self = shift;
    return $self->{+_WALK} //= {
        stack => [
            $self->_open_artifact_walk(
                base    => 'services/harness',
                run_id  => undef,
                job_id  => undef,
                job_try => undef,
                service => 'harness',
                collector_pid => undef,
            ),
        ],
    };
}

sub _open_artifact_walk {
    my ($self, %args) = @_;
    my $base = $args{base};
    my $records = $self->_artifact_iter_records($base, 'events.jsonl') || [];
    return {
        records       => $records,
        idx           => 0,
        base          => $base,
        ident         => {
            (defined $args{run_id}  ? (run_id  => $args{run_id})  : ()),
            (defined $args{job_id}  ? (job_id  => $args{job_id})  : ()),
            (defined $args{job_try} ? (job_try => $args{job_try}) : ()),
            (defined $args{service} ? (service_name => $args{service}) : ()),
        },
        collector_pid => $args{collector_pid},
    };
}

sub _facet {
    my ($self, $event, $name) = @_;
    return undef unless ref($event) eq 'HASH';
    my $fd = $event->{facet_data};
    return undef unless ref($fd) eq 'HASH';
    return $fd->{$name};
}

sub _base_for_collector_start {
    my ($self, $content) = @_;
    return undef unless ref($content) eq 'HASH';
    my $type = $content->{type};
    return undef unless defined $type;

    if ($type eq 'Job') {
        my $rid = $content->{run_id};
        my $jid = $content->{id};
        my $try = $content->{job_try} // 0;
        return undef unless defined $rid && defined $jid;
        return "runs/$rid/jobs/$jid/$try";
    }
    if ($type eq 'Run') {
        my $rid = $content->{id};
        return undef unless defined $rid;
        return "runs/$rid";
    }
    if ($type eq 'Service') {
        my $name = $content->{service_name} // $content->{id};
        return undef unless defined $name && length $name;
        my $rid = $content->{run_id};
        return defined $rid ? "runs/$rid/services/$name" : "services/$name";
    }
    return undef;
}

sub _inject_identifiers {
    my ($self, $event, $ident) = @_;
    return $event unless ref($event) eq 'HASH';

    my $fd = $event->{facet_data} // do { $event->{facet_data} = {}; $event->{facet_data} };
    my $h = $fd->{harness} // do { $fd->{harness} = {}; $fd->{harness} };

    for my $k (qw/run_id job_id job_try service_name/) {
        next unless exists $ident->{$k};
        $h->{$k} //= $ident->{$k};
    }
    return $event;
}

sub event {
    my ($self, $timeout) = @_;

    my $walk = $self->_walk_state;
    my $stack = $walk->{stack};

    while (1) {
        last unless @$stack;

        my $got;
        my $owner;
        for (my $i = $#$stack; $i >= 0; $i--) {
            my $entry = $stack->[$i];
            if ($entry->{idx} < scalar @{$entry->{records}}) {
                $got = $entry->{records}[$entry->{idx}++];
                $owner = $entry;
                last;
            }
        }

        if (defined $got) {
            if (my $start = $self->_facet($got, 'harness_collector_start')) {
                my $cpid = $start->{collector_pid};
                $self->{+_SEEN_STARTS}{$cpid} = $start if defined $cpid;
                my $child_base = $self->_base_for_collector_start($start);
                if (defined $child_base) {
                    my %args = (base => $child_base, collector_pid => $cpid);
                    my $type = $start->{type};
                    if ($type eq 'Job') {
                        $args{run_id}  = $start->{run_id};
                        $args{job_id}  = $start->{id};
                        $args{job_try} = $start->{job_try} // 0;
                    }
                    elsif ($type eq 'Run') {
                        $args{run_id} = $start->{id};
                    }
                    elsif ($type eq 'Service') {
                        $args{service} = $start->{service_name} // $start->{id};
                        $args{run_id}  = $start->{run_id} if defined $start->{run_id};
                    }
                    push @$stack => $self->_open_artifact_walk(%args);
                }
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            if (my $end = $self->_facet($got, 'harness_collector_end')) {
                my $cpid = $end->{collector_pid};
                $self->{+_CLOSED_STARTS}{$cpid} = 1 if defined $cpid;
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            return $self->_inject_identifiers($got, $owner->{ident});
        }

        my $popped = 0;
        while (@$stack && $stack->[-1]{idx} >= scalar @{$stack->[-1]{records}}) {
            pop @$stack;
            $popped++;
        }
        last if !@$stack;
    }

    return undef;
}

sub events {
    my ($self, $timeout) = @_;
    my @out;
    while (1) {
        my $e = $self->event(0);
        last unless defined $e;
        push @out => $e;
    }
    if (!@out && $self->EOE) {
        return (undef);
    }
    return @out;
}

sub EOE { $_[0]->end_of_events }

sub end_of_events {
    my $self = shift;
    my $walk = $self->_walk_state;
    my $stack = $walk->{stack};

    while (@$stack) {
        my $top = $stack->[-1];
        if ($top->{idx} < scalar @{$top->{records}}) {
            return 0;
        }
        pop @$stack;
    }
    return 1;
}

sub reset {
    my $self = shift;
    delete $self->{+_WALK};
    delete $self->{+_SEEN_STARTS};
    delete $self->{+_CLOSED_STARTS};
    return;
}

# }}}

# {{{ extract / archive / insert

# DB primitive consumed by App::Yath2::Role::DB::Backend::list_files
# (and other archive-shaped orchestrators). Returns an arrayref of
# hashrefs, one per artifacts row in the given archive_id, with the
# scope FKs and joined ord/name fields the role helpers need to
# compute on-disk paths. Includes j_run_ord (run_ord through
# job_tries -> jobs -> runs) so _base_for_artifact_row never has to
# fall back to a per-row lookup.
sub _artifact_rows_for_archive {
    my ($self, $aid) = @_;
    my $dbh = $self->dbh;
    return $dbh->selectall_arrayref(q{
        SELECT a.artifact_id,
               a.run_id, a.service_id, a.job_try_id,
               a.artifact_kind, a.format, a.name, a.compressed,
               s.name  AS service_name,
               sr.run_ord AS s_run_ord,
               r.run_ord  AS run_ord,
               t.try_ord  AS try_ord,
               j.job_ord  AS job_ord,
               jr.run_ord AS j_run_ord
          FROM artifacts a
          LEFT JOIN services  s  ON a.service_id = s.service_id
          LEFT JOIN runs      sr ON s.run_id     = sr.run_id
          LEFT JOIN runs      r  ON a.run_id     = r.run_id
          LEFT JOIN job_tries t  ON a.job_try_id = t.job_try_id
          LEFT JOIN jobs      j  ON t.job_id     = j.job_id
          LEFT JOIN runs      jr ON j.run_id     = jr.run_id
         WHERE a.archive_id = ?
    }, { Slice => {} }, $aid);
}

# extract($dir, %opts) -- materialize the archive into a directory
# tree matching the on-disk Directory layout.
sub extract {
    my ($self, $dir, %opts) = @_;
    croak "destination is required" unless defined $dir && length $dir;
    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $compressed = exists $opts{compressed} ? $opts{compressed} : 0;
    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    make_path($dir);

    require Test2::Harness2::Util::Zstd;
    require App::Yath2::Log::Directory;

    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    my $rows = $dbh->selectall_arrayref(q{
        SELECT a.artifact_id, a.run_id, a.service_id, a.job_try_id,
               a.artifact_kind, a.format,
               a.name, a.compressed, a.payload,
               s.name AS service_name, sr.run_ord AS s_run_ord,
               r.run_ord AS run_ord,
               t.try_ord AS try_ord, j.job_ord AS job_ord, jr.run_ord AS j_run_ord
          FROM artifacts a
          LEFT JOIN services s   ON a.service_id = s.service_id
          LEFT JOIN runs sr      ON s.run_id     = sr.run_id
          LEFT JOIN runs r       ON a.run_id     = r.run_id
          LEFT JOIN job_tries t  ON a.job_try_id = t.job_try_id
          LEFT JOIN jobs j       ON t.job_id     = j.job_id
          LEFT JOIN runs jr      ON j.run_id     = jr.run_id
         WHERE a.archive_id = ?
    }, { Slice => {} }, $aid);

    for my $row (@$rows) {
        # Determine run_ord for filter.
        my $rord;
        if    (defined $row->{run_id})                                          { $rord = $row->{run_ord}; }
        elsif (defined $row->{service_id} && defined $row->{s_run_ord})         { $rord = $row->{s_run_ord}; }
        elsif (defined $row->{job_try_id})                                      { $rord = $row->{j_run_ord}; }

        if (defined $rord) {
            if (defined $runs) {
                next unless grep { $_ eq $rord } @$runs;
            }
            elsif (defined $exclude_runs) {
                next if grep { $_ eq $rord } @$exclude_runs;
            }
        }

        my $base = $self->_base_for_artifact_row($row);
        next unless defined $base;
        my $stem = $self->_stem_for_artifact_row($row);
        next unless defined $stem;

        my $rel = length $base ? "$base/$stem" : $stem;

        my $payload = $self->_payload_to_bytes($row->{payload});
        my $stored_compressed = $row->{compressed} ? 1 : 0;

        my $out_rel;
        my $out_bytes;
        if ($compressed) {
            $out_rel = "$rel.zst";
            $out_bytes = $stored_compressed
                ? $payload
                : Test2::Harness2::Util::Zstd::compress_blob($payload);
        }
        else {
            $out_rel = $rel;
            # Multi-frame jsonl needs streaming decompress; single-frame
            # blobs decompress fine via _decompress_jsonl_bytes too.
            $out_bytes = $stored_compressed
                ? $self->_decompress_jsonl_bytes($payload)
                : $payload;
        }

        my $abs = File::Spec->catfile($dir, $out_rel);
        my $par = dirname($abs);
        make_path($par) unless -d $par;
        open(my $fh, '>', $abs) or croak "open '$abs': $!";
        binmode $fh;
        print $fh $out_bytes;
        close $fh or croak "close '$abs': $!";
    }

    # meta.json is reconstructed from archives columns
    # (AI_DOCS/2026-05-07-schema-redesign.md §D9 -- there is no artifact
    # row to walk for it). Write it explicitly at the archive root so an
    # extracted directory looks identical to a tar.zidx-extracted one.
    {
        my $rec = $self->_reconstruct_meta_record;
        if ($rec) {
            my $bytes = App::Yath2::Log->encode_archive_meta($rec);
            my $out_rel = $compressed ? 'meta.json.zst' : 'meta.json';
            my $out_bytes = $compressed
                ? Test2::Harness2::Util::Zstd::compress_blob($bytes)
                : $bytes;
            my $abs = File::Spec->catfile($dir, $out_rel);
            my $par = dirname($abs);
            make_path($par) unless -d $par;
            open(my $fh, '>', $abs) or croak "open '$abs': $!";
            binmode $fh;
            print $fh $out_bytes;
            close $fh or croak "close '$abs': $!";
        }
    }

    return App::Yath2::Log::Directory->new(path => $dir, live => 0);
}

sub archive {
    my ($self, $out, %opts) = @_;
    croak "output path is required" unless defined $out && length $out;

    my $format = $opts{format} // 'tar';
    $format = 'tar.zidx' if $format eq 'tar';

    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    if ($format eq 'tar.zidx') {
        require File::Temp;
        my $tmp = File::Temp::tempdir(CLEANUP => 1, TEMPLATE => 'yath-db-XXXXXX', TMPDIR => 1);
        require File::Path;
        File::Path::remove_tree($tmp, {keep_root => 1});
        $self->extract($tmp, compressed => 0, runs => $runs, exclude_runs => $exclude_runs);
        require App::Yath2::Log::Directory;
        my $dir = App::Yath2::Log::Directory->new(path => $tmp, live => 0);
        return $dir->archive($out);
    }

    if ($format eq 'sqlite') {
        require App::Yath2::DB::Internal::Sqlite;
        my $dest = App::Yath2::DB::Internal::Sqlite->new(file => $out);
        # seal => 1: this is a single-archive sealed file; append the
        # YATHFOOT trailer + zstd-compressed meta.json past the body.
        $dest->insert(
            $self,
            runs         => $runs,
            exclude_runs => $exclude_runs,
            seal         => 1,
        );
        return $dest;
    }

    if ($format eq 'postgres' || $format eq 'mariadb' || $format eq 'mysql') {
        croak "archive($format) requires a dsn => / dbh => target; not yet implemented";
    }

    croak "unknown archive format: $format";
}

# Insert another Log object's contents into this DB as a new archive
# row. The source can be any Log backend (Directory / TarZIdx / DB).
sub insert {
    my ($self, $source, %opts) = @_;
    croak "source log is required" unless defined $source;

    croak "Log is sealed; further inserts not permitted"
        if $self->{+SEALED};

    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    # compress=1 (default): store artifact payloads in their natural
    # shape -- bytes that arrived zstd-shaped stay zstd, plaintext
    # stays plaintext. compress=0: force every payload to plaintext;
    # any source .zst is decompressed on the way in.
    my $compress = exists $opts{compress} ? ($opts{compress} ? 1 : 0) : 1;

    my $dbh = $self->dbh;
    # bootstrap_schema runs DDL (CREATE TABLE / INDEX). Some flavors
    # implicitly commit DDL inside a transaction, which would render
    # our rollback a no-op for the rows we'd already written. Always
    # bootstrap BEFORE begin_work.
    $self->bootstrap_schema;

    require App::Yath2::Log;

    # Resolve the archive metadata. Per AI_DOCS/2026-05-07-schema-redesign.md
    # §D5, sealed_at carries the source archive's live->sealed timestamp
    # (== meta.created_at). Per §D5+§D6, archive_uuid carries over
    # verbatim so re-importing the same source raises a clean error
    # rather than silently duplicating it under a fresh uuid.
    my $meta = $self->_resolve_insert_meta($source, \%opts);

    # Pre-flight uniqueness check (AI_DOCS/2026-05-07-schema-redesign.md
    # §D6). If the source's archive_uuid already exists in this DB, refuse
    # the re-import cleanly -- before opening any transaction so there is
    # no partial state to roll back.
    $self->_check_archive_uuid_unique($meta->{archive_uuid});

    # Wrap the entire population pass in a single transaction
    # (AI_DOCS/2026-05-07-schema-redesign.md §D6). Any die mid-insert
    # -> full rollback; no partial archive rows.
    $dbh->begin_work;
    my $aid;
    my $ok = eval {
        $aid = $self->_insert_body($source, $meta, $compress, $runs, $exclude_runs);
        1;
    };
    my $err = $@;

    if ($ok) {
        $dbh->commit;
    }
    else {
        # Rollback the failed transaction. Any rollback failure is
        # secondary to the original error; warn so it isn't lost.
        my $rb_ok = eval { $dbh->rollback; 1 };
        my $rb_err = $@;
        warn "rollback failed after insert error: $rb_err" unless $rb_ok;
        # Insert state ($self->{+_INSERT_SOURCE}, +PROJECT_ID,
        # +ARCHIVE_ID, +UUID) may have been left set by the partial
        # body. Clear so a retry against the same Log instance is
        # not poisoned.
        delete $self->{+_INSERT_SOURCE};
        die $err;
    }

    # Caller asked for a single-archive sealed file -- after commit
    # checkpoint the WAL into the main file, disconnect the dbh, and
    # append meta.json + the 64-byte YATHFOOT trailer past the SQLite
    # body. Subsequent inserts on this instance will croak (the
    # +SEALED slot prevents silent corruption).
    if ($opts{seal}) {
        $self->_seal_with_footer($meta);
    }

    return $aid;
}

# Resolve the on-disk path backing this Log instance, or undef when
# the backend is not file-backed. The Sqlite subclass uses a 'file'
# slot; we also fall back to parsing 'dbi:SQLite:dbname=...' DSNs so
# Sqlite instances opened with dsn => still work. Postgres / MariaDB /
# MySQL backends do not have a single-file backing and return undef
# here so seal => 1 can refuse them cleanly.
sub _db_file_path {
    my $self = shift;
    return $self->{file} if defined $self->{file};
    my $dsn = $self->{+DSN};
    return undef unless defined $dsn;
    return $1 if $dsn =~ /dbname=([^;]+)/i;
    return $1 if $dsn =~ /dbi:SQLite:([^;]+)\z/i;
    return undef;
}

# Write meta.json + 64-byte YATHFOOT trailer past the SQLite body.
# Sequence:
#   1. PRAGMA wal_checkpoint(TRUNCATE) -- merge WAL into main file.
#   2. Disconnect the dbh (flushes / releases the file).
#   3. Validate disk size == page_count * page_size.
#   4. Append zstd-compressed meta.json + 64-byte trailer.
# After append the +SEALED slot prevents further inserts on this
# instance.
sub _seal_with_footer {
    my ($self, $meta) = @_;

    my $path = $self->_db_file_path
        or croak "seal => 1 is only supported for file-backed (sqlite) Log backends.";

    my $dbh = $self->dbh;

    my ($page_count) = $dbh->selectrow_array('PRAGMA page_count');
    my ($page_size)  = $dbh->selectrow_array('PRAGMA page_size');
    croak "_seal_with_footer: PRAGMA page_count returned undef"
        unless defined $page_count;
    croak "_seal_with_footer: PRAGMA page_size returned undef"
        unless defined $page_size;

    # Merge the WAL into the main file so trailing bytes go past the
    # full body. wal_checkpoint(TRUNCATE) is a no-op (or harmless
    # error) on non-WAL journal modes.
    eval { $dbh->do('PRAGMA wal_checkpoint(TRUNCATE)') };

    $dbh->disconnect;
    delete $self->{+DBH};

    # After checkpoint+disconnect the on-disk file should hold all
    # pages. Recompute page_count*page_size by reading the file size:
    # the WAL fold may have grown the main file, but the relationship
    # body_size == file_size must hold for the trailer to be
    # consistent. If a stale -wal / -shm sidecar still exists, leave
    # it alone -- the seal trailer ignores them.
    my $body_size = -s $path;
    croak "_seal_with_footer: cannot stat '$path': $!"
        unless defined $body_size;

    my $expected = $page_count * $page_size;
    croak "_seal_with_footer: file size $body_size != page_count*page_size $expected"
        unless $body_size == $expected;

    require App::Yath2::Log;
    my $meta_bytes = App::Yath2::Log->encode_archive_meta($meta);

    require App::Yath2::Log::Footer;
    App::Yath2::Log::Footer::append_meta(
        $path,
        $meta_bytes,
        format_id  => App::Yath2::Log::Footer::FORMAT_ID_SQL(),
        compressed => 1,
        body_size  => $body_size,
    );

    $self->{+SEALED} = 1;
    return;
}

# The transaction body of insert(). Split out so insert() can wrap
# this in begin_work / commit / rollback without growing a giant
# eval block in the public method. Returns the new archive_id.
sub _insert_body {
    my ($self, $source, $meta, $compress, $runs, $exclude_runs) = @_;
    my $dbh = $self->dbh;

    # Resolve (find-or-create) the projects row for this archive.
    my $project_name = $meta->{project} // 'unknown';
    my $project_id   = $self->_resolve_or_create_project($project_name);
    $self->{+PROJECT_ID} = $project_id;

    # Make $source visible to _ensure_job_row so it can read spec.jsonl
    # on demand when creating a jobs row (needed for NOT NULL test_file_id).
    # Cleared at the end of the body. On rollback the caller clears
    # it as well.
    $self->{+_INSERT_SOURCE} = $source;

    # Fresh archive row -- meta drives all promoted columns.
    my $aid = $self->_create_archive($meta);

    require Test2::Harness2::Util::Zstd;

    # Walk source directory layout and insert artifacts.
    my @files;
    if ($source->can('list_files')) {
        @files = $source->list_files;
    }
    else {
        croak "source log does not support list_files";
    }

    # De-dup: callers may emit the same logical artifact under both
    # 'foo.jsonl' and 'foo.jsonl.zst' when the source already exposes
    # both probes (e.g. the dispatcher's auto-detect). Pick the .zst
    # form when both exist; track logical paths to skip redundant
    # inserts.
    my %seen_logical;
    my @ordered;
    for my $rel (@files) {
        next if $rel eq 'LIVE';
        # Skip any meta.json the source already had; we mint a fresh
        # one below keyed to the new archive_uuid.
        next if $rel eq 'meta.json' || $rel eq 'meta.json.zst';
        # spec.jsonl / report.jsonl / state.jsonl are reconstructed
        # from typed columns + *_extras at read time; do not write them
        # as artifact rows.
        next if $rel =~ m{(?:^|/)(?:spec|report|state)\.jsonl(?:\.zst)?\z};
        (my $logical = $rel) =~ s/\.zst\z//;
        if ($rel =~ /\.zst\z/) {
            # Prefer the .zst variant -- replace any prior plain entry.
            $seen_logical{$logical} = $rel;
        }
        else {
            $seen_logical{$logical} //= $rel;
        }
        push @ordered => $logical;
    }
    # Preserve order, dedup by logical name.
    my %emitted;
    my @final = grep { !$emitted{$_}++ } @ordered;

    for my $logical (@final) {
        my $rel = $seen_logical{$logical};

        # Apply run filter.
        if ($rel =~ m{^runs/(\d+)/}) {
            my $rid = $1;
            if (defined $runs) {
                next unless grep { $_ eq $rid } @$runs;
            }
            elsif (defined $exclude_runs) {
                next if grep { $_ eq $rid } @$exclude_runs;
            }
        }

        my $info = $self->_parse_artifact_path($rel, create => 1);
        next unless $info;
        next unless defined $info->{artifact_kind};

        # Read raw bytes from the source. Tag whether they are
        # zstd-shaped: ($exists, $is_zst).
        my ($exists, $src_is_zst) = $source->_artifact_exists($rel);
        next unless $exists;

        my $raw = $source->_artifact_read($rel);

        # Decide storage shape. Default ($compress=1): preserve the
        # source's form so round-trips are byte-for-byte identical
        # (.zst stays compressed, plain stays plain). $compress=0:
        # force plaintext -- decompress source .zst on the way in.
        my ($stored_compressed, $stored_bytes);
        if ($compress) {
            $stored_compressed = $src_is_zst ? 1 : 0;
            $stored_bytes      = $raw;
        }
        else {
            $stored_compressed = 0;
            $stored_bytes      = $src_is_zst
                ? $self->_decompress_jsonl_bytes($raw)
                : $raw;
        }

        my $artifact_uuid = gen_uuid();
        my $now = $self->_now_iso;
        my $fk = $self->_scope_fk_values($info->{scope_kind}, $info->{scope_id});
        my $sth = $dbh->prepare(q{
            INSERT INTO artifacts
                (archive_id, artifact_uuid, run_id, service_id, job_try_id,
                 artifact_kind, format, name, compressed, payload, created_at, sealed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        });
        $sth->bind_param(1, $aid);
        $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid));
        $sth->bind_param(3, $fk->{run_id});
        $sth->bind_param(4, $fk->{service_id});
        $sth->bind_param(5, $fk->{job_try_id});
        $sth->bind_param(6, $info->{artifact_kind});
        $sth->bind_param(7, $info->{format});
        $sth->bind_param(8, $info->{name});
        $sth->bind_param(9, $stored_compressed);
        $self->_bind_payload($sth, 10, $self->_payload_from_bytes($stored_bytes));
        $sth->bind_param(11, $now);
        $sth->bind_param(12, 1);
        $sth->execute;
    }

    # Artifact loop complete; clear the source reference.
    delete $self->{+_INSERT_SOURCE};

    # No meta.json artifact-row write: per AI_DOCS/2026-05-07-schema-redesign.md
    # §D9, archive metadata lives in the typed archives columns +
    # meta_extras. Reads of meta.json at the archive root reconstruct
    # from those columns via _reconstruct_meta_record.

    # Populate summary columns on runs / jobs / job_tries / services
    # / subtests. The artifact rows are the authoritative bytes, but
    # the summary columns are what readers actually query (status /
    # pass / exit / file / etc.) -- a row of NULLs makes the DB
    # unusable for everything except raw artifact retrieval.
    $self->_populate_summary_rows($source, $aid, $runs, $exclude_runs, $project_id);

    # No sealed_at UPDATE here -- per AI_DOCS/2026-05-07-schema-redesign.md
    # §D5, sealed_at carries the source's live->sealed transition time
    # and was set at _create_archive time from $meta->{created_at}.

    return $aid;
}

# Read the source's meta.json if present (carry-over) or mint fresh.
# Per AI_DOCS/2026-05-07-schema-redesign.md §D5+§D6: archive_uuid is a
# fixed value per archive that carries over verbatim from the source.
# The caller may force a specific UUID via $opts->{archive_uuid}
# (which wins over both source and minted). A live-dir source has no
# meta.json; in that case build_archive_meta mints fresh. All other
# meta keys (created_at -> sealed_at, host, user, git_sha, project,
# yath_version, plus any future extras) carry over verbatim per §D5/§D9
# -- they reflect the source archive's identity, not the current insert.
#
# Re-import detection (§D6) relies on the source's archive_uuid
# colliding with an existing destination row; so we MUST NOT mint a
# fresh uuid when the source already carries one.
sub _resolve_insert_meta {
    my ($self, $source, $opts) = @_;
    my $meta;

    my $root = eval { $source->artifacts };
    if ($root && eval { $root->exists(App::Yath2::Log->META_FILENAME) }) {
        my $bytes = eval { $root->get(App::Yath2::Log->META_FILENAME) };
        if (defined $bytes && length $bytes) {
            my $decoded = eval { decode_json($bytes) };
            $meta = $decoded if ref($decoded) eq 'HASH';
        }
    }
    unless ($meta) {
        # Live-dir source (no meta.json) -- mint fresh.
        $meta = App::Yath2::Log->build_archive_meta(
            archive_uuid => $opts->{archive_uuid},
        );
    }

    # Caller's explicit override wins over both source and minted.
    if (defined $opts->{archive_uuid}) {
        $meta->{archive_uuid} = $opts->{archive_uuid};
    }

    # Source's archive_uuid carries over verbatim. Mint only when
    # nothing supplied it (defensive -- e.g. a meta.json that lacked
    # the key).
    $meta->{archive_uuid} //= gen_uuid();

    return $meta;
}

# Pre-flight uniqueness check on archive_uuid. If a row already
# exists with this uuid we throw a clean error
# (AI_DOCS/2026-05-07-schema-redesign.md §D6) BEFORE opening a
# transaction; deferring to the DB's UNIQUE constraint would also
# work but the error message varies by flavor and would happen
# mid-tx. The check assumes bootstrap_schema has already run.
sub _check_archive_uuid_unique {
    my ($self, $uuid) = @_;
    return unless defined $uuid && length $uuid;
    my $dbh = $self->dbh;

    my ($existing) = $dbh->selectrow_array(
        q{SELECT archive_id FROM archives WHERE archive_uuid = ?},
        undef, $self->_uuid_to_db($uuid),
    );
    return unless defined $existing;

    croak "archive uuid '$uuid' already exists; not re-imported";
}

# After the artifact bytes are in the DB, walk the source's runs /
# services / jobs / tries and project their spec.jsonl + report.jsonl
# rows into the typed summary columns. Subtests are exploded out of
# each job report's subtests array. Errors during a single row's
# population are isolated -- one corrupt artifact does not abort the
# seal -- but they warn so the user knows the row is partial.
sub _populate_summary_rows {
    my ($self, $source, $aid, $runs_filter, $exclude_runs_filter, $project_id) = @_;

    my $dbh = $self->dbh;
    require Test2::Harness2::Util::JSON;
    Test2::Harness2::Util::JSON->import('encode_json');

    my @run_ords = $source->can('runs') ? $source->runs : ();

    # Global services first (no run scope).
    if ($source->can('services')) {
        my @globals = $source->services;
        for my $name (@globals) {
            $self->_populate_service_lifetimes($source, $aid, $name, undef);
        }
    }

    for my $run_ord (@run_ords) {
        if (defined $runs_filter) {
            next unless grep { $_ eq $run_ord } @$runs_filter;
        }
        elsif (defined $exclude_runs_filter) {
            next if grep { $_ eq $run_ord } @$exclude_runs_filter;
        }

        $self->_populate_run_row($source, $aid, $run_ord, $project_id);

        if ($source->can('services')) {
            for my $name ($source->services($run_ord)) {
                $self->_populate_service_lifetimes($source, $aid, $name, $run_ord);
            }
        }

        my @job_ords = $source->can('jobs') ? $source->jobs($run_ord) : ();
        for my $job_ord (@job_ords) {
            $self->_populate_job_rows($source, $aid, $run_ord, $job_ord);
        }
    }

    return;
}

sub _read_first_jsonl_row {
    my ($self, $artifact, $stem) = @_;
    return undef unless $artifact;
    my $iter;
    if ($stem eq 'spec.jsonl') {
        $iter = eval { $artifact->spec_iter } or return undef;
    }
    elsif ($stem eq 'report.jsonl') {
        $iter = eval { $artifact->report_iter } or return undef;
    }
    else {
        return undef;
    }
    my $row = eval { $iter->next };
    return ref($row) eq 'HASH' ? $row : undef;
}

# Walk the named JSONL stream from $artifact and return all hash rows
# as an arrayref. Mirrors the eval-protected pattern of
# _read_first_jsonl_row: returns [] on missing artifact, missing stream,
# or any read error.
sub _read_all_jsonl_rows {
    my ($self, $artifact, $stem) = @_;
    return [] unless $artifact;
    my $iter;
    if ($stem eq 'spec.jsonl') {
        $iter = eval { $artifact->spec_iter } or return [];
    }
    elsif ($stem eq 'report.jsonl') {
        $iter = eval { $artifact->report_iter } or return [];
    }
    else {
        return [];
    }
    my @rows;
    while (1) {
        my $row = eval { $iter->next };
        last unless defined $row;
        push @rows => $row if ref($row) eq 'HASH';
    }
    return \@rows;
}

sub _encode_json_or_undef {
    my ($self, $val) = @_;
    return undef unless defined $val;
    require Test2::Harness2::Util::JSON;
    my $out = eval { Test2::Harness2::Util::JSON::encode_json($val) };
    return defined $out ? $out : undef;
}

# Decode a JSON column value. Tolerates a value that has already been
# decoded by the driver (Postgres' JSONB sometimes auto-decodes via
# DBD::Pg). Returns undef on undef / decode failure / empty string.
sub _maybe_decode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref($val);
    return undef unless length $val;
    my $decoded = eval { decode_json($val) };
    return $decoded;
}

# Keys promoted from a run spec.jsonl row to typed columns on `runs`.
# `run_uuid` is identity (already promoted at _ensure_run_row time);
# listed here so it doesn't leak into spec_extras. `times` /
# `child_times` / `child_wall` may appear in either spec or report; on
# collision the report value wins (it's the later writer).
our @RUNS_SPEC_PROMOTED_KEYS = qw(
    run_uuid started_at
    times child_times child_wall
);

# Keys promoted from a run report.jsonl row to typed columns on `runs`.
our @RUNS_REPORT_PROMOTED_KEYS = qw(
    ended_at exit exit_decoded pass
    total_jobs passed_jobs failed_jobs aborted_jobs
    times child_times child_wall
);

# Aggregated keys that are NOT stored in runs.spec_extras / state_extras.
# `jobs` / `services` are rebuilt via JOIN at read time; `subtests` is
# exploded into the subtests table per-job_try.
our @RUNS_AGGREGATED_KEYS = qw(jobs subtests services);

# Keys promoted from a job_tries spec.jsonl row to typed columns on
# `job_tries`.
our @JOB_TRIES_SPEC_PROMOTED_KEYS = qw(
    queued_at started_at
    times child_times child_wall
);

# Keys promoted from a job_tries report.jsonl row to typed columns on
# `job_tries`.
our @JOB_TRIES_REPORT_PROMOTED_KEYS = qw(
    ended_at exit exit_decoded pass
    pass_count fail_count assertion_count
    plan halt
    times child_times child_wall
);

# Aggregated keys excluded from job_tries.spec_extras / state_extras.
# `subtests` is exploded into the subtests table.
our @JOB_TRIES_AGGREGATED_KEYS = qw(subtests);

# Walk a run's spec.jsonl and report.jsonl and project them into the
# (already-existing) runs row. Single-row split: a run never restarts
# (only services do). Promoted keys go to typed columns; everything
# else lands in spec_extras / state_extras. Aggregated keys (`jobs`,
# `subtests`, `services`) are dropped from BOTH typed-promotion and
# extras -- they get rebuilt via JOIN at read time.
sub _populate_run_row {
    my ($self, $source, $aid, $run_ord, $project_id) = @_;

    my $artifact = eval { $source->artifacts($run_ord) } or return;
    my $spec   = $self->_read_first_jsonl_row($artifact, 'spec.jsonl');
    my $report = $self->_read_first_jsonl_row($artifact, 'report.jsonl');

    my %spec_promoted   = map { $_ => 1 } @RUNS_SPEC_PROMOTED_KEYS;
    my %report_promoted = map { $_ => 1 } @RUNS_REPORT_PROMOTED_KEYS;
    my %aggregated      = map { $_ => 1 } @RUNS_AGGREGATED_KEYS;

    my (%spec_typed, %spec_extras);
    if (ref($spec) eq 'HASH') {
        for my $k (sort keys %$spec) {
            next if $aggregated{$k};
            if ($spec_promoted{$k}) {
                $spec_typed{$k} = $spec->{$k};
            }
            else {
                $spec_extras{$k} = $spec->{$k};
            }
        }
    }

    my (%report_typed, %state_extras);
    if (ref($report) eq 'HASH') {
        for my $k (sort keys %$report) {
            next if $aggregated{$k};
            if ($report_promoted{$k}) {
                $report_typed{$k} = $report->{$k};
            }
            else {
                $state_extras{$k} = $report->{$k};
            }
        }
    }

    # times / child_times / child_wall: report wins on collision.
    my $times = exists $report_typed{times}       ? $report_typed{times}
              : exists $spec_typed{times}         ? $spec_typed{times}
              : undef;
    my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                    : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                    : undef;
    my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                   : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                   : undef;

    my $times_json       = ref($times)       ? $self->_encode_json_or_undef($times)       : $times;
    my $child_times_json = ref($child_times) ? $self->_encode_json_or_undef($child_times) : $child_times;

    my $spec_extras_json  = %spec_extras  ? $self->_encode_json_or_undef(\%spec_extras)  : undef;
    my $state_extras_json = %state_extras ? $self->_encode_json_or_undef(\%state_extras) : undef;

    my %set;
    $set{started_at}   = $self->_normalize_timestamp($spec_typed{started_at})   if defined $spec_typed{started_at};
    $set{ended_at}     = $self->_normalize_timestamp($report_typed{ended_at})   if defined $report_typed{ended_at};
    $set{exit}         = $report_typed{exit}                           if defined $report_typed{exit};
    $set{exit_decoded} = $self->_encode_json_or_undef($report_typed{exit_decoded})
        if defined $report_typed{exit_decoded};
    $set{pass}         = $report_typed{pass} ? 1 : 0                   if exists  $report_typed{pass};
    $set{total_jobs}   = $report_typed{total_jobs}                     if defined $report_typed{total_jobs};
    $set{passed_jobs}  = $report_typed{passed_jobs}                    if defined $report_typed{passed_jobs};
    $set{failed_jobs}  = $report_typed{failed_jobs}                    if defined $report_typed{failed_jobs};
    $set{aborted_jobs} = $report_typed{aborted_jobs}                   if defined $report_typed{aborted_jobs};
    $set{times}        = $times_json                                   if defined $times_json;
    $set{child_times}  = $child_times_json                             if defined $child_times_json;
    $set{child_wall}   = $child_wall                                   if defined $child_wall;
    $set{spec_extras}  = $spec_extras_json                             if defined $spec_extras_json;
    $set{state_extras} = $state_extras_json                            if defined $state_extras_json;
    $set{status}       = (ref($report) eq 'HASH' && defined $report->{ended_at}) ? 'completed' : 'incomplete';
    $set{project_id}   = $project_id                                   if defined $project_id;

    if (defined $spec_typed{run_uuid}) {
        $set{run_uuid} = $self->_uuid_to_db($spec_typed{run_uuid});
    }

    my %where = (archive_id => $aid, run_ord => $run_ord);
    return $self->_update_row('runs', \%set, \%where);
}

# Keys promoted from a service spec.jsonl row to typed columns on
# service_lifetimes. Anything else lands in spec_extras.
our @SERVICE_LIFETIME_SPEC_PROMOTED_KEYS = qw(
    type id service_name stage_name started_at
    times child_times child_wall
);

# Keys promoted from a service report.jsonl row to typed columns. Note
# `times` / `child_times` / `child_wall` may appear in either spec or
# report; on collision the report value wins (it's the later writer).
our @SERVICE_LIFETIME_REPORT_PROMOTED_KEYS = qw(
    ended_at exit exit_decoded
    times child_times child_wall
);

# Walk a service's spec.jsonl and report.jsonl artifacts and project
# them into service_lifetimes rows -- one row per start/end cycle.
# Per AI_DOCS/2026-05-07-schema-redesign.md §D1: services may restart,
# so report.jsonl can have multiple rows; spec rows may be sparser.
# Pair by ord index (1-based). The parent services row is identity-only
# (name/role/run_id); role is promoted from the first non-null spec row
# that carries a `role` key.
sub _populate_service_lifetimes {
    my ($self, $source, $aid, $name, $run_ord) = @_;
    my $dbh = $self->dbh;

    my $artifact;
    if (defined $run_ord) {
        # Run-scoped service: positional ($run_ord, $service_name).
        $artifact = eval { $source->artifacts($run_ord, $name) };
    }
    else {
        # Global service: positional ($service_name); falls back to
        # hashref form when the source's artifacts() does not auto-detect.
        $artifact = eval { $source->artifacts($name) }
                 || eval { $source->artifacts({service => $name}) };
    }
    return unless $artifact;

    my $specs   = $self->_read_all_jsonl_rows($artifact, 'spec.jsonl');
    my $reports = $self->_read_all_jsonl_rows($artifact, 'report.jsonl');

    # Make sure the service row exists (may have been skipped if the
    # artifact loop didn't cover it -- though normally it does).
    my $sid = $self->_ensure_service_row(name => $name, run_ord => $run_ord);

    # Promote `role` from the first spec row that carries one. Leave
    # NULL (do not touch) when no spec row supplies a `role` key.
    for my $spec (@$specs) {
        next unless ref($spec) eq 'HASH';
        next unless defined $spec->{role};
        $self->_update_row('services', {role => $spec->{role}}, {service_id => $sid});
        last;
    }

    my $count = (scalar @$specs > scalar @$reports)
        ? scalar @$specs
        : scalar @$reports;
    return unless $count;

    my %spec_promoted   = map { $_ => 1 } @SERVICE_LIFETIME_SPEC_PROMOTED_KEYS;
    my %report_promoted = map { $_ => 1 } @SERVICE_LIFETIME_REPORT_PROMOTED_KEYS;

    my $sth = $dbh->prepare(q{
        INSERT INTO service_lifetimes
            (service_id, lifetime_ord, status,
             type, id, service_name, stage_name,
             started_at, ended_at,
             "exit", exit_decoded,
             times, child_times, child_wall,
             spec_extras, state_extras)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });

    for (my $i = 0; $i < $count; $i++) {
        my $spec   = $specs->[$i];
        my $report = $reports->[$i];

        # Split spec keys: typed cols vs spec_extras catch-all.
        my (%spec_typed, %spec_extras);
        if (ref($spec) eq 'HASH') {
            for my $k (sort keys %$spec) {
                if ($spec_promoted{$k}) {
                    $spec_typed{$k} = $spec->{$k};
                }
                else {
                    $spec_extras{$k} = $spec->{$k};
                }
            }
        }

        # Split report keys: typed cols vs state_extras catch-all.
        my (%report_typed, %state_extras);
        if (ref($report) eq 'HASH') {
            for my $k (sort keys %$report) {
                if ($report_promoted{$k}) {
                    $report_typed{$k} = $report->{$k};
                }
                else {
                    $state_extras{$k} = $report->{$k};
                }
            }
        }

        # Resolve typed columns. Report wins on collision for the
        # shared keys (times / child_times / child_wall).
        my $type         = $spec_typed{type};
        my $id           = $spec_typed{id};
        my $service_name = $spec_typed{service_name};
        my $stage_name   = $spec_typed{stage_name};
        my $started_at   = $self->_normalize_timestamp($spec_typed{started_at});
        my $ended_at     = $self->_normalize_timestamp($report_typed{ended_at});
        my $exit_val     = $report_typed{exit};
        my $exit_decoded = exists $report_typed{exit_decoded}
            ? $self->_encode_json_or_undef($report_typed{exit_decoded})
            : undef;

        my $times = exists $report_typed{times}       ? $report_typed{times}
                  : exists $spec_typed{times}         ? $spec_typed{times}
                  : undef;
        my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                        : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                        : undef;
        my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                       : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                       : undef;

        my $times_json       = ref($times)       ? $self->_encode_json_or_undef($times)       : $times;
        my $child_times_json = ref($child_times) ? $self->_encode_json_or_undef($child_times) : $child_times;

        my $spec_extras_json  = (ref($spec)   eq 'HASH' && %spec_extras)
            ? $self->_encode_json_or_undef(\%spec_extras)  : undef;
        my $state_extras_json = (ref($report) eq 'HASH' && %state_extras)
            ? $self->_encode_json_or_undef(\%state_extras) : undef;

        my $status;
        if (ref($report) eq 'HASH' && defined $report->{ended_at}) {
            $status = 'completed';
        }
        else {
            $status = 'running';
        }

        $sth->execute(
            $sid, $i + 1, $status,
            $type, $id, $service_name, $stage_name,
            $started_at, $ended_at,
            $exit_val, $exit_decoded,
            $times_json, $child_times_json, $child_wall,
            $spec_extras_json, $state_extras_json,
        );
    }

    return;
}

sub _populate_job_rows {
    my ($self, $source, $aid, $run_ord, $job_ord) = @_;
    my $dbh = $self->dbh;

    my @tries = $source->can('tries') ? $source->tries($run_ord, $job_ord) : ();
    return unless @tries;

    my $job_db_id;
    my ($latest_try_ord, $latest_pass, $latest_status, $latest_spec);

    my %spec_promoted   = map { $_ => 1 } @JOB_TRIES_SPEC_PROMOTED_KEYS;
    my %report_promoted = map { $_ => 1 } @JOB_TRIES_REPORT_PROMOTED_KEYS;
    my %aggregated      = map { $_ => 1 } @JOB_TRIES_AGGREGATED_KEYS;

    for my $try_ord (@tries) {
        my $artifact = eval { $source->artifacts($run_ord, $job_ord, $try_ord) } or next;
        my $spec   = $self->_read_first_jsonl_row($artifact, 'spec.jsonl');
        my $report = $self->_read_first_jsonl_row($artifact, 'report.jsonl');

        my $jtid = $self->_ensure_job_try_row($run_ord, $job_ord, $try_ord);
        $job_db_id //= do {
            my ($x) = $dbh->selectrow_array(
                q{SELECT job_id FROM job_tries WHERE job_try_id = ?},
                undef, $jtid,
            );
            $x;
        };

        # Split spec keys: typed cols vs spec_extras catch-all. Drop
        # aggregated keys (subtests) from BOTH.
        my (%spec_typed, %spec_extras);
        if (ref($spec) eq 'HASH') {
            for my $k (sort keys %$spec) {
                next if $aggregated{$k};
                if ($spec_promoted{$k}) {
                    $spec_typed{$k} = $spec->{$k};
                }
                else {
                    $spec_extras{$k} = $spec->{$k};
                }
            }
        }

        # Split report keys: typed cols vs state_extras catch-all. Drop
        # aggregated keys (subtests) from BOTH; subtests is exploded
        # into its own table below.
        my (%report_typed, %state_extras);
        if (ref($report) eq 'HASH') {
            for my $k (sort keys %$report) {
                next if $aggregated{$k};
                if ($report_promoted{$k}) {
                    $report_typed{$k} = $report->{$k};
                }
                else {
                    $state_extras{$k} = $report->{$k};
                }
            }
        }

        # times / child_times / child_wall: report wins on collision.
        my $times = exists $report_typed{times}       ? $report_typed{times}
                  : exists $spec_typed{times}         ? $spec_typed{times}
                  : undef;
        my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                        : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                        : undef;
        my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                       : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                       : undef;

        my $times_json       = ref($times)       ? $self->_encode_json_or_undef($times)       : $times;
        my $child_times_json = ref($child_times) ? $self->_encode_json_or_undef($child_times) : $child_times;
        my $plan_json        = ref($report_typed{plan}) ? $self->_encode_json_or_undef($report_typed{plan}) : $report_typed{plan};
        my $halt_json        = ref($report_typed{halt}) ? $self->_encode_json_or_undef($report_typed{halt}) : $report_typed{halt};

        my $spec_extras_json  = %spec_extras  ? $self->_encode_json_or_undef(\%spec_extras)  : undef;
        my $state_extras_json = %state_extras ? $self->_encode_json_or_undef(\%state_extras) : undef;

        my %set;
        $set{queued_at}       = $self->_normalize_timestamp($spec_typed{queued_at})   if defined $spec_typed{queued_at};
        $set{started_at}      = $self->_normalize_timestamp($spec_typed{started_at})  if defined $spec_typed{started_at};
        $set{ended_at}        = $self->_normalize_timestamp($report_typed{ended_at})  if defined $report_typed{ended_at};
        $set{exit}            = $report_typed{exit}                        if defined $report_typed{exit};
        $set{exit_decoded}    = $self->_encode_json_or_undef($report_typed{exit_decoded})
            if defined $report_typed{exit_decoded};
        $set{pass}            = $report_typed{pass} ? 1 : 0                if exists  $report_typed{pass};
        $set{pass_count}      = $report_typed{pass_count}                  if defined $report_typed{pass_count};
        $set{fail_count}      = $report_typed{fail_count}                  if defined $report_typed{fail_count};
        $set{assertion_count} = $report_typed{assertion_count}             if defined $report_typed{assertion_count};
        $set{plan}            = $plan_json                                 if defined $plan_json;
        $set{halt}            = $halt_json                                 if defined $halt_json;
        $set{times}           = $times_json                                if defined $times_json;
        $set{child_times}     = $child_times_json                          if defined $child_times_json;
        $set{child_wall}      = $child_wall                                if defined $child_wall;
        $set{spec_extras}     = $spec_extras_json                          if defined $spec_extras_json;
        $set{state_extras}    = $state_extras_json                         if defined $state_extras_json;
        $set{status}          = (ref($report) eq 'HASH' && defined $report->{ended_at}) ? 'completed' : 'incomplete';

        $self->_update_row('job_tries', \%set, {job_try_id => $jtid});

        # Track the highest-ord try's headlines for the parent jobs row.
        if (!defined $latest_try_ord || $try_ord > $latest_try_ord) {
            $latest_try_ord = $try_ord;
            $latest_pass    = $set{pass};
            $latest_status  = $set{status};
            $latest_spec    = $spec;
        }

        # Subtests: explode the per-try report's subtests array into
        # rows. Idempotent across re-seal: the table is empty for a
        # fresh DB, so straight INSERTs are fine. If a future caller
        # re-runs insert() into an existing DB we'd want to clear the
        # subtests for this job_try_id first; not in scope for the
        # current single-pass writer.
        if ($report && ref($report->{subtests}) eq 'ARRAY') {
            my $sti = 0;
            my $sth = $dbh->prepare(q{
                INSERT INTO subtests (job_try_id, name, pass, count_pass, count_fail, ord)
                VALUES (?, ?, ?, ?, ?, ?)
            });
            for my $st (@{$report->{subtests}}) {
                next unless ref($st) eq 'HASH';
                my $name = $st->{name} // '';
                next unless length $name;
                $sth->execute(
                    $jtid, $name,
                    $st->{pass} ? 1 : 0,
                    $st->{count_pass},
                    $st->{count_fail},
                    $sti++,
                );
            }
        }
    }

    return unless defined $job_db_id;

    # Resolve test_file_id from spec's 'relative' key, if available.
    my $test_file_id;
    if (ref($latest_spec) eq 'HASH' && defined $latest_spec->{relative}) {
        my $project_id = $self->{+PROJECT_ID};
        if (defined $project_id) {
            $test_file_id = $self->_resolve_or_create_test_file(
                $project_id, $latest_spec->{relative},
            );
        }
    }

    my %job_set;
    $job_set{test_file_id} = $test_file_id    if defined $test_file_id;
    $job_set{pass}         = $latest_pass     if defined $latest_pass;
    $job_set{status}       = $latest_status   if defined $latest_status;
    $job_set{retry_count}  = scalar @tries;

    $self->_update_row('jobs', \%job_set, {job_id => $job_db_id});

    # Populate job_specs row from the latest-try spec. One row per job
    # (UNIQUE on job_id), written only if we have a spec to populate
    # from and the row does not already exist.
    $self->_populate_job_spec($job_db_id, $test_file_id, $latest_spec)
        if ref($latest_spec) eq 'HASH';

    return;
}

# Build and INSERT one job_specs row. Promoted keys go to typed columns;
# everything else (that is not structurally consumed) lands in extras.
sub _populate_job_spec {
    my ($self, $job_id, $test_file_id, $spec) = @_;
    return unless ref($spec) eq 'HASH';

    my $dbh = $self->dbh;

    # Check for existing row (idempotent).
    my ($existing) = $dbh->selectrow_array(
        q{SELECT job_spec_id FROM job_specs WHERE job_id = ?},
        undef, $job_id,
    );
    return if defined $existing;

    # Split spec keys: promoted -> typed columns; remainder -> extras.
    my %promoted;
    my %extras;
    for my $k (sort keys %$spec) {
        if ($_JOB_SPECS_CONSUMED{$k}) {
            $promoted{$k} = $spec->{$k};
        }
        else {
            $extras{$k} = $spec->{$k};
        }
    }

    # JSON-encode array/hash promoted values (features, switches).
    for my $k (qw/features switches/) {
        next unless exists $promoted{$k} && ref($promoted{$k});
        $promoted{$k} = $self->_encode_json_or_undef($promoted{$k});
    }
    my $extras_json = %extras ? $self->_encode_json_or_undef(\%extras) : undef;

    my $sth = $dbh->prepare(q{
        INSERT INTO job_specs
            (job_id, test_file_id,
             absolute, category, duration, stage,
             features, switches,
             retry, retry_isolated, smoke, isolation, non_perl, is_binary,
             event_timeout, post_exit_timeout, min_slots, max_slots,
             ch_dir, extras)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute(
        $job_id,
        $test_file_id,
        $promoted{absolute},
        $promoted{category},
        $promoted{duration},
        $promoted{stage},
        $promoted{features},
        $promoted{switches},
        $promoted{retry},
        $promoted{retry_isolated} ? 1 : (defined $promoted{retry_isolated} ? 0 : undef),
        $promoted{smoke}          ? 1 : (defined $promoted{smoke}          ? 0 : undef),
        $promoted{isolation}      ? 1 : (defined $promoted{isolation}      ? 0 : undef),
        $promoted{non_perl}       ? 1 : (defined $promoted{non_perl}       ? 0 : undef),
        $promoted{is_binary}      ? 1 : (defined $promoted{is_binary}      ? 0 : undef),
        $promoted{event_timeout},
        $promoted{post_exit_timeout},
        $promoted{min_slots},
        $promoted{max_slots},
        $promoted{ch_dir},
        $extras_json,
    );
    return;
}

sub _update_row {
    my ($self, $table, $set, $where) = @_;
    return unless $set && %$set;

    my @cols = sort keys %$set;
    my @wcols = sort keys %$where;

    # Quote reserved keywords (e.g. "exit").
    my $q = sub {
        my $c = shift;
        return $c eq 'exit' ? '"exit"' : $c;
    };

    my $sql = "UPDATE $table SET "
            . join(', ', map { $q->($_) . ' = ?' } @cols)
            . ' WHERE '
            . join(' AND ', map { $q->($_) . ' = ?' } @wcols);

    my $sth = $self->dbh->prepare($sql);
    my $idx = 1;
    for my $c (@cols) {
        my %attrs;
        my $type = $self->_param_type_for_col($table, $c);
        $attrs{TYPE} = $type if defined $type;
        $sth->bind_param($idx++, $set->{$c}, %attrs ? \%attrs : ());
    }
    for my $c (@wcols) {
        my %attrs;
        my $type = $self->_param_type_for_col($table, $c);
        $attrs{TYPE} = $type if defined $type;
        $sth->bind_param($idx++, $where->{$c}, %attrs ? \%attrs : ());
    }
    $sth->execute;
    return;
}

# Per-flavor column-name -> DBI bind type hint. Default: undef
# (driver guesses). MySQL/MariaDB override to bind BINARY(16) UUID
# columns as SQL_BINARY.
sub _param_type_for_col { undef }

# {{{ Reconstruction (spec.jsonl / report.jsonl from typed columns)
#
# Reverse of _populate_run_row / _populate_service_lifetimes /
# _populate_job_rows: rebuild the spec.jsonl / report.jsonl record
# arrays from typed columns + decoded *_extras. Used by the artifact
# read path for spec / report on run / service / job_try scopes --
# the only path, since spec/report rows are never persisted as
# artifacts. Aggregated keys (`subtests`, `jobs`) are rebuilt via
# JOIN; data preservation is the goal, not byte-exact round-trip.

# Layer typed-col pairs over a decoded extras hash. `$typed_pairs` is
# an arrayref of [$key => $value, ...]; values that are undef are
# skipped (preserves "key not present in original" vs "key was null").
# Typed cols win on collision (the population code excludes them from
# extras during writes, but layered-over-extras is still safer).
sub _merge_extras_and_typed {
    my ($self, $extras_json, $typed_pairs) = @_;
    my %record;
    my $decoded = $self->_maybe_decode_json($extras_json);
    if (ref($decoded) eq 'HASH') {
        %record = %$decoded;
    }
    for (my $i = 0; $i + 1 < scalar @$typed_pairs; $i += 2) {
        my ($k, $v) = @{$typed_pairs}[$i, $i + 1];
        next unless defined $v;
        $record{$k} = $v;
    }
    return \%record;
}

sub _reconstruct_spec_records {
    my ($self, $scope_kind, $scope_id) = @_;
    return undef if $scope_kind eq 'archive';
    return undef unless defined $scope_id;

    if    ($scope_kind eq 'run')     { return $self->_reconstruct_run_spec($scope_id) }
    elsif ($scope_kind eq 'service') { return $self->_reconstruct_service_specs($scope_id) }
    elsif ($scope_kind eq 'job_try') { return $self->_reconstruct_job_try_spec($scope_id) }
    return undef;
}

sub _reconstruct_report_records {
    my ($self, $scope_kind, $scope_id) = @_;
    return undef if $scope_kind eq 'archive';
    return undef unless defined $scope_id;

    if    ($scope_kind eq 'run')     { return $self->_reconstruct_run_report($scope_id) }
    elsif ($scope_kind eq 'service') { return $self->_reconstruct_service_reports($scope_id) }
    elsif ($scope_kind eq 'job_try') { return $self->_reconstruct_job_try_report($scope_id) }
    return undef;
}

# Reconstruct the meta.json hash for the active archive from typed
# columns + meta_extras. Returns a hashref ready to JSON-encode, or
# undef when the archive row is gone.
sub _reconstruct_meta_record {
    my ($self) = @_;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;

    my $user_col = $self->_quote_user_col;
    my @cols = $dbh->selectrow_array(
        qq{SELECT archive_uuid, sealed_at, host, $user_col, git_sha,
                  project, yath_version, meta_extras
             FROM archives WHERE archive_id = ?},
        undef, $aid,
    );
    return undef unless @cols;

    my ($uuid_db, $sealed_at, $host, $user, $git_sha,
        $project, $yath_version, $extras) = @cols;

    my %meta;
    if (defined $extras) {
        my $decoded = $self->_maybe_decode_json($extras);
        %meta = %$decoded if ref($decoded) eq 'HASH';
    }
    $meta{archive_uuid} = $self->_uuid_from_db($uuid_db);
    $meta{created_at}   = $self->_db_datetime_to_iso($sealed_at) if defined $sealed_at;
    $meta{host}         = $host         if defined $host;
    $meta{user}         = $user         if defined $user;
    $meta{git_sha}      = $git_sha      if defined $git_sha;
    $meta{project}      = $project      if defined $project;
    $meta{yath_version} = $yath_version if defined $yath_version;

    return \%meta;
}

sub _reconstruct_run_spec {
    my ($self, $run_id) = @_;
    my $dbh = $self->dbh;

    my $row = $dbh->selectrow_hashref(
        q{SELECT * FROM runs WHERE run_id = ?},
        undef, $run_id,
    );
    return [] unless $row;

    my $rec = $self->_merge_extras_and_typed(
        $row->{spec_extras},
        [
            run_uuid    => $self->_uuid_from_db($row->{run_uuid}),
            started_at  => $self->_db_datetime_to_iso($row->{started_at}),
            times       => $self->_maybe_decode_json($row->{times}),
            child_times => $self->_maybe_decode_json($row->{child_times}),
            child_wall  => $row->{child_wall},
        ],
    );

    delete $rec->{$_} for qw(jobs subtests services);
    return [$rec];
}

sub _reconstruct_run_report {
    my ($self, $run_id) = @_;
    my $dbh = $self->dbh;

    my $row = $dbh->selectrow_hashref(
        q{SELECT * FROM runs WHERE run_id = ?},
        undef, $run_id,
    );
    return [] unless $row;

    my $rec = $self->_merge_extras_and_typed(
        $row->{state_extras},
        [
            ended_at     => $self->_db_datetime_to_iso($row->{ended_at}),
            exit         => $row->{exit},
            exit_decoded => $self->_maybe_decode_json($row->{exit_decoded}),
            pass         => defined $row->{pass} ? ($row->{pass} ? 1 : 0) : undef,
            total_jobs   => $row->{total_jobs},
            passed_jobs  => $row->{passed_jobs},
            failed_jobs  => $row->{failed_jobs},
            aborted_jobs => $row->{aborted_jobs},
            times        => $self->_maybe_decode_json($row->{times}),
            child_times  => $self->_maybe_decode_json($row->{child_times}),
            child_wall   => $row->{child_wall},
        ],
    );

    # Rebuild jobs[] aggregate via JOIN. The original run-level report
    # producer emitted a per-job summary array; we reconstruct it as
    # [{job_ord, status, pass, retry_count, tries => [...]}]. Byte-level
    # round-trip is not the goal (AI_DOCS/2026-05-07-schema-redesign.md
    # §D2): preservation of data is.
    my $jobs = $dbh->selectall_arrayref(q{
        SELECT job_id, job_ord, status, pass, retry_count
          FROM jobs
         WHERE run_id = ?
         ORDER BY job_ord
    }, { Slice => {} }, $run_id);
    if ($jobs && @$jobs) {
        my @out;
        for my $j (@$jobs) {
            my $tries = $dbh->selectall_arrayref(q{
                SELECT try_ord, status, pass, exit_decoded, ended_at,
                       pass_count, fail_count, assertion_count
                  FROM job_tries
                 WHERE job_id = ?
                 ORDER BY try_ord
            }, { Slice => {} }, $j->{job_id});
            my @tries_out;
            for my $t (@$tries) {
                push @tries_out => {
                    try_ord         => $t->{try_ord},
                    (defined $t->{status}          ? (status          => $t->{status})                : ()),
                    (defined $t->{pass}            ? (pass            => $t->{pass} ? 1 : 0)          : ()),
                    (defined $t->{ended_at}        ? (ended_at        => $self->_db_datetime_to_iso($t->{ended_at})) : ()),
                    (defined $t->{pass_count}      ? (pass_count      => $t->{pass_count})            : ()),
                    (defined $t->{fail_count}      ? (fail_count      => $t->{fail_count})            : ()),
                    (defined $t->{assertion_count} ? (assertion_count => $t->{assertion_count})       : ()),
                    (defined $t->{exit_decoded}
                        ? (exit_decoded => $self->_maybe_decode_json($t->{exit_decoded})) : ()),
                };
            }
            push @out => {
                job_ord => $j->{job_ord},
                (defined $j->{status}      ? (status      => $j->{status})           : ()),
                (defined $j->{pass}        ? (pass        => $j->{pass} ? 1 : 0)     : ()),
                (defined $j->{retry_count} ? (retry_count => $j->{retry_count})      : ()),
                tries => \@tries_out,
            };
        }
        $rec->{jobs} = \@out;
    }

    delete $rec->{subtests};
    delete $rec->{services};
    return [$rec];
}

sub _reconstruct_service_specs {
    my ($self, $service_id) = @_;
    my $dbh = $self->dbh;

    my $svc = $dbh->selectrow_hashref(
        q{SELECT role FROM services WHERE service_id = ?},
        undef, $service_id,
    );

    my $rows = $dbh->selectall_arrayref(q{
        SELECT lifetime_ord, type, id, service_name, stage_name,
               started_at, times, child_times, child_wall, spec_extras
          FROM service_lifetimes
         WHERE service_id = ?
         ORDER BY lifetime_ord
    }, { Slice => {} }, $service_id);

    return [] unless $rows && @$rows;

    my @out;
    # Round-trip count: emit one record per service_lifetimes row even
    # when fields are mostly null (AI_DOCS/2026-05-07-schema-redesign.md
    # §D2 explicitly accepts that byte-level round-trip count of spec
    # rows is not preserved -- only data is).
    for my $row (@$rows) {
        my $rec = $self->_merge_extras_and_typed(
            $row->{spec_extras},
            [
                type         => $row->{type},
                id           => $row->{id},
                service_name => $row->{service_name},
                stage_name   => $row->{stage_name},
                started_at   => $self->_db_datetime_to_iso($row->{started_at}),
                times        => $self->_maybe_decode_json($row->{times}),
                child_times  => $self->_maybe_decode_json($row->{child_times}),
                child_wall   => $row->{child_wall},
                # role lives on the parent services row; promote to every
                # reconstructed spec record (population kept it on the
                # FIRST spec row that supplied it, but we don't preserve
                # which row -- AI_DOCS/2026-05-07-schema-redesign.md §D2
                # byte-level round-trip is not required).
                (defined $svc && defined $svc->{role}
                    ? (role => $svc->{role}) : ()),
            ],
        );
        push @out => $rec;
    }
    return \@out;
}

sub _reconstruct_service_reports {
    my ($self, $service_id) = @_;
    my $dbh = $self->dbh;

    my $rows = $dbh->selectall_arrayref(q{
        SELECT lifetime_ord, ended_at, "exit", exit_decoded,
               times, child_times, child_wall, state_extras
          FROM service_lifetimes
         WHERE service_id = ?
         ORDER BY lifetime_ord
    }, { Slice => {} }, $service_id);

    return [] unless $rows && @$rows;

    my @out;
    for my $row (@$rows) {
        my $rec = $self->_merge_extras_and_typed(
            $row->{state_extras},
            [
                ended_at     => $self->_db_datetime_to_iso($row->{ended_at}),
                exit         => $row->{exit},
                exit_decoded => $self->_maybe_decode_json($row->{exit_decoded}),
                times        => $self->_maybe_decode_json($row->{times}),
                child_times  => $self->_maybe_decode_json($row->{child_times}),
                child_wall   => $row->{child_wall},
            ],
        );
        push @out => $rec;
    }
    return \@out;
}

sub _reconstruct_job_try_spec {
    my ($self, $job_try_id) = @_;
    my $dbh = $self->dbh;

    my $jt = $dbh->selectrow_hashref(
        q{SELECT * FROM job_tries WHERE job_try_id = ?},
        undef, $job_try_id,
    );
    return [] unless $jt;

    my $rec = $self->_merge_extras_and_typed(
        $jt->{spec_extras},
        [
            queued_at   => $self->_db_datetime_to_iso($jt->{queued_at}),
            started_at  => $self->_db_datetime_to_iso($jt->{started_at}),
            times       => $self->_maybe_decode_json($jt->{times}),
            child_times => $self->_maybe_decode_json($jt->{child_times}),
            child_wall  => $jt->{child_wall},
        ],
    );

    # Merge in job_specs typed cols + decoded extras + test_files.relative.
    my $js = $dbh->selectrow_hashref(q{
        SELECT js.*, tf.relative AS relative
          FROM job_specs js
          JOIN test_files tf ON tf.test_file_id = js.test_file_id
         WHERE js.job_id = ?
    }, undef, $jt->{job_id});

    if ($js) {
        # Decoded job_specs.extras first; typed columns overwrite.
        my $extras = $self->_maybe_decode_json($js->{extras});
        if (ref($extras) eq 'HASH') {
            for my $k (keys %$extras) {
                next if exists $rec->{$k};   # job_tries.spec_extras wins
                $rec->{$k} = $extras->{$k};
            }
        }

        # Promoted typed columns (only when defined).
        $rec->{relative} = $js->{relative} if defined $js->{relative};
        for my $k (qw(absolute category duration stage retry
                      event_timeout post_exit_timeout min_slots max_slots ch_dir))
        {
            $rec->{$k} = $js->{$k} if defined $js->{$k};
        }
        # Boolean-ish promoted ints: keep as 0/1 when defined.
        for my $k (qw(retry_isolated smoke isolation non_perl is_binary)) {
            $rec->{$k} = $js->{$k} ? 1 : 0 if defined $js->{$k};
        }
        # JSON columns.
        for my $k (qw(features switches)) {
            my $decoded = $self->_maybe_decode_json($js->{$k});
            $rec->{$k} = $decoded if defined $decoded;
        }
    }

    delete $rec->{subtests};
    return [$rec];
}

sub _reconstruct_job_try_report {
    my ($self, $job_try_id) = @_;
    my $dbh = $self->dbh;

    my $jt = $dbh->selectrow_hashref(
        q{SELECT * FROM job_tries WHERE job_try_id = ?},
        undef, $job_try_id,
    );
    return [] unless $jt;

    my $rec = $self->_merge_extras_and_typed(
        $jt->{state_extras},
        [
            ended_at        => $self->_db_datetime_to_iso($jt->{ended_at}),
            exit            => $jt->{exit},
            exit_decoded    => $self->_maybe_decode_json($jt->{exit_decoded}),
            pass            => defined $jt->{pass} ? ($jt->{pass} ? 1 : 0) : undef,
            pass_count      => $jt->{pass_count},
            fail_count      => $jt->{fail_count},
            assertion_count => $jt->{assertion_count},
            plan            => $self->_maybe_decode_json($jt->{plan}),
            halt            => $self->_maybe_decode_json($jt->{halt}),
            times           => $self->_maybe_decode_json($jt->{times}),
            child_times     => $self->_maybe_decode_json($jt->{child_times}),
            child_wall      => $jt->{child_wall},
        ],
    );

    # Rebuild subtests[] via JOIN.
    my $subtests = $dbh->selectall_arrayref(q{
        SELECT name, pass, count_pass, count_fail
          FROM subtests
         WHERE job_try_id = ?
         ORDER BY ord
    }, { Slice => {} }, $job_try_id);

    if ($subtests && @$subtests) {
        my @out;
        for my $s (@$subtests) {
            push @out => {
                name => $s->{name},
                pass => $s->{pass} ? 1 : 0,
                (defined $s->{count_pass} ? (count_pass => $s->{count_pass}) : ()),
                (defined $s->{count_fail} ? (count_fail => $s->{count_fail}) : ()),
            };
        }
        $rec->{subtests} = \@out;
    }

    return [$rec];
}

# }}}

sub _normalize_run_filters {
    my ($self, $opts) = @_;
    my $runs         = $opts->{runs};
    my $exclude_runs = $opts->{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;
    return ($runs, $exclude_runs);
}

sub _dir_non_empty {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return 0;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        closedir($dh);
        return 1;
    }
    closedir($dh);
    return 0;
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Internal - Raw-SQL backend for yath DB archives.

=head1 DESCRIPTION

C<App::Yath2::DB::Internal> is the abstract base for the four
flavor-specific raw-SQL backends:
L<App::Yath2::DB::Internal::Sqlite>,
C<App::Yath2::DB::Internal::Postgres>,
C<App::Yath2::DB::Internal::MariaDB>, and
C<App::Yath2::DB::Internal::MySQL>.

It consumes L<App::Yath2::Role::DB::Backend>; bootstrap helpers
(C<bootstrap_schema>, C<schema_file>, C<preprocess_schema_sql>,
C<_is_bootstrapped>) come from the role.

It implements the full reader API (services / runs / jobs / tries
listing, depth-first event iterator with path-aware identifier
injection, artifacts handle factory) using SQL against the schema
under F<share/schema/>.

Subclasses provide the small number of flavor-specific bits:

=over 4

=item schema_flavor()

Returns the short flavor name (C<'sqlite'>, C<'postgres'>, C<'mariadb'>,
C<'mysql'>).

=item schema_file()

Returns the absolute path to the per-flavor C<.sql> file used to
bootstrap an empty database.

=item _connect_dbh()

Constructs a fresh L<DBI> handle from the C<dsn> / C<user> / C<pass>
attributes and applies any flavor-specific connect-time pragmas.

=item _payload_compressed_default()

Returns true when client-side zstd compression is the default
(SQLite, MySQL); false when the server provides equivalent
transparent compression (Postgres, MariaDB).

=item _uuid_to_db / _uuid_from_db

UUID bind / fetch hooks. Defaults are no-ops (TEXT(36) flavors).

=item _json_encode / _json_decode

Codec for JSON columns. Defaults to L<Test2::Harness2::Util::JSON>.

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
