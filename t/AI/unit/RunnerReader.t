use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::RunnerReader;

# Build a fixture runner-events.jsonl.zst the way the non-test collector that
# wraps the `yath test` runner would: the IOParser tags each line with its
# stream (STDOUT/STDERR, debug=1 for STDERR) plus a from_stream facet, and the
# collector finishes with a synthetic harness_process_exit.
my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/runner-events.jsonl.zst";

my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
my $ev = sub { Test2::Collector::Event->new(facet_data => {@_}) };
$rec->record_event($ev->(
    from_stream => {source => 'STDOUT', details => 'runner says hi'},
    info        => [{tag => 'STDOUT', debug => 0, details => 'runner says hi'}],
));
$rec->record_event($ev->(
    from_stream => {source => 'STDERR', details => 'runner warns'},
    info        => [{tag => 'STDERR', debug => 1, details => 'runner warns'}],
));
$rec->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 123}));
$rec->finalize;

my $reader = Test2::Harness2::RunnerReader->new(
    run_id      => 'RUN-1',
    events_file => $file,
);

my @events;
for (1 .. 5) {
    push @events => $reader->poll(1000);
    last if $reader->done;
}

ok($reader->done, "reader saw the runner process-exit and is done");

ok($_->isa('Test2::Harness2::Event'), "wrapped as harness event") for @events;
is($events[0]->job_id, 0, "runner events are run-level (job_id 0)");
is($events[0]->run_id, 'RUN-1', "run_id attached");

# stdout -> info INTERNAL/important, no debug.
my ($out_ev) = grep {
    my $i = $_->facet_data->{info};
    $i && grep { ($_->{details} // '') eq 'runner says hi' } @$i;
} @events;
ok($out_ev, "found the stdout event");
my ($out_info) = grep { ($_->{details} // '') eq 'runner says hi' } @{$out_ev->facet_data->{info}};
is($out_info->{tag},       'INTERNAL', "stdout remapped to INTERNAL");
is($out_info->{important}, 1,          "stdout marked important");
ok(!$out_info->{debug}, "stdout is not debug");
ok(!$out_ev->facet_data->{from_stream}, "from_stream bookkeeping dropped");

# stderr -> info INTERNAL/important + debug.
my ($err_ev) = grep {
    my $i = $_->facet_data->{info};
    $i && grep { ($_->{details} // '') eq 'runner warns' } @$i;
} @events;
ok($err_ev, "found the stderr event");
my ($err_info) = grep { ($_->{details} // '') eq 'runner warns' } @{$err_ev->facet_data->{info}};
is($err_info->{tag},       'INTERNAL', "stderr remapped to INTERNAL");
is($err_info->{important}, 1,          "stderr marked important");
is($err_info->{debug},     1,          "stderr marked debug");

# The terminal process-exit record is surfaced.
my ($px_ev) = grep { $_->facet_data->{harness_process_exit} } @events;
ok($px_ev, "harness_process_exit surfaced");

# A reader pointed at a not-yet-created events file must poll gracefully (no die,
# empty list) until the file appears.
subtest missing_file_is_graceful => sub {
    my $mreader = Test2::Harness2::RunnerReader->new(
        run_id      => 'RUN-2',
        events_file => "$dir/does-not-exist.jsonl.zst",
    );
    my @e;
    ok(lives { @e = $mreader->poll(1000) }, "poll on a missing file did not die");
    is(\@e, [], "no events yet");
    ok(!$mreader->done, "not done");
};

# A runner that exits non-zero is still detected: the process-exit record rides
# through unchanged so a downstream consumer can see the failure.
subtest nonzero_exit_detected => sub {
    my $fdir  = tempdir(CLEANUP => 1);
    my $ffile = "$fdir/runner-events.jsonl.zst";
    my $frec  = Test2::Collector::Recorder::Zstd->new(file => $ffile);
    $frec->record_event($ev->(
        from_stream => {source => 'STDERR', details => 'boom'},
        info        => [{tag => 'STDERR', debug => 1, details => 'boom'}],
    ));
    $frec->record_event($ev->(harness_process_exit => {err => 3, sig => 0, dmp => 0, all => 768, stamp => 9}));
    $frec->finalize;

    my $freader = Test2::Harness2::RunnerReader->new(run_id => 'RUN-3', events_file => $ffile);
    my @fe;
    for (1 .. 5) { push @fe => $freader->poll(1000); last if $freader->done }

    ok($freader->done, "done on process-exit");
    my ($fpx) = grep { $_->facet_data->{harness_process_exit} } @fe;
    is($fpx->facet_data->{harness_process_exit}{err}, 3, "non-zero runner exit preserved (err=3)");

    # The raw harness_process_exit facet has no renderer path, so a non-zero
    # runner exit must also be surfaced as a visible INTERNAL info diagnostic.
    my ($diag) = grep { ($_->{details} // '') =~ /runner exited abnormally/ } @{$fpx->facet_data->{info} // []};
    ok($diag, "non-zero runner exit produces a visible INTERNAL diagnostic");
    is($diag->{tag}, 'INTERNAL', "diagnostic tagged INTERNAL");
    ok($diag->{important}, "diagnostic marked important");
    like($diag->{details}, qr/exit: 768/, "diagnostic reports the exit status");
};

# A clean (zero) runner exit must NOT emit a spurious abnormal-exit diagnostic.
subtest clean_exit_no_diagnostic => sub {
    my $cdir  = tempdir(CLEANUP => 1);
    my $cfile = "$cdir/runner-events.jsonl.zst";
    my $crec  = Test2::Collector::Recorder::Zstd->new(file => $cfile);
    $crec->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 1}));
    $crec->finalize;

    my $creader = Test2::Harness2::RunnerReader->new(run_id => 'RUN-4', events_file => $cfile);
    my @ce;
    for (1 .. 5) { push @ce => $creader->poll(1000); last if $creader->done }

    my ($cpx) = grep { $_->facet_data->{harness_process_exit} } @ce;
    my ($cdiag) = grep { ($_->{details} // '') =~ /runner exited abnormally/ } @{$cpx->facet_data->{info} // []};
    ok(!$cdiag, "clean runner exit emits no abnormal-exit diagnostic");
};

# The abnormal-exit diagnostic is labelled. The default label names the runner;
# a custom label (used by the gatherer when reading per-stage events files, chunk
# 4b) names that source instead, so a stage that dies is reported as the stage.
subtest labelled_abnormal_exit => sub {
    my $ldir = tempdir(CLEANUP => 1);

    my $write_boom = sub {
        my ($path) = @_;
        my $r = Test2::Collector::Recorder::Zstd->new(file => $path);
        $r->record_event($ev->(harness_process_exit => {err => 5, sig => 0, dmp => 0, all => 1280, stamp => 7}));
        $r->finalize;
    };

    my $diag_for = sub {
        my ($reader) = @_;
        my @e;
        for (1 .. 5) { push @e => $reader->poll(1000); last if $reader->done }
        my ($px) = grep { $_->facet_data->{harness_process_exit} } @e;
        my ($d) = grep { ($_->{details} // '') =~ /exited abnormally/ } @{$px->facet_data->{info} // []};
        return $d;
    };

    my $dfile = "$ldir/runner-events.jsonl.zst";
    $write_boom->($dfile);
    my $default = Test2::Harness2::RunnerReader->new(run_id => 'RUN-L1', events_file => $dfile);
    like($diag_for->($default)->{details}, qr/^yath runner exited abnormally/, "default label names the runner");

    my $sfile = "$ldir/stage-MARK-events.jsonl.zst";
    $write_boom->($sfile);
    my $stage = Test2::Harness2::RunnerReader->new(
        run_id      => 'RUN-L2',
        events_file => $sfile,
        label       => "yath stage 'MARK'",
    );
    like($diag_for->($stage)->{details}, qr/^yath stage 'MARK' exited abnormally/, "custom label names the stage");
};

# A harness_process_restart (a resumable collector's restart boundary) must NOT
# end the stream: the reader stays not-done and surfaces a visible INTERNAL
# diagnostic carrying the exit value, then keeps reading the resumed output.
subtest restart_boundary => sub {
    my $rdir  = tempdir(CLEANUP => 1);
    my $rfile = "$rdir/stage-MARK-events.jsonl.zst";
    my $rrec  = Test2::Collector::Recorder::Zstd->new(file => $rfile);
    $rrec->record_event($ev->(
        from_stream => {source => 'STDOUT', details => 'before restart'},
        info        => [{tag => 'STDOUT', debug => 0, details => 'before restart'}],
    ));
    $rrec->record_event($ev->(harness_process_restart => {err => 2, sig => 0, dmp => 0, all => 512, stamp => 4}));
    $rrec->record_event($ev->(
        from_stream => {source => 'STDOUT', details => 'after restart'},
        info        => [{tag => 'STDOUT', debug => 0, details => 'after restart'}],
    ));
    $rrec->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 5}));
    $rrec->finalize;

    my $reader = Test2::Harness2::RunnerReader->new(
        run_id      => 'RUN-R',
        events_file => $rfile,
        label       => "yath stage 'MARK'",
    );
    my @e;
    for (1 .. 8) { push @e => $reader->poll(1000); last if $reader->done }

    my ($rs) = grep { $_->facet_data->{harness_process_restart} } @e;
    ok($rs, "restart record surfaced");
    my ($diag) = grep { ($_->{details} // '') =~ /restarting/ } @{$rs->facet_data->{info} // []};
    ok($diag, "restart produces a visible INTERNAL diagnostic");
    like($diag->{details}, qr/^yath stage 'MARK' restarting \(exit: 512\)/, "diagnostic labelled, carries the exit value");

    # Output recorded AFTER the restart is still read, and the terminal exit
    # (not the restart) is what marks done.
    ok((grep { my $i = $_->facet_data->{info}; $i && grep { ($_->{details} // '') eq 'after restart' } @$i } @e), "post-restart output read");
    ok($reader->done, "the later harness_process_exit -- not the restart -- ends the stream");
};

# Ticket TODO-141 (107): each record's OWN stamp is harvested (refreshing LAST_STAMP),
# so a stamp-bearing record uses its own time and, crucially, output after a
# harness_process_restart is no longer frozen at the restart instant -- a later
# stamp-bearing record advances the clock for the stampless output that follows.
subtest record_stamps_not_frozen_after_restart => sub {
    my $rdir  = tempdir(CLEANUP => 1);
    my $rfile = "$rdir/stage-STAMP-events.jsonl.zst";

    my $r = Test2::Collector::Recorder::Zstd->new(file => $rfile);
    $r->record_event($ev->(harness_process_restart => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 100}));
    $r->record_event($ev->(
        from_stream => {source => 'STDOUT', details => 'right after'},
        info        => [{tag => 'STDOUT', debug => 0, details => 'right after'}],
    ));
    # A later record that carries its OWN stamp (previously ignored by _wrap).
    $r->record_event($ev->(harness_state_transition => {state => 'starting', stamp => 250}));
    $r->record_event($ev->(
        from_stream => {source => 'STDOUT', details => 'much later'},
        info        => [{tag => 'STDOUT', debug => 0, details => 'much later'}],
    ));
    $r->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 300}));
    $r->finalize;

    my $reader = Test2::Harness2::RunnerReader->new(run_id => 'RUN-STAMP', events_file => $rfile);
    my @e;
    for (1 .. 8) { push @e => $reader->poll(1000); last if $reader->done }

    my $stamp_of = sub {
        my ($needle) = @_;
        my ($x) = grep {
            my $i = $_->facet_data->{info};
            $i && grep { ($_->{details} // '') eq $needle } @$i;
        } @e;
        return $x ? $x->stamp : undef;
    };

    my ($rs) = grep { $_->facet_data->{harness_process_restart} } @e;
    is($rs->stamp, 100, "restart record keeps its own stamp");

    my ($st) = grep { $_->facet_data->{harness_state_transition} } @e;
    is($st->stamp, 250, "a stamp-bearing record uses its OWN stamp (no longer ignored)");

    is($stamp_of->('right after'), 100, "stampless output right after the restart carries the restart stamp");
    is($stamp_of->('much later'),  250, "stampless output later carries the ADVANCED stamp, not frozen at the restart instant");
};

done_testing;
