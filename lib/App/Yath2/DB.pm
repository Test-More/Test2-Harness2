package App::Yath2::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

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
    # consumed by _backend_class; rename for DBIC.
    if ($backend eq 'dbic' && defined $args{flavor}) {
        $args{flavor_override} = delete $args{flavor};
    } else {
        delete $args{flavor};
    }

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
sub _BACKEND  () { 'backend' }
sub _UUID     () { 'uuid' }
sub _AID      () { 'archive_id' }

sub new {
    my ($class, %args) = @_;

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
    croak "NYI: artifact path create-mode (Phase 6)" if $create;

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
        $scope_id = $b->service_id_for_name($aid, $service_name, undef);
        return undef unless defined $scope_id;
        splice(@parts, 0, 2);
    }
    elsif ($parts[0] eq 'runs') {
        return undef unless @parts >= 2;
        $run_ord = $parts[1];
        return undef unless $run_ord =~ /^\d+\z/;

        if (@parts == 2) {
            $scope_kind = 'run';
            $scope_id = $b->run_exists($aid, $run_ord)
                ? $b->run_id_for_ord($aid, $run_ord)
                : undef;
            return undef unless defined $scope_id;
            splice(@parts, 0, 2);
        }
        elsif ($parts[2] eq 'services') {
            return undef unless @parts >= 4;
            $service_name = $parts[3];
            $scope_kind = 'service';
            $scope_id = $b->service_id_for_name($aid, $service_name, $run_ord);
            return undef unless defined $scope_id;
            splice(@parts, 0, 4);
        }
        elsif ($parts[2] eq 'jobs') {
            return undef unless @parts >= 5;
            $job_ord = $parts[3];
            $try_ord = $parts[4];
            return undef unless $job_ord =~ /^\d+\z/ && $try_ord =~ /^\d+\z/;
            $scope_kind = 'job_try';
            return undef unless $b->run_exists($aid, $run_ord);
            my $rid = $b->run_id_for_ord($aid, $run_ord);
            return undef unless $b->job_exists($aid, $rid, $job_ord);
            my $jid = $b->job_id_for_ord($aid, $rid, $job_ord);
            return undef unless $b->try_exists($jid, $try_ord);
            $scope_id = $b->try_id_for_ord($jid, $try_ord);
            return undef unless defined $scope_id;
            splice(@parts, 0, 5);
        }
        else {
            $scope_kind = 'run';
            $scope_id = $b->run_exists($aid, $run_ord)
                ? $b->run_id_for_ord($aid, $run_ord)
                : undef;
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
    croak "NYI: artifact_save (Phase 6)";
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
