use Test2::V0;

use App::Yath2::Filter::Quiet;

my $CLASS = 'App::Yath2::Filter::Quiet';

sub ev { {event_id => 'e1', facet_data => $_[0]} }

my $f = $CLASS->new;

subtest 'passes harness_job_end events' => sub {
    my $e = ev({harness_job_end => {job_id => 'j1', fail => 0}});
    ok(defined $f->filter_event($e), 'harness_job_end passes');
};

subtest 'passes harness_run_end events' => sub {
    my $e = ev({harness_run_end => {run_id => 'r1', pass => 1, pass_count => 3, fail_count => 0}});
    ok(defined $f->filter_event($e), 'harness_run_end passes');
};

subtest 'drops assert events' => sub {
    my $e = ev({assert => {pass => 1, details => 'ok'}});
    ok(!defined $f->filter_event($e), 'assert dropped');
};

subtest 'drops info/diag events' => sub {
    my $e = ev({info => [{tag => 'DIAG', details => 'msg'}]});
    ok(!defined $f->filter_event($e), 'info dropped');
};

subtest 'drops plan events' => sub {
    my $e = ev({plan => {count => 5}});
    ok(!defined $f->filter_event($e), 'plan dropped');
};

subtest 'drops events with no harness facet' => sub {
    ok(!defined $f->filter_event(ev({})), 'empty facet_data dropped');
    ok(!defined $f->filter_event({event_id => 'e1'}), 'no facet_data dropped');
};

done_testing;
