package App::Yath2::Plugin::SelfTest;
use strict;
use warnings;

use Test2::Harness2::TestFile;

use IPC::Cmd qw/can_run/;
use parent 'App::Yath2::Plugin';

sub find_files {
    my ($plugin, $run, $search) = @_;

    my $base = "t/Harness/selftest/non_perl";

    return if ($search && !grep { m{^(\./)?\Q$base\E(/.*)?$} } @$search);

    my @out;

    if (can_run('/usr/bin/bash')) {
        push @out => Test2::Harness2::TestFile->new(file => "$base/test.sh");
    }

    if (can_run('gcc')) {
        system('gcc', '-o' => "$base/test.binary", "$base/test.c") and die "Failed to compile $base/test.c";
        push @out => Test2::Harness2::TestFile->new(file => "$base/test.binary");
    }

    return @out;
}

1;
