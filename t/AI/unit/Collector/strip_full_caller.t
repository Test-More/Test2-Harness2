use Test2::V0;

use File::Temp qw/tempdir/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Test2::API populates trace.full_caller on every context. The
# collector strips it (and any nested copy under parent.children)
# from each event before it lands in events.jsonl.zst.

sub mk_job_collector {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-r1',
        ipc_parent  => 'run-r1',
        type        => 'Job',
        id          => 1,
        run_id      => 1,
        job_try     => 1,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
        spec        => {file => 'fake.t'},
    );
    return ($c, $tmpdir);
}

sub read_event_rows {
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

subtest 'top-level trace.full_caller stripped' => sub {
    my ($c, $tmp) = mk_job_collector;
    $c->_open_writers;

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            trace => {
                frame       => ['main', 't/foo.t', 12, 'main::ok'],
                full_caller => ['main', 't/foo.t', 12, 'main::ok', 1, undef, undef, undef, 0, "UU", undef],
                pid         => 1234,
            },
        },
    );

    $c->_write_event($event);

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my @rows = read_event_rows("$tmp/runs/1/jobs/1/1/events.jsonl.zst");
    is(scalar(@rows), 1, 'one event written');
    ok(!exists $rows[0]{facet_data}{trace}{full_caller}, 'full_caller removed');
    is($rows[0]{facet_data}{trace}{frame}[1], 't/foo.t', 'frame preserved');
};

subtest 'nested trace.full_caller in parent.children stripped recursively' => sub {
    my ($c, $tmp) = mk_job_collector;
    $c->_open_writers;

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            trace => {
                frame       => ['main', 't/foo.t', 50, 'subtest'],
                full_caller => ['main', 't/foo.t', 50, 'subtest', 1, undef, undef, undef, 0, "UU", undef],
            },
            parent => {
                children => [
                    {
                        trace => {
                            frame       => ['main', 't/foo.t', 51, 'inner'],
                            full_caller => ['main', 't/foo.t', 51, 'inner', 1, undef, undef, undef, 0, "UU", undef],
                        },
                    },
                    {
                        trace => {
                            frame       => ['main', 't/foo.t', 52, 'inner2'],
                            full_caller => ['main', 't/foo.t', 52, 'inner2', 1, undef, undef, undef, 0, "UU", undef],
                        },
                        parent => {
                            children => [
                                {
                                    trace => {
                                        frame       => ['main', 't/foo.t', 53, 'leaf'],
                                        full_caller => ['main', 't/foo.t', 53, 'leaf', 1, undef, undef, undef, 0, "UU", undef],
                                    },
                                },
                            ],
                        },
                    },
                ],
            },
        },
    );

    $c->_write_event($event);

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my @rows = read_event_rows("$tmp/runs/1/jobs/1/1/events.jsonl.zst");
    is(scalar(@rows), 1, 'one event written');

    my $row = $rows[0];
    ok(!exists $row->{facet_data}{trace}{full_caller}, 'top-level full_caller removed');

    my $kids = $row->{facet_data}{parent}{children};
    is(scalar(@$kids), 2, 'two child events preserved');
    ok(!exists $kids->[0]{trace}{full_caller}, 'child 0 full_caller removed');
    ok(!exists $kids->[1]{trace}{full_caller}, 'child 1 full_caller removed');

    my $grandkid = $kids->[1]{parent}{children}[0];
    ok(!exists $grandkid->{trace}{full_caller}, 'grandchild full_caller removed');

    is($kids->[0]{trace}{frame}[1], 't/foo.t', 'child frame preserved');
};

subtest 'event with no trace facet is a noop' => sub {
    my ($c, $tmp) = mk_job_collector;
    $c->_open_writers;

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            info => [{tag => 'STDOUT', details => 'hi'}],
        },
    );

    $c->_write_event($event);

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my @rows = read_event_rows("$tmp/runs/1/jobs/1/1/events.jsonl.zst");
    is(scalar(@rows), 1, 'one event written');
    is($rows[0]{facet_data}{info}[0]{details}, 'hi', 'info preserved unchanged');
};

done_testing;
