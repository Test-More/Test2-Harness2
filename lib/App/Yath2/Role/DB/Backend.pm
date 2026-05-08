package App::Yath2::Role::DB::Backend;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename ();
use File::Spec ();
use Test2::Harness2::LogLayout qw/
    run_dir
    job_dir
    service_global_dir
    service_run_dir
/;

use Role::Tiny;

# Required methods. Implementers must provide every one.
#
# Two layers split: high-level archive-shaped methods that the role
# itself provides as flavor-agnostic orchestration, and low-level
# DB-touching primitives that each consumer (raw SQL on
# App::Yath2::DB::Internal, ResultSet on App::Yath2::DB::DBIC)
# implements directly.
requires qw{
    dbh flavor _archive_id_or_die
    services runs jobs tries last_try
    has_service has_run has_job has_try
    event events end_of_events reset
    extract archive insert
    archives archive_count has_archive scoped
    _artifact_rows_for_archive
};

# Default identity preprocessor. Consumers override for flavor quirks
# (e.g., App::Yath2::DB::Internal::Postgres strips COMPRESSION lz4
# when the server build lacks it).
sub preprocess_schema_sql { $_[1] }

# Per-statement skip hook. Default: never skip. Consumers override for
# flavor quirks where individual schema statements must be elided at
# bootstrap time (e.g., App::Yath2::DB::Internal::MySQL skips CREATE
# TRIGGER when the live server is MariaDB, whose dialect rejects the
# MySQL-only BIN_TO_UUID() builtin used in the trigger bodies).
sub _should_skip_schema_statement { 0 }

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

# ----- flavor-agnostic helpers -----
#
# Both backends populate _artifact_rows_for_archive with the same row
# shape, so the row -> on-disk-path computation is shared here. Keep
# helpers private (leading underscore) to make the layering explicit:
# the role consumes consumer-supplied DB primitives and exposes the
# archive-shaped surface.

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

# Light heuristics matching what the schema's `format` column expects.
# Used by _parse_artifact_path during INSERT-side path tagging and by
# any reader that wants to classify a name on the fly.
sub _format_for_name {
    my $name = ref($_[0]) ? $_[1] : $_[0];
    return 'json'  if $name =~ /\.json\z/i;
    return 'jsonl' if $name =~ /\.jsonl\z/i;
    return 'csv'   if $name =~ /\.csv\z/i;
    return 'html'  if $name =~ /\.html?\z/i;
    return 'txt'   if $name =~ /\.txt\z/i;
    return 'bin';
}

# Translate a logical (scope_kind, scope_id) pair into a SQL WHERE
# fragment over the three nullable FK columns + bind values. The
# fragment never includes "archive_id = ?" -- callers prepend that.
# Used by the row-fetch primitives both backends layer on top of.
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
# scope_kind / scope_id pair. Used to pick FK column values.
sub _scope_fk_values {
    my ($self, $scope_kind, $scope_id) = @_;
    my %v = (run_id => undef, service_id => undef, job_try_id => undef);
    if    ($scope_kind eq 'run')     { $v{run_id}     = $scope_id }
    elsif ($scope_kind eq 'service') { $v{service_id} = $scope_id }
    elsif ($scope_kind eq 'job_try') { $v{job_try_id} = $scope_id }
    elsif ($scope_kind eq 'archive') { }
    else { croak "unknown scope_kind: $scope_kind" }
    return \%v;
}

# Streaming zstd decompress: events files are multi-frame, whole-file
# snapshots are single-frame. Concat-decoded payloads are correct
# either way. Pure zstd plumbing; no DB or flavor coupling.
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

# DB-backed Logs do not have a per-artifact filesystem path. Callers
# wanting on-disk bytes must extract() into a directory first, or use
# the Artifact handle's API to read bytes through the backend.
sub absolute_path {
    my ($self, $rel) = @_;
    croak "absolute_path is unavailable for the DB backend; "
        . "extract first or read via the Log API ($rel)";
}

# ----- role-provided archive-shaped methods -----

# artifacts(...) -- factory for App::Yath2::Log::Artifact handles.
# Pure arg-parsing + base-path construction; the per-row DB lookups
# happen later when the Artifact is queried. Both backends supply the
# same has_run / has_job / has_try / has_service / last_try natively
# so this orchestration runs unchanged on either.
#
# Accepted shapes:
#   ()                         archive-root handle
#   ({key => val, ...})        hashref -- accepts service / run_id /
#                              job_id / job_try
#   ($run_id)                  positional shorthand
#   ($service_name)            positional shorthand (when has_service)
#   ($run_id, $service_name)   run-scoped service
#   ($run_id, $job_id)         job at last_try
#   ($run_id, $job_id, $try)   specific job try
sub artifacts {
    my $self = shift;

    return $self->_artifacts_from_args($_[0]) if @_ == 1 && ref($_[0]) eq 'HASH';
    return $self->_artifacts_root             unless @_;

    my @args = @_;
    if (@args == 1) {
        my $arg = $args[0];
        if (defined $arg && $arg =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $arg});
        }
        if (defined $arg && $self->has_service($arg)) {
            return $self->_artifacts_from_args({service => $arg});
        }
        return $self->_artifacts_from_args({run_id => $arg});
    }
    if (@args == 2) {
        my ($run_id, $second) = @args;
        if (defined $second && $second =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $run_id, job_id => $second});
        }
        return $self->_artifacts_from_args({run_id => $run_id, service => $second});
    }
    if (@args == 3) {
        my ($run_id, $job_id, $job_try) = @args;
        return $self->_artifacts_from_args({
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job_try,
        });
    }
    croak "artifacts() got too many positional arguments";
}

sub _artifacts_root {
    my $self = shift;
    require App::Yath2::Log::Artifact;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => undef,
        base => undef,
        live => 0,
    );
}

sub _make_artifact {
    my ($self, $base) = @_;
    require App::Yath2::Log::Artifact;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => undef,
        base => $base,
        live => 0,
    );
}

sub _artifacts_from_args {
    my ($self, $args) = @_;
    my $service = $args->{service};
    my $run_id  = $args->{run_id};
    my $job_id  = $args->{job_id};
    my $job_try = $args->{job_try};

    croak "service name cannot start with a digit"
        if defined $service && $service =~ /^\d/;

    if (defined $service) {
        if (defined $run_id) {
            croak "no such run: $run_id" unless $self->has_run($run_id);
            croak "no such service: $service in run $run_id"
                unless $self->has_service($service, $run_id);
            return $self->_make_artifact(service_run_dir($run_id, $service));
        }
        croak "no such service: $service"
            unless $self->has_service($service);
        return $self->_make_artifact(service_global_dir($service));
    }

    if (defined $job_id) {
        croak "run_id is required when job_id is given"
            unless defined $run_id;
        croak "no such run: $run_id"          unless $self->has_run($run_id);
        croak "no such job: $run_id/$job_id"  unless $self->has_job($run_id, $job_id);

        if (!defined $job_try) {
            my $lt = $self->last_try($run_id, $job_id);
            croak "no tries for job $run_id/$job_id"
                unless defined $lt;
            $job_try = $lt;
        }
        croak "no such try: $run_id/$job_id/$job_try"
            unless $self->has_try($run_id, $job_id, $job_try);

        return $self->_make_artifact(job_dir($run_id, $job_id, $job_try));
    }

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        return $self->_make_artifact(run_dir($run_id));
    }

    return $self->_artifacts_root;
}

# list_files() -- enumerate every artifact in this archive as an
# on-disk-relative path. Drives extract/archive serialization and the
# `inspect` CLI. Pure orchestration on top of _artifact_rows_for_archive.
sub list_files {
    my $self = shift;
    my $aid = $self->_archive_id_or_die;
    my @paths;
    for my $row (@{ $self->_artifact_rows_for_archive($aid) }) {
        my $base = $self->_base_for_artifact_row($row);
        next unless defined $base;
        my $stem = $self->_stem_for_artifact_row($row);
        next unless defined $stem;
        my $rel = length $base ? "$base/$stem" : $stem;
        $rel .= '.zst' if $row->{compressed};
        push @paths => $rel;
    }
    return @paths;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::DB::Backend - the role yath DB-archive backends consume.

=head1 SYNOPSIS

    package MyBackend;
    use Role::Tiny::With;
    # ... define every required method ...
    with 'App::Yath2::Role::DB::Backend';

=head1 DESCRIPTION

The role L<App::Yath2::Log::DB> depends on. Two implementations satisfy
it: L<App::Yath2::DB::Internal> (raw SQL) and L<App::Yath2::DB::DBIC>
(DBIx::Class).

=head1 REQUIRED METHODS

=head2 Group A -- per-archive (require resolved uuid)

C<services>, C<runs>, C<jobs>, C<tries>, C<last_try>,
C<has_service>, C<has_run>, C<has_job>, C<has_try>,
C<artifacts>, C<event>, C<events>, C<end_of_events>, C<reset>,
C<list_files>, C<extract>, C<archive>, C<insert>.

=head2 Group B -- multi-archive

C<archives>, C<archive_count>, C<has_archive>, C<scoped>, C<flavor>,
C<dbh>.

=head1 PROVIDED METHODS

=over 4

=item bootstrap_schema()

Reads C<share/schema/$flavor.sql>, runs C<preprocess_schema_sql>,
splits, executes. Idempotent. DBIC's C<deploy()> is never called.

=item preprocess_schema_sql($sql)

Default identity. Consumers override for flavor quirks.

=item schema_file()

Locates C<share/schema/$flavor.sql> in the dev tree first, then the
installed share dir.

=item _is_bootstrapped()

Probes for the C<archives> table.

=back

=cut
