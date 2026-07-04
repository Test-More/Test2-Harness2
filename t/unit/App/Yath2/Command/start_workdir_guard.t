use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Command::start;

# Ticket TODO-145, finding 64: the already-running / not-responding abort path in
# `yath start` must remove_tree the workdir ONLY when it was freshly created for
# THIS invocation, is not the found runner's own workdir, and holds neither a
# runner.socket nor a PID file. The old unguarded remove_tree deleted ANY pinned
# workdir -- including the LIVE runner's own when YATH_WORKDIR was reused.

# Mocks for $self->settings->workspace and the found discovery object.
{
    package MockWorkspace;
    sub new { my ($c, %p) = @_; bless {%p}, $c }
    sub check_option { 1 }                       # created_workdir option is present
    sub created_workdir { $_[0]->{created} }

    package MockSettings;
    sub new { my ($c, %p) = @_; bless {ws => MockWorkspace->new(%p)}, $c }
    sub workspace { $_[0]->{ws} }

    package MockFound;
    sub new { my ($c, %p) = @_; bless {%p}, $c }
    sub workdir { $_[0]->{workdir} }
}

sub start_with { App::Yath2::Command::start->new(settings => MockSettings->new(@_)) }

sub fresh_dir {
    my (%files) = @_;
    my $dir = tempdir(CLEANUP => 1);
    for my $name (keys %files) {
        next unless $files{$name};
        open(my $fh, '>', File::Spec->catfile($dir, $name)) or die "write $name: $!";
        print $fh "x";
        close($fh);
    }
    return $dir;
}

# created this run, a DIFFERENT found dir, empty $dir -> REMOVE.
{
    my $dir   = fresh_dir();
    my $start = start_with(created => 1);
    my $found = MockFound->new(workdir => File::Spec->catdir(tempdir(CLEANUP => 1), 'other'));
    $start->_maybe_remove_workdir($dir, $found);
    ok(!-d $dir, "a freshly-created throwaway workdir is removed on the abort path");
}

# NOT created this run (pinned/reused) -> KEEP.
{
    my $dir   = fresh_dir();
    my $start = start_with(created => 0);
    my $found = MockFound->new(workdir => File::Spec->catdir(tempdir(CLEANUP => 1), 'other'));
    $start->_maybe_remove_workdir($dir, $found);
    ok(-d $dir, "a reused/pinned workdir (not created this run) is left intact");
}

# created, but $dir IS the found runner's own workdir -> KEEP.
{
    my $dir   = fresh_dir();
    my $start = start_with(created => 1);
    my $found = MockFound->new(workdir => $dir);
    $start->_maybe_remove_workdir($dir, $found);
    ok(-d $dir, "the found runner's own workdir is never removed (even flagged created)");
}

# created, but $dir holds a live runner.socket -> KEEP (paranoia against a lying flag).
{
    my $dir   = fresh_dir('runner.socket' => 1);
    my $start = start_with(created => 1);
    my $found = MockFound->new(workdir => File::Spec->catdir(tempdir(CLEANUP => 1), 'other'));
    $start->_maybe_remove_workdir($dir, $found);
    ok(-d $dir, "a workdir containing runner.socket is never removed");
}

# created, but $dir holds a PID file -> KEEP.
{
    my $dir   = fresh_dir('PID' => 1);
    my $start = start_with(created => 1);
    my $found = MockFound->new(workdir => File::Spec->catdir(tempdir(CLEANUP => 1), 'other'));
    $start->_maybe_remove_workdir($dir, $found);
    ok(-d $dir, "a workdir containing a PID file is never removed");
}

done_testing;
