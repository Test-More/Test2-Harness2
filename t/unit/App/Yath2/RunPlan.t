use Test2::V0 -target => 'App::Yath2::RunPlan';
use Test2::Tools::Spec;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::RunPlan;

# Minimal stand-ins for the settings tree RunPlan touches. RunPlan only ever
# calls: settings->run->all, settings->finder->finder, settings->finder->all,
# settings->harness->plugins, settings->check_group('display'),
# settings->display->verbose, settings->debug->interactive.
{

    package MockGroup;
    sub new { my ($c, %p) = @_; return bless {%p}, $c }
    sub all { return %{$_[0]->{all} // {}} }
    sub finder  { $_[0]->{finder} }
    sub plugins { $_[0]->{plugins} // [] }
    sub verbose { $_[0]->{verbose} }
    sub interactive { $_[0]->{interactive} }

    package MockSettings;
    sub new { my ($c, %p) = @_; return bless {%p}, $c }
    sub run     { $_[0]->{run} }
    sub finder  { $_[0]->{finder} }
    sub harness { $_[0]->{harness} }
    sub display { $_[0]->{display} }
    sub debug   { $_[0]->{debug} }
    sub check_group { $_[0]->{groups}->{$_[1]} ? 1 : 0 }
}

# A stub test "file": queue_item mirrors the real signature
# ($job_id, $run_id, %extra).
{

    package MockFile;
    sub new { my ($c, $name) = @_; return bless {name => $name}, $c }

    sub queue_item {
        my ($self, $job_id, $run_id, %extra) = @_;
        return {job_id => $job_id, run_id => $run_id, file => $self->{name}, %extra};
    }
}

# A stub finder: records construction args and returns a fixed file list.
our @FINDER_ARGS;
our @FINDER_FILES;
{

    package MockFinder;
    sub new {
        my ($c, @args) = @_;
        @main::FINDER_ARGS = @args;
        return bless {}, $c;
    }
    sub find_files {
        my ($self, $plugins, $settings) = @_;
        return [@main::FINDER_FILES];
    }
}

# RunPlan does require(mod2file($finder_class)); the finder is defined inline
# here, so mark it loaded to make that require a no-op.
$INC{'MockFinder.pm'} = __FILE__;

sub build_settings {
    my (%params) = @_;

    return MockSettings->new(
        run     => MockGroup->new(all => {run_id => $params{run_id} // 'RUN-1'}),
        finder  => MockGroup->new(finder => 'MockFinder', all => {ext => ['t']}),
        harness => MockGroup->new(plugins => $params{plugins} // []),
        display => MockGroup->new(verbose => $params{verbose} // 0),
        debug   => MockGroup->new(interactive => $params{interactive} // 0),
        groups  => $params{groups} // {},
    );
}

tests run_and_run_id => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $plan = App::Yath2::RunPlan->new(
        settings => build_settings(run_id => 'RUN-ABC'),
        workdir  => $dir,
    );

    my $run = $plan->run;
    isa_ok($run, ['Test2::Harness2::Run'], "built a Run");
    is($run->run_id, 'RUN-ABC', "run id from settings");
    is($plan->run_id, 'RUN-ABC', "run_id delegates to the run");
    ref_is($plan->run, $run, "run is cached");

    ok(-d File::Spec->catdir($dir, 'RUN-ABC'), "run dir was created");
};

tests populate => sub {
    local @main::FINDER_FILES = (MockFile->new('t/a.t'), MockFile->new('t/b.t'));

    my $dir = tempdir(CLEANUP => 1);
    my $plan = App::Yath2::RunPlan->new(
        settings => build_settings(run_id => 'RUN-P'),
        workdir  => $dir,
    );

    my $count = $plan->populate();
    is($count, 2, "two jobs found");

    my $tasks = $plan->tasks;
    is(scalar(@$tasks), 2, "two tasks stashed");
    is($tasks->[0], {job_id => 1, run_id => 'RUN-P', file => 't/a.t'}, "first task");
    is($tasks->[1], {job_id => 2, run_id => 'RUN-P', file => 't/b.t'}, "second task");
};

tests display_and_interactive => sub {
    local @main::FINDER_FILES = (MockFile->new('t/a.t'));

    my $dir = tempdir(CLEANUP => 1);
    my $plan = App::Yath2::RunPlan->new(
        settings => build_settings(
            run_id      => 'RUN-D',
            verbose     => 3,
            interactive => 1,
            groups      => {display => 1},
        ),
        workdir => $dir,
    );

    $plan->populate();
    my $task = $plan->tasks->[0];
    is($task->{verbose},  3,           "verbose threaded through when display group is set");
    is($task->{category}, 'isolation', "interactive forces isolation category");
};

tests finder_args_passthrough => sub {
    local @main::FINDER_FILES = ();
    local @main::FINDER_ARGS  = ();

    my $dir = tempdir(CLEANUP => 1);
    my $plan = App::Yath2::RunPlan->new(
        settings    => build_settings(run_id => 'RUN-F'),
        workdir     => $dir,
        finder_args => [multi_project => 1],
    );

    $plan->populate();

    # First the finder->all pairs (ext => [...]), then the extra finder_args.
    is(
        {@main::FINDER_ARGS},
        {ext => ['t'], multi_project => 1},
        "finder constructed with settings finder args plus extra finder_args",
    );
};

done_testing;
