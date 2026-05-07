package App::Yath2::Log::Artifact;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Harness2::Util::Zstd qw/compress_blob decompress_blob/;

use App::Yath2::Log::Iterator::JSONL;

use Object::HashBase qw{
    <log
    <base
    <live
    <root
};

# Handle for a single collector's artifact group (or the archive root
# when constructed with base=undef). Returned by
# L<App::Yath2::Log/artifacts>. Provides the new reader API:
#
#   $a->events / $a->events_zst / $a->events_iter
#   $a->spec   / $a->spec_zst   / $a->spec_iter
#   $a->report / $a->report_zst / $a->report_iter
#   $a->attachment($name, %opts)
#   $a->attachments
#   $a->exists($filename)
#   $a->get($filename, %opts)
#   $a->save($filename, $content, compress => $bool, force_no_overwrite => $bool)
#
# Required attributes:
#
#   log   The owning Log backend. Provides the read primitives the
#         handle delegates to:
#           $log->_artifact_exists($rel)        -> ($exists, $is_zst)
#           $log->_artifact_read($rel)          -> $bytes (compressed if .zst)
#           $log->_artifact_iter_records($stem) -> records-backed iterator
#                                                  (or undef -> file-backed)
#           $log->_artifact_list_dir($rel)      -> sorted basenames
#           $log->absolute_path($rel)           -> abs path or croak
#         Directory implements these against the filesystem; TarZIdx
#         implements them against the archive's index.
#   base  Relative path under the log root for this artifact group, or
#         undef when the handle targets the archive root.
#   live  Boolean -- true when the underlying source is a live workdir.
#         Forwarded to per-file iterators.
#   root  Absolute filesystem path of the log root (Directory) or the
#         archive file path (TarZIdx). Used by save() on filesystem-backed
#         backends; may be undef on archive-only backends where save is
#         not supported.

sub init {
    my $self = shift;
    croak "'log' is a required attribute"
        unless defined $self->{+LOG};
    $self->{+LIVE} //= 0;
    # base may be undef for archive-root handles.
    # root may be undef for archive-only backends.
    return;
}

# Compose an artifact-relative path under this handle's base.
sub _rel {
    my ($self, $rel) = @_;
    my $base = $self->{+BASE};
    if (defined $base && length $base) {
        return "$base/$rel";
    }
    return $rel;
}

# Resolve $stem ('events.jsonl' / 'spec.jsonl' / 'report.jsonl') to
# the on-disk variant that exists. Returns ($rel, $is_zst) or () when
# neither variant is present. Prefers the .zst variant.
sub _resolve_jsonl {
    my ($self, $stem) = @_;
    my $log = $self->{+LOG};

    my $rel_zst = $self->_rel("$stem.zst");
    my ($exists_zst) = $log->_artifact_exists($rel_zst);
    return ($rel_zst, 1) if $exists_zst;

    my $rel_plain = $self->_rel($stem);
    my ($exists_plain) = $log->_artifact_exists($rel_plain);
    return ($rel_plain, 0) if $exists_plain;

    return ();
}

sub _root_only {
    my $self = shift;
    return !defined($self->{+BASE}) || $self->{+BASE} eq '';
}

# events / spec / report -- decompressed bytes of the .jsonl(.zst).
sub events { $_[0]->_read_jsonl_bytes('events.jsonl', 0) }
sub spec   { $_[0]->_read_jsonl_bytes('spec.jsonl',   0) }
sub report { $_[0]->_read_jsonl_bytes('report.jsonl', 0) }

# events_zst / spec_zst / report_zst -- compressed bytes (zstd
# stream). When the on-disk file is plaintext we synthesize a
# compressed copy.
sub events_zst { $_[0]->_read_jsonl_bytes('events.jsonl', 1) }
sub spec_zst   { $_[0]->_read_jsonl_bytes('spec.jsonl',   1) }
sub report_zst { $_[0]->_read_jsonl_bytes('report.jsonl', 1) }

# events_iter / spec_iter / report_iter
sub events_iter { $_[0]->_jsonl_iter('events.jsonl') }
sub spec_iter   { $_[0]->_jsonl_iter('spec.jsonl') }
sub report_iter { $_[0]->_jsonl_iter('report.jsonl') }

sub _read_jsonl_bytes {
    my ($self, $stem, $want_compressed) = @_;

    croak "events / spec / report are not valid on archive-root artifacts handle"
        if $self->_root_only;

    my ($rel, $is_zst) = $self->_resolve_jsonl($stem);
    croak "no $stem found under " . ($self->{+BASE} // '')
        unless defined $rel;

    my $log = $self->{+LOG};
    my $bytes = $log->_artifact_read($rel);

    if ($want_compressed) {
        return $bytes if $is_zst;
        return compress_blob($bytes);
    }

    return $bytes unless $is_zst;

    # zstd_jsonl_decompress: events files are multi-frame; whole-file
    # snapshots are single-frame. Either way concat-decoded payloads
    # are correct. Use a streaming reader so multi-frame works without
    # a separate code path.
    return $log->_decompress_jsonl_bytes($bytes);
}

sub _jsonl_iter {
    my ($self, $stem) = @_;

    croak "events_iter / spec_iter / report_iter are not valid on archive-root artifacts handle"
        if $self->_root_only;

    my $log = $self->{+LOG};

    # Backend may want to short-circuit with a records-backed iterator
    # (e.g. TarZIdx already has the bytes in memory).
    if (my $records = $log->_artifact_iter_records($self->{+BASE}, $stem)) {
        return App::Yath2::Log::Iterator::JSONL->new(records => $records);
    }

    my ($rel, $is_zst) = $self->_resolve_jsonl($stem);
    # An iterator pointing at a non-existent file is allowed -- it
    # just produces no records. The Reader handles -e checks itself.
    $rel //= $self->_rel("$stem.zst");

    my $abs = $log->absolute_path($rel);
    return App::Yath2::Log::Iterator::JSONL->new(
        path => $abs,
        live => $self->{+LIVE},
    );
}

# attachment($name, %opts) -- bytes (default uncompressed). Options:
#   compressed => 1   (return raw .zst-compressed bytes if the file
#                      is compressed; otherwise return plain bytes)
#   filehandle => 1   (return an open filehandle instead of bytes)
sub attachment {
    my ($self, $name, %opts) = @_;
    croak "attachment is not valid on archive-root artifacts handle"
        if $self->_root_only;
    croak "attachment name is required" unless defined $name && length $name;

    return $self->_read_under('attachments', $name, %opts);
}

# Names of available attachments under <base>/attachments/. Strips
# the trailing '.zst' suffix when present so callers see logical
# names (matching what the writer used).
sub attachments {
    my $self = shift;
    croak "attachments is not valid on archive-root artifacts handle"
        if $self->_root_only;

    my $log    = $self->{+LOG};
    my $relbase = $self->_rel('attachments');

    my @entries = $log->_artifact_list_dir($relbase);
    my %names;
    for my $entry (@entries) {
        $entry =~ s{\.zst\z}{};
        $names{$entry} = 1;
    }
    return sort keys %names;
}

# Boolean -- does the named file exist under this artifact's base
# dir? Looks at exactly the path the caller asked for, plus the
# .zst variant.
sub exists {
    my ($self, $rel) = @_;
    croak "filename is required" unless defined $rel && length $rel;

    my $log = $self->{+LOG};
    my $full = $self->_rel($rel);

    my ($e1) = $log->_artifact_exists($full);
    return 1 if $e1;
    my ($e2) = $log->_artifact_exists("$full.zst");
    return 1 if $e2;
    return 0;
}

# Generic get($filename, %opts). Same options as attachment().
sub get {
    my ($self, $rel, %opts) = @_;
    croak "filename is required" unless defined $rel && length $rel;
    return $self->_read_under(undef, $rel, %opts);
}

# Internal: read $rel under the artifact base (optionally inside
# $subdir). Honors compressed / filehandle options.
sub _read_under {
    my ($self, $subdir, $rel, %opts) = @_;

    my $log = $self->{+LOG};
    my $relpath = defined $subdir ? "$subdir/$rel" : $rel;
    my $full = $self->_rel($relpath);

    my ($exists_plain, $plain_is_zst) = $log->_artifact_exists($full);
    my ($exists_zst, undef)            = $log->_artifact_exists("$full.zst");

    my ($pick_rel, $is_zst);
    if ($exists_plain) {
        $pick_rel = $full;
        $is_zst   = $plain_is_zst;
    }
    elsif ($exists_zst) {
        $pick_rel = "$full.zst";
        $is_zst   = 1;
    }
    else {
        croak "no such file: $relpath";
    }

    if ($opts{filehandle}) {
        return $log->_artifact_open_fh($pick_rel);
    }

    my $bytes = $log->_artifact_read($pick_rel);

    return $bytes if $opts{compressed};
    return $bytes unless $is_zst;
    return decompress_blob($bytes);
}

# save($filename, $content, %opts).
#
# Options:
#
#   compress           => $bool   (override per-backend default)
#   force_no_overwrite => $bool   (croak if file already exists)
#
# Returns the absolute on-disk path on success; throws on failure.
sub save {
    my ($self, $rel, $content, %opts) = @_;
    croak "filename is required"          unless defined $rel && length $rel;
    croak "content (third arg) is required" unless defined $content;

    croak "filename must not contain '..'" if $rel =~ m{(?:\A|/)\.\.(?:\z|/)};

    my $log = $self->{+LOG};
    croak "save is not supported on this Log backend"
        unless $log->can('_artifact_save');

    my $compress = exists $opts{compress}
        ? $opts{compress}
        : ($self->{+LIVE} ? 1 : 0);

    my $force_no_overwrite = $opts{force_no_overwrite} ? 1 : 0;

    my $rel_target = $compress ? "$rel.zst" : $rel;
    my $full = $self->_rel($rel_target);

    return $log->_artifact_save(
        rel                => $full,
        rel_alt            => $self->_rel($rel),
        rel_alt_zst        => $self->_rel("$rel.zst"),
        bytes              => $content,
        compress           => $compress,
        force_no_overwrite => $force_no_overwrite,
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Artifact - Handle for a collector's artifact group.

=head1 DESCRIPTION

Returned by L<App::Yath2::Log/artifacts>. Each handle targets one
collector's base directory (or the archive root when constructed
with no selector). Provides decoded / compressed / iterator forms of
the standard trio (events.jsonl.zst, spec.jsonl.zst,
report.jsonl.zst) plus generic file access (attachment, exists, get,
save).

The handle delegates all I/O to the owning Log backend via the
backend's C<_artifact_exists> / C<_artifact_read> /
C<_artifact_iter_records> / C<_artifact_list_dir> / C<_artifact_save>
methods. This keeps the handle backend-agnostic: directory and
tar.zidx and (eventually) SQLite all surface the same handle API
even though their underlying storage is different.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
