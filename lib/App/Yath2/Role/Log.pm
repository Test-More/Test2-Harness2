package App::Yath2::Role::Log;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Role::Tiny;

# The formal contract every yath Log backend consumes. Today
# implemented by App::Yath2::Log::Live, App::Yath2::Log::Directory,
# App::Yath2::Log::TarZIdx, and App::Yath2::Log::DB.
#
# Phase 1 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md §6)
# introduces this role. The required-method list is the union of
# every method any current Log backend exposes publicly plus the
# private _artifact_* family that App::Yath2::Log::Artifact calls
# back into.

requires qw{
    services runs jobs tries last_try
    has_service has_run has_job has_try

    artifacts
    list_files

    event events end_of_events reset

    extract archive

    absolute_path

    _artifact_exists _artifact_read _artifact_iter_records
    _artifact_list_dir _artifact_open_fh _artifact_save
};

# ----- Defaults -----
#
# Acceptable role-level defaults: methods whose body is genuinely
# uniform across every Log consumer. Consumers may still override
# (Live overrides is_live/static, Directory/TarZIdx override
# _decompress_jsonl_bytes for slight performance/dependency reasons,
# Log::DB overrides insert).

# Most Logs are static (sealed); only Live wants is_live=1 / static=0.
sub is_live { 0 }
sub static  { 1 }

# EOE is just "did end_of_events return true?" everywhere. Each
# consumer implements end_of_events; this surfaces it under the
# shorter alias.
sub EOE { $_[0]->end_of_events }

# Pure zstd plumbing: walk a possibly-multi-frame zstd byte string and
# return the concatenated plaintext. Identical across all consumers
# (events.jsonl is multi-frame; whole-file snapshots are single-frame;
# concat-decoding is correct either way). Consumers may override with
# a slightly cheaper implementation when they already loaded the zstd
# dependencies.
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

# insert($source_log) reverses the data flow: it is the DB-backed
# logs' way of importing another archive. Filesystem-shaped backends
# (Directory / Live / TarZIdx) cannot serve as an insert sink, so the
# default croaks. App::Yath2::Log::DB overrides with a real
# implementation that delegates to its underlying App::Yath2::DB
# backend.
sub insert {
    my $self = shift;
    my $class = ref($self) || $self;
    croak "insert is only available on DB-backed Logs (this is $class); "
        . "use \$db->insert(\$source_log) instead";
}

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
