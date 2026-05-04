package App::Yath2::Log::Artifact;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/write_file_atomic/;
use Test2::Harness2::Util::Zstd qw/compress_blob decompress_blob open_zstd_reader/;

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
#   log   The owning Log backend (used for is_live, root, save, etc.)
#   base  Relative path under the log root for this artifact group, or
#         undef when the handle targets the archive root.
#   live  Boolean -- true when the underlying source is a live workdir.
#         Forwarded to per-file iterators.
#   root  Absolute filesystem path of the log root.

sub init {
    my $self = shift;
    croak "'log' is a required attribute"
        unless defined $self->{+LOG};
    croak "'root' is a required attribute"
        unless defined $self->{+ROOT} && length $self->{+ROOT};
    $self->{+LIVE} //= 0;
    # base may be undef for archive-root handles.
    return;
}

# Compose the full path of $relative under this artifact's base.
sub _abs {
    my ($self, $rel) = @_;
    my $base = $self->{+BASE};
    if (defined $base && length $base) {
        return File::Spec->catfile($self->{+ROOT}, $base, $rel);
    }
    return File::Spec->catfile($self->{+ROOT}, $rel);
}

# Return the on-disk path that exists for $logical (a stem like
# 'events.jsonl' / 'spec.jsonl' / 'report.jsonl'). Prefers the .zst
# variant. Returns (path, is_zst) or () if neither exists.
sub _resolve_jsonl {
    my ($self, $stem) = @_;
    my $zst = $self->_abs("$stem.zst");
    return ($zst, 1) if -f $zst;
    my $plain = $self->_abs($stem);
    return ($plain, 0) if -f $plain;
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

    my ($path, $is_zst) = $self->_resolve_jsonl($stem);
    croak "no $stem found under " . ($self->{+BASE} // '')
        unless defined $path;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh;

    if ($want_compressed) {
        return $bytes if $is_zst;
        return compress_blob($bytes);
    }

    return $bytes unless $is_zst;

    # Multi-frame zstd: open via the streaming reader and concat the
    # decoded payloads. Single-frame would also work via decompress_blob
    # but the reader handles either case uniformly.
    my $r = open_zstd_reader($path);
    my $out = '';
    while (defined(my $frame = $r->readline)) {
        $out .= $frame;
    }
    $r->close;
    return $out;
}

sub _jsonl_iter {
    my ($self, $stem) = @_;

    croak "events_iter / spec_iter / report_iter are not valid on archive-root artifacts handle"
        if $self->_root_only;

    my ($path, $is_zst) = $self->_resolve_jsonl($stem);
    # An iterator pointing at a non-existent file is allowed -- it
    # just produces no records. The Reader handles -e checks itself.
    $path //= $self->_abs("$stem.zst");

    return App::Yath2::Log::Iterator::JSONL->new(
        path => $path,
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

    my $dir = $self->_abs('attachments');
    return () unless -d $dir;

    opendir(my $dh, $dir) or return ();
    my @names;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        next unless -f File::Spec->catfile($dir, $entry);
        $entry =~ s{\.zst\z}{};
        push @names => $entry;
    }
    closedir($dh);
    return sort @names;
}

# Boolean -- does the named file exist under this artifact's base
# dir? Looks at exactly the path the caller asked for, plus the
# .zst variant.
sub exists {
    my ($self, $rel) = @_;
    croak "filename is required" unless defined $rel && length $rel;

    return 1 if -e $self->_abs($rel);
    return 1 if -e $self->_abs("$rel.zst");
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

    my $relpath = defined $subdir ? "$subdir/$rel" : $rel;

    my $abs    = $self->_abs($relpath);
    my $abszst = "$abs.zst";

    my ($path, $is_zst);
    if (-e $abs) {
        ($path, $is_zst) = ($abs, $abs =~ /\.zst\z/ ? 1 : 0);
    }
    elsif (-e $abszst) {
        ($path, $is_zst) = ($abszst, 1);
    }
    else {
        croak "no such file: $relpath";
    }

    if ($opts{filehandle}) {
        open(my $fh, '<', $path) or croak "open '$path': $!";
        binmode $fh;
        return $fh;
    }

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh;

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

    my $compress = exists $opts{compress}
        ? $opts{compress}
        : ($self->{+LIVE} ? 1 : 0);

    my $force_no_overwrite = $opts{force_no_overwrite} ? 1 : 0;

    my $rel_target = $compress ? "$rel.zst" : $rel;
    my $abs        = $self->_abs($rel_target);

    if ($force_no_overwrite) {
        croak "file already exists: $abs" if -e $abs || -e $self->_abs("$rel_target.zst");
    }

    my $par = dirname($abs);
    make_path($par) unless -d $par;

    my $payload = $compress ? compress_blob($content) : $content;
    write_file_atomic($abs, $payload);

    # Drop a stale alternate-form file so future reads pick up the
    # form the caller asked for. (e.g. a save(compress=>1) over a
    # plaintext file should leave only the compressed form.)
    my $other = $compress ? $self->_abs($rel) : $self->_abs("$rel.zst");
    unlink $other if $other ne $abs && -e $other;

    return $abs;
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

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
