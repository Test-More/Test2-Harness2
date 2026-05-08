package App::Yath2::Role::Log;
use strict;
use warnings;

our $VERSION = '2.000012';

use Role::Tiny;

# The formal contract every yath Log backend consumes. Today
# implemented by App::Yath2::Log::Live, App::Yath2::Log::Directory,
# App::Yath2::Log::TarZIdx, and App::Yath2::Log::DB.
#
# Phase 1 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md)
# introduces this role. The required-method list is the union of
# every method any current Log backend exposes publicly plus the
# private _artifact_* family that App::Yath2::Log::Artifact calls
# back into.

requires qw{
    is_live static

    services runs jobs tries last_try
    has_service has_run has_job has_try

    artifacts
    list_files

    event events end_of_events EOE reset

    extract archive insert

    absolute_path

    _artifact_exists _artifact_read _artifact_iter_records
    _artifact_list_dir _artifact_open_fh _artifact_save
    _decompress_jsonl_bytes
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Log - the contract every yath Log backend consumes.

=head1 DESCRIPTION

A L<Role::Tiny> role enumerating the public Log API plus the private
helpers L<App::Yath2::Log::Artifact> calls back into the owning Log.

Consumers: L<App::Yath2::Log::Live>, L<App::Yath2::Log::Directory>,
L<App::Yath2::Log::TarZIdx>, L<App::Yath2::Log::DB>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
