use Test2::V0;
use Test2::Require::Module 'DBD::MariaDB';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version/;
for_each_db_version([qw/mariadb/], sub {
    skipall_unless_can_db(driver => 'MariaDB');

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use DBI ();

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::MariaDB;

my $qdb = get_db({ driver => 'MariaDB' });
{
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_iter');
    $admin->disconnect;
}
my $dsn = $qdb->connect_string('yath_log_test_iter');

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
    {facet_data => {harness => {note => 'harness up'}}},
    {facet_data => {harness_collector_start => {
        type => 'Run', id => 0, run_id => 0,
        collector_pid => 1001, collected_pid => 1002, started_at => 1.0,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Run', id => 0, run_id => 0,
        collector_pid => 1001, collected_pid => 1002, ended_at => 2.0, exit => 0,
    }}},
    {facet_data => {harness => {note => 'harness shutting down'}}},
);

write_jsonl_zst(
    "$src/runs/0/events.jsonl.zst",
    {facet_data => {harness => {note => 'run started'}}},
    {facet_data => {harness_collector_start => {
        type => 'Job', id => 0, run_id => 0, job_try => 0,
        collector_pid => 2001, collected_pid => 2002, started_at => 1.5,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Job', id => 0, run_id => 0, job_try => 0,
        collector_pid => 2001, collected_pid => 2002, ended_at => 1.8, exit => 0,
    }}},
    {facet_data => {harness => {note => 'run done'}}},
);

write_jsonl_zst(
    "$src/runs/0/jobs/0/0/events.jsonl.zst",
    {facet_data => {assert => {pass => 1, details => 'first'}}},
    {facet_data => {assert => {pass => 1, details => 'second'}}},
);

# spec.jsonl -- required now that jobs.test_file_id is NOT NULL.
write_jsonl_zst(
    "$src/runs/0/jobs/0/0/spec.jsonl.zst",
    {relative => 't/dummy.t'},
);

App::Yath2::Log::MariaDB->new(dsn => $dsn)->insert(App::Yath2::Log->new(dir => $src));

my $log = App::Yath2::Log::MariaDB->new(dsn => $dsn);
isa_ok($log, ['App::Yath2::Log::MariaDB']);

my @collected;
while (my $e = $log->event(0)) {
    push @collected => $e;
    last if @collected > 100;
}

ok($log->EOE, 'EOE flips true after stack drains');

my @notes;
my @asserts;
my @starts;
my @ends;
for my $e (@collected) {
    my $fd = $e->{facet_data};
    push @notes,   $fd->{harness}{note}            if $fd->{harness} && $fd->{harness}{note};
    push @asserts, $fd->{assert}{details}          if $fd->{assert};
    push @starts,  $fd->{harness_collector_start}  if $fd->{harness_collector_start};
    push @ends,    $fd->{harness_collector_end}    if $fd->{harness_collector_end};
}

is(\@notes, ['harness up', 'run started', 'run done', 'harness shutting down'],
    'depth-first notes order');
is(\@asserts, ['first', 'second'], 'job events surfaced between run start and end');
is(scalar(@starts), 2, 'two collector_start events');
is(scalar(@ends),   2, 'two collector_end events');

my @assert_events = grep { $_->{facet_data}{assert} } @collected;
is(scalar(@assert_events), 2, 'two assert events');
for my $e (@assert_events) {
    is($e->{facet_data}{harness}{run_id},  0, 'run_id injected');
    is($e->{facet_data}{harness}{job_id},  0, 'job_id injected');
    is($e->{facet_data}{harness}{job_try}, 0, 'job_try injected');
}

$log->reset;
my $first = $log->event(0);
is($first->{facet_data}{harness}{note}, 'harness up', 'reset rewinds');

{
    my $log2 = App::Yath2::Log::MariaDB->new(dsn => $dsn);
    my @first = $log2->events(0);
    is(scalar(@first), scalar(@collected),
        'events() first call returns full record set');
    my @second = $log2->events(0);
    is(\@second, [undef], 'events() returns (undef) once drained');
}

});

done_testing;
