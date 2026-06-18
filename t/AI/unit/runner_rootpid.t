use Test2::V0;
# HARNESS-DURATION-SHORT

# Chunk 19.2a: the runner honors an injected rootpid (the logical root runner's
# pid), defaulting to $$ when none is given. This lets the future preload-root
# build a stage-host Runner whose $$ differs from the real runner, so it
# identifies as a stage instead of the root.

use File::Temp qw/tempdir/;
use Getopt::Yath::Settings;

use Test2::Harness2::Runner;

my $dir = tempdir(CLEANUP => 1);

my $default = Test2::Harness2::Runner->new(
    dir       => $dir,
    settings  => Getopt::Yath::Settings->new(harness => {}),
    resources => [],
);
is($default->rootpid, $$, "rootpid defaults to this process when not injected");

my $injected = Test2::Harness2::Runner->new(
    dir       => $dir,
    settings  => Getopt::Yath::Settings->new(harness => {}),
    resources => [],
    rootpid   => 999_999,
);
is($injected->rootpid, 999_999, "injected rootpid is honored, not overwritten with \$\$");

# A process whose $$ != rootpid identifies as a stage once a stage is set
# (is_stage_service: false for the root, true for a non-root with a stage).
ok(!$injected->is_stage_service, "no stage yet -> not a stage service");
$injected->{stage} = 'base';
ok($injected->is_stage_service, "non-root pid with a stage -> stage service");
is($injected->service_name, 'preload-base', "stage service names its socket preload-<stage>");

done_testing;
