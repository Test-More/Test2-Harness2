package App::Yath2::Util::Log;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Temp qw/tempdir/;

use App::Yath2::Log;
use App::Yath2::Log::TarZIdx;

# Open a Log for a path, returning a backend that supports the new
# reader API (services / runs / jobs / tries / artifacts / event /
# EOE). The TarZIdx backend's new-API methods are not yet implemented
# (M2 step 13), so when given a tar.zidx file we extract to a temp
# directory and return a Directory backend pointing at that tree.
#
# Returns ($log, $cleanup) where $cleanup is a Scope::Guard-like
# coderef the caller invokes to remove any temporary directory we
# created (no-op when the path was already a directory). When called
# in scalar context only $log is returned; the temp directory is
# CLEANUP=>1 and dies with the process.
#
# Croaks if $path is missing or unrecognized.
sub open_log {
    my ($path, %opts) = @_;
    croak "path is required" unless defined $path && length $path;
    croak "path '$path' does not exist" unless -e $path;

    # Directory: straight to Directory backend.
    if (-d $path) {
        my $log = App::Yath2::Log->new(dir => $path);
        return wantarray ? ($log, sub { 1 }) : $log;
    }

    croak "path '$path' is not a file or directory" unless -f $path;

    # File: detect kind. SQLite is not implemented yet (M2 step 14);
    # tar.zidx we extract to a tempdir to access via Directory.
    my $kind = App::Yath2::Log->_detect_file_kind($path);

    if ($kind eq 'sqlite') {
        croak "App::Yath2::Log::Sqlite not yet implemented (M2 step 14): $path";
    }
    if ($kind ne 'tar.zidx') {
        croak "Unable to identify '$path' as a yath log archive (not sqlite or tar.zidx)";
    }

    my $tmp = tempdir(CLEANUP => 1, TEMPLATE => 'yath-log-XXXXXX', TMPDIR => 1);
    my $arc = App::Yath2::Log::TarZIdx->new(path => $path);
    $arc->extract($tmp);

    my $log = App::Yath2::Log->new(dir => $tmp);
    my $cleanup = sub {
        require File::Path;
        File::Path::remove_tree($tmp, {safe => 1});
    };
    return wantarray ? ($log, $cleanup) : $log;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Util::Log - Open a yath log for the new reader API.

=head1 DESCRIPTION

Helper that wraps L<App::Yath2::Log> for callers that want to read a
log via the new reader API regardless of whether the source path is
a directory, a tar.zidx archive, or a sqlite-as-file archive. Tar
archives are transparently extracted to a tempdir and accessed via
the Directory backend; sqlite is rejected until L<App::Yath2::Log::Sqlite>
lands.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
