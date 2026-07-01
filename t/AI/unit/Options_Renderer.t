use Test2::V0;

use App::Yath2;
use Getopt::Yath::Settings;

$ENV{'YATH_SELF_TEST'} = 1;

# Inline custom renderer that contributes its OWN option group. With
# `mod_adds_options => 1` on the Display `renderers` option, naming this
# renderer on the command line must auto-load its option_group so the
# renderer-defined flag (--zz-render-thing) parses. This mirrors the
# dynamic_finder_option test in Options_Finder.t but for the renderers Map.
{
    package Test2::Harness2::Renderer::TestOpt;
    use Getopt::Yath;
    option_group {group => 'testrender', category => 'TestRender'} => sub {
        option zz_render_thing => (type => 'Scalar', description => 'zz');
    };
    our @ISA = ('Test2::Harness2::Renderer::Base');
    $INC{'Test2/Harness2/Renderer/TestOpt.pm'} = __FILE__;
}

subtest renderer_contributes_options => sub {
    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['test', '--renderer', 'TestOpt', '--zz-render-thing', 'hello', __FILE__],
        config   => {},
        settings => $settings,
    );

    my $ok;
    my @ignore = warns { $ok = eval { $app->process_argv; 1 } };
    my $err = $@;

    ok($ok, "A custom renderer's own option parses after --renderer") or diag($err);
    is($settings->testrender->zz_render_thing, 'hello', "renderer-contributed option value captured");

    # The renderer itself still lands in the renderers map under its fully
    # qualified class name (mod_adds_options does not displace the trigger).
    ok($settings->display->renderers->{'Test2::Harness2::Renderer::TestOpt'}, "renderer registered in renderers map");
};

# Fully qualified form via '+' must also auto-load the renderer's options.
subtest renderer_contributes_options_fqmod => sub {
    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(
        argv     => ['test', '--renderer', '+Test2::Harness2::Renderer::TestOpt', '--zz-render-thing', 'world', __FILE__],
        config   => {},
        settings => $settings,
    );

    my $ok;
    my @ignore = warns { $ok = eval { $app->process_argv; 1 } };
    my $err = $@;

    ok($ok, "A custom renderer's own option parses after --renderer +Full::Class") or diag($err);
    is($settings->testrender->zz_render_thing, 'world', "renderer-contributed option value captured (fqmod form)");
};

done_testing;
