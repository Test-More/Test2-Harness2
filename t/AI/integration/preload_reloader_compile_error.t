use Test2::V0;
use Test2::Require::AuthorTesting;
use Data::Dumper ();
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;
use App::Yath2::TestFile;

# End-to-end test for the reloader's broken-preload behavior:
#
#   1. The preload pre-loads a fixture; a test routed through the
#      preload passes ("before").
#   2. The fixture is rewritten with a syntax error and its mtime
#      bumped; HiResStat picks up the change, fails to require the
#      file, records last_error -- so PreloadService emits
#      preload_broken to the harness.
#   3. A test that opts out of the preload (HARNESS2: preload @off)
#      runs successfully; the broken preload does not affect tests
#      routed around it.
#   4. The fixture is rewritten back to a valid module with greet
#      returning 'after'; HiResStat re-attempts the reload, succeeds,
#      PreloadService emits preload_ready, and a default-routed test
#      runs through the recovered preload and sees greet='after'.

sub _dd { Data::Dumper->new([@_])->Sortkeys(1)->Indent(1)->Terse(1)->Dump }

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print $fh $content;
    close $fh;
}

sub wait_for_run {
    my ($spawn, $run_id) = @_;
    my $results;
    wait_until(
        sub {
            $results = $spawn->_send_request('run_results', {run_id => $run_id});
            return defined($results) && defined($results->{pass});
        },
        30,
    ) or diag "timed out waiting for run_results on run $run_id";
    return $results;
}

subtest 'reloader compile error: broken preload does not block <no>-routed tests' => sub {
    my $keep = $ENV{KEEP_WORKDIR};
    my $dir = tempdir(CLEANUP => $keep ? 0 : 1);
    diag "workdir: $dir" if $keep;

    # The reloader's default project_root walks up from cwd looking
    # for .git or .yath.rc*; we plant a .git here and pin
    # project_root + watch_paths via reloader_args so the reloader
    # only watches our isolated fixture tree.
    mkdir "$dir/.git";

    my $lib = "$dir/lib";
    mkdir $lib;
    mkdir "$lib/Reloadable";

    my $fixture = "$lib/Reloadable/Fixture.pm";
    write_file($fixture, <<'EOM');
package Reloadable::Fixture;
use strict; use warnings;
sub greet { 'before' }
1;
EOM

    # @INC propagation: the harness child (and the preload service
    # it execs) only sees libdirs that are on @INC at fork time;
    # PERL5LIB does not affect an already-running interpreter.
    push @INC, $lib;
    require Reloadable::Fixture;

    # Test routed through the preload, asserting greet='before'.
    my $tf_before = "$dir/before.t";
    write_file($tf_before, <<'EOT');
# HARNESS2: preload default
use Test2::V0;
ok($INC{'Reloadable/Fixture.pm'}, 'fixture pre-loaded');
is(Reloadable::Fixture::greet(), 'before', 'fixture greet=before');
done_testing;
EOT

    # Test that explicitly opts out of any preload; this must run
    # successfully even while the named preload is in the broken
    # state, exercising the harness's "no_preload" fallback path
    # for HARNESS2: preload @off.
    my $tf_no = "$dir/no_preload.t";
    write_file($tf_no, <<'EOT');
# HARNESS2: preload @off
use Test2::V0;
ok(1, 'no-preload test ran while the preload was broken');
done_testing;
EOT

    my $preload = Test2::Harness2::Resource::Preload->new(
        name           => 'default',
        modules        => ['Reloadable::Fixture'],
        reloader_class => 'Test2::Harness2::Reloader::HiResStat',
        reloader_args  => {
            project_root       => $dir,
            watch_paths        => [$lib],
            poll_interval_secs => 0.1,
        },
    );

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        resources    => [$preload],
        kill_timeout => 5,
        keep_workdir => $keep ? 1 : 0,
    );

    # Step 1: baseline run through the preload, greet='before'.
    my $q1 = $spawn->queue_test_run(
        files => [App::Yath2::TestFile->new(file => $tf_before)],
    );
    ok($q1->{ok}, 'queued before-run') or diag _dd($q1);
    my $r1 = wait_for_run($spawn, $q1->{run_id});
    ok($r1 && $r1->{ok}, 'got run_results for before-run');
    is($r1->{pass}, 1, 'before-run passed (preload greet=before)')
        or diag _dd($r1);

    # Let the reloader complete its initial-tick mtime snapshot
    # before we rewrite. Without this beat the syntax-error rewrite
    # can land before the initial snapshot, and the corrupted
    # mtime becomes the baseline (no diff -> no reload attempt ->
    # no preload_broken transition).
    sleep(0.5);

    # Step 2: rewrite the fixture with a syntax error. HiResStat's
    # next tick hits the diff, attempts _attempt_in_place_reload,
    # the require throws, last_error is set, and PreloadService's
    # run_on_interval emits preload_broken to the harness on the
    # !defined->defined edge.
    #
    # The error is a bareword/method-resolution failure ("this is
    # not perl"); kept as syntactically-valid-but-runtime-bogus so
    # the surrounding here-doc is not itself broken.
    write_file($fixture, <<'EOM');
package Reloadable::Fixture;
use strict; use warnings;
this is not perl;
sub greet { 'after' }
1;
EOM
    my $future = time + 2;
    utime($future, $future, $fixture) or die "utime $fixture: $!";

    # Give the service plenty of ticks to attempt the reload and
    # mark the preload broken.
    sleep(2.0);

    # Step 3: a <no>-routed test runs while the preload is broken.
    # The harness's resolver picks the no_preload path for any
    # HARNESS2: preload @off file regardless of the named preload's
    # state, so this run must complete and pass.
    my $q2 = $spawn->queue_test_run(
        files => [App::Yath2::TestFile->new(file => $tf_no)],
    );
    ok($q2->{ok}, 'queued no-preload-run') or diag _dd($q2);
    my $r2 = wait_for_run($spawn, $q2->{run_id});
    ok($r2 && $r2->{ok}, 'got run_results for no-preload-run');
    is($r2->{pass}, 1, 'no-preload test passes even with broken preload')
        or diag _dd($r2);

    # Step 4: rewrite the fixture back to a valid module with
    # greet='after', bump the mtime past the broken-version mtime,
    # and queue a default-routed test that asserts greet='after'.
    #
    # The reloader's failure path restores the %INC mappings on the
    # broken require so the next tick still picks the file up as a
    # candidate; the successful re-require then clears last_error
    # and PreloadService emits preload_ready, unblocking any
    # default-routed run that was queued after the recovery.
    write_file($fixture, <<'EOM');
package Reloadable::Fixture;
use strict; use warnings;
sub greet { 'after' }
1;
EOM
    my $future2 = time + 4;
    utime($future2, $future2, $fixture) or die "utime $fixture: $!";

    # Give the reloader time to pick up the fix and emit
    # preload_ready before queueing the after-run.
    sleep(2.0);

    my $tf_after = "$dir/after.t";
    write_file($tf_after, <<'EOT');
# HARNESS2: preload default
use Test2::V0;
ok($INC{'Reloadable/Fixture.pm'}, 'fixture pre-loaded');
is(Reloadable::Fixture::greet(), 'after', 'fixture greet=after after recovery');
done_testing;
EOT

    my $q3 = $spawn->queue_test_run(
        files => [App::Yath2::TestFile->new(file => $tf_after)],
    );
    ok($q3->{ok}, 'queued after-run') or diag _dd($q3);
    my $r3 = wait_for_run($spawn, $q3->{run_id});
    ok($r3 && $r3->{ok}, 'got run_results for after-run');
    is($r3->{pass}, 1, 'after-run passed (preload recovered, greet=after)')
        or diag _dd($r3);

    $spawn->finish;
    $spawn->wait;
};

done_testing;
