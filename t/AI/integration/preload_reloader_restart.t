use Test2::V0;
use Test2::Require::AuthorTesting;
use Data::Dumper ();
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;
use App::Yath2::TestFile;

sub _dd { Data::Dumper->new([@_])->Sortkeys(1)->Indent(1)->Terse(1)->Dump }

# End-to-end test for the HiResStat reloader's happy path: a preload
# pre-loads a fixture module; the fixture file is rewritten on disk
# while the preload service is alive; the reloader picks up the
# mtime bump and re-requires the file; a subsequent test queued
# through the same preload sees the new value.

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

subtest 'HiResStat reloader: edit fixture mid-run, new value reaches new test' => sub {
    my $keep = $ENV{KEEP_WORKDIR};
    my $dir = tempdir(CLEANUP => $keep ? 0 : 1);
    diag "workdir: $dir" if $keep;

    # The reloader's default project_root walks up from cwd looking
    # for .git or .yath.rc*; for an isolated fixture we plant a .git
    # directory under the tempdir and pass project_root + watch_paths
    # explicitly via reloader_args so the reloader only watches our
    # fixture tree.
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

    # Push the libdir onto @INC for this process so the about-to-be
    # spawned harness (and the preload service it forks) inherits it.
    # PERL5LIB does not affect an already-running interpreter.
    push @INC, $lib;

    # Make sure the parent process loads the module too, so the
    # @INC propagation Resource::Preload's services() does via -I
    # flags carries it forward (and the preload service can require
    # it at do_preload time).
    require Reloadable::Fixture;
    is(Reloadable::Fixture::greet(), 'before', 'parent sees initial value');

    my $tf_before = "$dir/before.t";
    write_file($tf_before, <<'EOT');
use Test2::V0;
ok($INC{'Reloadable/Fixture.pm'}, 'fixture pre-loaded');
is(Reloadable::Fixture::greet(), 'before', 'fixture greet=before');
done_testing;
EOT

    my $tf_after = "$dir/after.t";
    write_file($tf_after, <<'EOT');
use Test2::V0;
ok($INC{'Reloadable/Fixture.pm'}, 'fixture still pre-loaded after reload');
is(Reloadable::Fixture::greet(), 'after', 'fixture greet=after (post-reload)');
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

    # First run: assert the preload delivered 'before'.
    my $q1 = $spawn->queue_test_run(
        files => [App::Yath2::TestFile->new(file => $tf_before)],
    );
    ok($q1->{ok}, 'queued before-run') or diag _dd($q1);

    my $r1 = wait_for_run($spawn, $q1->{run_id});
    ok($r1 && $r1->{ok}, 'got run_results for before-run');
    is($r1->{pass}, 1, 'before-run passed (preload greet=before)')
        or diag _dd($r1);

    # Give the reloader's initial-tick mtime snapshot a chance to
    # finish before we rewrite. HiResStat's first do_reload tick
    # only records the current mtimes; the comparison-and-reload
    # path begins on the second tick. Without a beat here the
    # rewrite below can land before that initial snapshot, and the
    # post-rewrite mtime becomes the initial value (no diff
    # detected).
    sleep(0.5);

    # Rewrite the fixture so greet returns 'after'. Bump mtime
    # forward by a couple of seconds so HiResStat sees a change even
    # at coarse FS resolution.
    write_file($fixture, <<'EOM');
package Reloadable::Fixture;
use strict; use warnings;
sub greet { 'after' }
1;
EOM
    my $future = time + 2;
    utime($future, $future, $fixture) or die "utime $fixture: $!";

    # The service's IPC loop drives run_on_interval every ~0.2s.
    # Give the reloader several ticks to notice the mtime change
    # before queuing the next run.
    sleep(2.0);

    my $q2 = $spawn->queue_test_run(
        files => [App::Yath2::TestFile->new(file => $tf_after)],
    );
    ok($q2->{ok}, 'queued after-run') or diag _dd($q2);

    my $r2 = wait_for_run($spawn, $q2->{run_id});
    ok($r2 && $r2->{ok}, 'got run_results for after-run');
    is($r2->{pass}, 1, 'after-run passed (preload greet=after, reloaded)')
        or diag _dd($r2);

    $spawn->finish;
    $spawn->wait;
};

done_testing;
