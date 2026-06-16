use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::JobReader;

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/events.jsonl.zst";

# Build a fixture events file the way Test2-Collector would: one frame per
# event, each a {facet_data => {...}} record. The terminal records are written
# in PRODUCTION order -- harness_process_exit first, then harness_final_state
# (Auditor emits the exit event, then 'completed', then the final-state event).
my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
my $ev = sub { my %fd = @_; bless({facet_data => {@_}}, 'Test2::Collector::Event') };
$rec->record_event($ev->(from_tap => {source => 'STDOUT', details => '1..1'}, plan => {count => 1}));
$rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'pass'}));
$rec->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 123}));
$rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
$rec->finalize;

my $reader = Test2::Harness2::JobReader->new(
    job_id     => 'JOB-1',
    job_try    => 0,
    run_id     => 'RUN-1',
    events_file => $file,
    file        => "t/foo.t",
);

my @events;
# Poll until done (the fixture is complete, so a couple of polls suffice).
for (1 .. 5) {
    push @events => $reader->poll(1000);
    last if $reader->done;
}

ok($reader->done, "reader saw process exit and drained");

# Every emitted event is a harness event carrying job identity.
ok($_->isa('Test2::Harness2::Event'), "wrapped as harness event") for @events;
is($events[0]->job_id, 'JOB-1', "job_id attached");

my %seen = map { my $fd = $_->facet_data; map {($_ => 1)} keys %$fd } @events;
ok($seen{assert},           "assert passed through");
ok($seen{from_tap},         "from_tap passed through");
ok($seen{harness_job_exit}, "synthesized harness_job_exit from harness_process_exit");
ok($seen{harness_job_end},  "synthesized harness_job_end from harness_final_state");

my ($exit_ev) = grep { $_->facet_data->{harness_job_exit} } @events;
is($exit_ev->facet_data->{harness_job_exit}{exit}, 0,        "exit code mapped");
is($exit_ev->facet_data->{harness_job_exit}{job_id}, 'JOB-1', "exit carries job_id");

my ($end_ev) = grep { $_->facet_data->{harness_job_end} } @events;
is($end_ev->facet_data->{harness_job_end}{fail}, 0,        "job_end fail derived from final_state");
is($end_ev->facet_data->{harness_job_end}{file}, "t/foo.t", "job_end carries file");

# Failing fixture with distinct exit/code values, so a field swap or a
# fail-inversion cannot pass green (the all-zero/pass=1 case above cannot
# distinguish exit from code, nor exercise the fail=1 branch).
subtest failing_job => sub {
    my $fdir  = tempdir(CLEANUP => 1);
    my $ffile = "$fdir/events.jsonl.zst";

    my $frec = Test2::Collector::Recorder::Zstd->new(file => $ffile);
    $frec->record_event($ev->(assert => {pass => 0, number => 1, details => 'boom'}));
    $frec->record_event($ev->(harness_process_exit => {all => 256, err => 1, sig => 0, dmp => 0, stamp => 456}));
    $frec->record_event($ev->(harness_final_state => {pass => 0, fail_count => 1, pass_count => 0, assertion_count => 1, exit => 256}));
    $frec->finalize;

    my $freader = Test2::Harness2::JobReader->new(
        job_id => 'JOB-2', job_try => 0, run_id => 'RUN-1', events_file => $ffile, file => "t/bar.t",
    );

    my @fe;
    for (1 .. 5) { push @fe => $freader->poll(1000); last if $freader->done }

    my ($fx) = grep { $_->facet_data->{harness_job_exit} } @fe;
    is($fx->facet_data->{harness_job_exit}{exit},   256, "exit <- process_exit.all");
    is($fx->facet_data->{harness_job_exit}{code},   1,   "code <- process_exit.err (not swapped with exit)");
    is($fx->facet_data->{harness_job_exit}{signal}, 0,   "signal <- process_exit.sig");

    my ($fend) = grep { $_->facet_data->{harness_job_end} } @fe;
    is($fend->facet_data->{harness_job_end}{fail}, 1, "job_end fail=1 when final_state pass=0");
};

# skip_all: Test2-Collector's plan facet carries {count=>0, skip=>1 (bool),
# details=>'reason'}. job_end must surface the DETAILS as the skip reason
# (not the boolean flag), and not mark it failed.
subtest skip_all_job => sub {
    my $sdir  = tempdir(CLEANUP => 1);
    my $sfile = "$sdir/events.jsonl.zst";

    my $srec = Test2::Collector::Recorder::Zstd->new(file => $sfile);
    $srec->record_event($ev->(plan => {count => 0, skip => 1, details => 'no thanks'}));
    $srec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 789}));
    $srec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 0, assertion_count => 0, exit => 0, plan => {count => 0, skip => 1, details => 'no thanks'}}));
    $srec->finalize;

    my $sreader = Test2::Harness2::JobReader->new(
        job_id => 'JOB-3', job_try => 0, run_id => 'RUN-1', events_file => $sfile, file => "t/skip.t",
    );

    my @se;
    for (1 .. 5) { push @se => $sreader->poll(1000); last if $sreader->done }

    my ($send) = grep { $_->facet_data->{harness_job_end} } @se;
    is($send->facet_data->{harness_job_end}{skip}, 'no thanks', "skip reason is plan details, not the boolean flag");
    is($send->facet_data->{harness_job_end}{fail}, 0,           "skip_all is not a failure");
};

# Regression: harness_process_exit and harness_final_state must survive a poll
# batch boundary. With max=1, process_exit fills one batch and final_state lands
# in the next; keying done on process_exit (the old bug) skipped final_state and
# dropped harness_job_end, making a completed job report as "never ran".
subtest poll_boundary => sub {
    my $bdir  = tempdir(CLEANUP => 1);
    my $bfile = "$bdir/events.jsonl.zst";

    my $brec = Test2::Collector::Recorder::Zstd->new(file => $bfile);
    $brec->record_event($ev->(assert => {pass => 1, number => 1, details => 'pass'}));
    $brec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 11}));
    $brec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
    $brec->finalize;

    my $breader = Test2::Harness2::JobReader->new(
        job_id => 'JOB-B', job_try => 0, run_id => 'RUN-1', events_file => $bfile, file => "t/boundary.t",
    );

    my @be;
    for (1 .. 20) { push @be => $breader->poll(1); last if $breader->done }

    ok($breader->done, "reader reached done across poll boundaries");
    ok((grep { $_->facet_data->{harness_job_exit} } @be), "harness_job_exit emitted");
    ok((grep { $_->facet_data->{harness_job_end} } @be),  "harness_job_end emitted (not dropped at boundary)");
};

# A bail-out / halt reason on the audited final_state must ride through into the
# synthesized harness_job_end so the gatherer can list the job under "Halted".
subtest halt_threaded => sub {
    my $hdir  = tempdir(CLEANUP => 1);
    my $hfile = "$hdir/events.jsonl.zst";

    my $hrec = Test2::Collector::Recorder::Zstd->new(file => $hfile);
    $hrec->record_event($ev->(assert => {pass => 0, number => 1, details => 'boom'}));
    $hrec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 22}));
    $hrec->record_event($ev->(harness_final_state => {pass => 0, fail_count => 1, pass_count => 0, assertion_count => 1, exit => 0, halt => 'review bailout'}));
    $hrec->finalize;

    my $hreader = Test2::Harness2::JobReader->new(
        job_id => 'JOB-H', job_try => 0, run_id => 'RUN-1', events_file => $hfile, file => "t/halt.t",
    );

    my @he;
    for (1 .. 5) { push @he => $hreader->poll(1000); last if $hreader->done }

    my ($hend) = grep { $_->facet_data->{harness_job_end} } @he;
    is($hend->facet_data->{harness_job_end}{halt}, 'review bailout', "halt reason threaded into job_end");
};

done_testing;
