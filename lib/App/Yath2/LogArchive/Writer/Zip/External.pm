package App::Yath2::LogArchive::Writer::Zip::External;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

with 'App::Yath2::LogArchive::Role::Writer';

use constant ZIP_BIN => scalar can_run('zip');

sub viable { defined ZIP_BIN }

sub write_archive {
    my $self = shift;

    my $bin = ZIP_BIN or croak "no zip binary";
    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $pid = fork // die "fork: $!";
    unless ($pid) {
        chdir $src or die "chdir $src: $!";
        open(STDOUT, '>', '/dev/null');
        exec $bin, '-r', '-q', $tmp, '.';
        die "exec zip: $!";
    }
    waitpid $pid, 0;
    croak "zip exited $?" if $?;

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;
