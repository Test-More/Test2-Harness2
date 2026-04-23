package App::Yath2::LogArchive::Writer::SevenZip;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

with 'App::Yath2::LogArchive::Role::Writer';

use constant SEVENZ_BIN => scalar can_run('7z');

sub viable { defined SEVENZ_BIN }

sub write_archive {
    my $self = shift;

    my $bin = SEVENZ_BIN or croak "no 7z binary";
    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $pid = fork // die "fork: $!";
    unless ($pid) {
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec $bin, 'a', $tmp, "$src/.";
        die "exec 7z: $!";
    }
    waitpid $pid, 0;
    croak "7z exited $?" if $?;

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;
