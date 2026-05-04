package App::Yath2::Util::Log;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use App::Yath2::Log;

# Open a Log for a path, returning a backend that supports the new
# reader API (services / runs / jobs / tries / artifacts / event /
# EOE). The dispatcher in App::Yath2::Log handles directory vs
# tar.zidx vs sqlite detection; this helper just normalizes the
# "give me a Log for an arbitrary $path" pattern that commands use.
#
# Returns ($log, $cleanup) where $cleanup is a no-op coderef preserved
# for back-compat with the previous auto-extract version. When called
# in scalar context only $log is returned.
#
# Croaks if $path is missing or unrecognized.
sub open_log {
    my ($path, %opts) = @_;
    croak "path is required" unless defined $path && length $path;
    croak "path '$path' does not exist" unless -e $path;

    my $log;
    if (-d $path) {
        $log = App::Yath2::Log->new(dir => $path);
    }
    elsif (-f $path) {
        $log = App::Yath2::Log->new(file => $path);
    }
    else {
        croak "path '$path' is not a file or directory";
    }

    my $cleanup = sub { 1 };
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
a directory, a tar.zidx archive, or a sqlite-as-file archive. All
backends are now driven directly through their native primitives;
no auto-extract is required.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
