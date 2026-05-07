use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;

# Round-trip: directory -> sqlite -> directory. The event sequences
# emitted by the iterator should match the original directory's.

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/harness/attachments");
make_path("$src/runs/0");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

write_jsonl_zst(
    "$src/services/harness/events.jsonl.zst",
    {facet_data => {harness => {note => 'harness up'}}},
    {facet_data => {harness_collector_start => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
    }}},
    {facet_data => {harness => {note => 'harness shutting down'}}},
);

write_jsonl_zst(
    "$src/services/harness/spec.jsonl.zst",
    {type => 'Service', id => 'harness'},
);

write_jsonl_zst(
    "$src/runs/0/events.jsonl.zst",
    {facet_data => {harness => {note => 'run started'}}},
    {facet_data => {harness_collector_start => {
        type => 'Job',
        id => 0, run_id => 0, job_try => 0,
        collector_pid => 2001,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Job',
        id => 0, run_id => 0, job_try => 0,
        collector_pid => 2001,
    }}},
    {facet_data => {harness_collector_start => {
        type => 'Job',
        id => 0, run_id => 0, job_try => 1,
        collector_pid => 2002,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Job',
        id => 0, run_id => 0, job_try => 1,
        collector_pid => 2002,
    }}},
    {facet_data => {harness => {note => 'run done'}}},
);

write_jsonl_zst(
    "$src/runs/0/jobs/0/0/events.jsonl.zst",
    {facet_data => {assert => {pass => 0, details => 'try0 first'}}},
);

write_jsonl_zst(
    "$src/runs/0/jobs/0/1/events.jsonl.zst",
    {facet_data => {assert => {pass => 1, details => 'try1 first'}}},
    {facet_data => {assert => {pass => 1, details => 'try1 second'}}},
);

# spec.jsonl for each job try -- required now that jobs.test_file_id is NOT NULL.
write_jsonl_zst("$src/runs/0/jobs/0/0/spec.jsonl.zst", {relative => 't/dummy.t'});
write_jsonl_zst("$src/runs/0/jobs/0/1/spec.jsonl.zst", {relative => 't/dummy.t'});

# An attachment to verify pass-through.
open(my $a, '>', "$src/services/harness/attachments/0001-hello.txt") or die $!;
print $a "hi there\n";
close $a;

# Drive the original directory iterator and capture the event stream.
my $dir_log = App::Yath2::Log->new(dir => $src);

sub drain_iterator {
    my ($log) = @_;
    my @collected;
    while (my $e = $log->event(0)) {
        push @collected => $e;
        last if @collected > 1000;
    }
    return @collected;
}

my @from_dir = drain_iterator($dir_log);
ok(@from_dir, 'got events from directory iterator');

# directory -> sqlite
my (undef, $arc_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $arc_path;
$dir_log->archive($arc_path, format => 'sqlite');

my $sqlite_log = App::Yath2::Log->new(file => $arc_path);
isa_ok($sqlite_log, ['App::Yath2::Log::Sqlite']);

my @from_sqlite = drain_iterator($sqlite_log);
is(scalar(@from_sqlite), scalar(@from_dir),
    'sqlite iterator yields the same number of events as the source');

# Compare events ignoring identifier injection (which both should do
# identically -- so they must match exactly).
is(\@from_sqlite, \@from_dir, 'sqlite events match directory events');

# Listing parity.
is([$sqlite_log->runs],     [$dir_log->runs],     'runs match');
is([$sqlite_log->services], [$dir_log->services], 'services match');
is([$sqlite_log->jobs(0)],  [$dir_log->jobs(0)],  'jobs(0) match');
is([$sqlite_log->tries(0,0)], [$dir_log->tries(0,0)], 'tries(0,0) match');

# Round-trip back: sqlite -> directory.
my $extract = tempdir(CLEANUP => 1);
File::Path::remove_tree($extract, {keep_root => 1});
my $extracted = $sqlite_log->extract($extract);
isa_ok($extracted, ['App::Yath2::Log::Directory']);

my @from_extract = drain_iterator($extracted);
is(scalar(@from_extract), scalar(@from_dir),
    'extracted directory iterator yields same number of events');
is(\@from_extract, \@from_dir, 'extracted directory events match original');

# Attachment round-trip.
my $h_orig = $dir_log->artifacts('harness');
my $h_db   = $sqlite_log->artifacts('harness');
my $h_ext  = $extracted->artifacts('harness');

is([$h_db->attachments],  [$h_orig->attachments], 'attachments listing matches');
is([$h_ext->attachments], [$h_orig->attachments], 'extracted attachments listing matches');
is($h_db->attachment('0001-hello.txt'),  "hi there\n", 'sqlite attachment bytes match');
is($h_ext->attachment('0001-hello.txt'), "hi there\n", 'extracted attachment bytes match');

# events / spec / report parity. events are byte-for-byte from the
# events.jsonl artifact row. spec / report are reconstructed from
# typed columns + extras for DB backends (post-B5), so byte-level
# equality across key order isn't guaranteed -- compare decoded.
is($h_db->events, $h_orig->events,  'harness events bytes match');

use Test2::Harness2::Util::JSON ();
sub _decode_jsonl_records {
    my ($bytes) = @_;
    my @out;
    for my $line (split /\n/, $bytes // '') {
        next unless length $line;
        push @out => Test2::Harness2::Util::JSON::decode_json($line);
    }
    return \@out;
}
is(
    _decode_jsonl_records($h_db->spec),
    _decode_jsonl_records($h_orig->spec),
    'harness spec records match (modulo key order)',
);

# tar.zidx -> sqlite passes through cleanly.
{
    my (undef, $tar_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $tar_path;
    $dir_log->archive($tar_path);   # tar.zidx by default
    my $tar = App::Yath2::Log->new(file => $tar_path);
    isa_ok($tar, ['App::Yath2::Log::TarZIdx']);

    my (undef, $sqlite_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $sqlite_path;
    $tar->archive($sqlite_path, format => 'sqlite');
    my $tar_sqlite = App::Yath2::Log->new(file => $sqlite_path);
    isa_ok($tar_sqlite, ['App::Yath2::Log::Sqlite']);

    my @from_tar_sqlite = drain_iterator($tar_sqlite);
    is(\@from_tar_sqlite, \@from_dir, 'tar.zidx -> sqlite events match original');
}

done_testing;
