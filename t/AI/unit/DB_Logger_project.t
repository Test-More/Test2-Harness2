use Test2::V0;

# Ticket #128: the DB logger attributed EVERY run to a single 'tmp' projects row.
#
# _project_name derived the name from the workdir's PARENT directory. The default
# workdir is a random 'yath-<pid>-XXXXXX' tempdir under the system temp dir, so its
# parent is just 'tmp' -- every `yath test -L db.sqlite` from every project
# collapsed into one 'tmp' row, and the user's --project was ignored entirely.
#
# The fix threads --project (and the launch cwd) through the logger config written
# by Command/test.pm start_loggers, and _project_name now prefers --project, then
# falls back to the launch cwd's BASENAME -- never a workdir-derived path.
#
# This drives both halves: (1) start_loggers writes project + launch_dir into the
# logger config; (2) the logger's _ensure_run_row attributes the runs row to that
# project (or the launch-dir fallback). The logger half needs the opt-in DB deps;
# skipped cleanly when they are missing (R11). The command half needs no DB.

use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/decode_json/;

my $tmp_root = tempdir(CLEANUP => 1);

# The logger half is opt-in on the DB deps (R11). The command half is DB-free, so
# it always runs; we gate only the DB subtests (a top-level skip_all is impossible
# once the command-half events have been emitted).
my $HAVE_DB = (eval { require DBD::SQLite; 1 } && eval { require DBIx::QuickORM; 1 }) ? 1 : 0;

# --------------------------------------------------------------------------- #
# Command half: start_loggers threads --project + launch_dir into the config.
# --------------------------------------------------------------------------- #
{
    package t2h2::FakeLogger;
    sub new     { my ($c, %a) = @_; bless {%a}, $c }
    sub targets { $_[0]->{targets} }

    package t2h2::FakeHarness;
    sub new      { my ($c, %a) = @_; bless {%a}, $c }
    sub project  { $_[0]->{project} }
    sub dev_libs { $_[0]->{dev_libs} }

    package t2h2::FakeSettings;
    sub new         { my ($c, %a) = @_; bless {%a}, $c }
    sub check_group { $_[0]->{groups}{$_[1]} ? 1 : 0 }
    sub logger      { $_[0]->{logger} }
    sub harness     { $_[0]->{harness} }

    package t2h2::FakeTestCmd;
    our @ISA = ('App::Yath2::Command::test');
    sub settings { $_[0]->{settings} }
    sub workdir  { $_[0]->{workdir} }
    sub run_id   { $_[0]->{run_id} }
}

require App::Yath2::Command::test;
require Test2::Harness2::Util::IPC;

# Capture the spawned command (so we can read the config file) without launching a
# real logger process.
sub run_start_loggers {
    my ($project) = @_;

    my $settings = t2h2::FakeSettings->new(
        groups  => {logger => 1, harness => 1},
        logger  => t2h2::FakeLogger->new(targets => ["$tmp_root/attr.sqlite"]),
        harness => t2h2::FakeHarness->new(project => $project, dev_libs => []),
    );

    my $cmd = bless {
        settings => $settings,
        workdir  => "$tmp_root/yath-99999-ABCDEF",    # a workdir-shaped path
        run_id   => lc(gen_uuid()),
    }, 't2h2::FakeTestCmd';

    my @spawned;
    no warnings 'redefine', 'once';
    local *Test2::Harness2::Util::IPC::run_cmd = sub { my %a = @_; push @spawned, $a{command}; return 4242 };
    $cmd->start_loggers;

    my $cfg_file = $spawned[0][-1];    # the logger reads $ARGV[0] = the config path
    open(my $fh, '<', $cfg_file) or die "no config file: $!";
    my $json = do { local $/; <$fh> };
    close($fh);
    unlink($cfg_file);

    return decode_json($json);
}

subtest 'start_loggers threads --project into the logger config' => sub {
    my $cfg = run_start_loggers('foo');
    is($cfg->{project}, 'foo', "config carries the --project value");
    ok(defined($cfg->{launch_dir}) && length($cfg->{launch_dir}), "config carries the launch cwd");
    is($cfg->{launch_dir}, File::Spec->rel2abs(Cwd::getcwd()), "launch_dir is the command's cwd (the launch dir)")
        if eval { require Cwd; 1 };
};

subtest 'start_loggers still threads launch_dir when --project is unset' => sub {
    my $cfg = run_start_loggers(undef);
    ok(!defined($cfg->{project}), "no --project -> config project is null");
    ok(defined($cfg->{launch_dir}) && length($cfg->{launch_dir}), "launch_dir still present for the fallback");
};

# --------------------------------------------------------------------------- #
# Logger half: _ensure_run_row attributes the runs row from project/launch_dir.
# --------------------------------------------------------------------------- #
require App::Yath2::DB::Logger;

my $db_seq = 0;
sub seed_run {
    my (%args) = @_;
    my $db = "$tmp_root/proj-" . ($db_seq++) . ".sqlite";
    my $log = App::Yath2::DB::Logger->new(
        run_id => lc(gen_uuid()),
        target => $db,
        %args,
    );
    $log->_ensure_run_row(undef);    # seeds hosts/machine_users/projects + the runs row
    return $log;
}

subtest '--project attributes the run to that project (not tmp)' => sub {
    skip_all "DB deps (DBD::SQLite + DBIx::QuickORM) not available" unless $HAVE_DB;

    my $log = seed_run(
        workdir => "$tmp_root/yath-99999-ABCDEF",    # workdir shaped like the real tempdir
        project => 'foo',
    );

    my @projects = $log->con->handle('projects')->all;
    is(scalar(@projects), 1, "exactly one project row");
    is($projects[0]->field('name'), 'foo', "project attributed to --project 'foo', not 'tmp'");

    my ($run) = $log->con->handle('runs')->all;
    is($run->field('project_id'), $projects[0]->field('project_id'), "runs row points at the 'foo' project");
};

subtest 'no --project falls back to the launch cwd basename (never tmp / yath-*)' => sub {
    skip_all "DB deps (DBD::SQLite + DBIx::QuickORM) not available" unless $HAVE_DB;

    my $launch = File::Spec->catdir($tmp_root, 'coolproj');
    my $log = seed_run(
        workdir    => "$tmp_root/yath-99999-ABCDEF",
        launch_dir => $launch,
        # project intentionally unset
    );

    my ($proj) = $log->con->handle('projects')->all;
    is($proj->field('name'), 'coolproj', "project = launch cwd basename");
    isnt($proj->field('name'), 'tmp', "never the workdir-parent 'tmp'");
    unlike($proj->field('name'), qr/^yath-/, "never the random workdir basename");
};

subtest '_project_name ignores the workdir entirely (regression on the parent-dir bug)' => sub {
    # No project, no launch_dir: fall back to THIS process cwd -- must not be the
    # workdir's parent ('tmp') nor the workdir basename.
    my $log = App::Yath2::DB::Logger->new(
        run_id  => lc(gen_uuid()),
        target  => "$tmp_root/nolaunch.sqlite",
        workdir => "$tmp_root/yath-99999-ABCDEF",
    );
    my $name = $log->_project_name;
    isnt($name, 'tmp',              "workdir parent 'tmp' is never used");
    isnt($name, 'yath-99999-ABCDEF', "workdir basename is never used");
    ok(defined($name) && length($name), "a concrete fallback name is produced");
};

done_testing;
