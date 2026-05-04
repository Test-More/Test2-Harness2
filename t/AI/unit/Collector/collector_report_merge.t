use Test2::V0;

use File::Temp qw/tempdir/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Unit-test the collector_report capture + merge into report.jsonl.zst.
# Build a Collector for a Run, hand it an event whose facet_data has
# collector_report => {...}, run write_phase, then trigger the report
# row write and verify the merged content.

sub mk_run_collector {
    my (%extra) = @_;
    my $tmpdir = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        ipc_run     => 'run-r0',
        type        => 'Run',
        id          => 0,
        run_id      => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
        spec        => {run_id => 0},
        %extra,
    );
    return ($c, $tmpdir);
}

sub read_zst_rows {
    my ($path) = @_;
    return () unless -f $path;
    my $r = open_zstd_reader($path);
    my @rows;
    while (defined(my $line = $r->readline)) {
        chomp $line;
        next unless length $line;
        push @rows, decode_json($line);
    }
    $r->close;
    return @rows;
}

subtest 'collector_report facet captured + merged into report.jsonl.zst' => sub {
    my ($c, $tmp) = mk_run_collector;

    $c->_open_writers;

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            collector_report => {
                pass        => 1,
                total_jobs  => 3,
                passed_jobs => 3,
                failed_jobs => 0,
                started_at  => 1714875000.0,
                ended_at    => 1714875100.0,
                jobs        => [
                    { job_id => 0, file => '/x/a.t', pass => 1, tries => 1, subtests => [] },
                ],
            },
        },
    );

    # write_phase captures the facet AND writes the event normally.
    $c->_write_event($event);

    # Close writers so the report row is on disk.
    $c->{Test2::Harness2::Collector::_EVENTS_WRITER()}->close
        if $c->{Test2::Harness2::Collector::_EVENTS_WRITER()};

    # Drive the report-write path with a known exit status.
    $c->{Test2::Harness2::Collector::CHILD_PID()} //= 99999;
    $c->_write_report_row(0);    # 0 = clean exit

    $c->{Test2::Harness2::Collector::_REPORT_WRITER()}->close
        if $c->{Test2::Harness2::Collector::_REPORT_WRITER()};

    my $base = $c->base_dir;
    my @rows = read_zst_rows("$base/report.jsonl.zst");
    is(scalar @rows, 1, 'one report row written');

    my $row = $rows[0];

    # Service-supplied keys came through.
    is($row->{pass},        1, 'pass merged from facet');
    is($row->{total_jobs},  3, 'total_jobs merged from facet');
    is($row->{passed_jobs}, 3, 'passed_jobs merged from facet');
    is($row->{started_at},  1714875000.0, 'started_at merged from facet');

    # Collector-supplied keys came through (and override service keys
    # with the same name).
    is($row->{exit},          0, 'exit set by collector');
    ok(ref($row->{exit_decoded}) eq 'HASH', 'exit_decoded is a hashref');
    is($row->{exit_decoded}{err}, 0, 'exit_decoded.err = 0');
    ok(defined $row->{ended_at}, 'ended_at populated by collector (overrides facet ended_at)');
    isnt($row->{ended_at}, 1714875100.0, 'collector ended_at overrides facet ended_at');
    is($row->{collector_pid}, $$,    'collector_pid stamped');
    is($row->{collected_pid}, 99999, 'collected_pid stamped');

    # Also verify the event was written to events.jsonl.zst.
    my @events = read_zst_rows("$base/events.jsonl.zst");
    is(scalar @events, 1, 'one event row in events.jsonl.zst');
    ok(exists $events[0]{facet_data}{collector_report}, 'collector_report facet preserved on disk');
};

subtest 'no collector_report facet -> report row has only collector exit info' => sub {
    my ($c, $tmp) = mk_run_collector;
    $c->_open_writers;

    # Event without collector_report.
    my $event = Test2::Harness2::Event->new(
        facet_data => { info => [{ details => 'hi', tag => 'INFO' }] },
    );
    $c->_write_event($event);

    $c->{Test2::Harness2::Collector::_EVENTS_WRITER()}->close
        if $c->{Test2::Harness2::Collector::_EVENTS_WRITER()};

    $c->{Test2::Harness2::Collector::CHILD_PID()} //= 88888;
    $c->_write_report_row(0);

    $c->{Test2::Harness2::Collector::_REPORT_WRITER()}->close
        if $c->{Test2::Harness2::Collector::_REPORT_WRITER()};

    my $base = $c->base_dir;
    my @rows = read_zst_rows("$base/report.jsonl.zst");
    is(scalar @rows, 1, 'one report row');

    my $row = $rows[0];
    is($row->{exit}, 0,           'exit set');
    is($row->{collector_pid}, $$, 'collector_pid set');
    is($row->{collected_pid}, 88888, 'collected_pid set');
    ok(!exists $row->{pass},        'no pass key (no facet to merge)');
    ok(!exists $row->{total_jobs},  'no total_jobs key');
};

done_testing;
