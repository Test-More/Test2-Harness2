package App::Yath2::Role::DB::Backend;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename ();
use File::Spec ();

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
    run_exists job_exists try_exists service_exists
    run_id_for_ord job_id_for_ord try_id_for_ord service_id_for_name

    ensure_project_row ensure_test_file_row ensure_run_row
    ensure_service_row ensure_job_row ensure_job_try_row

    artifact_rows_for_archive artifact_row_for_scope artifact_payload
    artifact_create artifact_update artifact_event_count_for_archive

    job_spec_rows service_lifetime_rows subtest_rows
    job_spec_create service_lifetime_create subtest_create
};

# Default identity preprocessor. Consumers override for flavor quirks
# (e.g., App::Yath2::DB::SQL strips COMPRESSION lz4 from the Postgres
# schema when the server build lacks it).
sub preprocess_schema_sql { $_[1] }

# Per-statement skip hook. Default: never skip. Consumers override for
# flavor quirks where individual schema statements must be elided at
# bootstrap time (e.g., App::Yath2::DB::SQL on MySQL skips CREATE
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
