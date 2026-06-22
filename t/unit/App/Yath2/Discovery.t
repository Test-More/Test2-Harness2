use Test2::V0 -target => 'App::Yath2::Discovery';
use Test2::Tools::Spec;

use File::Temp qw/tempdir/;
use File::Spec;
use Sys::Hostname qw/hostname/;

use Test2::Collector::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util qw/clean_path/;

use App::Yath2::Discovery;

# A minimal stand-in for Getopt::Yath::Settings: find_runner_link only ever calls
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

# Stand up a real runner-style workdir: a bound unix socket named runner.socket
# plus a PID file. Returns ($workdir, $listen_socket) -- keep the socket in scope
# so it stays bound for connect-based liveness checks.
sub make_workdir {
    my (%params) = @_;
    my $workdir = clean_path(tempdir(CLEANUP => 1));

    my $listen;
    unless ($params{no_socket}) {
        my $sock_path = File::Spec->catfile($workdir, 'runner.socket');
        $listen = open_unix_listen($sock_path);
    }

    unless ($params{no_pid}) {
        my $pidfile = File::Spec->catfile($workdir, 'PID');
        open(my $fh, '>', $pidfile) or die "Could not write PID file: $!";
        print $fh ($params{pid} // $$);
        close($fh);
    }

    return ($workdir, $listen);
}

# A settings object pinned to a fresh persist dir (via persist_dir, so no env
# juggling) plus the symlink path find_runner_link picks for it.
sub link_in_persist_dir {
    my $persist  = tempdir(CLEANUP => 1);
    my $settings = MockSettings->new(project => 'Disco-Test', persist_dir => $persist);
    my $link     = App::Yath2::Util::find_runner_link($settings, vivify => 1);
    return ($persist, $link, $settings);
}

tests publish_and_find => sub {
    my ($workdir, $listen) = make_workdir();
    my $persist = tempdir(CLEANUP => 1);
    local $ENV{YATH_PERSISTENCE_DIR} = $persist;

    my $settings = MockSettings->new(project => 'Disco-Pub');

    my $pub = App::Yath2::Discovery->publish($settings, workdir => $workdir);
    isa_ok($pub, [$CLASS], "publish returned a Discovery");
    ok(-l $pub->link, "publish created a symlink");
    is(readlink($pub->link), File::Spec->catfile($workdir, 'runner.socket'), "symlink points at runner.socket");

    my $found = App::Yath2::Discovery->find($settings);
    isa_ok($found, [$CLASS], "find located the published runner");
    is($found->link, $pub->link, "find resolved the same symlink");
    is($found->workdir, $workdir, "find resolved the workdir from the socket dir");
    is($found->socket, clean_path(File::Spec->catfile($workdir, 'runner.socket')), "find resolved the socket path");
    is($found->pid, "$$", "find read the runner pid from the workdir PID file");

    my $link_path = $found->link;
    is(
        $found->describe,
        "\nFound: $link_path\n  PID: $$\n  Dir: $workdir\n\n",
        "describe matches the which/watch banner",
    );
};

tests dangling_symlink_is_cleaned => sub {
    my ($persist, $link, $settings) = link_in_persist_dir();

    # Point the symlink at a runner.socket that does not exist (a crashed runner).
    my $gone = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');
    symlink($gone, $link) or die "symlink failed: $!";
    ok(-l $link, "dangling symlink created");

    my $found = App::Yath2::Discovery->find($settings);
    is($found, undef, "find returns nothing for a dangling symlink (runner absent)");
    ok(!-l $link, "find cleaned up the stale dangling symlink");
};

tests dead_socket_is_cleaned => sub {
    my ($workdir, $listen) = make_workdir();
    my ($persist, $link, $settings) = link_in_persist_dir();

    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink failed: $!";

    # Close the listener -- the socket inode still exists on disk, but connect now
    # fails (a wedged/dead runner whose socket no longer accepts).
    close($listen);
    unlink(File::Spec->catfile($workdir, 'runner.socket'));

    my $found = App::Yath2::Discovery->find($settings);
    is($found, undef, "find returns nothing when the socket no longer accepts");
    ok(!-l $link, "find cleaned up the stale symlink for the dead runner");
};

tests no_clean_leaves_stale_link => sub {
    my ($persist, $link, $settings) = link_in_persist_dir();
    my $gone = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');
    symlink($gone, $link) or die "symlink failed: $!";

    my $found = App::Yath2::Discovery->find($settings, no_clean => 1);
    is($found, undef, "find still returns nothing for a dead runner");
    ok(-l $link, "no_clean left the stale symlink in place");
};

tests pid_fallback => sub {
    # The PID file is the signal fallback when the socket is unresponsive. Even with
    # no live socket, an instance built directly over the workdir reads the pid.
    my ($workdir, $listen) = make_workdir(pid => 4242);
    my $link = File::Spec->catfile($workdir, 'the.sock');
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink failed: $!";

    my $disco = $CLASS->new(link => $link);
    is($disco->pid, "4242", "pid read from the workdir PID file");
    is($disco->workdir, $workdir, "workdir derived from the symlink target");
};

tests missing_pid_file => sub {
    my ($workdir, $listen) = make_workdir(no_pid => 1);
    my $link = File::Spec->catfile($workdir, 'the.sock');
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink failed: $!";

    my $disco = $CLASS->new(link => $link);
    is($disco->pid, undef, "pid is undef when the PID file is missing");
};

tests find_when_absent => sub {
    my $persist = tempdir(CLEANUP => 1);
    local $ENV{YATH_PERSISTENCE_DIR} = $persist;
    my $settings = MockSettings->new(project => 'Disco-None');

    is(App::Yath2::Discovery->find($settings), undef, "find returns nothing when no symlink exists");

    like(
        dies { App::Yath2::Discovery->find() },
        qr/Settings is a required argument/,
        "settings is required",
    );

    like(
        dies { App::Yath2::Discovery->new() },
        qr/'link' is a required attribute/,
        "link is a required attribute",
    );
};

tests publish_replaces_stale_link => sub {
    my ($workdir, $listen) = make_workdir();
    my $persist = tempdir(CLEANUP => 1);
    local $ENV{YATH_PERSISTENCE_DIR} = $persist;
    my $settings = MockSettings->new(project => 'Disco-Replace');

    # A stale symlink from a crashed runner already sits at the path.
    my $first = App::Yath2::Discovery->publish($settings, workdir => tempdir(CLEANUP => 1));
    ok(-l $first->link, "stale symlink exists");

    my $second = App::Yath2::Discovery->publish($settings, workdir => $workdir);
    is($second->link, $first->link, "publish reused the same well-known path");
    is(readlink($second->link), File::Spec->catfile($workdir, 'runner.socket'), "publish replaced the stale target");
};

tests publish_refuses_non_symlink => sub {
    my ($workdir, $listen) = make_workdir();
    my $persist = tempdir(CLEANUP => 1);
    local $ENV{YATH_PERSISTENCE_DIR} = $persist;
    my $settings = MockSettings->new(project => 'Disco-Refuse');

    my $link = App::Yath2::Util::find_runner_link($settings, vivify => 1);
    open(my $fh, '>', $link) or die "could not create blocker file: $!";
    print $fh "not a symlink";
    close($fh);

    like(
        dies { App::Yath2::Discovery->publish($settings, workdir => $workdir) },
        qr/exists and is not a symlink/,
        "publish refuses to clobber a non-symlink at the discovery path",
    );
};

done_testing;
