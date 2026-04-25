package App::Yath2::LogArchive;
use strict;
use warnings;

use Carp qw/croak/;
use File::Spec ();

use App::Yath2::LogArchive::Format qw/detect_format reader_class_for writer_class_for/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Zstd qw/decompress_blob/;

sub new {
    my ($class, %args) = @_;

    if ($class eq __PACKAGE__) {
        my $path          = $args{path} // croak "path is required";
        my $format        = detect_format($path);
        my $backend_class = reader_class_for($format);
        return $backend_class->new(%args, format => $format);
    }

    my $self = bless {%args}, $class;
    $self->init if $self->can('init');
    return $self;
}

sub create {
    my ($class, %args) = @_;
    my $source = $args{source} // croak "source is required";
    croak "source '$source' is not a directory" unless -d $source;

    my $format = $args{format} // 'tar.bz2';
    $args{path} // croak "path is required";

    my $writer_class = writer_class_for($format);
    return $writer_class->new(%args, format => $format)->write_archive;
}

# Shared high-level API. Backends inherit this.

sub artifacts {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    my $rel = defined $run_id ? "runs/$run_id/artifacts.json.zst" : 'artifacts.json.zst';
    return {} unless $self->has_file($rel);

    my $fh   = $self->read_file($rel);
    my $bytes = do { local $/; <$fh> };
    close $fh;

    my $dict_bytes = $self->can('dict_bytes') ? $self->dict_bytes : undef;
    my $json = decompress_blob(
        $bytes,
        ($dict_bytes ? (dict_bytes => $dict_bytes) : ()),
    );
    return decode_json($json);
}

sub runs {
    my ($self, %opts) = @_;

    my %runs;
    for my $path ($self->list_files) {
        next unless $path =~ m{^runs/([^/]+)/};
        my $id = $1;
        if ($opts{include_empty}) {
            $runs{$id} = 1;
        }
        else {
            $runs{$id} = 1 if $path eq "runs/$id/artifacts.json.zst";
        }
    }
    return sort keys %runs;
}

sub services {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    my $art    = $self->artifacts(defined $run_id ? ($run_id) : ());
    my $prefix = defined $run_id ? "runs/$run_id/services/" : 'services/';

    my %names;
    for my $key (keys %$art) {
        next unless $key =~ m{^\Q$prefix\E([^/.]+)\.[^/]+\z};
        $names{$1} = 1;
    }
    return sort keys %names;
}

sub rogue_files {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    my $manifest = $self->artifacts(defined $run_id ? ($run_id) : ());
    my %known    = map { $_ => 1 } keys %$manifest;

    my @all = $self->list_files;
    my @rogue;
    if (defined $run_id) {
        my $prefix = "runs/$run_id/";
        for my $f (@all) {
            next unless index($f, $prefix) == 0;
            next if $f eq "${prefix}artifacts.json.zst";
            next if $known{$f};
            push @rogue => $f;
        }
    }
    else {
        for my $f (@all) {
            next if $f =~ m{^runs/};
            next if $f eq 'artifacts.json.zst';
            next if $f eq 'zstd-dict.bin';
            next if $known{$f};
            push @rogue => $f;
        }
    }
    return sort @rogue;
}

sub _parse_scope_args {
    my ($self, @args) = @_;
    if (@args % 2 == 1) {
        my $run_id = shift @args;
        return ($run_id, @args);
    }
    return (undef, @args);
}

1;
