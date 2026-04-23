package Test2::Harness2::Reloader;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Harness2::Util::HashBase qw{
    <restrict
    <stage
    <in_place
    <_watches
    <_started
};

BEGIN {
    local $@;
    my $ok  = eval { require Linux::Inotify2; 1 };
    my $err = $@;
    if ($ok) {
        *USE_INOTIFY = sub() { 1 };
    }
    else {
        *USE_INOTIFY = sub() { 0 };
    }
}

{
    no warnings 'redefine';
    my $oldnew = \&new;
    *new = sub {
        my $class = shift;

        if ($class eq __PACKAGE__) {
            if (USE_INOTIFY) {
                require Test2::Harness2::Reloader::Inotify2;
                $class = 'Test2::Harness2::Reloader::Inotify2';
            }
            else {
                require Test2::Harness2::Reloader::Stat;
                $class = 'Test2::Harness2::Reloader::Stat';
            }
        }

        unshift @_ => $class;
        goto &$oldnew;
    };
}

sub init {
    my $self = shift;

    $self->{+RESTRICT} //= [];
    $self->{+_WATCHES} //= {};
    $self->{+_STARTED} //= 0;
}

sub changed_files { croak ref($_[0]) . " does not implement 'changed_files'" }

sub do_watch { croak ref($_[0]) . " does not implement 'do_watch'" }

sub watch {
    my $self = shift;
    my ($file, $cb) = @_;

    croak "The first argument must be a file path" unless $file;

    my $watches = $self->{+_WATCHES} //= {};
    $watches->{$file} = $cb;

    if ($self->{+_STARTED}) {
        $self->do_watch($file);
    }
}

sub start {
    my $self = shift;

    $self->{+_STARTED} = 1;

    my $watches = $self->{+_WATCHES} //= {};
    for my $file (keys %$watches) {
        $self->do_watch($file);
    }
}

1;
