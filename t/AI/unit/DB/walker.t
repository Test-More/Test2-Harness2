use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::Log::DB;

# Phase 7 acceptance test: cross-backend parity for the App::Yath2::DB
# walker. The walker is the depth-first iterator over a yath archive's
# events.jsonl streams; output must match (a) the source Directory's
# walker and (b) the other DB backend's walker on the same source.

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

# Build a fixture source carrying:
#   - harness root with two collector_start facets (Run, Service)
#   - run-scoped collector_start (Job)
#   - job_try with a couple of asserts
#   - run end
#   - harness shutdown
sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");
    make_path("$src/runs/0/services/run");

    write_jsonl_zst(
        "$src/services/harness/events.jsonl.zst",
        {facet_data => {harness => {note => 'harness up'}}},
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
            ended_at => 5.0,
            exit => 0,
        }}},
        {facet_data => {harness => {note => 'harness shutting down'}}},
    );

    write_jsonl_zst(
        "$src/runs/0/events.jsonl.zst",
        {facet_data => {harness => {note => 'run started'}}},
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
            ended_at => 4.0,
            exit => 0,
        }}},
        {facet_data => {harness => {note => 'run done'}}},
    );

    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/events.jsonl.zst",
        {facet_data => {assert => {pass => 1, details => 'first'}}},
        {facet_data => {assert => {pass => 1, details => 'second'}}},
        {facet_data => {assert => {pass => 1, details => 'third'}}},
    );

    # spec.jsonl required for jobs.test_file_id NOT NULL.
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {relative => 't/dummy.t'},
    );

    return $src;
}

# Walker output canonicalization: drop walker-injected harness ids
# (_walk_state injects run_id / job_id / job_try / service_name into
# harness facet on emit; both backends do this identically, but the
# source Directory walker also does it -- so comparing is fine for
# cross-backend parity, but we strip them when comparing against the
# source events.jsonl bytes since per-event identifier injection is a
# walker concern, not part of the recorded jsonl).
sub canon_event {
    my $e = shift;
    return undef unless ref($e) eq 'HASH';
    return $e;   # leave injected ids intact for parity comparisons
}

# {{{ Build sqlite + dbic copies of the same archive
my $src = build_source();
my $src_log = App::Yath2::Log->new(dir => $src);

my (undef, $sql_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $sql_path;
my $sql_db = App::Yath2::DB->new(file => $sql_path, backend => 'sql');
my $sql_aid = $sql_db->insert($src_log);
my ($sql_uuid) = $sql_db->archives;

my (undef, $dbic_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $dbic_path;
my $dbic_db = App::Yath2::DB->new(file => $dbic_path, backend => 'dbic');
my $dbic_aid = $dbic_db->insert(App::Yath2::Log->new(dir => $src));
my ($dbic_uuid) = $dbic_db->archives;
# }}}

# {{{ Drain walker on each side; compare against the source Directory walker
sub collect_events {
    my $log = shift;
    my @out;
    while (my $e = $log->event(0)) {
        push @out => $e;
        last if @out > 200;   # safety cap
    }
    return \@out;
}

my $src_events  = collect_events($src_log);
my $sql_events  = collect_events(App::Yath2::Log::DB->new(db => $sql_db,  uuid => $sql_uuid));
my $dbic_events = collect_events(App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid));

# Source carries 11 records (4 harness + 4 run + 3 asserts).
is(scalar(@$src_events),  11, 'source walker yields 11 records');
is(scalar(@$sql_events),  11, 'sql backend walker yields 11 records');
is(scalar(@$dbic_events), 11, 'dbic backend walker yields 11 records');

# Walker output must be identical across SQL/DBIC for the same source.
is($sql_events, $dbic_events, 'sql and dbic walkers produce identical output');
# }}}

# {{{ Compare event ordering by note / details / facet kind
sub event_signature {
    my $e = shift;
    my $fd = $e->{facet_data} or return '???';
    return "note:$fd->{harness}{note}"        if $fd->{harness} && $fd->{harness}{note};
    return "assert:$fd->{assert}{details}"    if $fd->{assert};
    return "start:$fd->{harness_collector_start}{type}"
        if $fd->{harness_collector_start};
    return "end:$fd->{harness_collector_end}{type}"
        if $fd->{harness_collector_end};
    return '???';
}

my @src_sigs  = map { event_signature($_) } @$src_events;
my @sql_sigs  = map { event_signature($_) } @$sql_events;
my @dbic_sigs = map { event_signature($_) } @$dbic_events;

is(\@sql_sigs, \@src_sigs,
    'sql backend walker matches source walker order');
is(\@dbic_sigs, \@src_sigs,
    'dbic backend walker matches source walker order');
# }}}

# {{{ EOE flips true after stack drains
my $sql_log_eoe = App::Yath2::Log::DB->new(db => $sql_db, uuid => $sql_uuid);
collect_events($sql_log_eoe);
ok($sql_log_eoe->end_of_events, 'EOE true after sql walker drains');
ok($sql_log_eoe->EOE,           'EOE alias also true');

my $dbic_log_eoe = App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid);
collect_events($dbic_log_eoe);
ok($dbic_log_eoe->end_of_events, 'EOE true after dbic walker drains');
# }}}

# {{{ reset() rewinds the walker
my $sql_log_r = App::Yath2::Log::DB->new(db => $sql_db, uuid => $sql_uuid);
my $first = $sql_log_r->event(0);
ok(defined $first, 'first event present');
$sql_log_r->reset;
my $first_again = $sql_log_r->event(0);
is(event_signature($first_again), event_signature($first),
    'reset() rewinds the walker (first event matches)');
# }}}

# {{{ events() drains in one call and returns the same set
{
    my $sql_log_ev  = App::Yath2::Log::DB->new(db => $sql_db,  uuid => $sql_uuid);
    my @sql_via_events = $sql_log_ev->events(0);
    is(scalar(@sql_via_events), scalar(@$sql_events),
        'sql events() returns same number of records as event() loop');
    is([map { event_signature($_) } @sql_via_events], \@sql_sigs,
        'sql events() preserves walker order');

    # Second call after drain returns (undef) -- the role's "drained"
    # sentinel.
    my @second = $sql_log_ev->events(0);
    is(\@second, [undef], 'sql events() returns (undef) after drain');
}

{
    my $dbic_log_ev = App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid);
    my @dbic_via_events = $dbic_log_ev->events(0);
    is(scalar(@dbic_via_events), scalar(@$dbic_events),
        'dbic events() returns same number of records as event() loop');
    is([map { event_signature($_) } @dbic_via_events], \@dbic_sigs,
        'dbic events() preserves walker order');
}
# }}}

# {{{ Walker on a uuid-scoped App::Yath2::DB (no Log::DB wrapper)
{
    my $scoped = $sql_db->scoped($sql_uuid);
    my @collected;
    while (my $e = $scoped->event($scoped->uuid, 0)) {
        push @collected => $e;
        last if @collected > 200;
    }
    is(scalar(@collected), 11,
        'scoped App::Yath2::DB walker yields the same 11 records');
    is([map { event_signature($_) } @collected], \@sql_sigs,
        'scoped App::Yath2::DB walker preserves order');
}
# }}}

done_testing;
