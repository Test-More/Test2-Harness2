use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket #150 (79): an explicit --no-notify-email-owner /
# --no-notify-slack-owner must NOT be force-flipped back on when a matching
# notification source (address / url) is also configured. The owner flags now use
# a maybe=>1 undef sentinel resolved in post_process: undef (untouched) defaults
# from list presence (1.0 semantics), a defined 0 (explicit --no-*) always wins.

use App::Yath2::Plugin::Notify;
use Getopt::Yath::Settings;

sub settings {
    my %notify = (
        slack_url   => undef,
        slack       => [],
        slack_fail  => [],
        slack_owner => undef,

        email       => [],
        email_fail  => [],
        email_owner => undef,

        @_,
    );

    return Getopt::Yath::Settings->new(
        notify  => {%notify},
        harness => {plugins => []},
    );
}

sub run_post {
    my ($settings) = @_;
    App::Yath2::Plugin::Notify::post_process(undef, {settings => $settings});
    return $settings;
}

subtest 'email: explicit --no-notify-email-owner suppresses owner but still loads plugin for the address' => sub {
    my $s = run_post(settings(email => ['foo@example.com'], email_owner => 0));

    is($s->notify->email_owner, 0, "explicit opt-out stays off (not force-flipped on)");
    is(scalar(@{$s->harness->plugins}), 1, "plugin still loaded to mail the explicit --notify-email address");
};

subtest 'email: untouched owner defaults ON from list presence (1.0 semantics)' => sub {
    my $s = run_post(settings(email => ['foo@example.com']));

    is($s->notify->email_owner, 1, "owner defaults on when an email list is present and flag untouched");
    is(scalar(@{$s->harness->plugins}), 1, "plugin loaded");
};

subtest 'email: no sources, untouched owner => off, no plugin' => sub {
    my $s = run_post(settings());

    is($s->notify->email_owner, 0, "email_owner resolves to a defined 0");
    is($s->notify->slack_owner, 0, "slack_owner resolves to a defined 0");
    is(scalar(@{$s->harness->plugins}), 0, "no plugin loaded with no sources");
};

subtest 'slack: explicit --no-notify-slack-owner suppresses owner but slack still active for the url' => sub {
    my $s = run_post(settings(slack_url => 'https://hooks.slack.com/services/x', slack_owner => 0));

    is($s->notify->slack_owner, 0, "explicit slack opt-out stays off");
    is(scalar(@{$s->harness->plugins}), 1, "plugin loaded because a slack url source is present");
};

subtest 'slack: untouched owner defaults ON from a slack source' => sub {
    my $s = run_post(settings(slack_url => 'https://hooks.slack.com/services/x', slack => ['#chan']));

    is($s->notify->slack_owner, 1, "slack_owner defaults on from list presence when untouched");
    is(scalar(@{$s->harness->plugins}), 1, "plugin loaded");
};

subtest 'email: --notify-email-fail alone registers the plugin without enabling owner (ticket #126)' => sub {
    my $s = run_post(settings(email_fail => ['dev@example.com']));

    is($s->notify->email_owner, 0, "email_fail does NOT auto-enable email_owner (1.0 semantics preserved)");
    is(scalar(@{$s->harness->plugins}), 1, "plugin registered so the failure email is actually sent");
};

subtest 'email: --notify-email-fail with an explicit --notify-email-owner still honors both' => sub {
    my $s = run_post(settings(email_fail => ['dev@example.com'], email_owner => 1));

    is($s->notify->email_owner, 1, "explicit owner opt-in preserved alongside email_fail");
    is(scalar(@{$s->harness->plugins}), 1, "plugin registered");
};

subtest 'slack: enabling owner without a url dies (unchanged contract)' => sub {
    like(
        dies { run_post(settings(slack_owner => 1)) },
        qr/slack url must be provided/,
        "explicit --notify-slack-owner with no url still errors",
    );
};

done_testing;
