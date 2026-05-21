use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::Recorder::DB;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

sub _new_harness {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'harness.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'test');
    return ($h, $dir);
}

sub _seed {
    my $h = shift;
    my ($host)     = $h->insert(hosts    => {name => 'localhost'});
    my ($user)     = $h->insert(users    => {name => 'tester'});
    my ($instance) = $h->insert(instances => {
        instance_uuid => 'fake-uuid-1',
        host_id       => $host->host_id,
        user_id       => $user->user_id,
        started       => 1.0,
    });
    my ($runner) = $h->insert(runners => {
        instance_id => $instance->instance_id,
        pid         => $$,
        started     => 1.0,
    });
    return $runner;
}

subtest required_attributes => sub {
    my ($h, $dir) = _new_harness();
    like(
        dies {
            Test2::Harness2::Collector::Recorder::DB->new(
                handle => $h, runner_id => 1, name => 'x', type => 'test job',
            );
        },
        qr/workdir/,
        'missing workdir croaks',
    );
    $h->disconnect;
};

subtest full_collector_lifecycle => sub {
    my ($h, $dir) = _new_harness();
    my $runner = _seed($h);

    my $rec = Test2::Harness2::Collector::Recorder::DB->new(
        handle    => $h,
        runner_id => $runner->runner_id,
        name      => 'c1',
        type      => 'test job',
        workdir   => $dir,
    );

    isa_ok($rec, 'Test2::Harness2::Collector::Recorder::DB');

    my $col = $h->fetch(collectors => collector_id => $rec->{collector_id});
    ok($col, 'collectors row created at startup');
    is($col->name,      'c1');
    is($col->type,      'test job');
    is($col->runner_id, $runner->runner_id);
    ok(!defined $col->watched, 'watched still null pre-set');

    my $art = $h->fetch(artifacts => collector_id => $col->collector_id);
    ok($art, 'artifacts row created at startup');
    is($art->filename, 'events.jsonl.zst', 'artifact filename is canonical events.jsonl.zst');
    ok($art->local_path, 'artifact has local_path');
    like($art->local_path, qr{/events/[0-9a-f-]+\.jsonl\.zst$}i, 'local on-disk path uses a uuid name');
    is($art->content, undef, 'artifact has no content yet');
    ok(-e $art->local_path, 'on-disk events file exists');

    $rec->set_watched(42424);
    $col->refresh;
    is($col->watched, 42424, 'set_watched updated the row');

    my $event = Test2::Harness2::Event->new(
        facet_data => {assert => {pass => 1, details => 'one'}},
    );
    $rec->record_event($event);
    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'NOTE'}]}));
    $rec->record_state(running => undef);

    $rec->record_exit(0);
    $col->refresh;
    is($col->exit_code, 0,    'exit_code recorded');
    ok($col->stop_time,        'stop_time stamped');
    ok(!defined $col->finalized, 'not yet finalized');

    my $events_path = $art->local_path;
    $rec->finalize;

    ok(!-e $events_path, 'on-disk events file unlinked after finalize');

    $art->refresh;
    is($art->local_path, undef, 'local_path cleared on artifact');
    ok($art->content,            'content migrated into artifact');

    open(my $tmp, '>:raw', File::Spec->catfile($dir, 'recovered.jsonl.zst')) or die "open: $!";
    print {$tmp} $art->content;
    close($tmp);

    my $reader = open_zstd_reader(File::Spec->catfile($dir, 'recovered.jsonl.zst'));
    my @lines;
    while (defined(my $line = $reader->readline)) {
        chomp $line;
        push @lines, $line;
    }
    is(scalar(@lines), 2, 'two event frames recovered');

    my $first = decode_json($lines[0]);
    is($first->{facet_data}{assert}{pass}, 1, 'first event round-tripped through migration');

    $col->refresh;
    ok($col->finalized, 'collectors.finalized stamped');

    $h->disconnect;
};

subtest finalize_is_idempotent => sub {
    my ($h, $dir) = _new_harness();
    my $runner = _seed($h);

    my $rec = Test2::Harness2::Collector::Recorder::DB->new(
        handle    => $h,
        runner_id => $runner->runner_id,
        name      => 'c2',
        type      => 'service',
        workdir   => $dir,
    );

    $rec->record_exit(0);
    $rec->finalize;
    my $ok = eval { $rec->finalize; 1 };
    ok($ok, 'second finalize is a no-op');

    like(
        dies { $rec->record_event(Test2::Harness2::Event->new) },
        qr/already finalized/,
        'record_event after finalize croaks',
    );

    $h->disconnect;
};

done_testing;
