use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD
#
# Ticket TODO-151 (finding 49): CoverageAggregator::ByRun::get_coverage_tests had
# its --changes-exclude-loads / --changes-exclude-opens guards SWAPPED relative
# to ByTest and the option docs. On run-level (JSON) coverage each flag then had
# the mirror-image wrong effect, so the two coverage formats produced
# contradictory test selections for identical data (only manifests when a user
# passes either flag).
#
# The '*' bucket is "loads" (code run outside a sub / file loaded) and must be
# gated by changes_exclude_loads; the '<>' bucket is "opens" (file open()ed) and
# must be gated by changes_exclude_opens. This test drives both aggregators over
# equivalent data and asserts:
#   1. each flag excludes the correct bucket in ByRun (the un-swap pin), and
#   2. ByRun and ByTest select the identical set of tests for identical data
#      under every flag combination.

use strict;
use warnings;

BEGIN {
    eval { require Test2::Harness2::Log::CoverageAggregator::ByRun;  1 }
        or plan skip_all => "ByRun aggregator required: $@";
    eval { require Test2::Harness2::Log::CoverageAggregator::ByTest; 1 }
        or plan skip_all => "ByTest aggregator required: $@";
}

# ---------------------------------------------------------------------------
# Minimal settings stand-in: get_coverage_tests only calls check_group('finder')
# and then $settings->finder->changes_exclude_loads / changes_exclude_opens.
# ---------------------------------------------------------------------------
{
    package MockFinder;
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub changes_exclude_loads { $_[0]->{changes_exclude_loads} }
    sub changes_exclude_opens { $_[0]->{changes_exclude_opens} }

    package MockSettings;
    sub new { my ($c, %a) = @_; bless {finder => MockFinder->new(%a)}, $c }
    sub check_group { $_[1] eq 'finder' ? 1 : 0 }
    sub finder      { $_[0]->{finder} }
}

sub settings { MockSettings->new(@_) }

my $CHANGED = 'lib/Changed.pm';

# The user changed only the 'mysub' sub, so 'mysub' is the sole explicit part.
# The load/open buckets ('*' / '<>') are only pulled in via the exclude guards.
my $changes = {$CHANGED => {mysub => 1}};

my $T_SUB  = 't/sub.t';     # touches lib/Changed.pm via the changed sub
my $T_LOAD = 't/load.t';    # only loads lib/Changed.pm ('*' bucket)
my $T_OPEN = 't/open.t';    # only open()s lib/Changed.pm ('<>' bucket)

# Run-level (ByRun) blob: files => {file => {part => {test => [...]}}}
my $run_cov = {
    aggregator => 'Test2::Harness2::Log::CoverageAggregator::ByRun',
    files      => {
        $CHANGED => {
            'mysub' => {$T_SUB  => ['*']},
            '*'     => {$T_LOAD => ['*']},
            '<>'    => {$T_OPEN => ['*']},
        },
    },
};

# Per-test (ByTest) records: files => {file => {part => [...]}}
my %test_cov = (
    $T_SUB  => {test => $T_SUB,  files => {$CHANGED => {'mysub' => ['*']}}},
    $T_LOAD => {test => $T_LOAD, files => {$CHANGED => {'*'  => ['*']}}},
    $T_OPEN => {test => $T_OPEN, files => {$CHANGED => {'<>' => ['*']}}},
);

sub byrun_tests {
    my (%flags) = @_;
    return [sort(Test2::Harness2::Log::CoverageAggregator::ByRun->get_coverage_tests(settings(%flags), $changes, $run_cov))];
}

sub bytest_tests {
    my (%flags) = @_;
    my %seen;
    for my $t (sort keys %test_cov) {
        $seen{$_}++ for Test2::Harness2::Log::CoverageAggregator::ByTest->get_coverage_tests(settings(%flags), $changes, $test_cov{$t});
    }
    return [sort keys %seen];
}

# --- No flags: every touching test runs -------------------------------------
{
    my $expect = [$T_LOAD, $T_OPEN, $T_SUB];
    is(byrun_tests(),  $expect, "ByRun:  no flags => all three tests");
    is(bytest_tests(), $expect, "ByTest: no flags => all three tests");
}

# --- exclude_loads: the LOAD-only test drops, OPEN stays --------------------
{
    my $expect = [$T_OPEN, $T_SUB];
    is(
        byrun_tests(changes_exclude_loads => 1),
        $expect,
        "ByRun: --changes-exclude-loads drops the load-only test (not the open-only one)",
    );
    is(
        bytest_tests(changes_exclude_loads => 1),
        $expect,
        "ByTest: --changes-exclude-loads drops the load-only test",
    );
}

# --- exclude_opens: the OPEN-only test drops, LOAD stays --------------------
{
    my $expect = [$T_LOAD, $T_SUB];
    is(
        byrun_tests(changes_exclude_opens => 1),
        $expect,
        "ByRun: --changes-exclude-opens drops the open-only test (not the load-only one)",
    );
    is(
        bytest_tests(changes_exclude_opens => 1),
        $expect,
        "ByTest: --changes-exclude-opens drops the open-only test",
    );
}

# --- The two formats never contradict each other for identical data ---------
for my $flags (
    {},
    {changes_exclude_loads => 1},
    {changes_exclude_opens => 1},
    {changes_exclude_loads => 1, changes_exclude_opens => 1},
) {
    my $label = join(',', map {"$_=$flags->{$_}"} sort keys %$flags) || '(none)';
    is(
        byrun_tests(%$flags),
        bytest_tests(%$flags),
        "ByRun and ByTest select identical tests under flags: $label",
    );
}

done_testing;
