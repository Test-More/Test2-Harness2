package App::Yath2::DB::SQL;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <dsn <user <pass <attrs <dbh <file
    <flavor
    +_is_mariadb
};

# Phase 0 skeleton. Method bodies land in Phases 2 (read) and 5
# (write) of the DB rebuild
# (AI_DOCS/2026-05-08-yath-db-rebuild.md). Replaces the per-flavor
# App::Yath2::DB::Internal::* tree with a single class whose methods
# branch on $self->flavor where flavor differences matter (UUID bind,
# bytea, MariaDB trigger skip).
#
# Role::DB::Backend consumption deferred until Phase 9 when the role
# contract swaps from the legacy Internal-shaped requires-list to the
# new primitive list. Until then SQL is a free-standing class with the
# new method names declared directly.

sub init {
    my $self = shift;
    croak "App::Yath2::DB::SQL is a Phase 0 skeleton; "
        . "Phases 2 (read) and 5 (write) fill in the body";
}

# Stubs for the new primitive contract. Phases 2 / 5 replace each
# stub with a real implementation. Listed in dependency order.

# --- Archive layer (Phase 2 read; Phase 5 write)
sub archive_rows         { croak 'NYI: archive_rows' }
sub archive_for_uuid     { croak 'NYI: archive_for_uuid' }
sub archive_count        { croak 'NYI: archive_count' }
sub archive_create       { croak 'NYI: archive_create' }
sub mark_sealed          { croak 'NYI: mark_sealed' }

# --- Run / job / service / try (Phase 2)
sub run_rows             { croak 'NYI: run_rows' }
sub service_rows         { croak 'NYI: service_rows' }
sub job_rows             { croak 'NYI: job_rows' }
sub try_rows             { croak 'NYI: try_rows' }

sub run_exists           { croak 'NYI: run_exists' }
sub job_exists           { croak 'NYI: job_exists' }
sub try_exists           { croak 'NYI: try_exists' }
sub service_exists       { croak 'NYI: service_exists' }

sub run_id_for_ord       { croak 'NYI: run_id_for_ord' }
sub job_id_for_ord       { croak 'NYI: job_id_for_ord' }
sub try_id_for_ord       { croak 'NYI: try_id_for_ord' }
sub service_id_for_name  { croak 'NYI: service_id_for_name' }

# --- Find-or-create (Phase 5)
sub ensure_run_row       { croak 'NYI: ensure_run_row' }
sub ensure_service_row   { croak 'NYI: ensure_service_row' }
sub ensure_job_row       { croak 'NYI: ensure_job_row' }
sub ensure_job_try_row   { croak 'NYI: ensure_job_try_row' }
sub ensure_test_file_row { croak 'NYI: ensure_test_file_row' }
sub ensure_project_row   { croak 'NYI: ensure_project_row' }

# --- Artifacts (Phase 2 read; Phase 5 write)
sub artifact_rows_for_archive { croak 'NYI: artifact_rows_for_archive' }
sub artifact_row_for_scope    { croak 'NYI: artifact_row_for_scope' }
sub artifact_payload          { croak 'NYI: artifact_payload' }
sub artifact_create           { croak 'NYI: artifact_create' }
sub artifact_update           { croak 'NYI: artifact_update' }

# --- Spec / report data layer (Phase 2 read; Phase 5 write)
sub job_spec_rows         { croak 'NYI: job_spec_rows' }
sub service_lifetime_rows { croak 'NYI: service_lifetime_rows' }
sub subtest_rows          { croak 'NYI: subtest_rows' }

sub job_spec_create         { croak 'NYI: job_spec_create' }
sub service_lifetime_create { croak 'NYI: service_lifetime_create' }
sub subtest_create          { croak 'NYI: subtest_create' }

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
(L<AI_DOCS/2026-05-08-yath-db-rebuild.md>). Flavor differences are
handled inside individual methods.

=head1 STATUS

Phase 0 skeleton. Method bodies land in Phases 2 (read) and 5 (write).

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
