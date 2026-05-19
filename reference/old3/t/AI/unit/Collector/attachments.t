use Test2::V0;

use File::Temp qw/tempdir/;
use MIME::Base64 qw/encode_base64/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader decompress_blob/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Unit-test the attachment-extraction step of write_phase. We construct
# a Collector instance directly, open the writers, hand-craft events
# that carry base64 attachment hashes in info[*], and verify the
# on-disk side effects + the rewritten event row.

sub mk_job_collector {
    my (%extra) = @_;
    my $tmpdir = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-r0',
        ipc_parent  => 'run-r0',
        type        => 'Job',
        id          => 0,
        run_id      => 0,
        job_try     => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
        spec        => {file => 'fake.t'},
        %extra,
    );
    return ($c, $tmpdir);
}

# Read the events.jsonl.zst stream into decoded hashes.
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

sub mk_event_with_attachment {
    my (%att) = @_;
    return Test2::Harness2::Event->new(
        facet_data => {
            info => [
                {%att},
            ],
        },
    );
}

subtest 'png attachment extracted uncompressed; event facet rewritten' => sub {
    my ($c, $tmp) = mk_job_collector;

    # Open writers (write_phase needs the events writer).
    $c->_open_writers;

    my $bytes = "\x89PNG\r\n\x1A\n" . "fake png payload";
    my $event = mk_event_with_attachment(
        filename => 'foo.png',
        data     => encode_base64($bytes),
        encoding => 'base64',
        is_image => 1,
        details  => 'screenshot',
    );

    $c->_write_event($event);

    # Close writers so the data is flushed.
    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my $att_path = "$tmp/runs/0/jobs/0/0/attachments/0001-foo.png";
    ok(-f $att_path, "attachment file written at expected path ($att_path)");

    # PNG extension -> not zstd-compressed, raw bytes match.
    open(my $fh, '<:raw', $att_path) or die "open '$att_path': $!";
    local $/;
    my $on_disk = <$fh>;
    close $fh;
    is($on_disk, $bytes, 'on-disk bytes are the raw PNG payload (not zstd)');

    # Event row was rewritten.
    my @rows = read_event_rows("$tmp/runs/0/jobs/0/0/events.jsonl.zst");
    is(scalar(@rows), 1, 'one event written');
    my $info = $rows[0]{facet_data}{info}[0];
    is($info->{filename}, 'foo.png',                             'filename preserved');
    is($info->{is_image}, 1,                                     'is_image preserved');
    is($info->{details},  'screenshot',                          'details preserved');
    is($info->{archive_path}, 'runs/0/jobs/0/0/attachments/0001-foo.png', 'archive_path set');
    ok(!exists $info->{data},     'data stripped from event');
    ok(!exists $info->{encoding}, 'encoding stripped from event');
};

subtest 'txt attachment is zstd-compressed on disk' => sub {
    my ($c, $tmp) = mk_job_collector;
    $c->_open_writers;

    my $payload = "hello world";
    my $event   = mk_event_with_attachment(
        filename => 'data.txt',
        data     => encode_base64($payload),
        encoding => 'base64',
    );
    $c->_write_event($event);

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my $att_path = "$tmp/runs/0/jobs/0/0/attachments/0001-data.txt.zst";
    ok(-f $att_path, "attachment compressed at $att_path");

    open(my $fh, '<:raw', $att_path) or die "open '$att_path': $!";
    local $/;
    my $on_disk_compressed = <$fh>;
    close $fh;

    is(decompress_blob($on_disk_compressed), $payload, 'decompressed bytes match');

    my @rows = read_event_rows("$tmp/runs/0/jobs/0/0/events.jsonl.zst");
    is(scalar(@rows), 1, 'one event written');
    my $info = $rows[0]{facet_data}{info}[0];
    is($info->{archive_path}, 'runs/0/jobs/0/0/attachments/0001-data.txt.zst',
       'archive_path includes the .zst suffix');
    ok(!exists $info->{data},     'data stripped');
    ok(!exists $info->{encoding}, 'encoding stripped');
};

subtest 'colliding filenames get distinct counter prefixes' => sub {
    my ($c, $tmp) = mk_job_collector;
    $c->_open_writers;

    # Three events with the same filename "foo.png".
    for my $n (1 .. 3) {
        my $event = mk_event_with_attachment(
            filename => 'foo.png',
            data     => encode_base64("payload-$n"),
            encoding => 'base64',
        );
        $c->_write_event($event);
    }

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c->{$slot} or next;
        eval { $w->close; 1 };
    }

    my $att_dir = "$tmp/runs/0/jobs/0/0/attachments";
    for my $n (1 .. 3) {
        my $path = sprintf('%s/%04d-foo.png', $att_dir, $n);
        ok(-f $path, "attachment $n at $path (counter increments)");
    }

    my @rows = read_event_rows("$tmp/runs/0/jobs/0/0/events.jsonl.zst");
    is(scalar(@rows), 3, 'three events written');
    is(
        [map { $_->{facet_data}{info}[0]{archive_path} } @rows],
        [
            'runs/0/jobs/0/0/attachments/0001-foo.png',
            'runs/0/jobs/0/0/attachments/0002-foo.png',
            'runs/0/jobs/0/0/attachments/0003-foo.png',
        ],
        'archive_paths use 0001/0002/0003 counter prefixes',
    );
};

subtest 'restart resumes from highest existing counter' => sub {
    my ($c1, $tmp) = mk_job_collector;
    $c1->_open_writers;

    # Three attachments through the first instance.
    for my $n (1 .. 3) {
        my $event = mk_event_with_attachment(
            filename => 'foo.png',
            data     => encode_base64("p$n"),
            encoding => 'base64',
        );
        $c1->_write_event($event);
    }

    # "Exit" the first collector cleanly.
    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c1->{$slot} or next;
        eval { $w->close; 1 };
    }
    undef $c1;

    # New collector pointed at the same logdir + same identity.
    my $c2 = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-r0',
        ipc_parent  => 'run-r0',
        type        => 'Job',
        id          => 0,
        run_id      => 0,
        job_try     => 0,
        logdir      => $tmp,
        launch      => ['perl', '-e', 1],
        spec        => {file => 'fake.t'},
    );
    $c2->_open_writers;

    my $event = mk_event_with_attachment(
        filename => 'foo.png',
        data     => encode_base64("post-restart"),
        encoding => 'base64',
    );
    $c2->_write_event($event);

    for my $slot (qw/_events_writer _spec_writer _report_writer/) {
        my $w = delete $c2->{$slot} or next;
        eval { $w->close; 1 };
    }

    # Should have started at 0004, NOT 0001 (which would clobber).
    ok(-f "$tmp/runs/0/jobs/0/0/attachments/0001-foo.png", 'pre-existing 0001 still there');
    ok(-f "$tmp/runs/0/jobs/0/0/attachments/0002-foo.png", 'pre-existing 0002 still there');
    ok(-f "$tmp/runs/0/jobs/0/0/attachments/0003-foo.png", 'pre-existing 0003 still there');
    ok(-f "$tmp/runs/0/jobs/0/0/attachments/0004-foo.png", 'new attachment lands at 0004');
};

done_testing;
