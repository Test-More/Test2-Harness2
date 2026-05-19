use Test2::V0;

use App::Yath2::Filter::Verbose;

my $CLASS = 'App::Yath2::Filter::Verbose';

sub ev { {event_id => 'e1', facet_data => $_[0]} }

my $f = $CLASS->new;

subtest 'passes assert events' => sub {
    my $e = ev({assert => {pass => 1, details => 'ok'}});
    ok(defined $f->filter_event($e), 'assert event passes');
};

subtest 'passes events with info facet' => sub {
    my $e = ev({info => [{tag => 'DIAG', details => 'msg'}]});
    ok(defined $f->filter_event($e), 'info event passes');
};

subtest 'passes events with errors facet' => sub {
    my $e = ev({errors => [{tag => 'ERROR', details => 'bad'}]});
    ok(defined $f->filter_event($e), 'errors event passes');
};

subtest 'passes events with plan facet' => sub {
    my $e = ev({plan => {count => 5}});
    ok(defined $f->filter_event($e), 'plan event passes');
};

subtest 'passes harness_job_end events' => sub {
    my $e = ev({harness_job_end => {job_id => 'j1', fail => 0}});
    ok(defined $f->filter_event($e), 'harness_job_end passes');
};

subtest 'passes harness_job_start events' => sub {
    my $e = ev({harness_job_start => {job_id => 'j1'}});
    ok(defined $f->filter_event($e), 'harness_job_start passes');
};

subtest 'passes harness_job_queued events' => sub {
    my $e = ev({harness_job_queued => {job_id => 'j1'}});
    ok(defined $f->filter_event($e), 'harness_job_queued passes');
};

subtest 'passes harness_run_end events' => sub {
    my $e = ev({harness_run_end => {run_id => 'r1', pass => 1}});
    ok(defined $f->filter_event($e), 'harness_run_end passes');
};

subtest 'drops empty facet_data events' => sub {
    my $e = ev({});
    ok(!defined $f->filter_event($e), 'empty event dropped');
};

subtest 'drops housekeeping events with no displayable facet' => sub {
    my $e = ev({harness => {some_internal_thing => 1}});
    ok(!defined $f->filter_event($e), 'internal harness event dropped');
};

subtest 'drops events with no facet_data' => sub {
    my $e = {event_id => 'e1'};
    ok(!defined $f->filter_event($e), 'no facet_data dropped');
};

done_testing;
