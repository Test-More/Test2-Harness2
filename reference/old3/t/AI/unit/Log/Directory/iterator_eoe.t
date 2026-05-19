use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON  qw/encode_json/;
use Test2::Harness2::Util::Zstd  qw/open_zstd_writer/;
use App::Yath2::Log;

# Sealed: EOE flips true once the iterator stack drains.
{
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services/harness");

    my $w = open_zstd_writer("$dir/services/harness/events.jsonl.zst");
    $w->say(encode_json({facet_data => {harness => {note => 'a'}}}));
    $w->say(encode_json({facet_data => {harness => {note => 'b'}}}));
    $w->close;

    my $log = App::Yath2::Log->new(dir => $dir);
    is($log->EOE, 0, 'sealed: EOE false initially');

    my @got;
    while (my $e = $log->event(0)) {
        push @got => $e;
    }
    is(scalar(@got), 2, 'two events surfaced');
    is($log->EOE, 1, 'sealed: EOE flips true after drain');
}

# Live: EOE remains false until matching collector_end is seen for
# every collector_start.
{
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services/harness");
    make_path("$dir/runs/0");

    # Touch LIVE so live iterator considers harness still running.
    open(my $lf, '>', "$dir/LIVE") or die $!;
    print $lf "1\n";
    close $lf;

    # Harness has a start but no matching end yet.
    my $w = open_zstd_writer("$dir/services/harness/events.jsonl.zst");
    $w->say(encode_json({facet_data => {harness_collector_start => {
        type => 'Run', id => 0, run_id => 0,
        collector_pid => 999, collected_pid => 1000, started_at => 1.0,
    }}}));
    $w->close;

    my $w2 = open_zstd_writer("$dir/runs/0/events.jsonl.zst");
    $w2->say(encode_json({facet_data => {harness => {note => 'run alive'}}}));
    $w2->close;

    my $log = App::Yath2::Log->new(live => $dir);

    # Drain whatever we have so far (zero timeout, no waiting).
    while (my $e = $log->event(0)) {
        # collected
    }

    # Live: with one open collector_start and no end, EOE must be false.
    is($log->EOE, 0, 'live: EOE false while collector_end unseen');

    # Now write the matching collector_end into the harness stream.
    my $w3 = open_zstd_writer("$dir/services/harness/events.jsonl.zst");
    $w3->say(encode_json({facet_data => {harness_collector_end => {
        type => 'Run', id => 0, run_id => 0,
        collector_pid => 999, collected_pid => 1000, ended_at => 2.0, exit => 0,
    }}}));
    $w3->close;

    # Drain the new end event.
    while (my $e = $log->event(0)) { }

    # Now remove the LIVE marker so the harness reader treats itself as done.
    unlink "$dir/LIVE" or die $!;

    is($log->EOE, 1, 'live: EOE true once all starts have ends and LIVE gone');
}

done_testing;
