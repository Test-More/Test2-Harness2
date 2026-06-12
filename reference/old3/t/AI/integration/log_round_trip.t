use Test2::V0;
use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;

# Build a moderately-realistic log directory, archive it, and verify
# the iterator produces the same event sequence from both backends.

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/runs/0");
make_path("$src/runs/0/jobs/0/0");

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

write_jsonl_zst(
    "$src/services/harness/events.jsonl.zst",
    {facet_data => {harness => {note => 'h1'}}},
    {facet_data => {harness_collector_start => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
        collected_pid => 1002,
        started_at    => 1.0,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
        collected_pid => 1002,
        ended_at => 2.0,
        exit => 0,
    }}},
    {facet_data => {harness => {note => 'h2'}}},
);

write_jsonl_zst(
    "$src/runs/0/events.jsonl.zst",
    {facet_data => {harness => {note => 'r1'}}},
    {facet_data => {harness_collector_start => {
        type   => 'Job',
        id     => 0,
        run_id => 0,
        job_try => 0,
        collector_pid => 2001,
        collected_pid => 2002,
        started_at    => 1.5,
    }}},
    {facet_data => {harness_collector_end => {
        type   => 'Job',
        id     => 0,
        run_id => 0,
        job_try => 0,
        collector_pid => 2001,
        collected_pid => 2002,
        ended_at => 1.8,
        exit => 0,
    }}},
    {facet_data => {harness => {note => 'r2'}}},
);

write_jsonl_zst(
    "$src/runs/0/jobs/0/0/events.jsonl.zst",
    {facet_data => {assert => {pass => 1, details => 'first'}}},
    {facet_data => {assert => {pass => 1, details => 'second'}}},
);

# Drive the directory backend and collect a fingerprint of every event.
sub fingerprint {
    my ($log) = @_;
    my @sig;
    while (my $e = $log->event(0)) {
        my $fd = $e->{facet_data} // {};
        my @parts;
        if (exists $fd->{harness} && exists $fd->{harness}{note}) {
            push @parts, "note:$fd->{harness}{note}";
        }
        if (exists $fd->{harness_collector_start}) {
            my $s = $fd->{harness_collector_start};
            push @parts, "start:$s->{type}:" . ($s->{id} // 'undef');
        }
        if (exists $fd->{harness_collector_end}) {
            my $s = $fd->{harness_collector_end};
            push @parts, "end:$s->{type}:" . ($s->{id} // 'undef');
        }
        if (exists $fd->{assert}) {
            push @parts, "assert:$fd->{assert}{details}";
        }
        # Record any path-aware identifiers that were injected.
        my $h = $fd->{harness} // {};
        for my $k (qw/run_id job_id job_try service_name/) {
            push @parts, "$k=" . $h->{$k} if defined $h->{$k};
        }
        push @sig => join(';', @parts);
    }
    return \@sig;
}

my $dir_log = App::Yath2::Log->new(dir => $src);
my $dir_sig = fingerprint($dir_log);
ok($dir_log->EOE, 'directory: EOE after drain');
ok(scalar(@$dir_sig) > 0, 'directory: collected some events');

# Archive, then drive the tar.zidx backend.
my (undef, $arc_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $arc_path;
$dir_log->archive($arc_path);

my $tar_log = App::Yath2::Log->new(file => $arc_path);
isa_ok($tar_log, ['App::Yath2::Log::TarZIdx']);
my $tar_sig = fingerprint($tar_log);
ok($tar_log->EOE, 'tar: EOE after drain');

is($tar_sig, $dir_sig, 'directory and tar.zidx iterators produce identical event sequence');

# Per-artifact iterator parity.
{
    my $dir_a = $dir_log->artifacts(0, 0, 0);
    my $tar_a = $tar_log->artifacts(0, 0, 0);
    is($dir_a->events_iter->count, 2, 'directory job has 2 events');
    is($tar_a->events_iter->count, 2, 'tar    job has 2 events');
}

done_testing;
