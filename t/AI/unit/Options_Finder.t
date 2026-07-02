use Test2::V0;

use App::Yath2;
use Getopt::Yath::Settings;

$ENV{'YATH_SELF_TEST'} = 1;

# Inline custom finder that records when its munge_settings extension point is
# invoked. Registered under the App::Yath2::Finder::* namespace so that
# `--finder TestMunge` resolves to it.
{
    package App::Yath2::Finder::TestMunge;
    our @ISA = ('App::Yath2::Finder');
    our $MUNGED = 0;
    sub munge_settings { $MUNGED++ }
    $INC{'App/Yath2/Finder/TestMunge.pm'} = __FILE__;
}

subtest munge_settings_invoked => sub {
    local $App::Yath2::Finder::TestMunge::MUNGED = 0;

    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['test', '--finder', 'TestMunge', __FILE__],
        config   => {},
        settings => $settings,
    );

    my @ignore = warns { $app->process_argv };

    ok($App::Yath2::Finder::TestMunge::MUNGED, "finder->munge_settings() was invoked during option processing");
};

# Inline custom finder that contributes its OWN option. Its options are only
# included from the finder trigger (mid-parse), exercising the dynamic-include
# preload path.
{
    package App::Yath2::Finder::TestOpt;
    use Getopt::Yath;
    option_group {group => 'testopt', category => 'TestOpt'} => sub {
        option zz_thing => (type => 'Scalar', description => 'zz');
    };
    our @ISA = ('App::Yath2::Finder');
    $INC{'App/Yath2/Finder/TestOpt.pm'} = __FILE__;
}

subtest dynamic_finder_option => sub {
    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['test', '--finder', 'TestOpt', '--zz-thing', 'hello', __FILE__],
        config   => {},
        settings => $settings,
    );

    my $ok;
    my @ignore = warns { $ok = eval { $app->process_argv; 1 } };
    my $err = $@;

    ok($ok, "A custom finder's own option parses after --finder") or diag($err);
    is($settings->testopt->zz_thing, 'hello', "finder-contributed option value captured");
};

subtest rerun_conflicting_logs => sub {
    my $run = sub {
        my (@argv) = @_;
        my $settings = Getopt::Yath::Settings->new(harness => {});
        my $app = App::Yath2->new(argv => [@argv], config => {}, settings => $settings);
        my ($err, $ok);
        my @ignore = warns { $ok = eval { $app->process_argv; 1 }; $err = $@ };
        return ($ok, $err, $settings);
    };

    my ($ok, $err) = $run->('test', '--rerun-failed=a.jsonl', '--rerun-passed=b.jsonl', __FILE__);
    ok(!$ok, "Conflicting rerun log paths are rejected");
    like($err, qr/Multiple runs specified for rerun/, "Got the expected error message");

    (my $ok2, my $err2, my $settings) = $run->('test', '--rerun-failed=a.jsonl', '--rerun-passed=a.jsonl', __FILE__);
    ok($ok2, "Same rerun log path for two modes is fine") or diag($err2);
    is($settings->finder->rerun, 'a.jsonl', "rerun set to the shared log path");
};

# Ticket #99 step 3: changes_applicable is now a single copy exported from
# App::Yath2::Util and imported by both Options::Finder and Plugin::Cover
# (the two byte-identical local copies were deleted).
subtest changes_applicable_deduped => sub {
    require App::Yath2::Util;
    require App::Yath2::Options::Finder;
    require App::Yath2::Plugin::Cover;

    my $canon = \&App::Yath2::Util::changes_applicable;

    # Both consumers resolve the imported sub to the SINGLE Util copy.
    ok(\&App::Yath2::Options::Finder::changes_applicable == $canon, "Finder imports Util::changes_applicable (same coderef)");
    ok(\&App::Yath2::Plugin::Cover::changes_applicable   == $canon, "Cover imports Util::changes_applicable (same coderef)");

    # Policy: changed-files options do NOT apply to the projects command.
    my $projects = bless {}, 'App::Yath2::Command::projects';
    my $other    = bless {}, 'App::Yath2::Command::test';

    my $with_cmd = sub { Getopt::Yath::Settings->new(harness => {command => $_[0]}) };

    is($canon->(undef, undef, $with_cmd->($projects)), 0, "not applicable for the projects command");
    is($canon->(undef, undef, $with_cmd->($other)),    1, "applicable for a non-projects command");
    is($canon->(undef, undef, Getopt::Yath::Settings->new(harness => {})), 1, "applicable when no command is set");
    is($canon->(undef, undef, Getopt::Yath::Settings->new()), 1, "applicable when there is no harness group");
    is($canon->(undef, undef, undef), 1, "applicable when there are no settings");
};

done_testing;
