use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use Test2::Util::UUID qw/gen_uuid/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::DB::Iterator;

# Focused tests on App::Yath2::DB::Iterator (independent of Log::DB).

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0/jobs/0/0");

    # 4 harness records.
    write_jsonl_zst(
        "$src/services/harness/events.jsonl.zst",
        {facet_data => {harness => {note => 'a'}}},
        {facet_data => {harness_collector_start => {
            type => 'Run', id => 0, run_id => 0,
            collector_pid => 11, collected_pid => 12,
        }}},
        {facet_data => {harness_collector_end => {
            type => 'Run', id => 0, run_id => 0,
            collector_pid => 11, collected_pid => 12,
        }}},
        {facet_data => {harness => {note => 'd'}}},
    );

    # 3 run records.
    write_jsonl_zst(
        "$src/runs/0/events.jsonl.zst",
        {facet_data => {harness => {note => 'r1'}}},
        {facet_data => {harness_collector_start => {
            type => 'Job', id => 0, run_id => 0, job_try => 0,
            collector_pid => 21, collected_pid => 22,
        }}},
        {facet_data => {harness => {note => 'r2'}}},
    );

    # 2 job_try records.
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/events.jsonl.zst",
        {facet_data => {assert => {pass => 1, details => 'aa'}}},
        {facet_data => {assert => {pass => 0, details => 'bb'}}},
    );

    # spec.jsonl required for jobs.test_file_id NOT NULL.
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {relative => 't/dummy.t'},
    );

    return $src;
}

my $src = build_source();

my (undef, $sql_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $sql_path;
my $db = App::Yath2::DB->new(file => $sql_path, backend => 'sql');
$db->insert(App::Yath2::Log->new(dir => $src));
my ($uuid) = $db->archives;

# {{{ Construction validation
{
    my $err = dies { App::Yath2::DB::Iterator->new() };
    like($err, qr/'db' is required/, 'missing db croaks');

    $err = dies { App::Yath2::DB::Iterator->new(db => $db) };
    like($err, qr/'uuid' is required/, 'missing uuid croaks');

    $err = dies { App::Yath2::DB::Iterator->new(db => $db, uuid => gen_uuid()) };
    like($err, qr/no archive/, 'unknown uuid croaks at construction (eager)');

    $err = dies { App::Yath2::DB::Iterator->new(db => 'not-a-db', uuid => $uuid) };
    like($err, qr/App::Yath2::DB instance/, 'bad db croaks');
}
# }}}

# {{{ next, EOE, reset, all, first, count
{
    my $iter = $db->iterator($uuid);
    isa_ok($iter, ['App::Yath2::DB::Iterator'], 'iterator() returns Iterator');
    is($iter->uuid, $uuid, 'iterator->uuid matches');
    is($iter->db, $db, 'iterator->db matches');

    ok(!$iter->EOE, 'EOE false at start');
    my $e = $iter->next;
    ok(ref($e) eq 'HASH', 'next returns a hashref');

    # Drain.
    my $n = 1;
    while (defined($iter->next)) { $n++ }
    is($n, 9, 'drain returns 9 records (4 harness + 3 run + 2 job)');
    ok($iter->EOE, 'EOE true after drain');

    # Re-draining without reset returns nothing.
    is($iter->next, undef, 'next undef when drained');

    # reset rewinds.
    $iter->reset;
    ok(!$iter->EOE, 'EOE false after reset');
    my $first = $iter->next;
    is(
        ref($first->{facet_data}) eq 'HASH'
            && $first->{facet_data}{harness}
            && $first->{facet_data}{harness}{note},
        'a',
        'first event after reset is the harness note',
    );

    # count returns expected total.
    is($iter->count, 9, 'count returns 9');

    # Cached: a stub on the backend would crash if called twice.
    # Verify by construction: count is a +slot defined via HashBase.
    ok(exists $iter->{App::Yath2::DB::Iterator::_COUNT()},
        'count cached on instance after first call');
}
# }}}

# {{{ all() drains via the role
{
    my $iter = $db->iterator($uuid);
    my @all = $iter->all;
    is(scalar(@all), 9, 'all() drains 9 records');
    ok($iter->EOE, 'EOE true after all()');
}
# }}}

# {{{ first() returns the first event after reset
{
    my $iter = $db->iterator($uuid);
    # Walk forward, then call first() — it should reset and return record 0.
    $iter->next for 1..3;
    my $f = $iter->first;
    is($f->{facet_data}{harness}{note}, 'a', 'first() returns record 0 after partial walk');
}
# }}}

# {{{ Multiple iterators on the same DB do not share state
{
    my $i1 = $db->iterator($uuid);
    my $i2 = $db->iterator($uuid);

    # Drain i1.
    my @one = $i1->all;
    is(scalar(@one), 9, 'i1 drained 9');
    ok($i1->EOE, 'i1 EOE true');

    # i2 still pristine.
    ok(!$i2->EOE, 'i2 EOE still false');
    my @two = $i2->all;
    is(scalar(@two), 9, 'i2 drains independently');
}
# }}}

done_testing;
