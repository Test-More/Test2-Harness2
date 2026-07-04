use Test2::V0;
use v5.38;
# HARNESS-DURATION-LONG

# Chunk 20 / ticket TODO-40: interactive mode shares ONLY the command's STDIN with the
# one running test (-j1), by passing the real STDIN descriptor over a Unix socket
# (SCM_RIGHTS) instead of proxying bytes through a FIFO. STDOUT/STDERR stay with
# the collector and render normally (ARCHITECTURE.md §4.10).
#
# This drives a real `yath test --interactive` run via App::Yath2::Tester (the
# new `stdin` param feeds the command's STDIN), once on the NO-PRELOAD path and
# once on the PRELOAD path. Each test reads a line from STDIN and records what it
# saw to a marker file; we assert the test received the command's STDIN, that the
# normal (verbose, collector-rendered) output appears, and that the run passes.

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
skip_all "This feature requires IO::FDPass"
    unless eval { require IO::FDPass; 1 };

# Build a test directory with:
#   - a test that reads ONE line from STDIN and records it to a marker file
#   - (for the preload run) a preload module
sub make_dir {
    my ($marker) = @_;

    my $dir = tempdir(CLEANUP => 1);
    mkdir(File::Spec->catdir($dir, 't'))   or die "mkdir t: $!";
    mkdir(File::Spec->catdir($dir, 'lib')) or die "mkdir lib: $!";

    my $test = File::Spec->catfile($dir, 't', 'reads_stdin.t');
    open(my $tfh, '>', $test) or die "test: $!";
    print $tfh <<"    EOT";
use Test2::V0;
my \$line = <STDIN>;
chomp(\$line) if defined \$line;
open(my \$o, '>', "$marker") or die "marker: \$!";
print \$o "STDIN:" . (defined(\$line) ? \$line : 'UNDEF') . "\\n";
close(\$o);
ok(defined(\$line) && \$line eq 'feed-me-interactive', "test read the command's STDIN");
done_testing;
    EOT
    close($tfh);

    return $dir;
}

# A passing run that read the expected STDIN line.
sub check_marker {
    my ($marker) = @_;
    return 'NO-MARKER' unless -f $marker;
    open(my $r, '<', $marker) or return 'UNREADABLE';
    my $got = <$r>;
    close($r);
    chomp($got) if defined $got;
    return $got;
}

subtest no_preload_path => sub {
    my $marker = File::Temp->new(UNLINK => 1, SUFFIX => '.txt')->filename;
    unlink($marker) if -f $marker;
    my $dir = make_dir($marker);

    yath(
        command => 'test',
        args    => ['--interactive', File::Spec->catdir($dir, 't')],
        stdin   => "feed-me-interactive\n",
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/reads_stdin\.t/, "the test file is rendered (collector output, verbose)");
        },
    );

    is(check_marker($marker), "STDIN:feed-me-interactive",
        "no-preload interactive test received the command's STDIN over the socket");
};

subtest preload_path => sub {
    my $marker = File::Temp->new(UNLINK => 1, SUFFIX => '.txt')->filename;
    unlink($marker) if -f $marker;
    my $dir = make_dir($marker);

    open(my $pfh, '>', File::Spec->catfile($dir, 'lib', 'IntPreload.pm')) or die "preload: $!";
    print $pfh <<'    EOT';
package IntPreload;
use strict;
use warnings;
use Test2::Harness2::Runner::Preload;
stage DEFAULT => sub { default() };
1;
    EOT
    close($pfh);

    yath(
        command => 'test',
        args    => ["-I" . File::Spec->catdir($dir, 'lib'), '-PIntPreload', '--interactive', File::Spec->catdir($dir, 't')],
        stdin   => "feed-me-interactive\n",
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/reads_stdin\.t/, "the test file is rendered (collector output, verbose)");
        },
    );

    is(check_marker($marker), "STDIN:feed-me-interactive",
        "preload interactive test received the command's STDIN over the socket (goto::file hook)");
};

done_testing;
