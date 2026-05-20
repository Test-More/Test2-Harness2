use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Test2::Harness2::Event;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2::Collector::Recorder::Files;

sub _read_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    return @lines;
}

subtest dir_required => sub {
    like(
        dies { Test2::Harness2::Collector::Recorder::Files->new },
        qr/'dir' is a required attribute/,
        'missing dir croaks',
    );
};

subtest writes_files => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Collector::Recorder::Files->new(dir => $dir);

    $r->record_state(starting => {pid => 4242});
    $r->record_event(Test2::Harness2::Event->new(facet_data => {assert => {pass => 1}}));
    $r->record_artifact({name => 'shot.png', local_path => '/tmp/shot.png'});
    $r->record_exit(0);
    $r->finalize;

    ok(-e File::Spec->catfile($dir, 'events.jsonl'),    'events.jsonl exists');
    ok(-e File::Spec->catfile($dir, 'state.jsonl'),     'state.jsonl exists');
    ok(-e File::Spec->catfile($dir, 'exit'),            'exit file exists');
    ok(-e File::Spec->catfile($dir, 'artifacts.jsonl'), 'artifacts.jsonl exists');
    ok(-e File::Spec->catfile($dir, 'finalized'),       'finalized marker exists');

    my ($exit_line) = _read_lines(File::Spec->catfile($dir, 'exit'));
    is($exit_line, '0', 'exit file content');

    my ($state) = _read_lines(File::Spec->catfile($dir, 'state.jsonl'));
    my $state_row = decode_json($state);
    is($state_row->{state},        'starting');
    is($state_row->{extra}{pid},   4242);
    ok(defined $state_row->{stamp}, 'state row has stamp');

    my ($evt) = _read_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my $event_row = decode_json($evt);
    is($event_row->{facet_data}{assert}{pass}, 1, 'event facet preserved');

    my ($art) = _read_lines(File::Spec->catfile($dir, 'artifacts.jsonl'));
    my $art_row = decode_json($art);
    is($art_row->{name}, 'shot.png');
};

subtest compressed_form_stripped_from_event_file => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Collector::Recorder::Files->new(dir => $dir);

    my $event = Test2::Harness2::Event->new(facet_data => {info => [{tag => 'X'}]});
    $event->{compressed_form} = "\x01\x02BYTES";

    $r->record_event($event);
    $r->finalize;

    my ($line) = _read_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my $row = decode_json($line);
    ok(!exists $row->{compressed_form}, 'compressed_form not written to disk');
    is($event->{compressed_form}, "\x01\x02BYTES", 'compressed_form restored on event');
};

subtest record_exit_orphaned_writes_marker => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Collector::Recorder::Files->new(dir => $dir);

    $r->record_exit(0, {orphaned => 1});

    ok(-e File::Spec->catfile($dir, 'orphaned'), 'orphaned marker written');
    my ($stamp) = _read_lines(File::Spec->catfile($dir, 'orphaned'));
    ok($stamp && $stamp + 0 > 0, 'orphaned marker holds a numeric timestamp');
};

subtest record_exit_without_orphaned_skips_marker => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Collector::Recorder::Files->new(dir => $dir);

    $r->record_exit(0);
    $r->record_exit(0, {});
    $r->record_exit(0, {orphaned => 0});

    ok(!-e File::Spec->catfile($dir, 'orphaned'), 'no orphaned marker when flag absent / false');
};

subtest finalize_blocks_further_writes => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Collector::Recorder::Files->new(dir => $dir);

    $r->finalize;

    like(
        dies { $r->record_event(Test2::Harness2::Event->new) },
        qr/already finalized/,
        'record_event after finalize croaks',
    );
    like(
        dies { $r->record_state('running') },
        qr/already finalized/,
        'record_state after finalize croaks',
    );

    my $ok = eval { $r->finalize; 1 };
    ok($ok, 'finalize is idempotent');
};

done_testing;
