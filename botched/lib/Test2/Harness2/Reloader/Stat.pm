package Test2::Harness2::Reloader::Stat;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use parent 'Test2::Harness2::Reloader';

use Test2::Harness2::Util::HashBase qw{
    <_times
    <_last_check
};

sub init {
    my $self = shift;

    $self->{+_TIMES}      //= {};
    $self->{+_LAST_CHECK} //= 0;

    $self->SUPER::init();
}

sub _get_file_times {
    my $self = shift;
    my ($file) = @_;

    my @stat = stat($file);
    return [$stat[9], $stat[10]];    # mtime, ctime
}

sub do_watch {
    my $self = shift;
    my ($file) = @_;

    $self->{+_TIMES}->{$file} //= $self->_get_file_times($file);
}

sub changed_files {
    my $self = shift;

    my $time  = time();
    my $last  = $self->{+_LAST_CHECK} // 0;
    my $delta = $time - $last;

    return [] if $delta < 1;
    $self->{+_LAST_CHECK} = $time;

    my $watches = $self->{+_WATCHES} // croak "Reloader is not started yet";

    my @out;
    for my $file (keys %$watches) {
        my $new_times = $self->_get_file_times($file);
        my $old_times = $self->{+_TIMES}->{$file} //= $new_times;

        next if $old_times->[0] == $new_times->[0] && $old_times->[1] == $new_times->[1];

        # Update so we do not reload twice for the same change
        $self->{+_TIMES}->{$file} = $new_times;

        push @out => $file;
    }

    return \@out;
}

1;
