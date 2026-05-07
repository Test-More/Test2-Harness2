package App::Yath2::Log::MySQL;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'App::Yath2::Log::DB';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Spec ();
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase;

# MySQL/Percona-backed Log backend. Inherits the bulk of its behavior
# from App::Yath2::Log::DB; this class only fills in flavor-specific
# bits:
#
#   - DSN / DBH construction (dsn => ... | dbh => ...). Uses
#     DBD::MariaDB which speaks both MySQL and MariaDB protocols.
#   - Schema bootstrap from share/schema/mysql.sql.
#   - UUID codec: convert canonical UUID string <-> BINARY(16) by
#     stripping/inserting dashes and using UNHEX/HEX in SQL. The
#     companion <col>_string field is populated by triggers in the
#     schema; we never write to it.
#   - JSON codec: text in / text out (MySQL JSON columns).
#   - Payload compression default = 1 (client-side zstd; MySQL has no
#     native column compression).
#   - last_insert_id via DBI's standard accessor.
#   - _bind_payload: SQL_BLOB so DBD::MariaDB does not UTF-8-mangle
#     the bytes.
#
# Connection sets ANSI_QUOTES for portable double-quoted identifiers.

sub init {
    my $self = shift;

    croak "MySQL backend requires one of: dbh, dsn"
        unless defined $self->{App::Yath2::Log::DB::DBH}
        || defined $self->{App::Yath2::Log::DB::DSN};

    $self->dbh;
    $self->_apply_session_state;
    $self->bootstrap_schema;
    $self->_resolve_archive(missing_ok => 1);

    return;
}

# True if the connected server is MariaDB (not real MySQL). Distros
# routinely symlink mysqld -> mariadbd, so tests that ask for the
# "MySQL" QuickDB driver may end up on a MariaDB server. The schema's
# BIN_TO_UUID() triggers are MySQL-specific and fail on MariaDB; we
# skip those when the server is MariaDB.
sub _server_is_mariadb {
    my $self = shift;
    return $self->{__is_mariadb} //= do {
        my ($v) = $self->dbh->selectrow_array('SELECT VERSION()');
        defined $v && $v =~ /MariaDB/i ? 1 : 0;
    };
}

sub schema_flavor { 'mysql' }

sub schema_file {
    my $self = shift;
    my $dev = _dev_schema_path('mysql');
    return $dev if defined $dev && -e $dev;

    require File::ShareDir;
    my $share = eval { File::ShareDir::dist_dir('Test2-Harness2') };
    if ($share && -e "$share/schema/mysql.sql") {
        return "$share/schema/mysql.sql";
    }
    croak "could not locate schema file for mysql";
}

sub _dev_schema_path {
    my ($flavor) = @_;
    my $here = __FILE__;
    my $dir = $here;
    for (1 .. 10) {
        $dir = dirname($dir);
        my $candidate = File::Spec->catfile($dir, 'share', 'schema', "$flavor.sql");
        return $candidate if -e $candidate;
        last if $dir eq '/' || $dir eq '.';
    }
    return undef;
}

sub _connect_dbh {
    my $self = shift;

    # Per K3: use DBD::MariaDB to talk to MySQL servers. DBD::mysql is
    # not supported in this round.
    my $ok = eval { require DBI; require DBD::MariaDB; 1 };
    my $err = $@;
    croak "install DBD::MariaDB to use the MySQL backend: $err" unless $ok;

    my $dsn   = $self->{App::Yath2::Log::DB::DSN};
    my $user  = $self->{App::Yath2::Log::DB::USER};
    my $pass  = $self->{App::Yath2::Log::DB::PASS};
    my $attrs = $self->{App::Yath2::Log::DB::ATTRS} || {};

    croak "no dsn provided" unless defined $dsn;

    my $dbh = DBI->connect($dsn, $user, $pass, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        %$attrs,
    }) or croak "DBI->connect $dsn: $DBI::errstr";

    return $dbh;
}

sub _apply_session_state {
    my $self = shift;
    my $dbh = $self->{App::Yath2::Log::DB::DBH} or return;
    $dbh->do(q{SET SESSION sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')});
    return;
}

# The base class' bootstrap parses schema.sql and ->do()s each
# statement. The MySQL schema's triggers call BIN_TO_UUID() which is
# MySQL-only; against a MariaDB server (which is what most distros
# install via the mysqld -> mariadbd symlink) those triggers fail.
# Skip trigger statements on a MariaDB server -- the companion
# <col>_string fields will simply stay NULL, which is harmless because
# the application never reads them.
sub bootstrap_schema {
    my $self = shift;
    return if $self->_is_bootstrapped;

    my $dbh = $self->dbh;
    my $path = $self->schema_file;
    open(my $fh, '<', $path) or croak "cannot open schema file '$path': $!";
    my $sql = do { local $/; <$fh> };
    close $fh;

    my $skip_triggers = $self->_server_is_mariadb;

    $sql =~ s{--[^\n]*\n}{\n}g;

    my @statements = grep { /\S/ } split /;\s*\n/, $sql;

    for my $stmt (@statements) {
        $stmt =~ s/^\s+//;
        $stmt =~ s/\s+$//;
        next unless length $stmt;
        next if $skip_triggers && $stmt =~ /^CREATE\s+TRIGGER\b/i;
        $dbh->do($stmt) or croak "schema bootstrap failed: " . $dbh->errstr;
    }
    return;
}

# UUIDs are stored as BINARY(16). gen_uuid() returns a 36-char canonical
# string; convert to/from a 16-byte raw binary by stripping dashes and
# packing the hex.
sub _uuid_to_db {
    my ($self, $u) = @_;
    return undef unless defined $u;
    (my $h = $u) =~ tr/-//d;
    return pack('H*', $h);
}

sub _uuid_from_db {
    my ($self, $bytes) = @_;
    return undef unless defined $bytes;
    return undef unless length($bytes) == 16;
    my $hex = uc unpack('H*', $bytes);
    return join '-',
        substr($hex,  0, 8),
        substr($hex,  8, 4),
        substr($hex, 12, 4),
        substr($hex, 16, 4),
        substr($hex, 20);
}

sub _json_encode { defined $_[1] ? encode_json($_[1]) : undef }
sub _json_decode {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return decode_json($val);
}

# MySQL has no per-column server-side compression usable for our
# workload; client-side zstd is required. Per K8c.
sub _payload_compressed_default { 1 }

sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    require DBI;
    $sth->bind_param($idx, $bytes, DBI::SQL_BLOB());
    return;
}

# MySQL DATETIME(6): same format as MariaDB.
sub _now_iso {
    my $self = shift;
    my $t  = Time::HiRes::time();
    my @lt = gmtime(int $t);
    my $frac = $t - int $t;
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d.%03d',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0],
        int($frac * 1000));
}

# Format DateTime for MySQL DATETIME(6) via DateTime::Format::MySQL.
sub _format_datetime {
    my ($self, $dt) = @_;
    return undef unless defined $dt;
    require DateTime::Format::MySQL;
    return DateTime::Format::MySQL->format_datetime($dt);
}

# Parse MySQL DATETIME column values via DateTime::Format::MySQL.
sub _to_datetime {
    my ($self, $val) = @_;
    return undef unless defined $val;
    return $val if ref $val && eval { $val->isa('DateTime') };
    if (!ref $val && $val =~ /\A\d{4}-\d{2}-\d{2}\s/) {
        require DateTime::Format::MySQL;
        my $dt = eval { DateTime::Format::MySQL->parse_datetime($val) };
        return $dt if defined $dt;
    }
    return $self->SUPER::_to_datetime($val);
}

sub _last_insert_id {
    my ($self, $dbh, $table, $col) = @_;
    return $dbh->last_insert_id(undef, undef, $table, $col);
}

# UUID columns are BINARY(16) — DBD::MariaDB returns 16-byte raw bytes
# but UTF-8 mode may try to decode them. Override to bind as SQL_BINARY
# would be ideal, but the base class binds via execute(@bind). The raw
# bytes round-trip through DBD::MariaDB without UTF-8 mangling because
# the binary form contains many high-bit bytes that fail UTF-8 validation
# and DBD::MariaDB falls through to raw on those. Safer: bind UUID
# columns explicitly with SQL_BINARY in our INSERT primitives.
#
# For simplicity, we override the INSERT path that touches archive/run/
# job_try/service rows with UUID columns by also binding those as
# SQL_BINARY. This includes _create_archive and _ensure_run_row, which
# the base class drives. We use bind_param-aware overrides.

sub _create_archive {
    my ($self, $meta) = @_;
    croak "_create_archive requires a meta hashref"
        unless ref($meta) eq 'HASH';
    require DBI;
    my $uuid = $meta->{archive_uuid} // gen_uuid();
    my $dbh = $self->dbh;

    my ($extras_json, undef) = $self->_split_meta_extras($meta);

    # ANSI_QUOTES is on for this session, so "user" is treated as an
    # identifier. Use the same syntax as the base class for symmetry.
    my $user_col = $self->_quote_user_col;
    my $sth = $dbh->prepare(qq{
        INSERT INTO archives
            (archive_uuid, archive_version, sealed_at,
             host, $user_col, git_sha, project, yath_version, meta_extras)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->bind_param(1, $self->_uuid_to_db($uuid), DBI::SQL_BINARY());
    $sth->bind_param(2, $App::Yath2::Log::VERSION);
    $sth->bind_param(3, $self->_iso_to_db_datetime($meta->{created_at}));
    $sth->bind_param(4, $meta->{host});
    $sth->bind_param(5, $meta->{user});
    $sth->bind_param(6, $meta->{git_sha});
    $sth->bind_param(7, $meta->{project});
    $sth->bind_param(8, $meta->{yath_version});
    $sth->bind_param(9, $extras_json);
    $sth->execute;

    my $id = $self->_last_insert_id($dbh, 'archives', 'archive_id');
    $self->{App::Yath2::Log::DB::ARCHIVE_ID} = $id;
    $self->{App::Yath2::Log::DB::UUID}       = $uuid;
    return $id;
}

# MySQL/MariaDB-via-mysqld-binary: archive_uuid is BINARY(16). The
# base-class _check_archive_uuid_unique uses selectrow_array with no
# explicit bind type, which DBD::MariaDB treats as TEXT and never
# matches the stored binary bytes. Bind explicitly as SQL_BINARY so
# the pre-flight check actually finds the existing row.
sub _check_archive_uuid_unique {
    my ($self, $uuid) = @_;
    return unless defined $uuid && length $uuid;
    require DBI;
    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(
        q{SELECT archive_id FROM archives WHERE archive_uuid = ?});
    $sth->bind_param(1, $self->_uuid_to_db($uuid), DBI::SQL_BINARY());
    $sth->execute;
    my ($existing) = $sth->fetchrow_array;
    $sth->finish;
    return unless defined $existing;

    croak "archive uuid '$uuid' already exists; not re-imported";
}

sub _ensure_run_row {
    my ($self, $run_ord) = @_;
    require DBI;
    my $aid = $self->_archive_id_or_die;
    my $dbh = $self->dbh;
    my ($id) = $dbh->selectrow_array(
        q{SELECT run_id FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    return $id if defined $id;

    my $run_uuid   = gen_uuid();
    my $project_id = $self->{App::Yath2::Log::DB::PROJECT_ID}
        // croak("project_id not set on DB object before _ensure_run_row");
    my $sth = $dbh->prepare(q{
        INSERT INTO runs (archive_id, project_id, run_ord, run_uuid, status, aborted, timed_out)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    });
    $sth->bind_param(1, $aid);
    $sth->bind_param(2, $project_id);
    $sth->bind_param(3, $run_ord);
    $sth->bind_param(4, $self->_uuid_to_db($run_uuid), DBI::SQL_BINARY());
    $sth->bind_param(5, 'unknown');
    $sth->bind_param(6, 0);
    $sth->bind_param(7, 0);
    $sth->execute;
    return $self->_last_insert_id($dbh, 'runs', 'run_id');
}

# UUID lookups need _uuid_to_db form too. The base class' _resolve_archive
# fetches archive_uuid and case-folds via _uuid_from_db before comparing
# to the user's $uuid arg — so that path works as long as
# _uuid_from_db produces a comparable string. Our _uuid_from_db
# returns uppercase canonical, gen_uuid() returns uppercase canonical:
# uc-compare on both sides matches.

# The base class _artifact_save / insert use bind_param + _bind_payload.
# Those bind the UUID via _uuid_to_db -> packed bytes. DBD::MariaDB will
# bind those as TEXT by default (and break). We override to bind UUID
# columns via SQL_BINARY on the insert path. The cleanest seam is to
# wrap the base class' INSERT prepares: re-implement just the artifact
# inserts with explicit SQL_BINARY for the artifact_uuid column.

sub _artifact_save {
    my ($self, %p) = @_;
    require DBI;
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
    }

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

    my $existing = $self->_select_artifact_row($info);
    if ($existing) {
        my $sth = $dbh->prepare(q{
            UPDATE artifacts
               SET compressed = ?, payload = ?, format = ?, created_at = ?
             WHERE artifact_id = ?
        });
        $sth->bind_param(1, $stored_compressed);
        $self->_bind_payload($sth, 2, $stored_bytes);
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
    $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid), DBI::SQL_BINARY());
    $sth->bind_param(3, $fk->{run_id});
    $sth->bind_param(4, $fk->{service_id});
    $sth->bind_param(5, $fk->{job_try_id});
    $sth->bind_param(6, $info->{artifact_kind});
    $sth->bind_param(7, $info->{format});
    $sth->bind_param(8, $info->{name});
    $sth->bind_param(9, $stored_compressed);
    $self->_bind_payload($sth, 10, $stored_bytes);
    $sth->bind_param(11, $now);
    $sth->bind_param(12, 1);
    $sth->execute;

    my $id = $self->_last_insert_id($dbh, 'artifacts', 'artifact_id');
    return "db:archive=$aid:artifact=$id";
}

sub insert {
    my ($self, $source, %opts) = @_;
    require DBI;
    croak "source log is required" unless defined $source;

    my $runs         = $opts{runs};
    my $exclude_runs = $opts{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;

    my $dbh = $self->dbh;
    # MySQL/MariaDB implicitly commit DDL inside a transaction, so
    # bootstrap_schema (CREATE TABLE / INDEX) MUST run before
    # begin_work or any rollback would be rendered a no-op.
    $self->bootstrap_schema;

    require App::Yath2::Log;
    # Per D5/D6/D9: carry source meta.json verbatim when present, mint
    # otherwise. archive_uuid carries over so re-import is detected.
    my $meta = $self->_resolve_insert_meta($source, \%opts);

    # Pre-flight uniqueness (D6): collide cleanly before opening tx.
    $self->_check_archive_uuid_unique($meta->{archive_uuid});

    # Wrap the whole population pass in a transaction (D6).
    $dbh->begin_work;
    my $aid;
    my $ok = eval {
        $aid = $self->_mysql_insert_body(
            $source, $meta, $runs, $exclude_runs,
        );
        1;
    };
    my $err = $@;

    if ($ok) {
        $dbh->commit;
    }
    else {
        my $rb_ok = eval { $dbh->rollback; 1 };
        warn "rollback failed after insert error: $@" unless $rb_ok;
        delete $self->{App::Yath2::Log::DB::_INSERT_SOURCE()};
        die $err;
    }

    return $aid;
}

sub _mysql_insert_body {
    my ($self, $source, $meta, $runs, $exclude_runs) = @_;
    my $dbh = $self->dbh;

    # Resolve (find-or-create) the projects row for this archive.
    my $project_name = $meta->{project} // 'unknown';
    my $project_id   = $self->_resolve_or_create_project($project_name);
    $self->{App::Yath2::Log::DB::PROJECT_ID} = $project_id;

    # Make $source visible to _ensure_job_row so it can read spec.jsonl
    # on demand when creating a jobs row (needed for NOT NULL test_file_id).
    $self->{App::Yath2::Log::DB::_INSERT_SOURCE()} = $source;

    my $aid = $self->_create_archive($meta);

    my @files;
    if ($source->can('list_files')) {
        @files = $source->list_files;
    }
    else {
        croak "source log does not support list_files";
    }

    my %seen_logical;
    my @ordered;
    for my $rel (@files) {
        next if $rel eq 'LIVE';
        # meta.json is reconstructed from archives columns (D9), not
        # carried as an artifact row.
        next if $rel eq 'meta.json' || $rel eq 'meta.json.zst';
        # B9: spec.jsonl / report.jsonl / state.jsonl are reconstructed
        # from typed columns + *_extras at read time; do not write them
        # as artifact rows.
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

        my $info = $self->_parse_artifact_path($rel, create => 1);
        next unless $info;
        next unless defined $info->{artifact_kind};

        my ($exists, $src_is_zst) = $source->_artifact_exists($rel);
        next unless $exists;

        my $raw = $source->_artifact_read($rel);

        my $stored_compressed = $src_is_zst ? 1 : 0;
        my $stored_bytes      = $raw;

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
        $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid), DBI::SQL_BINARY());
        $sth->bind_param(3, $fk->{run_id});
        $sth->bind_param(4, $fk->{service_id});
        $sth->bind_param(5, $fk->{job_try_id});
        $sth->bind_param(6, $info->{artifact_kind});
        $sth->bind_param(7, $info->{format});
        $sth->bind_param(8, $info->{name});
        $sth->bind_param(9, $stored_compressed);
        $self->_bind_payload($sth, 10, $stored_bytes);
        $sth->bind_param(11, $now);
        $sth->bind_param(12, 1);
        $sth->execute;
    }

    # Artifact loop complete; clear the source reference.
    delete $self->{App::Yath2::Log::DB::_INSERT_SOURCE()};

    # Mirror the base-class flow: populate summary rows
    # (runs / services / service_lifetimes / jobs / job_tries / ...).
    # sealed_at was set during _create_archive from $meta->{created_at}
    # (D5: it carries the source's live->sealed timestamp, not insert
    # wall time).
    $self->_populate_summary_rows($source, $aid, $runs, $exclude_runs, $project_id);

    return $aid;
}

# _resolve_archive in the base class fetches archive_uuid as raw bytes
# (BINARY(16)). _uuid_from_db converts to canonical uppercase string,
# which compares correctly to gen_uuid() output. No override needed.

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::MySQL - MySQL/Percona-backed Log reader / writer.

=head1 SYNOPSIS

    my $log = App::Yath2::Log::MySQL->new(
        dsn => 'dbi:MariaDB:database=yath;host=db.local',
    );
    # OR
    my $log = App::Yath2::Log::MySQL->new(dbh => $dbh, uuid => $u);

    while (my $event = $log->event(0)) {
        ...;
        last if $log->EOE;
    }

    my $a = $log->artifacts(0, 0);
    my $events_iter = $a->events_iter;

=head1 DESCRIPTION

MySQL/Percona-backed Log backend (MySQL E<gt>= 8.0.16, for CHECK
constraint enforcement and native JSON). Subclasses
L<App::Yath2::Log::DB> and provides only the MySQL-specific bits:

=over 4

=item *

C<DBD::MariaDB> connection (talks to both MySQL and MariaDB protocols).
DBD::mysql is not supported in this round.

=item *

UUID columns stored as C<BINARY(16)> with companion C<<col>_string>
fields populated by triggers in the schema. Application code only ever
writes the binary column.

=item *

Native JSON columns; payload C<LONGBLOB> stored client-side
zstd-compressed (no usable native column compression on stock MySQL).

=item *

C<ANSI_QUOTES> session mode so the base-class SQL's double-quoted
identifiers (C<"exit">) work.

=back

C<DBD::MariaDB> is loaded lazily on first connection. Calling the
constructor without C<DBD::MariaDB> installed throws a clear error.

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
