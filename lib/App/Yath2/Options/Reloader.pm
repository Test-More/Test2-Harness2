package App::Yath2::Options::Reloader;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Getopt::Yath;

use Importer Importer => 'import';
our @EXPORT_OK = qw/resolve_reloader_class/;

option_group {group => 'reloader', category => "Reloader Options"} => sub {
    option backend => (
        type           => 'Scalar',
        name           => 'reloader',
        long_examples  => [' mstat', ' inotify', ' none'],
        short_examples => [' mstat', ' inotify', ' none'],
        description    => "Hot-reload backend for preloaded modules. " . "'mstat' polls mtime via Time::HiRes::stat, 'inotify' " . "uses Linux::Inotify2 (Linux-only), 'none' disables " . "the reloader.",
        default        => sub { 'none' },
        normalize      => sub {
            my ($v) = @_;
            return $v unless defined $v && length $v;
            my $lc = lc $v;
            croak "--reloader must be one of: mstat, inotify, none (got '$v')"
                unless $lc eq 'mstat' || $lc eq 'inotify' || $lc eq 'none';
            return $lc;
        },
    );
};

# Map a normalized backend name to its concrete reloader class, or
# undef when no reloader should be installed. Used by test / start /
# run when building Resource::Preload entries.
sub resolve_reloader_class {
    my ($backend) = @_;
    return undef unless defined $backend && length $backend;
    $backend = lc $backend;
    return undef if $backend eq 'none';
    return 'Test2::Harness2::Reloader::HiResStat' if $backend eq 'mstat';
    return 'Test2::Harness2::Reloader::INotify'   if $backend eq 'inotify';
    croak "Unknown --reloader backend '$backend'";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Reloader - C<--reloader> CLI option.

=head1 DESCRIPTION

Defines the C<--reloader=mstat|inotify|none> option group. Default
C<none>. Commands that build preload resources
(C<App::Yath2::Command::test|start|run>) call
C<resolve_reloader_class($settings-E<gt>reloader-E<gt>backend)> and
pass the resulting class (or undef) into the
L<Test2::Harness2::Resource::Preload> constructor.

=cut
