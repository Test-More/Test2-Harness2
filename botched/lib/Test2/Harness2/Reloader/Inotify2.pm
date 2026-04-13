package Test2::Harness2::Reloader::Inotify2;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use parent 'Test2::Harness2::Reloader';

use Test2::Harness2::Util::HashBase qw{
    <_watcher
};

# Only import constants if Linux::Inotify2 is available. The module can be
# loaded cleanly even without it; the factory in Reloader.pm won't select it.
my $MASK;
{
    local $@;
    my $ok  = eval { require Linux::Inotify2; 1 };
    my $err = $@;
    if ($ok) {
        Linux::Inotify2->import(qw/IN_MODIFY IN_ATTRIB IN_DELETE_SELF IN_MOVE_SELF/);
        $MASK = Linux::Inotify2::IN_MODIFY() | Linux::Inotify2::IN_ATTRIB() | Linux::Inotify2::IN_DELETE_SELF() | Linux::Inotify2::IN_MOVE_SELF();
    }
}

sub start {
    my $self = shift;

    my $watcher = Linux::Inotify2->new;
    $watcher->blocking(0);
    $self->{+_WATCHER} = $watcher;

    return $self->SUPER::start(@_);
}

sub stop {
    my $self = shift;
    delete $self->{+_WATCHER};
}

sub do_watch {
    my $self = shift;
    my ($file) = @_;

    my $watcher = $self->{+_WATCHER} or return;
    $watcher->watch($file, $MASK);
}

sub changed_files {
    my $self = shift;

    my $watcher = $self->{+_WATCHER} // croak "Reloader is not started yet";

    my @out;
    my %seen;
    my @events = $watcher->read;
    for my $e (@events) {
        my $file = $e->fullname();
        next unless $file;
        next if $seen{$file}++;
        push @out => $file;
    }

    return \@out;
}

1;
