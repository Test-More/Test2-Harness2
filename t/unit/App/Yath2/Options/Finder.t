use Test2::V0;

use App::Yath2;
use Getopt::Yath::Settings;

$ENV{'YATH_SELF_TEST'} = 1;

# Inline custom finder that records when its munge_settings extension point is
# invoked. Registered under the Test2::Harness2::Finder::* namespace so that
# `--finder TestMunge` resolves to it.
{
    package Test2::Harness2::Finder::TestMunge;
    our @ISA = ('Test2::Harness2::Finder');
    our $MUNGED = 0;
    sub munge_settings { $MUNGED++ }
    $INC{'Test2/Harness2/Finder/TestMunge.pm'} = __FILE__;
}

subtest munge_settings_invoked => sub {
    local $Test2::Harness2::Finder::TestMunge::MUNGED = 0;

    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['test', '--finder', 'TestMunge', __FILE__],
        config   => {},
        settings => $settings,
    );

    my @ignore = warns { $app->process_argv };

    ok($Test2::Harness2::Finder::TestMunge::MUNGED, "finder->munge_settings() was invoked during option processing");
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

done_testing;
