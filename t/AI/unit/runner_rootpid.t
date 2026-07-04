use Test2::V0;
# HARNESS-DURATION-SHORT

# Ticket TODO-22: the runner and the preload-root stage host are now two fully
# independent classes. The runner is ALWAYS the root scheduler (it never becomes a
# stage host), so it no longer carries the rootpid-gated is_stage_service /
# service_name stage behavior. That stage-service identity now lives in
# Test2::Harness2::Preload::Host, the independent stage host. This test pins the
# split: the runner names the 'runner' service unconditionally, and the host names
# 'preload-<stage>' once it is hosting a stage.

use File::Temp qw/tempdir/;
use Getopt::Yath::Settings;

use Test2::Harness2::Runner;
use Test2::Harness2::Preload::Host;

my $dir = tempdir(CLEANUP => 1);

# The runner still honors an injected rootpid (it is conveyed down as
# runner_pid / watch_parent_pid), defaulting to this process when not given.
my $default = Test2::Harness2::Runner->new(
    dir       => $dir,
    settings  => Getopt::Yath::Settings->new(harness => {}),
    resources => [],
);
is($default->rootpid, $$, "runner rootpid defaults to this process when not injected");

my $injected = Test2::Harness2::Runner->new(
    dir       => $dir,
    settings  => Getopt::Yath::Settings->new(harness => {}),
    resources => [],
    rootpid   => 999_999,
);
is($injected->rootpid, 999_999, "injected rootpid is honored, not overwritten with \$\$");

# The runner is always the root scheduler: it has no stage-service identity, and
# its service is always 'runner.socket'.
ok(!$injected->can('is_stage_service'), "runner no longer carries is_stage_service (it is never a stage host)");
is($injected->service_name, 'runner', "runner always names the 'runner' service");

# The stage host (Preload::Host) owns the stage-service identity. It requires the
# real runner's pid as rootpid and identifies as a 'preload-<stage>' service once
# it is hosting a stage.
my $host = Test2::Harness2::Preload::Host->new(
    dir       => $dir,
    settings  => Getopt::Yath::Settings->new(harness => {}),
    resources => [],
    rootpid   => 999_999,
);
ok(!$host->is_stage_service, "host with no stage yet -> not a stage service");
is($host->service_name, 'runner', "host with no stage yet -> names the base 'runner' service");

$host->{stage} = 'base';
ok($host->is_stage_service, "host with a stage -> stage service");
is($host->service_name, 'preload-base', "host stage service names its socket preload-<stage>");

done_testing;
