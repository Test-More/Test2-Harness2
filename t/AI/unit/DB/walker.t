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

# Cross-backend parity test for the App::Yath2::DB::Iterator walker.
# The iterator is the depth-first reader over a yath archive's
# events.jsonl streams; output must match (a) the source Directory's
# walker and (b) the other DB backend's iterator on the same source.

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

# Build a fixture source carrying:
#   - harness root with a Run collector_start / end
#   - run-scoped collector_start (Job)
#   - job_try with three asserts
#   - harness shutdown notes
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

# {{{ Drain via Log::DB on each side; compare against the source Directory walker
sub collect_via_log {
    my $log = shift;
    my @out;
    while (my $e = $log->event(0)) {
        push @out => $e;
        last if @out > 200;   # safety cap
    }
    return \@out;
}

sub collect_via_iter {
    my $iter = shift;
    my @out;
    while (my $e = $iter->next) {
        push @out => $e;
        last if @out > 200;
    }
    return \@out;
}

my $src_events  = collect_via_log($src_log);
my $sql_events  = collect_via_log(App::Yath2::Log::DB->new(db => $sql_db,  uuid => $sql_uuid));
my $dbic_events = collect_via_log(App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid));

# Source carries 11 records (4 harness + 4 run + 3 asserts).
is(scalar(@$src_events),  11, 'source walker yields 11 records');
is(scalar(@$sql_events),  11, 'sql backend iterator yields 11 records');
is(scalar(@$dbic_events), 11, 'dbic backend iterator yields 11 records');

is($sql_events, $dbic_events, 'sql and dbic iterators produce identical output');
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
    'sql backend iterator matches source walker order');
is(\@dbic_sigs, \@src_sigs,
    'dbic backend iterator matches source walker order');
# }}}

# {{{ EOE flips true after stack drains
my $sql_log_eoe = App::Yath2::Log::DB->new(db => $sql_db, uuid => $sql_uuid);
collect_via_log($sql_log_eoe);
ok($sql_log_eoe->end_of_events, 'EOE true after sql iterator drains');
ok($sql_log_eoe->EOE,           'EOE alias also true');

my $dbic_log_eoe = App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid);
collect_via_log($dbic_log_eoe);
ok($dbic_log_eoe->end_of_events, 'EOE true after dbic iterator drains');
# }}}

# {{{ reset() rewinds the iterator
my $sql_log_r = App::Yath2::Log::DB->new(db => $sql_db, uuid => $sql_uuid);
my $first = $sql_log_r->event(0);
ok(defined $first, 'first event present');
$sql_log_r->reset;
my $first_again = $sql_log_r->event(0);
is(event_signature($first_again), event_signature($first),
    'reset() rewinds the iterator (first event matches)');
# }}}

# {{{ events() drains in one call and returns the same set
{
    my $sql_log_ev  = App::Yath2::Log::DB->new(db => $sql_db,  uuid => $sql_uuid);
    my @sql_via_events = $sql_log_ev->events(0);
    is(scalar(@sql_via_events), scalar(@$sql_events),
        'sql events() returns same number of records as event() loop');
    is([map { event_signature($_) } @sql_via_events], \@sql_sigs,
        'sql events() preserves iterator order');

    # Second call after drain returns an empty list; the iterator
    # contract is "next returns undef when drained" rather than
    # producing a (undef) sentinel.
    my @second = $sql_log_ev->events(0);
    is(\@second, [], 'sql events() returns () after drain');
}

{
    my $dbic_log_ev = App::Yath2::Log::DB->new(db => $dbic_db, uuid => $dbic_uuid);
    my @dbic_via_events = $dbic_log_ev->events(0);
    is(scalar(@dbic_via_events), scalar(@$dbic_events),
        'dbic events() returns same number of records as event() loop');
    is([map { event_signature($_) } @dbic_via_events], \@dbic_sigs,
        'dbic events() preserves iterator order');
}
# }}}

# {{{ Walker via direct App::Yath2::DB::Iterator (no Log::DB wrapper)
{
    my $iter = $sql_db->iterator($sql_uuid);
    my $collected = collect_via_iter($iter);
    is(scalar(@$collected), 11,
        'direct iterator yields the same 11 records');
    is([map { event_signature($_) } @$collected], \@sql_sigs,
        'direct iterator preserves order');
    ok($iter->EOE, 'direct iterator EOE true after drain');

    # count() == drain length.
    is($iter->count, 11,
        'iterator->count == scalar @drain');
}
# }}}

done_testing;
