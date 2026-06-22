use Test2::V0 -target => 'App::Yath2::Pfile';
use Test2::Tools::Spec;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Collector::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util qw/clean_path/;

use App::Yath2::Pfile;

# A minimal stand-in for Getopt::Yath::Settings; find_runner_link only ever calls
# $settings->harness and then accessors on the result.
{

    package MockHarness;

    sub new { my ($c, %p) = @_; return bless {%p}, $c }
    sub persist_file { $_[0]->{persist_file} }
    sub persist_dir  { $_[0]->{persist_dir} }
    sub project      { $_[0]->{project} }

    package MockSettings;

    sub new { my ($c, %p) = @_; return bless {harness => MockHarness->new(%p)}, $c }
    sub harness { $_[0]->{harness} }
}

# Stand up a live runner-style workdir (bound runner.socket + PID file) and publish
# the discovery symlink for $settings at it. Returns ($settings, $workdir, $listen);
# keep $listen in scope so the socket stays bound for the connect-based liveness.
sub live_runner {
    my (%params) = @_;

    my $workdir = clean_path(tempdir(CLEANUP => 1));
    my $listen  = open_unix_listen(File::Spec->catfile($workdir, 'runner.socket'));

    my $pidfile = File::Spec->catfile($workdir, 'PID');
    open(my $fh, '>', $pidfile) or die "Could not write PID file: $!";
    print $fh ($params{pid} // $$);
    close($fh);

    my $persist  = tempdir(CLEANUP => 1);
    my $settings = MockSettings->new(project => 'Pfile-Test', persist_dir => $persist);
    require App::Yath2::Discovery;
    App::Yath2::Discovery->publish($settings, workdir => $workdir);

    return ($settings, $workdir, $listen);
}

tests find_and_accessors => sub {
    my ($settings, $workdir, $listen) = live_runner();

    my $pfile = App::Yath2::Pfile->find($settings);
    isa_ok($pfile, [$CLASS], "find returned a Pfile");

    ok(-l $pfile->path, "path is the discovery symlink");
    is($pfile->workdir, $workdir, "workdir resolves through the symlink");
    is($pfile->dir,     $workdir, "dir alias matches workdir");
    is($pfile->pid,     "$$",     "pid read from the workdir PID file");

    my $data = $pfile->data;
    is($data->{dir},        $workdir,      "data carries the workdir");
    is($data->{pid},        "$$",          "data carries the pid");
    is($data->{pfile_path}, $pfile->path,  "data carries the discovery symlink path");
    ref_is($pfile->data, $data, "data is cached");
};

tests describe => sub {
    my ($settings, $workdir, $listen) = live_runner();
    my $pfile = App::Yath2::Pfile->find($settings);

    my $link = $pfile->path;
    is(
        $pfile->describe,
        "\nFound: $link\n  PID: $$\n  Dir: $workdir\n\n",
        "describe matches the which/watch banner",
    );
};

tests legacy_params_ignored => sub {
    my ($settings, $workdir, $listen) = live_runner();

    # The old liveness-banner controls are accepted and ignored now.
    my $pfile = App::Yath2::Pfile->find($settings, no_fatal => 1, no_checks => 1, no_warn => 1);
    isa_ok($pfile, [$CLASS], "find still works with legacy params");
    is($pfile->workdir, $workdir, "discovery still resolved");
};

tests find_absent => sub {
    my $persist  = tempdir(CLEANUP => 1);
    my $settings = MockSettings->new(project => 'Pfile-None', persist_dir => $persist);

    is(App::Yath2::Pfile->find($settings), undef, "find returns undef when no runner is published");

    like(
        dies { App::Yath2::Pfile->find() },
        qr/Settings is a required argument/,
        "settings is required",
    );
};

done_testing;
