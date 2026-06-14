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

done_testing;
