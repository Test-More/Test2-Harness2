package App::Yath2::Options::Reloader;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Getopt::Yath;

option_group {group => 'reloader', category => "Reloader Options"} => sub {
    option backend => (
        type           => 'Scalar',
        name           => 'reloader',
        long_examples  => [' mstat', ' inotify', ' none'],
        short_examples => [' mstat', ' inotify', ' none'],
        description    => "Hot-reload backend for preloaded modules. 'mstat' polls mtime via Time::HiRes::stat, 'inotify' uses Linux::Inotify2 (Linux-only), 'none' disables the reloader.",
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Reloader - C<--reloader> CLI option.

=head1 DESCRIPTION

Defines the C<--reloader=mstat|inotify|none> option group. Default
C<none>. Backend resolution and reloader-class lookup live in
L<App::Yath2::Preload> (see C<resolve_reloader_class>).

=cut
