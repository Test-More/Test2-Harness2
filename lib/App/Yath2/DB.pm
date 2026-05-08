package App::Yath2::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Spec ();
use Time::HiRes ();

use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

# App::Yath2::DB is the backend-agnostic data access + transformation
# layer for yath log archives stored in a database. Two distinct entry
# points:
#
#   - App::Yath2::DB->open(...)   -- legacy factory; returns a backend
#                                     instance directly (a doer of
#                                     App::Yath2::Role::DB::Backend).
#                                     Existing callers depend on this
#                                     shape; preserved verbatim.
#
#   - App::Yath2::DB->new(...)    -- new shape introduced by the DB
#                                     rebuild. Returns an
#                                     App::Yath2::DB instance wrapping
#                                     a backend. Owns codecs,
#                                     reconstruction, and the
#                                     archive-shaped read API.
#
# See AI_DOCS/2026-05-08-yath-db-rebuild.md for the rebuild plan.

# ---------------------------------------------------------------------------
# Legacy factory: ->open
# ---------------------------------------------------------------------------

# open(file => $path, backend => 'internal'|'sql'|'dbic')
# open(dsn  => $dsn,  user => $u, pass => $p, attrs => \%a, backend => ...)
# open(dbh  => $dbh,  backend => ...)
#
# Returns a Role::DB::Backend doer with no uuid set (multi-archive
# capable). Use ->scoped($uuid) or wrap in App::Yath2::Log::DB to
# scope to one archive.
sub open {
    my ($class, %args) = @_;

    croak "App::Yath2::DB->open requires one of: file, dsn, dbh"
        unless defined $args{file}
        || defined $args{dsn}
        || defined $args{dbh};

    my $backend = delete $args{backend} // 'internal';
    my $impl = _backend_class($backend, %args);

    my $file = mod2file($impl);
    my $ok = eval { require $file; 1 };
    my $err = $@;
    croak "could not load backend '$impl': $err" unless $ok;

    # The DBIC backend accepts an explicit flavor override (caller
    # knows whether they're talking to MariaDB or MySQL through the
    # DBD::MariaDB driver). The Internal backends already had `flavor`
    # consumed by _backend_class; rename for DBIC. The new SQL backend
    # consumes `flavor` directly via its HashBase slot.
    if ($backend eq 'dbic' && defined $args{flavor}) {
        $args{flavor_override} = delete $args{flavor};
    }
    elsif ($backend ne 'sql') {
        delete $args{flavor};
    }
    # backend=sql: leave $args{flavor} alone; SQL.pm's HashBase
    # accepts +flavor and the override propagates correctly.

    return $impl->new(%args);
}

sub _backend_class {
    my ($name, %args) = @_;
    return 'App::Yath2::DB::DBIC' if $name eq 'dbic';
    return 'App::Yath2::DB::SQL'  if $name eq 'sql';
    if ($name eq 'internal') {
        return internal_class_for_flavor(_detect_flavor(%args));
    }
    croak "unknown backend '$name' (expected 'sql', 'dbic', or 'internal')";
}

# Public helper: map a flavor token ('sqlite', 'postgres', 'mariadb',
# 'mysql') to its concrete App::Yath2::DB::Internal::* class name.
# Shared with App::Yath2::DB::DBIC, which lazily wraps an Internal
# helper bound to the same dbh.
my %INTERNAL_FLAVOR_CLASS = (
    sqlite   => 'App::Yath2::DB::Internal::Sqlite',
    postgres => 'App::Yath2::DB::Internal::Postgres',
    mariadb  => 'App::Yath2::DB::Internal::MariaDB',
    mysql    => 'App::Yath2::DB::Internal::MySQL',
);

sub internal_class_for_flavor {
    my $flavor = shift;
    croak "flavor is required" unless defined $flavor && length $flavor;
    my $class = $INTERNAL_FLAVOR_CLASS{$flavor}
        or croak "unknown internal flavor '$flavor'";
    return $class;
}

# Detect flavor from open() inputs. Caller may also pass flavor =>
# explicitly to override.
sub _detect_flavor {
    my %args = @_;
    return $args{flavor} if defined $args{flavor};

    if (defined $args{dsn}) {
        my $dsn = $args{dsn};
        return 'postgres' if $dsn =~ /^dbi:Pg:/i;
        return 'mariadb'  if $dsn =~ /^dbi:MariaDB:/i;
        return 'mysql'    if $dsn =~ /^dbi:mysql:/i;
        return 'sqlite'   if $dsn =~ /^dbi:SQLite:/i;
        croak "could not detect flavor from DSN: $dsn";
    }

    if (defined $args{dbh}) {
        my $name = $args{dbh}->{Driver}{Name} // '';
        return 'sqlite'   if $name eq 'SQLite';
        return 'postgres' if $name eq 'Pg';
        return 'mariadb'  if $name eq 'MariaDB';
        return 'mysql'    if $name eq 'mysql';
        croak "could not detect flavor from dbh (DBI driver: $name)";
    }

    if (defined $args{file}) {
        # File path: only sqlite is supported as a single-file flavor.
        # New file (does not exist) is assumed sqlite (we'll create it).
        my $f = $args{file};
        return 'sqlite' unless -e $f;

        require App::Yath2::Log;
        my $kind = App::Yath2::Log->detect_file_kind($f);
        return 'sqlite' if $kind eq 'sqlite';
        croak "file '$f' is not a SQLite database";
    }

    croak "no flavor source available (no file/dbh/dsn)";
}

# ---------------------------------------------------------------------------
# New shape: ->new returns an App::Yath2::DB instance wrapping a backend
# ---------------------------------------------------------------------------

# Slot keys for the wrapper instance. Kept as bare constants (not
# Object::HashBase) because some callers may want to mix this class
# with their own role consumption later; minimal accessor surface keeps
# the implementation transparent.
sub _BACKEND        () { 'backend' }
sub _UUID           () { 'uuid' }
sub _AID            () { 'archive_id' }
sub _LEGACY_BACKEND () { '_legacy_backend' }
sub _SEALED            () { 'sealed' }
sub _INSERT_SOURCE     () { '_insert_source' }
sub _PROJECT_ID        () { '_project_id' }
sub _LAST_INSERT_UUID  () { '_last_insert_uuid' }

sub new {
    my ($class, %args) = @_;

    # Phase 4 internal-use shortcut: caller passes a fully-built backend
    # instance (a doer of App::Yath2::Role::DB::Backend) and we wrap it
    # without re-running backend selection. Used by App::Yath2::Log::DB
    # to wrap legacy backend instances handed in via the deprecated
    # `backend => $obj` constructor shape during the gap phase. Plan to
    # remove this hatch once the rebuild reaches Phase 9 and Log::DB
    # only sees `db => ...` callers.
    if (my $bi = delete $args{backend_instance}) {
        croak "backend_instance must consume App::Yath2::Role::DB::Backend"
            unless eval { $bi->DOES('App::Yath2::Role::DB::Backend') };

        # Two flavors of $bi during the gap phase:
        #   - A new-style backend (App::Yath2::DB::SQL / DBIC) that
        #     implements the Phase 2 primitives (archive_rows, etc).
        #     Store directly; both new + legacy methods route through it.
        #   - A legacy App::Yath2::DB::Internal::* instance, which has the
        #     full legacy surface but NONE of the new primitives. We wrap
        #     it by spinning up a fresh App::Yath2::DB::SQL bound to the
        #     same dbh for the new read paths and stashing the Internal
        #     instance pre-cached as our legacy backend so write/walker
        #     traffic still goes to the same connection.
        my $self;
        if ($bi->isa('App::Yath2::DB::Internal')) {
            require App::Yath2::DB::SQL;
            my $sql = App::Yath2::DB::SQL->new(
                dbh    => $bi->dbh,
                flavor => $bi->flavor,
            );
            $self = bless {
                _BACKEND()        => $sql,
                _LEGACY_BACKEND() => $bi,
            }, $class;
        }
        else {
            $self = bless {
                _BACKEND() => $bi,
            }, $class;
        }

        if (defined (my $u = $args{uuid})) {
            $self->{_UUID()} = _canon_uuid($u);
        }
        elsif ($bi->can('uuid') && defined (my $bu = $bi->uuid)) {
            $self->{_UUID()} = _canon_uuid($bu);
        }
        return $self;
    }

    my $backend_name = delete $args{backend};
    # 'internal' is a deprecated alias for 'sql' during Phase 3; do
    # not warn yet (warning lands in a later phase to keep test output
    # quiet during the rebuild).
    if (defined $backend_name && $backend_name eq 'internal') {
        $backend_name = 'sql';
    }
    $backend_name //= 'sql';

    my $backend;
    if (my $schema = delete $args{schema}) {
        # Caller-supplied DBIC schema implies the dbic backend.
        require App::Yath2::DB::DBIC;
        $backend_name = 'dbic';
        $backend = App::Yath2::DB::DBIC->new(schema => $schema, %args);
    }
    elsif ($backend_name eq 'dbic') {
        require App::Yath2::DB::DBIC;
        if (defined $args{flavor}) {
            $args{flavor_override} = delete $args{flavor};
        }
        $backend = App::Yath2::DB::DBIC->new(%args);
    }
    elsif ($backend_name eq 'sql') {
        require App::Yath2::DB::SQL;
        $backend = App::Yath2::DB::SQL->new(%args);
    }
    else {
        croak "unknown backend '$backend_name' (expected 'sql' or 'dbic')";
    }

    my $self = bless {
        _BACKEND() => $backend,
    }, $class;

    if (defined (my $u = $args{uuid})) {
        $self->{_UUID()} = _canon_uuid($u);
    }

    return $self;
}

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------

sub backend { $_[0]->{_BACKEND()} }
sub dbh     { $_[0]->{_BACKEND()}->dbh }
sub flavor  { $_[0]->{_BACKEND()}->flavor }

# Phase 4 gap-shim: methods that App::Yath2::DB does NOT yet implement
# natively (event/events/end_of_events/reset, artifacts factory,
# extract/archive/insert, _artifact_save) still need to work for
# App::Yath2::Log::DB callers during the rebuild's middle phases. We
# route them through a legacy backend that has the full surface:
#
#   - DBIC backend: already implements every legacy method (the
#     BEGIN-block forwarder + native methods + Role::DB::Backend's
#     `artifacts` default), so it is its own legacy backend.
#
#   - SQL backend: stub-only on legacy methods (croaks NYI), so we
#     spin up an `App::Yath2::DB::Internal::*` sibling sharing the
#     same dbh and serve legacy traffic out of it. The sibling reads
#     and writes the same underlying tables; transactional state stays
#     consistent because there's only one DBI connection.
#
# Lazy-built and cached. Phases 6-7 reroute the remaining methods to
# native App::Yath2::DB code, after which this helper can be deleted.
sub _legacy_backend {
    my $self = shift;
    return $self->{_LEGACY_BACKEND()} if defined $self->{_LEGACY_BACKEND()};

    my $backend = $self->{_BACKEND()};
    if ($backend->isa('App::Yath2::DB::DBIC')) {
        return $self->{_LEGACY_BACKEND()} = $backend;
    }

    my $flavor = $self->flavor;
    my $class = internal_class_for_flavor($flavor);
    my $file = mod2file($class);
    my $ok = eval { require $file; 1 };
    my $err = $@;
    croak "could not load legacy backend '$class': $err" unless $ok;

    my %extra;
    # Forward the file path on sqlite so the Internal helper's seal=>1
    # path resolution still works through the gap.
    if ($flavor eq 'sqlite' && $backend->can('file')) {
        my $f = $backend->file;
        $extra{file} = $f if defined $f;
    }
    $extra{uuid} = $self->{_UUID()} if defined $self->{_UUID()};

    my $obj = $class->new(dbh => $backend->dbh, flavor => $flavor, %extra);
    return $self->{_LEGACY_BACKEND()} = $obj;
}

# DB-backed logs have no on-disk path per artifact. Mirrors the
# Role::DB::Backend default, exposed here so App::Yath2::Log::DB can
# call $self->{db}->absolute_path(...) without hitting AUTOLOAD or
# missing-method errors.
sub absolute_path {
    my ($self, $rel) = @_;
    croak "absolute_path is unavailable for the DB backend; "
        . "extract first or read via the Log API ($rel)";
}

# Phase 4 gap-shim: get a legacy backend scoped to $uuid with
# archive_id already resolved. Bypasses the legacy backend's own
# uuid lookup, which fails across the canonical-hex / DB-native
# case mismatch (App::Yath2::DB returns canonical lowercase hex
# from archives(); legacy SQLite stores uppercase via Internal's
# identity codec). Resolving the archive_id at the new layer (which
# does case-insensitive matching) and seeding it on the legacy
# instance sidesteps the mismatch entirely.
sub legacy_scoped_for_uuid {
    my ($self, $uuid) = @_;
    croak "uuid required" unless defined $uuid;
    my $aid = $self->_resolve_archive_id($uuid);
    my $legacy = $self->_legacy_backend;

    # Two paths:
    #   - DBIC backend: it implements services/runs/jobs natively but
    #     forwards the heavier methods (event/insert/extract/...) to a
    #     lazy Internal helper, AND has no _artifact_save of its own
    #     (Artifact handles bind to _internal_for_artifact). Skip the
    #     DBIC layer entirely for the gap shim and return the Internal
    #     helper directly -- it carries the full surface we need.
    #
    #   - Internal-style backend: scoped() returns a fresh Internal
    #     instance bound to the same dbh; pre-seed archive_id so its
    #     _resolve_archive short-circuits on the canonical-hex uuid.
    if ($legacy->isa('App::Yath2::DB::DBIC')) {
        my $inner = $legacy->_internal->scoped($uuid);
        $inner->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $aid;
        $inner->{App::Yath2::DB::Internal::UUID()} //= _canon_uuid($uuid);
        return $inner;
    }

    my $scoped = $legacy->scoped($uuid);
    if ($scoped->isa('App::Yath2::DB::Internal')) {
        $scoped->{App::Yath2::DB::Internal::ARCHIVE_ID()} = $aid;
        $scoped->{App::Yath2::DB::Internal::UUID()} //= _canon_uuid($uuid);
    }
    return $scoped;
}

sub uuid {
    my $self = shift;
    return $self->{_UUID()} if defined $self->{_UUID()};
    return undef;
}

# Resolved DB id for the scoped uuid. Lazy.
sub archive_id {
    my $self = shift;
    return $self->{_AID()} if defined $self->{_AID()};
    return undef unless defined $self->{_UUID()};
    $self->{_AID()} = $self->_resolve_archive_id($self->{_UUID()});
    return $self->{_AID()};
}

# Return a NEW App::Yath2::DB scoped to $uuid, sharing the same backend.
sub scoped {
    my ($self, $uuid) = @_;
    croak "scoped() requires a uuid" unless defined $uuid;
    my $clone = bless {
        _BACKEND() => $self->{_BACKEND()},
        _UUID()    => _canon_uuid($uuid),
    }, ref($self);
    return $clone;
}

# ---------------------------------------------------------------------------
# Codec helpers (single source of truth)
# ---------------------------------------------------------------------------

# Normalize a UUID to canonical 36-char lowercase hex. Tolerates input
# that is already canonical, uppercase, or lacking dashes (32-char
# hex). Returns undef when the input cannot be massaged into shape.
sub _canon_uuid {
    my $u = shift;
    return undef unless defined $u && length $u;
    $u = lc $u;
    if ($u =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/) {
        return $u;
    }
    if ($u =~ /^[0-9a-f]{32}\z/) {
        return join '-',
            substr($u,  0, 8),
            substr($u,  8, 4),
            substr($u, 12, 4),
            substr($u, 16, 4),
            substr($u, 20);
    }
    return undef;
}

# Multi-frame zstd concat decompress (events files, etc.).
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

sub _compress_blob {
    my ($self, $bytes) = @_;
    require Test2::Harness2::Util::Zstd;
    return Test2::Harness2::Util::Zstd::compress_blob($bytes);
}

sub _decode_json {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val;
    return undef unless length $val;
    my $decoded;
    my $ok = eval { $decoded = decode_json($val); 1 };
    return $ok ? $decoded : undef;
}

sub _encode_json {
    my ($self, $val) = @_;
    return encode_json($val);
}

# Reverse of _to_datetime: column value -> ISO-8601 for meta.json
# reconstruction. Tolerates pre-formatted ISO strings and drivers that
# hand back DateTime objects already.
# Alias kept for tests that previously called the Internal-named
# helper. Both names format a column value (string / DateTime) as
# ISO-8601 with optional millisecond precision.
sub _db_datetime_to_iso { goto &_format_iso8601 }

sub _format_iso8601 {
    my ($self, $val) = @_;
    return undef unless defined $val;
    if (ref($val)) {
        return $val->iso8601 . 'Z' if eval { $val->isa('DateTime') };
        return undef;
    }
    if ($val =~ /\A\d{4}-\d{2}-\d{2}/) {
        require DateTime::Format::ISO8601;
        my $tweaked = $val;
        $tweaked =~ s/ /T/;
        my $dt = eval { DateTime::Format::ISO8601->parse_datetime($tweaked) };
        if ($dt) {
            my $ns = $dt->nanosecond;
            return $dt->strftime('%Y-%m-%dT%H:%M:%SZ') if $ns == 0;
            return $dt->strftime('%Y-%m-%dT%H:%M:%S.%3NZ');
        }
    }
    return $val;
}

# ---------------------------------------------------------------------------
# Archive layer
# ---------------------------------------------------------------------------

sub archives {
    my $self = shift;
    return map { $_->{archive_uuid} } @{ $self->{_BACKEND()}->archive_rows };
}

sub archive_count {
    my $self = shift;
    return $self->{_BACKEND()}->archive_count;
}

sub has_archive {
    my ($self, $uuid) = @_;
    return 0 unless defined $uuid;
    my $canon = _canon_uuid($uuid);
    return 0 unless defined $canon;
    for my $u ($self->archives) {
        return 1 if lc($u) eq $canon;
    }
    return 0;
}

# Resolve canonical hex uuid -> archive_id. Croaks if absent. Also
# enforces the archive_version floor (refuses archives older than
# App::Yath2::Log->last_breaking_version).
sub _resolve_archive_id {
    my ($self, $uuid) = @_;
    croak "uuid required" unless defined $uuid;
    my $canon = _canon_uuid($uuid)
        or croak "bad uuid: $uuid";

    my $row = $self->{_BACKEND()}->archive_for_uuid($canon)
        or croak "no archive '$canon' in this DB";
    $self->_check_archive_version($canon, $row->{archive_version});
    return $row->{archive_id};
}

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

# Reconstruct meta.json record for a given archive uuid. Output shape
# matches App::Yath2::Log::Internal::_reconstruct_meta_record exactly:
# typed columns from the archives row + decoded meta_extras blob.
sub meta {
    my ($self, $uuid) = @_;
    croak "uuid required" unless defined $uuid;
    my $canon = _canon_uuid($uuid)
        or croak "bad uuid: $uuid";

    my $row = $self->{_BACKEND()}->archive_for_uuid($canon)
        or croak "no archive '$canon' in this DB";
    $self->_check_archive_version($canon, $row->{archive_version});

    my %meta;
    if (ref($row->{meta_extras}) eq 'HASH') {
        %meta = %{ $row->{meta_extras} };
    }
    $meta{archive_uuid} = $row->{archive_uuid};
    $meta{created_at}   = $self->_format_iso8601($row->{sealed_at})
        if defined $row->{sealed_at};
    $meta{host}         = $row->{host}         if defined $row->{host};
    $meta{user}         = $row->{user}         if defined $row->{user};
    $meta{git_sha}      = $row->{git_sha}      if defined $row->{git_sha};
    $meta{project}      = $row->{project}      if defined $row->{project};
    $meta{yath_version} = $row->{yath_version} if defined $row->{yath_version};

    return \%meta;
}

# ---------------------------------------------------------------------------
# Run / service / job / try layer
# ---------------------------------------------------------------------------

# Each public listing method takes a $uuid first; resolve to archive_id
# via the backend, then emit the simple ord/name list.

sub runs {
    my ($self, $uuid) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    return map { $_->{run_ord} } @{ $self->{_BACKEND()}->run_rows($aid) };
}

sub services {
    my ($self, $uuid, $run_ord) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    if (defined $run_ord) {
        croak "no such run: $run_ord" unless $self->{_BACKEND()}->run_exists($aid, $run_ord);
        my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
        my @rows = sort { $a->{name} cmp $b->{name} }
            @{ $self->{_BACKEND()}->service_rows($aid, run_id => $rid) };
        return map { $_->{name} } @rows;
    }
    my @rows = sort { $a->{name} cmp $b->{name} }
        @{ $self->{_BACKEND()}->service_rows($aid, run_id => undef) };
    return map { $_->{name} } @rows;
}

sub jobs {
    my ($self, $uuid, $run_ord) = @_;
    croak "run_id is required" unless defined $run_ord;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    croak "no such run: $run_ord" unless $self->{_BACKEND()}->run_exists($aid, $run_ord);
    my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
    return map { $_->{job_ord} } @{ $self->{_BACKEND()}->job_rows($aid, $rid) };
}

sub tries {
    my ($self, $uuid, $run_ord, $job_ord) = @_;
    croak "run_id is required" unless defined $run_ord;
    croak "job_id is required" unless defined $job_ord;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    croak "no such run: $run_ord" unless $self->{_BACKEND()}->run_exists($aid, $run_ord);
    my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
    croak "no such job: $run_ord/$job_ord"
        unless $self->{_BACKEND()}->job_exists($aid, $rid, $job_ord);
    my $jid = $self->{_BACKEND()}->job_id_for_ord($aid, $rid, $job_ord);
    return map { $_->{try_ord} } @{ $self->{_BACKEND()}->try_rows($jid) };
}

sub last_try {
    my ($self, $uuid, $run_ord, $job_ord) = @_;
    my @t = $self->tries($uuid, $run_ord, $job_ord);
    return undef unless @t;
    return $t[-1];
}

# Existence checks. Tolerant of bad input (non-numeric, missing) --
# return 0 rather than croak.

sub has_run {
    my ($self, $uuid, $run_ord) = @_;
    return 0 unless defined $run_ord && length $run_ord;
    return 0 unless $run_ord =~ /^\d+\z/;
    my $aid = eval { $self->_resolve_archive_id($uuid // $self->{_UUID()}) };
    return 0 unless defined $aid;
    return $self->{_BACKEND()}->run_exists($aid, $run_ord);
}

sub has_job {
    my ($self, $uuid, $run_ord, $job_ord) = @_;
    return 0 unless $self->has_run($uuid, $run_ord);
    return 0 unless defined $job_ord && length $job_ord;
    return 0 unless $job_ord =~ /^\d+\z/;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
    return $self->{_BACKEND()}->job_exists($aid, $rid, $job_ord);
}

sub has_try {
    my ($self, $uuid, $run_ord, $job_ord, $try_ord) = @_;
    return 0 unless $self->has_job($uuid, $run_ord, $job_ord);
    return 0 unless defined $try_ord && length $try_ord;
    return 0 unless $try_ord =~ /^\d+\z/;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
    my $jid = $self->{_BACKEND()}->job_id_for_ord($aid, $rid, $job_ord);
    return $self->{_BACKEND()}->try_exists($jid, $try_ord);
}

sub has_service {
    my ($self, $uuid, $name, $run_ord) = @_;
    return 0 unless defined $name && length $name;
    my $aid = eval { $self->_resolve_archive_id($uuid // $self->{_UUID()}) };
    return 0 unless defined $aid;
    if (defined $run_ord) {
        return 0 unless $self->{_BACKEND()}->run_exists($aid, $run_ord);
        my $rid = $self->{_BACKEND()}->run_id_for_ord($aid, $run_ord);
        return $self->{_BACKEND()}->service_exists($aid, $name, $rid);
    }
    return $self->{_BACKEND()}->service_exists($aid, $name, undef);
}

# ---------------------------------------------------------------------------
# list_files
# ---------------------------------------------------------------------------

sub list_files {
    my ($self, $uuid) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});
    my $rows = $self->{_BACKEND()}->artifact_rows_for_archive($aid);
    my @paths;
    for my $row (@$rows) {
        my $base = $self->{_BACKEND()}->_base_for_artifact_row($row);
        next unless defined $base;
        my $stem = $self->{_BACKEND()}->_stem_for_artifact_row($row);
        next unless defined $stem;
        my $rel = length $base ? "$base/$stem" : $stem;
        $rel .= '.zst' if $row->{compressed};
        push @paths, $rel;
    }
    return @paths;
}

# ---------------------------------------------------------------------------
# Path -> scope translation
# ---------------------------------------------------------------------------

# Parse a relative path into a scope tuple. Returns a hashref with
# keys: scope_kind, scope_id (DB id), scope_ords {run_ord/job_ord/
# try_ord/service}, artifact_kind, format, name, is_zst. Returns undef
# if the path is not parseable as a known artifact in this archive.
#
# The 'create' flag enables INSERT-side autovivification. Phase 3 only
# supports read mode; create mode is stubbed pending Phase 6.
sub _parse_artifact_path {
    my ($self, $aid, $rel, %opts) = @_;
    my $create = $opts{create} ? 1 : 0;

    return undef unless defined $rel && length $rel;

    my @parts = split m{/}, $rel;
    return undef unless @parts;

    my ($scope_kind, $scope_id);
    my ($run_ord, $job_ord, $try_ord, $service_name);
    my $b = $self->{_BACKEND()};

    if ($parts[0] eq 'services') {
        return undef unless @parts >= 2;
        $service_name = $parts[1];
        $scope_kind = 'service';
        if ($create) {
            $scope_id = $b->ensure_service_row($aid, $service_name, undef);
        }
        else {
            $scope_id = $b->service_id_for_name($aid, $service_name, undef);
        }
        return undef unless defined $scope_id;
        splice(@parts, 0, 2);
    }
    elsif ($parts[0] eq 'runs') {
        return undef unless @parts >= 2;
        $run_ord = $parts[1];
        return undef unless $run_ord =~ /^\d+\z/;

        if (@parts == 2) {
            $scope_kind = 'run';
            if ($create) {
                $scope_id = $self->_ensure_run_id($aid, $run_ord);
            }
            else {
                $scope_id = $b->run_exists($aid, $run_ord)
                    ? $b->run_id_for_ord($aid, $run_ord)
                    : undef;
            }
            return undef unless defined $scope_id;
            splice(@parts, 0, 2);
        }
        elsif ($parts[2] eq 'services') {
            return undef unless @parts >= 4;
            $service_name = $parts[3];
            $scope_kind = 'service';
            if ($create) {
                my $rid = $self->_ensure_run_id($aid, $run_ord);
                $scope_id = $b->ensure_service_row($aid, $service_name, $rid);
            }
            else {
                $scope_id = $b->service_id_for_name($aid, $service_name, $run_ord);
            }
            return undef unless defined $scope_id;
            splice(@parts, 0, 4);
        }
        elsif ($parts[2] eq 'jobs') {
            return undef unless @parts >= 5;
            $job_ord = $parts[3];
            $try_ord = $parts[4];
            return undef unless $job_ord =~ /^\d+\z/ && $try_ord =~ /^\d+\z/;
            $scope_kind = 'job_try';
            if ($create) {
                $scope_id = $self->_ensure_job_try_id($aid, $run_ord, $job_ord, $try_ord);
            }
            else {
                return undef unless $b->run_exists($aid, $run_ord);
                my $rid = $b->run_id_for_ord($aid, $run_ord);
                return undef unless $b->job_exists($aid, $rid, $job_ord);
                my $jid = $b->job_id_for_ord($aid, $rid, $job_ord);
                return undef unless $b->try_exists($jid, $try_ord);
                $scope_id = $b->try_id_for_ord($jid, $try_ord);
            }
            return undef unless defined $scope_id;
            splice(@parts, 0, 5);
        }
        else {
            $scope_kind = 'run';
            if ($create) {
                $scope_id = $self->_ensure_run_id($aid, $run_ord);
            }
            else {
                $scope_id = $b->run_exists($aid, $run_ord)
                    ? $b->run_id_for_ord($aid, $run_ord)
                    : undef;
            }
            return undef unless defined $scope_id;
            splice(@parts, 0, 2);
        }
    }
    else {
        # Archive-root artifact (e.g. meta.json).
        $scope_kind = 'archive';
        $scope_id = $aid;
    }

    return undef unless @parts;

    my $remaining = join('/', @parts);

    if ($remaining =~ m{^(events|spec|state|report)\.jsonl(\.zst)?\z}) {
        return {
            scope_kind    => $scope_kind,
            scope_id      => $scope_id,
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

    if ($remaining =~ m{^attachments/(.+?)(\.zst)?\z}) {
        return {
            scope_kind    => $scope_kind,
            scope_id      => $scope_id,
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

    my ($base_name, $is_zst) = $remaining =~ /\.zst\z/
        ? (do { (my $b2 = $remaining) =~ s/\.zst\z//; $b2 }, 1)
        : ($remaining, 0);

    return {
        scope_kind    => $scope_kind,
        scope_id      => $scope_id,
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

sub _format_for_name {
    my $name = shift;
    return 'json'  if $name =~ /\.json\z/i;
    return 'jsonl' if $name =~ /\.jsonl\z/i;
    return 'csv'   if $name =~ /\.csv\z/i;
    return 'html'  if $name =~ /\.html?\z/i;
    return 'txt'   if $name =~ /\.txt\z/i;
    return 'bin';
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

sub _entity_exists_for_scope {
    my ($self, $aid, $scope_kind, $scope_id) = @_;
    return 0 unless defined $scope_id;
    my $b = $self->{_BACKEND()};
    if ($scope_kind eq 'run') {
        # scope_id is a run_id; check it belongs to this archive.
        for my $r (@{ $b->run_rows($aid) }) {
            return 1 if $r->{run_id} == $scope_id;
        }
        return 0;
    }
    if ($scope_kind eq 'service') {
        for my $s (@{ $b->service_rows($aid) }) {
            return 1 if $s->{service_id} == $scope_id;
        }
        return 0;
    }
    if ($scope_kind eq 'job_try') {
        # Walk archive's run/job tree for a try with this id. Cheaper
        # to query try_rows over candidate jobs.
        for my $r (@{ $b->run_rows($aid) }) {
            for my $j (@{ $b->job_rows($aid, $r->{run_id}) }) {
                for my $t (@{ $b->try_rows($j->{job_id}) }) {
                    return 1 if $t->{job_try_id} == $scope_id;
                }
            }
        }
        return 0;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# Artifact read API
# ---------------------------------------------------------------------------

# Returns ($exists, $is_zst). Mirrors the contract of
# App::Yath2::DB::Internal::_artifact_exists exactly: both .zst and
# plain forms are reported separately, attachments and arbitrary files
# only "exist" at the form they were stored, and standard streams that
# are reconstructed (spec.jsonl / report.jsonl on run/service/job_try
# scopes) always advertise both forms.
sub artifact_exists {
    my ($self, $uuid, $rel) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});

    if (defined $rel && ($rel eq 'meta.json' || $rel eq 'meta.json.zst')) {
        return (1, $rel =~ /\.zst\z/ ? 1 : 0);
    }

    my $info = $self->_parse_artifact_path($aid, $rel) or return (0, 0);

    if ($self->_is_reconstruct_target($info)) {
        return (0, 0)
            unless $self->_entity_exists_for_scope(
                $aid, $info->{scope_kind}, $info->{scope_id});
        return (1, $info->{is_zst} ? 1 : 0);
    }

    my $row = $self->{_BACKEND()}->artifact_row_for_scope(
        $aid, $info->{scope_kind}, $info->{scope_id},
        $info->{artifact_kind}, $info->{name},
    );
    return (0, 0) unless $row;

    my $stored_compressed = $row->{compressed} ? 1 : 0;
    my $probed_zst        = $info->{is_zst}    ? 1 : 0;
    return (0, 0) if $stored_compressed != $probed_zst;
    return (1, $probed_zst);
}

sub artifact_read {
    my ($self, $uuid, $rel) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});

    if (defined $rel && ($rel eq 'meta.json' || $rel eq 'meta.json.zst')) {
        my $rec = $self->meta($uuid // $self->{_UUID()});
        require App::Yath2::Log;
        my $bytes = App::Yath2::Log->encode_archive_meta($rec);
        return $bytes unless $rel =~ /\.zst\z/;
        return $self->_compress_blob($bytes);
    }

    my $info = $self->_parse_artifact_path($aid, $rel)
        or croak "cannot parse artifact path: $rel";

    if ($self->_is_reconstruct_target($info)) {
        return $self->_artifact_read_reconstructed($aid, $info);
    }

    my $row = $self->{_BACKEND()}->artifact_row_for_scope(
        $aid, $info->{scope_kind}, $info->{scope_id},
        $info->{artifact_kind}, $info->{name},
    );
    croak "no such artifact in DB: $rel" unless $row;

    my $payload = $row->{payload};
    my $stored_compressed = $row->{compressed} ? 1 : 0;

    if ($info->{is_zst}) {
        return $payload if $stored_compressed;
        return $self->_compress_blob($payload);
    }

    return $payload unless $stored_compressed;
    return $self->_decompress_jsonl_bytes($payload);
}

# Reconstruct the bytes for a spec.jsonl / report.jsonl on a
# run/service/job_try scope. Returns plaintext bytes unless
# $info->{is_zst} is set (then zstd-compressed bytes).
sub _artifact_read_reconstructed {
    my ($self, $aid, $info) = @_;
    my $records = $info->{artifact_kind} eq 'spec'
        ? $self->_reconstruct_spec_records($aid, $info->{scope_kind}, $info->{scope_id})
        : $self->_reconstruct_report_records($aid, $info->{scope_kind}, $info->{scope_id});
    $records ||= [];

    my $plain = '';
    for my $rec (@$records) {
        $plain .= encode_json($rec) . "\n";
    }

    return $plain unless $info->{is_zst};
    return $self->_compress_blob($plain);
}

# Records-backed iterator: returns an arrayref of decoded JSON objects,
# or undef when the artifact does not exist or the path is not
# parseable. Matches the contract Internal exposes through
# _artifact_iter_records.
sub artifact_iter_records {
    my ($self, $uuid, $base, $stem) = @_;
    return undef unless defined $stem && length $stem;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});

    my $rel = defined $base && length $base ? "$base/$stem" : $stem;

    my $info = $self->_parse_artifact_path($aid, $rel) or return undef;

    if ($self->_is_reconstruct_target($info)) {
        return undef
            unless $self->_entity_exists_for_scope(
                $aid, $info->{scope_kind}, $info->{scope_id});
        my $records = $info->{artifact_kind} eq 'spec'
            ? $self->_reconstruct_spec_records($aid, $info->{scope_kind}, $info->{scope_id})
            : $self->_reconstruct_report_records($aid, $info->{scope_kind}, $info->{scope_id});
        return $records || [];
    }

    my $row = $self->{_BACKEND()}->artifact_row_for_scope(
        $aid, $info->{scope_kind}, $info->{scope_id},
        $info->{artifact_kind}, $info->{name},
    );
    return undef unless $row;

    my $payload = $row->{payload};
    my $stored_compressed = $row->{compressed} ? 1 : 0;

    my $plain = $stored_compressed
        ? $self->_decompress_jsonl_bytes($payload)
        : $payload;

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
        push @records, $decoded;
    }
    return \@records;
}

# List basenames (not paths) of files at $reldir. Matches Internal's
# _artifact_list_dir contract.
sub artifact_list_dir {
    my ($self, $uuid, $rel) = @_;
    my $aid = $self->_resolve_archive_id($uuid // $self->{_UUID()});

    my $info;
    my $kind;
    if ($rel =~ m{/attachments\z} || $rel eq 'attachments') {
        (my $scope_rel = $rel) =~ s{/?attachments\z}{};
        $info = $self->_parse_artifact_path($aid, "$scope_rel/_dummy_") if length $scope_rel;
        $info //= $self->_parse_artifact_path($aid, '_dummy_');
        $kind = 'attachment';
    }
    else {
        $info = $self->_parse_artifact_path($aid, "$rel/_dummy_");
        $kind = 'arbitrary';
    }
    return () unless $info;

    my $rows = $self->{_BACKEND()}->artifact_rows_for_archive($aid);

    my @names;
    for my $row (@$rows) {
        next unless ($row->{artifact_kind} // '') eq $kind;
        next unless defined $row->{name};

        # Match the scope.
        if ($info->{scope_kind} eq 'archive') {
            next if defined $row->{run_id};
            next if defined $row->{service_id};
            next if defined $row->{job_try_id};
        }
        elsif ($info->{scope_kind} eq 'run') {
            next unless defined $row->{run_id} && $row->{run_id} == $info->{scope_id};
            next if defined $row->{service_id};
            next if defined $row->{job_try_id};
        }
        elsif ($info->{scope_kind} eq 'service') {
            next unless defined $row->{service_id} && $row->{service_id} == $info->{scope_id};
            next if defined $row->{run_id};
            next if defined $row->{job_try_id};
        }
        elsif ($info->{scope_kind} eq 'job_try') {
            next unless defined $row->{job_try_id} && $row->{job_try_id} == $info->{scope_id};
            next if defined $row->{run_id};
            next if defined $row->{service_id};
        }
        push @names, $row->{name};
    }
    return sort @names;
}

sub artifact_open_fh {
    my ($self, $uuid, $rel) = @_;
    my $bytes = $self->artifact_read($uuid, $rel);
    CORE::open(my $sfh, '<', \$bytes) or croak "open scalar fh: $!";
    return $sfh;
}

sub artifact_save {
    my $self = shift;
    return $self->save_artifact(@_);
}

# ---------------------------------------------------------------------------
# Write paths (Phase 6)
# ---------------------------------------------------------------------------

# save_artifact($uuid, %opts)
#
# Persist a single artifact at $rel under the archive identified by
# $uuid. opts:
#   rel                 -- relative path (e.g. 'runs/1/events.jsonl')
#   bytes               -- payload bytes (plaintext; we compress here
#                          when compress => 1 and the flavor wants it)
#   compress            -- 1 = client-side zstd if the flavor uses it
#   force_no_overwrite  -- 1 = croak if a row already exists at this scope
#
# Returns the canonical identifier string used by the legacy callers:
#   "db:archive=$aid:artifact=$artifact_id"
sub save_artifact {
    my ($self, $uuid, %opts) = @_;
    croak "uuid required" unless defined $uuid;

    my $rel = $opts{rel};
    croak "rel required" unless defined $rel && length $rel;

    my $aid = $self->_resolve_archive_id($uuid);

    my $info = $self->_parse_artifact_path($aid, $rel, create => 1)
        or croak "cannot parse artifact path: $rel";

    my $b = $self->{_BACKEND()};
    my $existing = $b->artifact_row_for_scope(
        $aid, $info->{scope_kind}, $info->{scope_id},
        $info->{artifact_kind}, $info->{name},
    );

    if ($opts{force_no_overwrite} && $existing) {
        croak "artifact already exists: $rel";
    }

    my $client_compress = $self->_payload_compressed_default;
    my ($stored_compressed, $stored_bytes);
    if ($opts{compress} && $client_compress) {
        $stored_compressed = 1;
        $stored_bytes      = $self->_compress_blob($opts{bytes});
    }
    else {
        $stored_compressed = 0;
        $stored_bytes      = $opts{bytes};
    }

    my $now = $self->_now_iso;

    if ($existing) {
        $b->artifact_update($existing->{artifact_id}, {
            compressed => $stored_compressed,
            payload    => $stored_bytes,
            format     => $info->{format},
            created_at => $now,
        });
        return "db:archive=$aid:artifact=$existing->{artifact_id}";
    }

    my $fk = $b->_scope_fk_values($info->{scope_kind}, $info->{scope_id});
    my $id = $b->artifact_create({
        archive_id    => $aid,
        run_id        => $fk->{run_id},
        service_id    => $fk->{service_id},
        job_try_id    => $fk->{job_try_id},
        artifact_kind => $info->{artifact_kind},
        format        => $info->{format},
        name          => $info->{name},
        compressed    => $stored_compressed,
        payload       => $stored_bytes,
        created_at    => $now,
        sealed        => 1,
    });
    return "db:archive=$aid:artifact=$id";
}

# extract($uuid, $dir, %opts) -> App::Yath2::Log::Directory
#
# Materialize the archive into a directory tree matching the on-disk
# Directory layout. Honors compressed => 1 to keep payloads zstd-shaped
# on disk; default 0 emits plaintext.
sub extract {
    my ($self, $uuid, $dir, %opts) = @_;
    croak "uuid required" unless defined $uuid;
    croak "destination is required" unless defined $dir && length $dir;
    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $aid = $self->_resolve_archive_id($uuid);
    my $canon = _canon_uuid($uuid);

    my $compressed = exists $opts{compressed} ? $opts{compressed} : 0;
    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    make_path($dir);

    require App::Yath2::Log;
    require App::Yath2::Log::Directory;

    my $b = $self->{_BACKEND()};
    my $rows = $b->artifact_rows_for_archive($aid, with_payload => 1);

    for my $row (@$rows) {
        my $rord;
        if    (defined $row->{run_id})                                  { $rord = $row->{run_ord}; }
        elsif (defined $row->{service_id} && defined $row->{s_run_ord}) { $rord = $row->{s_run_ord}; }
        elsif (defined $row->{job_try_id})                              { $rord = $row->{j_run_ord}; }

        if (defined $rord) {
            if (defined $runs) {
                next unless grep { $_ eq $rord } @$runs;
            }
            elsif (defined $exclude_runs) {
                next if grep { $_ eq $rord } @$exclude_runs;
            }
        }

        my $base = $b->_base_for_artifact_row($row);
        next unless defined $base;
        my $stem = $b->_stem_for_artifact_row($row);
        next unless defined $stem;

        my $rel = length $base ? "$base/$stem" : $stem;

        my $payload = $row->{payload};
        my $stored_compressed = $row->{compressed} ? 1 : 0;

        my ($out_rel, $out_bytes);
        if ($compressed) {
            $out_rel   = "$rel.zst";
            $out_bytes = $stored_compressed ? $payload : $self->_compress_blob($payload);
        }
        else {
            $out_rel   = $rel;
            $out_bytes = $stored_compressed
                ? $self->_decompress_jsonl_bytes($payload)
                : $payload;
        }

        $self->_write_extract_file($dir, $out_rel, $out_bytes);
    }

    # meta.json reconstructed from archives row + meta_extras.
    {
        my $rec = $self->meta($canon);
        if ($rec) {
            my $bytes = App::Yath2::Log->encode_archive_meta($rec);
            my $out_rel = $compressed ? 'meta.json.zst' : 'meta.json';
            my $out_bytes = $compressed ? $self->_compress_blob($bytes) : $bytes;
            $self->_write_extract_file($dir, $out_rel, $out_bytes);
        }
    }

    return App::Yath2::Log::Directory->new(path => $dir, live => 0);
}

sub _write_extract_file {
    my ($self, $dir, $rel, $bytes) = @_;
    my $abs = File::Spec->catfile($dir, $rel);
    my $par = dirname($abs);
    make_path($par) unless -d $par;
    CORE::open(my $fh, '>', $abs) or croak "open '$abs': $!";
    binmode $fh;
    print $fh $bytes;
    close $fh or croak "close '$abs': $!";
    return;
}

# archive_to($uuid, $out_path, %opts)
#
# Materialize a sealed archive at $out_path. Formats:
#   tar / tar.zidx -- extract to temp dir, repack via Log::Directory.
#   sqlite         -- create a fresh App::Yath2::DB sqlite file and
#                     insert(self_log_for_uuid, seal => 1).
#   postgres / mariadb / mysql -- not supported here (need dsn target).
sub archive_to {
    my ($self, $uuid, $out, %opts) = @_;
    croak "uuid required"             unless defined $uuid;
    croak "output path is required"   unless defined $out && length $out;

    my $format = $opts{format} // 'tar';
    $format = 'tar.zidx' if $format eq 'tar';

    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    if ($format eq 'tar.zidx') {
        require File::Temp;
        my $tmp = File::Temp::tempdir(CLEANUP => 1, TEMPLATE => 'yath-db-XXXXXX', TMPDIR => 1);
        require File::Path;
        File::Path::remove_tree($tmp, {keep_root => 1});
        $self->extract($uuid, $tmp,
            compressed   => 0,
            runs         => $runs,
            exclude_runs => $exclude_runs,
        );
        require App::Yath2::Log::Directory;
        my $dir = App::Yath2::Log::Directory->new(path => $tmp, live => 0);
        return $dir->archive($out);
    }

    if ($format eq 'sqlite') {
        # Wrap source in a Log::DB so insert() can read it like any
        # other Log backend.
        require App::Yath2::Log::DB;
        my $source_log = App::Yath2::Log::DB->new(db => $self, uuid => $uuid);

        my $dest = (ref $self)->new(file => $out, backend => 'sql');
        $dest->insert(
            $source_log,
            runs         => $runs,
            exclude_runs => $exclude_runs,
            seal         => 1,
        );
        return $dest;
    }

    if ($format eq 'postgres' || $format eq 'mariadb' || $format eq 'mysql') {
        croak "archive_to($format) requires a dsn => / dbh => target; not yet implemented";
    }

    croak "unknown archive format: $format";
}

# insert($source, %opts) -> $archive_uuid
#
# Insert another Log object's contents into this DB as a new archive
# row. The source can be any Log backend (Directory / TarZIdx / DB).
sub insert {
    my ($self, $source, %opts) = @_;
    croak "source log is required" unless defined $source;

    croak "Log is sealed; further inserts not permitted"
        if $self->{_SEALED()};

    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    # compress=1 (default): preserve the source's natural shape
    # (.zst stays compressed, plain stays plain).
    # compress=0: force every payload to plaintext.
    my $compress = exists $opts{compress} ? ($opts{compress} ? 1 : 0) : 1;

    my $dbh = $self->dbh;

    require App::Yath2::Log;

    # Resolve carried meta or mint fresh. archive_uuid carries over so
    # re-importing the same source raises a clean error rather than
    # silently duplicating it.
    my $meta = $self->_resolve_insert_meta($source, \%opts);

    # Pre-flight uniqueness: collide cleanly before opening a tx.
    $self->_check_archive_uuid_unique($meta->{archive_uuid});

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
        my $rb_ok = eval { $dbh->rollback; 1 };
        my $rb_err = $@;
        warn "rollback failed after insert error: $rb_err" unless $rb_ok;
        delete $self->{_INSERT_SOURCE()};
        delete $self->{_PROJECT_ID()};
        die $err;
    }

    if ($opts{seal}) {
        $self->_seal_with_footer($meta);
    }

    # Mirror Internal's return shape: $aid is the integer archive_id row
    # in the destination DB. Callers wanting the archive uuid should
    # read it from $self->{_LAST_INSERT_UUID} or the source meta.
    $self->{_LAST_INSERT_UUID()} = $meta->{archive_uuid};
    return $aid;
}

# Body of insert(), wrapped by the transactional shell above.
sub _insert_body {
    my ($self, $source, $meta, $compress, $runs, $exclude_runs) = @_;
    my $b = $self->{_BACKEND()};

    # Find or create projects row.
    my $project_name = $meta->{project} // 'unknown';
    my $project_id   = $b->ensure_project_row($project_name);
    $self->{_PROJECT_ID()} = $project_id;

    # Make $source visible to _ensure_job_try_id so it can resolve
    # test_file_id from spec.jsonl when minting jobs rows (NOT NULL).
    $self->{_INSERT_SOURCE()} = $source;

    # Build archive row.
    my %meta_extras;
    my %promoted;
    {
        my %prom_keys = map { $_ => 1 } App::Yath2::Log->META_PROMOTED_KEYS;
        for my $k (keys %$meta) {
            if ($prom_keys{$k}) { $promoted{$k} = $meta->{$k}; }
            else                { $meta_extras{$k} = $meta->{$k}; }
        }
    }

    my $aid = $b->archive_create({
        archive_uuid    => $meta->{archive_uuid},
        archive_version => $App::Yath2::Log::VERSION,
        sealed_at       => $self->_format_db_datetime($meta->{created_at}),
        host            => $meta->{host},
        user            => $meta->{user},
        git_sha         => $meta->{git_sha},
        project         => $meta->{project},
        yath_version    => $meta->{yath_version},
        meta_extras     => %meta_extras ? \%meta_extras : undef,
    });

    # Walk source list_files; insert artifact rows.
    my @files;
    if ($source->can('list_files')) {
        @files = $source->list_files;
    }
    else {
        croak "source log does not support list_files";
    }

    # De-dup .zst vs plain probes for the same logical artifact.
    my %seen_logical;
    my @ordered;
    for my $rel (@files) {
        next if $rel eq 'LIVE';
        next if $rel eq 'meta.json' || $rel eq 'meta.json.zst';
        # spec/report/state.jsonl on run/service/job_try are reconstructed
        # from typed columns; never written as artifact rows.
        next if $rel =~ m{(?:^|/)(?:spec|report|state)\.jsonl(?:\.zst)?\z};
        (my $logical = $rel) =~ s/\.zst\z//;
        if ($rel =~ /\.zst\z/) {
            $seen_logical{$logical} = $rel;
        }
        else {
            $seen_logical{$logical} //= $rel;
        }
        push @ordered => $logical;
    }
    my %emitted;
    my @final = grep { !$emitted{$_}++ } @ordered;

    for my $logical (@final) {
        my $rel = $seen_logical{$logical};

        if ($rel =~ m{^runs/(\d+)/}) {
            my $rid = $1;
            if (defined $runs) {
                next unless grep { $_ eq $rid } @$runs;
            }
            elsif (defined $exclude_runs) {
                next if grep { $_ eq $rid } @$exclude_runs;
            }
        }

        my $info = $self->_parse_artifact_path($aid, $rel, create => 1);
        next unless $info;
        next unless defined $info->{artifact_kind};

        my ($exists, $src_is_zst) = $source->_artifact_exists($rel);
        next unless $exists;

        my $raw = $source->_artifact_read($rel);

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

        my $fk = $b->_scope_fk_values($info->{scope_kind}, $info->{scope_id});
        $b->artifact_create({
            archive_id    => $aid,
            run_id        => $fk->{run_id},
            service_id    => $fk->{service_id},
            job_try_id    => $fk->{job_try_id},
            artifact_kind => $info->{artifact_kind},
            format        => $info->{format},
            name          => $info->{name},
            compressed    => $stored_compressed,
            payload       => $stored_bytes,
            created_at    => $self->_now_iso,
            sealed        => 1,
        });
    }

    delete $self->{_INSERT_SOURCE()};

    # Populate summary rows from the source's spec.jsonl / report.jsonl
    # walks. Without these the DB is unusable for everything but raw
    # artifact retrieval.
    $self->_populate_summary_rows($source, $aid, $runs, $exclude_runs, $project_id);

    return $aid;
}

# ---------------------------------------------------------------------------
# Insert helpers
# ---------------------------------------------------------------------------

# Read source meta.json if present (carry-over) or mint fresh. Caller's
# explicit archive_uuid override (in opts) wins over both.
sub _resolve_insert_meta {
    my ($self, $source, $opts) = @_;
    my $meta;

    require App::Yath2::Log;

    my $root = eval { $source->artifacts };
    if ($root && eval { $root->exists(App::Yath2::Log->META_FILENAME) }) {
        my $bytes = eval { $root->get(App::Yath2::Log->META_FILENAME) };
        if (defined $bytes && length $bytes) {
            my $decoded = eval { decode_json($bytes) };
            $meta = $decoded if ref($decoded) eq 'HASH';
        }
    }
    unless ($meta) {
        # Live-dir source -- mint fresh.
        $meta = App::Yath2::Log->build_archive_meta(
            archive_uuid => $opts->{archive_uuid},
        );
    }

    if (defined $opts->{archive_uuid}) {
        $meta->{archive_uuid} = $opts->{archive_uuid};
    }

    $meta->{archive_uuid} //= gen_uuid();

    return $meta;
}

sub _check_archive_uuid_unique {
    my ($self, $uuid) = @_;
    return unless defined $uuid && length $uuid;
    croak "archive uuid '$uuid' already exists; not re-imported"
        if $self->has_archive($uuid);
    return;
}

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

# Backend-flavored "now" for created_at columns. Format mirrors what
# the backends parse on read; SQLite/Postgres accept ISO with T+Z;
# MySQL/MariaDB want "YYYY-MM-DD HH:MM:SS.fff" via DateTime::Format::MySQL.
sub _now_iso {
    my $self = shift;
    my $t = Time::HiRes::time();
    my @lt = gmtime(int $t);
    my $frac = $t - int $t;
    my $flavor = $self->flavor;
    if ($flavor eq 'mysql' || $flavor eq 'mariadb') {
        return sprintf('%04d-%02d-%02d %02d:%02d:%02d.%03d',
            $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
            int($frac * 1000));
    }
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
        int($frac * 1000));
}

# Convert an ISO-8601-ish (or epoch-numeric, or DateTime) value into
# the active flavor's accepted DATETIME shape. Pass-through for shapes
# we cannot parse so the DB error message points at the bad value.
sub _format_db_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;
    my $dt = $self->_to_datetime($val);
    return $val unless defined $dt;
    my $flavor = $self->flavor;
    if ($flavor eq 'mysql' || $flavor eq 'mariadb') {
        require DateTime::Format::MySQL;
        return DateTime::Format::MySQL->format_datetime($dt);
    }
    if ($flavor eq 'postgres') {
        require DateTime::Format::Pg;
        return DateTime::Format::Pg->format_datetime($dt);
    }
    # SQLite default: ISO with millisecond precision.
    my $ns = $dt->nanosecond;
    return $dt->iso8601 . 'Z' if $ns == 0;
    return $dt->strftime('%Y-%m-%dT%H:%M:%S.%3NZ');
}

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
        my $tweaked = $val;
        $tweaked =~ s/ /T/;
        return eval { DateTime::Format::ISO8601->parse_datetime($tweaked) };
    }
    return undef;
}

sub _normalize_db_datetime {
    my ($self, $val) = @_;
    return $self->_format_db_datetime($val);
}

# Whether the active flavor wants client-side zstd compression for
# artifact payloads. Postgres + MariaDB compress server-side (page
# compression / TOAST); SQLite + MySQL want client zstd.
sub _payload_compressed_default {
    my $self = shift;
    my $flavor = $self->flavor;
    return 0 if $flavor eq 'postgres' || $flavor eq 'mariadb';
    return 1;
}

# Resolve (or create) a runs row id. When the row already exists, we
# return its id without needing a project_id; only the create path
# requires one (via the data layer's _PROJECT_ID slot, set during
# insert). save_artifact on an existing run scope works without an
# active insert flow because the runs row is already there.
sub _ensure_run_id {
    my ($self, $aid, $run_ord) = @_;
    my $b = $self->{_BACKEND()};
    if ($b->run_exists($aid, $run_ord)) {
        return $b->run_id_for_ord($aid, $run_ord);
    }
    my $project_id = $self->{_PROJECT_ID()}
        // croak "project_id not set on App::Yath2::DB before _ensure_run_id (call insert() to set it)";
    return $b->ensure_run_row($aid, $run_ord, $project_id);
}

# Resolve (or create) a job_try row id, minting jobs + job_tries on
# the way. Resolves test_file_id by reading the source's spec.jsonl
# for the (run_ord, job_ord) pair.
sub _ensure_job_try_id {
    my ($self, $aid, $run_ord, $job_ord, $try_ord) = @_;
    my $b = $self->{_BACKEND()};
    my $rid = $self->_ensure_run_id($aid, $run_ord);

    # Existing jobs row?
    my $jid;
    if ($b->job_exists($aid, $rid, $job_ord)) {
        $jid = $b->job_id_for_ord($aid, $rid, $job_ord);
    }
    else {
        my $tfid = $self->_resolve_test_file_for_job($run_ord, $job_ord);
        croak "could not resolve test_file_id for job ($run_ord, $job_ord) -- "
            . "source must carry a spec.jsonl with a 'relative' key for every job"
            unless defined $tfid;
        $jid = $b->ensure_job_row($aid, $rid, $job_ord, $tfid);
    }

    return $b->ensure_job_try_row($jid, $try_ord);
}

# Walk the source's tries for (run_ord, job_ord), reading spec.jsonl
# from each until we find a 'relative' key. Resolves (or creates) the
# test_files row and returns test_file_id. Requires _INSERT_SOURCE
# and _PROJECT_ID to be set (done by insert()).
sub _resolve_test_file_for_job {
    my ($self, $run_ord, $job_ord) = @_;

    my $source = $self->{_INSERT_SOURCE()};
    return undef unless defined $source;

    my $project_id = $self->{_PROJECT_ID()};
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
        return $self->{_BACKEND()}->ensure_test_file_row($project_id, $relative);
    }

    return undef;
}

sub _read_first_jsonl_row {
    my ($self, $artifact, $stem) = @_;
    return undef unless $artifact;
    my $iter;
    if    ($stem eq 'spec.jsonl')   { $iter = eval { $artifact->spec_iter }   or return undef; }
    elsif ($stem eq 'report.jsonl') { $iter = eval { $artifact->report_iter } or return undef; }
    else                            { return undef; }
    my $row = eval { $iter->next };
    return ref($row) eq 'HASH' ? $row : undef;
}

sub _read_all_jsonl_rows {
    my ($self, $artifact, $stem) = @_;
    return [] unless $artifact;
    my $iter;
    if    ($stem eq 'spec.jsonl')   { $iter = eval { $artifact->spec_iter }   or return []; }
    elsif ($stem eq 'report.jsonl') { $iter = eval { $artifact->report_iter } or return []; }
    else                            { return []; }
    my @rows;
    while (1) {
        my $row = eval { $iter->next };
        last unless defined $row;
        push @rows => $row if ref($row) eq 'HASH';
    }
    return \@rows;
}

# ---------------------------------------------------------------------------
# Sealing (sqlite-only YATHFOOT trailer)
# ---------------------------------------------------------------------------

# Resolve the on-disk path backing this DB (sqlite-only). Returns undef
# for non-file backends so seal => 1 can refuse them cleanly.
sub _db_file_path {
    my $self = shift;
    my $b = $self->{_BACKEND()};
    if ($b->can('file')) {
        my $f = $b->file;
        return $f if defined $f;
    }
    if ($b->can('dsn')) {
        my $dsn = $b->dsn;
        return $1 if defined $dsn && $dsn =~ /dbname=([^;]+)/i;
        return $1 if defined $dsn && $dsn =~ /dbi:SQLite:([^;]+)\z/i;
    }
    return undef;
}

sub _seal_with_footer {
    my ($self, $meta) = @_;

    my $path = $self->_db_file_path
        or croak "seal => 1 is only supported for file-backed (sqlite) DB backends.";

    my $dbh = $self->dbh;

    my ($page_count) = $dbh->selectrow_array('PRAGMA page_count');
    my ($page_size)  = $dbh->selectrow_array('PRAGMA page_size');
    croak "_seal_with_footer: PRAGMA page_count returned undef" unless defined $page_count;
    croak "_seal_with_footer: PRAGMA page_size returned undef"  unless defined $page_size;

    eval { $dbh->do('PRAGMA wal_checkpoint(TRUNCATE)') };

    $dbh->disconnect;
    # Drop the cached dbh on the backend so a future $self->dbh would
    # reconnect cleanly. Both backends store the handle in {dbh} (SQL
    # via HashBase, DBIC via storage); for sealing we never expect the
    # caller to use the DB again, but keep state consistent anyway.
    delete $self->{_BACKEND()}{dbh};

    my $body_size = -s $path;
    croak "_seal_with_footer: cannot stat '$path': $!" unless defined $body_size;

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

    $self->{_SEALED()} = 1;
    return;
}

# ---------------------------------------------------------------------------
# Summary-row population (spec.jsonl / report.jsonl -> typed columns)
# ---------------------------------------------------------------------------

# Keys promoted from a run spec.jsonl row to typed runs columns.
# `times` / `child_times` / `child_wall` may appear in either spec or
# report; on collision the report value wins.
my @_RUNS_SPEC_PROMOTED   = qw(run_uuid started_at times child_times child_wall);
my @_RUNS_REPORT_PROMOTED = qw(
    ended_at exit exit_decoded pass
    total_jobs passed_jobs failed_jobs aborted_jobs
    times child_times child_wall
);
my @_RUNS_AGGREGATED = qw(jobs subtests services);

my @_JOB_TRIES_SPEC_PROMOTED   = qw(queued_at started_at times child_times child_wall);
my @_JOB_TRIES_REPORT_PROMOTED = qw(
    ended_at exit exit_decoded pass
    pass_count fail_count assertion_count
    plan halt
    times child_times child_wall
);
my @_JOB_TRIES_AGGREGATED = qw(subtests);

my @_SVC_SPEC_PROMOTED   = qw(type id service_name stage_name started_at times child_times child_wall);
my @_SVC_REPORT_PROMOTED = qw(ended_at exit exit_decoded times child_times child_wall);

my @_JOB_SPECS_PROMOTED = qw(
    absolute category duration stage features switches
    retry retry_isolated smoke isolation non_perl is_binary
    event_timeout post_exit_timeout min_slots max_slots ch_dir
);
my %_JOB_SPECS_CONSUMED = map { $_ => 1 } (@_JOB_SPECS_PROMOTED, qw(relative));

sub _populate_summary_rows {
    my ($self, $source, $aid, $runs_filter, $exclude_runs_filter, $project_id) = @_;

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

sub _populate_run_row {
    my ($self, $source, $aid, $run_ord, $project_id) = @_;
    my $b = $self->{_BACKEND()};
    my $dbh = $self->dbh;

    my $artifact = eval { $source->artifacts($run_ord) } or return;
    my $spec   = $self->_read_first_jsonl_row($artifact, 'spec.jsonl');
    my $report = $self->_read_first_jsonl_row($artifact, 'report.jsonl');

    my %spec_promoted   = map { $_ => 1 } @_RUNS_SPEC_PROMOTED;
    my %report_promoted = map { $_ => 1 } @_RUNS_REPORT_PROMOTED;
    my %aggregated      = map { $_ => 1 } @_RUNS_AGGREGATED;

    my (%spec_typed, %spec_extras);
    if (ref($spec) eq 'HASH') {
        for my $k (sort keys %$spec) {
            next if $aggregated{$k};
            if ($spec_promoted{$k}) { $spec_typed{$k} = $spec->{$k}; }
            else                    { $spec_extras{$k} = $spec->{$k}; }
        }
    }

    my (%report_typed, %state_extras);
    if (ref($report) eq 'HASH') {
        for my $k (sort keys %$report) {
            next if $aggregated{$k};
            if ($report_promoted{$k}) { $report_typed{$k} = $report->{$k}; }
            else                      { $state_extras{$k} = $report->{$k}; }
        }
    }

    my $times = exists $report_typed{times}       ? $report_typed{times}
              : exists $spec_typed{times}         ? $spec_typed{times}
              : undef;
    my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                    : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                    : undef;
    my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                   : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                   : undef;

    my $times_json       = ref($times)       ? $self->_encode_json($times)       : $times;
    my $child_times_json = ref($child_times) ? $self->_encode_json($child_times) : $child_times;

    my $spec_extras_json  = %spec_extras  ? $self->_encode_json(\%spec_extras)  : undef;
    my $state_extras_json = %state_extras ? $self->_encode_json(\%state_extras) : undef;

    my %set;
    $set{started_at}   = $self->_normalize_db_datetime($spec_typed{started_at}) if defined $spec_typed{started_at};
    $set{ended_at}     = $self->_normalize_db_datetime($report_typed{ended_at}) if defined $report_typed{ended_at};
    $set{exit}         = $report_typed{exit}                           if defined $report_typed{exit};
    $set{exit_decoded} = $self->_encode_json($report_typed{exit_decoded})
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
        # The runs.run_uuid column needs the per-flavor bind (BINARY(16)
        # for MySQL etc). Route through the backend's _uuid_to_db helper
        # if available. For DBIC we keep the canonical hex string and
        # let DBIC's column_info handle it.
        my $bcan_to_db = $b->can('_uuid_to_db') ? $b->_uuid_to_db($spec_typed{run_uuid})
                       : $spec_typed{run_uuid};
        $set{run_uuid} = $bcan_to_db;
    }

    $self->_update_row('runs', \%set, {archive_id => $aid, run_ord => $run_ord});
}

sub _populate_service_lifetimes {
    my ($self, $source, $aid, $name, $run_ord) = @_;
    my $b = $self->{_BACKEND()};

    my $artifact;
    if (defined $run_ord) {
        $artifact = eval { $source->artifacts($run_ord, $name) };
    }
    else {
        $artifact = eval { $source->artifacts($name) }
                 || eval { $source->artifacts({service => $name}) };
    }
    return unless $artifact;

    my $specs   = $self->_read_all_jsonl_rows($artifact, 'spec.jsonl');
    my $reports = $self->_read_all_jsonl_rows($artifact, 'report.jsonl');

    my $rid = defined $run_ord ? $self->_ensure_run_id($aid, $run_ord) : undef;
    my $sid = $b->ensure_service_row($aid, $name, $rid);

    # Promote `role` from the first spec row that carries one.
    for my $spec (@$specs) {
        next unless ref($spec) eq 'HASH';
        next unless defined $spec->{role};
        $self->_update_row('services', {role => $spec->{role}}, {service_id => $sid});
        last;
    }

    my $count = (scalar @$specs > scalar @$reports) ? scalar @$specs : scalar @$reports;
    return unless $count;

    my %spec_promoted   = map { $_ => 1 } @_SVC_SPEC_PROMOTED;
    my %report_promoted = map { $_ => 1 } @_SVC_REPORT_PROMOTED;

    for (my $i = 0; $i < $count; $i++) {
        my $spec   = $specs->[$i];
        my $report = $reports->[$i];

        my (%spec_typed, %spec_extras);
        if (ref($spec) eq 'HASH') {
            for my $k (sort keys %$spec) {
                if ($spec_promoted{$k}) { $spec_typed{$k} = $spec->{$k}; }
                else                    { $spec_extras{$k} = $spec->{$k}; }
            }
        }

        my (%report_typed, %state_extras);
        if (ref($report) eq 'HASH') {
            for my $k (sort keys %$report) {
                if ($report_promoted{$k}) { $report_typed{$k} = $report->{$k}; }
                else                      { $state_extras{$k} = $report->{$k}; }
            }
        }

        my $times = exists $report_typed{times}       ? $report_typed{times}
                  : exists $spec_typed{times}         ? $spec_typed{times}
                  : undef;
        my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                        : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                        : undef;
        my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                       : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                       : undef;

        my $status = (ref($report) eq 'HASH' && defined $report->{ended_at})
            ? 'completed' : 'running';

        my %fields = (
            lifetime_ord => $i + 1,
            status       => $status,
            type         => $spec_typed{type},
            id           => $spec_typed{id},
            service_name => $spec_typed{service_name},
            stage_name   => $spec_typed{stage_name},
            started_at   => $self->_normalize_db_datetime($spec_typed{started_at}),
            ended_at     => $self->_normalize_db_datetime($report_typed{ended_at}),
            exit         => $report_typed{exit},
            child_wall   => $child_wall,
        );
        $fields{exit_decoded} = $report_typed{exit_decoded} if exists $report_typed{exit_decoded};
        $fields{times}        = $times                      if defined $times;
        $fields{child_times}  = $child_times                if defined $child_times;
        $fields{spec_extras}  = \%spec_extras               if %spec_extras;
        $fields{state_extras} = \%state_extras              if %state_extras;

        $b->service_lifetime_create($sid, \%fields);
    }

    return;
}

sub _populate_job_rows {
    my ($self, $source, $aid, $run_ord, $job_ord) = @_;
    my $b = $self->{_BACKEND()};
    my $dbh = $self->dbh;

    my @tries = $source->can('tries') ? $source->tries($run_ord, $job_ord) : ();
    return unless @tries;

    my $job_db_id;
    my ($latest_try_ord, $latest_pass, $latest_status, $latest_spec);

    my %spec_promoted   = map { $_ => 1 } @_JOB_TRIES_SPEC_PROMOTED;
    my %report_promoted = map { $_ => 1 } @_JOB_TRIES_REPORT_PROMOTED;
    my %aggregated      = map { $_ => 1 } @_JOB_TRIES_AGGREGATED;

    for my $try_ord (@tries) {
        my $artifact = eval { $source->artifacts($run_ord, $job_ord, $try_ord) } or next;
        my $spec   = $self->_read_first_jsonl_row($artifact, 'spec.jsonl');
        my $report = $self->_read_first_jsonl_row($artifact, 'report.jsonl');

        my $jtid = $self->_ensure_job_try_id($aid, $run_ord, $job_ord, $try_ord);
        $job_db_id //= do {
            my ($x) = $dbh->selectrow_array(
                q{SELECT job_id FROM job_tries WHERE job_try_id = ?},
                undef, $jtid,
            );
            $x;
        };

        my (%spec_typed, %spec_extras);
        if (ref($spec) eq 'HASH') {
            for my $k (sort keys %$spec) {
                next if $aggregated{$k};
                if ($spec_promoted{$k}) { $spec_typed{$k} = $spec->{$k}; }
                else                    { $spec_extras{$k} = $spec->{$k}; }
            }
        }

        my (%report_typed, %state_extras);
        if (ref($report) eq 'HASH') {
            for my $k (sort keys %$report) {
                next if $aggregated{$k};
                if ($report_promoted{$k}) { $report_typed{$k} = $report->{$k}; }
                else                      { $state_extras{$k} = $report->{$k}; }
            }
        }

        my $times = exists $report_typed{times}       ? $report_typed{times}
                  : exists $spec_typed{times}         ? $spec_typed{times}
                  : undef;
        my $child_times = exists $report_typed{child_times} ? $report_typed{child_times}
                        : exists $spec_typed{child_times}   ? $spec_typed{child_times}
                        : undef;
        my $child_wall = exists $report_typed{child_wall} ? $report_typed{child_wall}
                       : exists $spec_typed{child_wall}   ? $spec_typed{child_wall}
                       : undef;

        my $times_json       = ref($times)       ? $self->_encode_json($times)       : $times;
        my $child_times_json = ref($child_times) ? $self->_encode_json($child_times) : $child_times;
        my $plan_json        = ref($report_typed{plan}) ? $self->_encode_json($report_typed{plan}) : $report_typed{plan};
        my $halt_json        = ref($report_typed{halt}) ? $self->_encode_json($report_typed{halt}) : $report_typed{halt};

        my $spec_extras_json  = %spec_extras  ? $self->_encode_json(\%spec_extras)  : undef;
        my $state_extras_json = %state_extras ? $self->_encode_json(\%state_extras) : undef;

        my %set;
        $set{queued_at}       = $self->_normalize_db_datetime($spec_typed{queued_at})  if defined $spec_typed{queued_at};
        $set{started_at}      = $self->_normalize_db_datetime($spec_typed{started_at}) if defined $spec_typed{started_at};
        $set{ended_at}        = $self->_normalize_db_datetime($report_typed{ended_at}) if defined $report_typed{ended_at};
        $set{exit}            = $report_typed{exit}                        if defined $report_typed{exit};
        $set{exit_decoded}    = $self->_encode_json($report_typed{exit_decoded})
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

        if (!defined $latest_try_ord || $try_ord > $latest_try_ord) {
            $latest_try_ord = $try_ord;
            $latest_pass    = $set{pass};
            $latest_status  = $set{status};
            $latest_spec    = $spec;
        }

        if ($report && ref($report->{subtests}) eq 'ARRAY') {
            my $sti = 0;
            for my $st (@{$report->{subtests}}) {
                next unless ref($st) eq 'HASH';
                my $name = $st->{name} // '';
                next unless length $name;
                $b->subtest_create($jtid, {
                    name       => $name,
                    pass       => $st->{pass} ? 1 : 0,
                    count_pass => $st->{count_pass},
                    count_fail => $st->{count_fail},
                    ord        => $sti++,
                });
            }
        }
    }

    return unless defined $job_db_id;

    my $test_file_id;
    if (ref($latest_spec) eq 'HASH' && defined $latest_spec->{relative}) {
        my $project_id = $self->{_PROJECT_ID()};
        if (defined $project_id) {
            $test_file_id = $self->{_BACKEND()}->ensure_test_file_row(
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

    $self->_populate_job_spec($job_db_id, $test_file_id, $latest_spec)
        if ref($latest_spec) eq 'HASH';

    return;
}

sub _populate_job_spec {
    my ($self, $job_id, $test_file_id, $spec) = @_;
    return unless ref($spec) eq 'HASH';
    return unless defined $test_file_id;

    my $b = $self->{_BACKEND()};
    my $dbh = $self->dbh;

    # Idempotent: skip if a row already exists for this job_id.
    my ($existing) = $dbh->selectrow_array(
        q{SELECT job_spec_id FROM job_specs WHERE job_id = ?},
        undef, $job_id,
    );
    return if defined $existing;

    my (%promoted, %extras);
    for my $k (sort keys %$spec) {
        if ($_JOB_SPECS_CONSUMED{$k}) {
            $promoted{$k} = $spec->{$k};
        }
        else {
            $extras{$k} = $spec->{$k};
        }
    }

    my %fields = (test_file_id => $test_file_id);
    for my $c (qw/absolute category duration stage retry retry_isolated smoke
                  isolation non_perl is_binary event_timeout post_exit_timeout
                  min_slots max_slots ch_dir/)
    {
        next unless exists $promoted{$c};
        my $v = $promoted{$c};
        if ($c =~ /^(?:retry_isolated|smoke|isolation|non_perl|is_binary)\z/) {
            $fields{$c} = $v ? 1 : (defined $v ? 0 : undef);
        }
        else {
            $fields{$c} = $v;
        }
    }
    for my $c (qw/features switches/) {
        next unless exists $promoted{$c};
        $fields{$c} = $promoted{$c};
    }
    $fields{extras} = \%extras if %extras;

    $b->job_spec_create($job_id, \%fields);
    return;
}

# Generic row update via raw SQL on the shared dbh. Both backends
# point at the same connection / shape; using DBI directly keeps us
# from having to plumb every typed-column update through both
# backends' ResultSet / SQL paths.
sub _update_row {
    my ($self, $table, $set, $where) = @_;
    return unless $set && %$set;

    my @cols = sort keys %$set;
    my @wcols = sort keys %$where;

    # Quote reserved keywords ("exit" is the only one we touch).
    my $q = sub {
        my $c = shift;
        return $c eq 'exit' ? '"exit"' : $c;
    };

    my $sql = "UPDATE $table SET "
            . join(', ', map { $q->($_) . ' = ?' } @cols)
            . ' WHERE '
            . join(' AND ', map { $q->($_) . ' = ?' } @wcols);

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    my $idx = 1;
    for my $c (@cols) {
        $sth->bind_param($idx++, $set->{$c});
    }
    for my $c (@wcols) {
        $sth->bind_param($idx++, $where->{$c});
    }
    $sth->execute;
    return;
}

# ---------------------------------------------------------------------------
# Reconstruction (spec.jsonl / report.jsonl from typed columns + extras)
# ---------------------------------------------------------------------------

# Merge an extras hashref + an arrayref of [key, value] pairs into a
# single record. Pairs override extras on collision; undef values are
# skipped (preserves "key not present in original" vs "key was null").
sub _merge_extras_and_typed {
    my ($self, $extras, $typed_pairs) = @_;
    my %record;
    if (ref($extras) eq 'HASH') {
        %record = %$extras;
    }
    for (my $i = 0; $i + 1 < scalar @$typed_pairs; $i += 2) {
        my ($k, $v) = @{$typed_pairs}[$i, $i + 1];
        next unless defined $v;
        $record{$k} = $v;
    }
    return \%record;
}

sub _reconstruct_spec_records {
    my ($self, $aid, $scope_kind, $scope_id) = @_;
    return undef if $scope_kind eq 'archive';
    return undef unless defined $scope_id;

    if    ($scope_kind eq 'run')     { return $self->_reconstruct_run_spec($aid, $scope_id) }
    elsif ($scope_kind eq 'service') { return $self->_reconstruct_service_specs($aid, $scope_id) }
    elsif ($scope_kind eq 'job_try') { return $self->_reconstruct_job_try_spec($aid, $scope_id) }
    return undef;
}

sub _reconstruct_report_records {
    my ($self, $aid, $scope_kind, $scope_id) = @_;
    return undef if $scope_kind eq 'archive';
    return undef unless defined $scope_id;

    if    ($scope_kind eq 'run')     { return $self->_reconstruct_run_report($aid, $scope_id) }
    elsif ($scope_kind eq 'service') { return $self->_reconstruct_service_reports($aid, $scope_id) }
    elsif ($scope_kind eq 'job_try') { return $self->_reconstruct_job_try_report($aid, $scope_id) }
    return undef;
}

# Find the runs row for $run_id within $aid. Returns the row hashref.
sub _run_row_by_id {
    my ($self, $aid, $run_id) = @_;
    for my $r (@{ $self->{_BACKEND()}->run_rows($aid) }) {
        return $r if $r->{run_id} == $run_id;
    }
    return undef;
}

sub _reconstruct_run_spec {
    my ($self, $aid, $run_id) = @_;
    my $b = $self->{_BACKEND()};

    my $row = $self->_run_row_full($run_id);
    return [] unless $row;

    my $rec = $self->_merge_extras_and_typed(
        $self->_decode_json($row->{spec_extras}),
        [
            run_uuid    => $row->{run_uuid_canonical},
            started_at  => $self->_format_iso8601($row->{started_at}),
            times       => $self->_decode_json($row->{times}),
            child_times => $self->_decode_json($row->{child_times}),
            child_wall  => $row->{child_wall},
        ],
    );

    delete $rec->{$_} for qw(jobs subtests services);
    return [$rec];
}

sub _reconstruct_run_report {
    my ($self, $aid, $run_id) = @_;
    my $b = $self->{_BACKEND()};

    my $row = $self->_run_row_full($run_id);
    return [] unless $row;

    my $rec = $self->_merge_extras_and_typed(
        $self->_decode_json($row->{state_extras}),
        [
            ended_at     => $self->_format_iso8601($row->{ended_at}),
            exit         => $row->{exit},
            exit_decoded => $self->_decode_json($row->{exit_decoded}),
            pass         => defined $row->{pass} ? ($row->{pass} ? 1 : 0) : undef,
            total_jobs   => $row->{total_jobs},
            passed_jobs  => $row->{passed_jobs},
            failed_jobs  => $row->{failed_jobs},
            aborted_jobs => $row->{aborted_jobs},
            times        => $self->_decode_json($row->{times}),
            child_times  => $self->_decode_json($row->{child_times}),
            child_wall   => $row->{child_wall},
        ],
    );

    # Rebuild jobs[] aggregate via the backend's job_rows + try_rows.
    my $jobs = $b->job_rows($aid, $run_id);
    if ($jobs && @$jobs) {
        my @out;
        for my $j (@$jobs) {
            my $j_full = $self->_job_row_full($aid, $run_id, $j->{job_ord});
            my $tries = $b->try_rows($j->{job_id});
            my @tries_out;
            for my $t (@$tries) {
                push @tries_out, {
                    try_ord         => $t->{try_ord},
                    (defined $t->{status}          ? (status          => $t->{status})                : ()),
                    (defined $t->{pass}            ? (pass            => $t->{pass} ? 1 : 0)          : ()),
                    (defined $t->{ended_at}        ? (ended_at        => $self->_format_iso8601($t->{ended_at})) : ()),
                    (defined $t->{pass_count}      ? (pass_count      => $t->{pass_count})            : ()),
                    (defined $t->{fail_count}      ? (fail_count      => $t->{fail_count})            : ()),
                    (defined $t->{assertion_count} ? (assertion_count => $t->{assertion_count})       : ()),
                    (defined $t->{exit_decoded}
                        ? (exit_decoded => ref($t->{exit_decoded}) ? $t->{exit_decoded} : $self->_decode_json($t->{exit_decoded}))
                        : ()),
                };
            }
            push @out, {
                job_ord => $j->{job_ord},
                (defined $j_full->{status}      ? (status      => $j_full->{status})           : ()),
                (defined $j_full->{pass}        ? (pass        => $j_full->{pass} ? 1 : 0)     : ()),
                (defined $j_full->{retry_count} ? (retry_count => $j_full->{retry_count})      : ()),
                tries => \@tries_out,
            };
        }
        $rec->{jobs} = \@out;
    }

    delete $rec->{subtests};
    delete $rec->{services};
    return [$rec];
}

# Helpers that pull a fully-populated runs / jobs row through the dbh
# (the backend's run_rows / job_rows shape is intentionally narrow).
# We touch the dbh directly here -- this is the data layer; backend
# canonicalization on UUIDs and JSON columns has already happened for
# the columns the backends advertise. For columns NOT in the backend
# row shape (started_at, ended_at, exit, status, pass, *_extras,
# child_times, etc.), we have to query directly. Both backends share
# the same dbh, so this is a single SQL path.
sub _run_row_full {
    my ($self, $run_id) = @_;
    my $dbh = $self->{_BACKEND()}->dbh;
    my $row = $dbh->selectrow_hashref(
        q{SELECT * FROM runs WHERE run_id = ?},
        undef, $run_id,
    ) or return undef;
    # Canonicalize the UUID. Prefer the backend's flavor-specific
    # decoder (DBIC has _flavor_uuid_from_db that lowercases; SQL has
    # _uuid_from_db that lowercases). For DBIC, _uuid_from_db
    # delegates to its Internal helper, whose Sqlite override is
    # identity -- so we use _flavor_uuid_from_db on DBIC to get the
    # lowercase form.
    if ($self->{_BACKEND()}->can('_flavor_uuid_from_db')) {
        $row->{run_uuid_canonical}
            = $self->{_BACKEND()}->_flavor_uuid_from_db($row->{run_uuid});
    }
    elsif ($self->{_BACKEND()}->can('_uuid_from_db')) {
        $row->{run_uuid_canonical}
            = $self->{_BACKEND()}->_uuid_from_db($row->{run_uuid});
    }
    else {
        $row->{run_uuid_canonical} = lc("$row->{run_uuid}");
    }
    return $row;
}

sub _job_row_full {
    my ($self, $aid, $run_id, $job_ord) = @_;
    my $dbh = $self->{_BACKEND()}->dbh;
    return $dbh->selectrow_hashref(
        q{SELECT * FROM jobs WHERE archive_id = ? AND run_id = ? AND job_ord = ?},
        undef, $aid, $run_id, $job_ord,
    );
}

sub _reconstruct_service_specs {
    my ($self, $aid, $service_id) = @_;
    my $b = $self->{_BACKEND()};
    my $dbh = $b->dbh;

    my ($svc_role) = $dbh->selectrow_array(
        q{SELECT role FROM services WHERE service_id = ?},
        undef, $service_id,
    );

    my $rows = $b->service_lifetime_rows($service_id);
    return [] unless $rows && @$rows;

    my @out;
    for my $row (@$rows) {
        my $rec = $self->_merge_extras_and_typed(
            ref($row->{spec_extras}) ? $row->{spec_extras}
                                     : $self->_decode_json($row->{spec_extras}),
            [
                type         => $row->{type},
                id           => $row->{id},
                service_name => $row->{service_name},
                stage_name   => $row->{stage_name},
                started_at   => $self->_format_iso8601($row->{started_at}),
                times        => ref($row->{times})       ? $row->{times}       : $self->_decode_json($row->{times}),
                child_times  => ref($row->{child_times}) ? $row->{child_times} : $self->_decode_json($row->{child_times}),
                child_wall   => $row->{child_wall},
                (defined $svc_role ? (role => $svc_role) : ()),
            ],
        );
        push @out, $rec;
    }
    return \@out;
}

sub _reconstruct_service_reports {
    my ($self, $aid, $service_id) = @_;
    my $b = $self->{_BACKEND()};

    my $rows = $b->service_lifetime_rows($service_id);
    return [] unless $rows && @$rows;

    my @out;
    for my $row (@$rows) {
        my $rec = $self->_merge_extras_and_typed(
            ref($row->{state_extras}) ? $row->{state_extras}
                                      : $self->_decode_json($row->{state_extras}),
            [
                ended_at     => $self->_format_iso8601($row->{ended_at}),
                exit         => $row->{exit},
                exit_decoded => ref($row->{exit_decoded}) ? $row->{exit_decoded}
                                                          : $self->_decode_json($row->{exit_decoded}),
                times        => ref($row->{times})       ? $row->{times}       : $self->_decode_json($row->{times}),
                child_times  => ref($row->{child_times}) ? $row->{child_times} : $self->_decode_json($row->{child_times}),
                child_wall   => $row->{child_wall},
            ],
        );
        push @out, $rec;
    }
    return \@out;
}

sub _reconstruct_job_try_spec {
    my ($self, $aid, $job_try_id) = @_;
    my $dbh = $self->{_BACKEND()}->dbh;

    my $jt = $dbh->selectrow_hashref(
        q{SELECT * FROM job_tries WHERE job_try_id = ?},
        undef, $job_try_id,
    );
    return [] unless $jt;

    my $rec = $self->_merge_extras_and_typed(
        $self->_decode_json($jt->{spec_extras}),
        [
            queued_at   => $self->_format_iso8601($jt->{queued_at}),
            started_at  => $self->_format_iso8601($jt->{started_at}),
            times       => $self->_decode_json($jt->{times}),
            child_times => $self->_decode_json($jt->{child_times}),
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
        my $extras = $self->_decode_json($js->{extras});
        if (ref($extras) eq 'HASH') {
            for my $k (keys %$extras) {
                next if exists $rec->{$k};
                $rec->{$k} = $extras->{$k};
            }
        }

        $rec->{relative} = $js->{relative} if defined $js->{relative};
        for my $k (qw(absolute category duration stage retry
                      event_timeout post_exit_timeout min_slots max_slots ch_dir))
        {
            $rec->{$k} = $js->{$k} if defined $js->{$k};
        }
        for my $k (qw(retry_isolated smoke isolation non_perl is_binary)) {
            $rec->{$k} = $js->{$k} ? 1 : 0 if defined $js->{$k};
        }
        for my $k (qw(features switches)) {
            my $decoded = $self->_decode_json($js->{$k});
            $rec->{$k} = $decoded if defined $decoded;
        }
    }

    delete $rec->{subtests};
    return [$rec];
}

sub _reconstruct_job_try_report {
    my ($self, $aid, $job_try_id) = @_;
    my $dbh = $self->{_BACKEND()}->dbh;

    my $jt = $dbh->selectrow_hashref(
        q{SELECT * FROM job_tries WHERE job_try_id = ?},
        undef, $job_try_id,
    );
    return [] unless $jt;

    my $rec = $self->_merge_extras_and_typed(
        $self->_decode_json($jt->{state_extras}),
        [
            ended_at        => $self->_format_iso8601($jt->{ended_at}),
            exit            => $jt->{exit},
            exit_decoded    => $self->_decode_json($jt->{exit_decoded}),
            pass            => defined $jt->{pass} ? ($jt->{pass} ? 1 : 0) : undef,
            pass_count      => $jt->{pass_count},
            fail_count      => $jt->{fail_count},
            assertion_count => $jt->{assertion_count},
            plan            => $self->_decode_json($jt->{plan}),
            halt            => $self->_decode_json($jt->{halt}),
            times           => $self->_decode_json($jt->{times}),
            child_times     => $self->_decode_json($jt->{child_times}),
            child_wall      => $jt->{child_wall},
        ],
    );

    my $subtests = $self->{_BACKEND()}->subtest_rows($job_try_id);
    if ($subtests && @$subtests) {
        my @out;
        for my $s (@$subtests) {
            push @out, {
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB - top-level entry point for yath DB-archive backends.

=head1 SYNOPSIS

    use App::Yath2::DB;

    # Legacy factory: returns a backend instance directly.
    my $db = App::Yath2::DB->open(file => '/tmp/runs.yath');

    my $db = App::Yath2::DB->open(
        dsn  => 'dbi:Pg:dbname=yath',
        user => 'yath',
        pass => 'yath',
        backend => 'dbic',
    );

    # New shape: returns an App::Yath2::DB instance wrapping a backend.
    my $db = App::Yath2::DB->new(file => '/tmp/runs.yath');
    for my $uuid ($db->archives) {
        my $scoped = $db->scoped($uuid);
        my @runs   = $scoped->runs;
    }

=head1 BACKENDS

Two implementations of L<App::Yath2::Role::DB::Backend>:

=over 4

=item C<backend =E<gt> 'sql'> (default)

L<App::Yath2::DB::SQL>. Single class, raw-DBI, flavor-aware.

=item C<backend =E<gt> 'dbic'>

L<App::Yath2::DB::DBIC>. Single class wrapping a
L<DBIx::Class::Schema>; flavor handled by storage detection.

=item C<backend =E<gt> 'internal'>

Deprecated alias for C<sql>. Will be removed in a future release.

=back

Both consume L<App::Yath2::Role::DB::Backend>. Bootstrap is always
driven by C<share/schema/$flavor.sql>; DBIC's C<deploy()> is never
called.

=cut
