#!/usr/bin/env perl
# scripts/atomic_pipe_repro.pl — diagnostic script for GH#389
#
# Verifies whether Atomic::Pipe mixed_data_mode guarantees FIFO ordering
# between a plain print+flush (line write) and a write_message call that
# immediately follow each other on the same pipe fd, from a single process.
#
# Run 20 times on Linux (ideally in a container matching the CI matrix) to
# gather a representative sample:
#
#   for i in $(seq 1 20); do perl -Ilib scripts/atomic_pipe_repro.pl; done
#
# Or from a containerized environment:
#
#   docker run --rm -v "$PWD:/src" -w /src perl:5.38-slim \
#     sh -c 'cpanm Atomic::Pipe && for i in $(seq 1 20); do perl scripts/atomic_pipe_repro.pl; done'
#
# IMPORTANT: This script mirrors the interleaving pattern used in real test
# runs — it dups the write filehandle (matching Atomic::Pipe->from_fh('>&=',
# \*STDOUT)) rather than using a fresh pair, because the race is between
# kernel buffer slots for the same underlying fd.
#
# Expected output (Outcome B): the script reports how many of ITERS iterations
# show a message arriving before its preceding line.  Even one reorder in 20
# runs confirms the race is real and the ordering is non-guaranteed.

use strict;
use warnings;
use Atomic::Pipe;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep/;

use constant ITERS => 1000;

# Build a mixed-mode pair where the writer is obtained by duping an IO::Handle,
# mirroring how EventEmitter->_as_atomic_pipe and Stream2 do it in production.
my ($r, $w_raw) = Atomic::Pipe->pair(mixed_data_mode => 1);

# Dup the writer side the same way EventEmitter does via from_fh('>&=', ...):
# this gives us a separate Atomic::Pipe object sharing the same kernel fd.
my $w = Atomic::Pipe->from_fh('>&=', $w_raw->wh);
$w->set_mixed_data_mode();

my $child = fork // die "fork: $!";

if (!$child) {
    # Child: close reader and the original writer (keep only $w / dup'd side).
    $r->close();
    $w_raw->close();

    for my $i (1 .. ITERS) {
        # Plain print first (line write), then an atomic message write.
        # No sleep between them — this is the race window.
        my $fh = $w->wh;
        print $fh "line-$i\n";
        $fh->flush;
        $w->write_message(qq/{"n":$i}/);
    }

    $w->close();
    exit(0);
}

# Parent: close writer halves, read until EOF.
$w->close();
$w_raw->close();

my @tuples;    # [ kind, seq ] in arrival order

while (1) {
    my ($type, $data) = $r->get_line_burst_or_data();
    if (!defined $type) {
        last if $r->eof();
        sleep 0.001;    # spin-wait when non-blocking and nothing ready yet
        next;
    }
    if ($type eq 'line') {
        chomp $data;
        if ($data =~ /^line-(\d+)$/) {
            push @tuples => [line => $1 + 0];
        }
    }
    elsif ($type eq 'message') {
        if ($data =~ /"n"\s*:\s*(\d+)/) {
            push @tuples => [message => $1 + 0];
        }
    }
}

waitpid($child, 0);
$r->close();

# Check ordering: for each iteration N, "line-N" must appear before {"n":N}.
my %line_pos;
my %msg_pos;
for my $idx (0 .. $#tuples) {
    my ($kind, $seq) = @{$tuples[$idx]};
    $line_pos{$seq} = $idx if $kind eq 'line';
    $msg_pos{$seq}  = $idx if $kind eq 'message';
}

my @out_of_order;
for my $n (1 .. ITERS) {
    next unless defined $line_pos{$n} && defined $msg_pos{$n};
    push @out_of_order => $n if $msg_pos{$n} < $line_pos{$n};
}

my $reorders = scalar @out_of_order;
if ($reorders) {
    printf "FAIL: %d/%d iterations out of order (first: n=%d, line@%d msg@%d)\n",
        $reorders, ITERS,
        $out_of_order[0], $line_pos{$out_of_order[0]}, $msg_pos{$out_of_order[0]};
}
else {
    printf "PASS: all %d iterations arrived in write order\n", ITERS;
}
