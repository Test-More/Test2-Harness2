use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression guard for ticket TODO-99 step 1: the slack/email notification paths in
# App::Yath2::Plugin::Notify were de-duplicated behind a per-service spec plus
# shared _send_*/_gen_* builders, with the five gen_*_text names kept as thin
# delegators. These tests pin the exact text and dispatch behavior so the
# refactor is provably byte-for-byte identical to the old copy/paste pair.

use App::Yath2::Plugin::Notify;
use Getopt::Yath::Settings;
use Sys::Hostname qw/hostname/;
use Test2::Tools::GenTemp qw/gen_temp/;
use File::Spec;

my $HOST = hostname();

# A stand-in test file whose ->relative is fixed (so text is deterministic).
{
    package FakeTF;
    sub new { bless {rel => $_[1]}, $_[0] }
    sub relative { $_[0]->{rel} }
}

sub notify { App::Yath2::Plugin::Notify->new() }

sub settings {
    my %notify = (
        text        => 'snippet',
        text_module => undef,

        no_batch_slack => 0,
        slack          => [],
        slack_fail     => [],
        slack_owner    => 0,

        no_batch_email => 0,
        email          => [],
        email_fail     => [],
        email_owner    => 0,

        @_,
    );

    return Getopt::Yath::Settings->new(
        notify => {%notify},
        run    => {links => ['http://a', 'http://b']},
    );
}

subtest 'gen_text job: slack vs email differ only in link formatting' => sub {
    my $s  = settings();
    my $ff = FakeTF->new('t/some_test.t');
    my $n  = notify;

    my $slack = $n->gen_text(scope => 'job', service => 'slack', settings => $s, file => $ff, tries => 2);
    my $email = $n->gen_text(scope => 'job', service => 'email', settings => $s, file => $ff, tries => 2);

    my $common = "snippet\n\nFailed test on $HOST: 't/some_test.t'.\n\nTest was run 3 time(s).\n\n";

    is($slack, $common . "> <http://a|http://a>\n> <http://b|http://b>", "slack job text wraps links");
    is($email, $common . "http://a\nhttp://b", "email job text uses plain links");
};

subtest 'gen_text job: tries=0 omits the run-count line; empty text omitted' => sub {
    my $s  = settings(text => '');
    my $ff = FakeTF->new('t/x.t');
    my $n  = notify;

    my $slack = $n->gen_text(scope => 'job', service => 'slack', settings => $s, file => $ff, tries => 0);
    is(
        $slack,
        "Failed test on $HOST: 't/x.t'.\n\n> <http://a|http://a>\n> <http://b|http://b>",
        "no snippet, no run-count line when text is empty and tries=0",
    );
};

subtest 'gen_text run: slack vs email, subject fallback' => sub {
    my $s = settings();
    my $n = notify;

    my $slack = $n->gen_text(scope => 'run', service => 'slack', settings => $s, final => {pass => 0}, files => "f1\nf2");
    my $email = $n->gen_text(scope => 'run', service => 'email', settings => $s, final => {pass => 0}, files => "f1\nf2");
    my $subj  = $n->gen_text(scope => 'run', service => 'email_subject', settings => $s, final => {pass => 0});

    my $common = "snippet\n\nTests failed on $HOST\n\nf1\nf2\n\n";

    is($slack, $common . "> <http://a|http://a>\n> <http://b|http://b>", "slack run text wraps links");
    is($email, $common . "http://a\nhttp://b", "email run text uses plain links + subject fallback == pass/fail line");
    is($subj, "Tests failed on $HOST", "email subject text");

    my $pass = $n->gen_text(scope => 'run', service => 'email_subject', settings => $s, final => {pass => 1});
    is($pass, "Tests passed on $HOST", "pass subject text");
};

# Capturing subclass: record which low-level sender ran and with what args,
# instead of hitting HTTP::Tiny / Email::Stuffer.
{
    package CaptureNotify;
    our @ISA = ('App::Yath2::Plugin::Notify');
    our @CALLS;
    sub _send_slack { my $self = shift; my ($text, $settings, @to) = @_; push @CALLS, {service => 'slack', text => $text, to => [@to]} }
    sub _send_email { my $self = shift; my ($subject, $text, $settings, @to) = @_; push @CALLS, {service => 'email', subject => $subject, text => $text, to => [@to]} }
}

sub capture { local @CaptureNotify::CALLS = (); my $cb = shift; $cb->(CaptureNotify->new()); [@CaptureNotify::CALLS] }

subtest '_send_job_notification routes per service, honors no_batch gate' => sub {
    my $f = {harness_job_end => {abs_file => File::Spec->rel2abs(__FILE__)}};

    # slack, batched off -> no send
    my $none = capture(sub { $_[0]->_send_job_notification('slack', undef, $f, 0, settings(no_batch_slack => 0, slack_fail => ['#x'])) });
    is($none, [], "no_batch_slack off => job notification is batched (no immediate send)");

    # slack, batched on, one fail target
    my $sl = capture(sub { $_[0]->_send_job_notification('slack', undef, $f, 0, settings(no_batch_slack => 1, slack_fail => ['#x'])) });
    is(scalar(@$sl), 1, "one slack send");
    is($sl->[0]{service}, 'slack', "routed to slack");
    is($sl->[0]{to}, ['#x'], "slack recipients from slack_fail");

    # email, batched on, subject present
    my $abs = File::Spec->rel2abs(__FILE__);
    my $rel = File::Spec->abs2rel($abs);
    my $em = capture(sub { $_[0]->_send_job_notification('email', undef, $f, 0, settings(no_batch_email => 1, email_fail => ['a@b'])) });
    is(scalar(@$em), 1, "one email send");
    is($em->[0]{service}, 'email', "routed to email");
    is($em->[0]{to}, ['a@b'], "email recipients from email_fail");
    is($em->[0]{subject}, "Failed test on $HOST: '$rel'.", "email job subject");

    # no recipients => nothing sent even when batched on
    my $empty = capture(sub { $_[0]->_send_job_notification('slack', undef, $f, 0, settings(no_batch_slack => 1)) });
    is($empty, [], "no slack recipients => no send");
};

subtest '_send_run_notification routes per service, honors no_batch gate + owner meta' => sub {
    # A test file carrying slack/owner meta so the owner path contributes recipients.
    my $tmp  = gen_temp(owned => "# HARNESS-META slack #owner-chan\n# HARNESS-META owner owner\@example.com\nok 1\n");
    my $file = File::Spec->catfile($tmp, 'owned');

    # slack: batched-send ON => run summary is SKIPPED
    my $skip = capture(sub { $_[0]->_send_run_notification('slack', {pass => 0, failed => []}, settings(no_batch_slack => 1, slack => ['#c'])) });
    is($skip, [], "no_batch_slack on => run summary skipped");

    # slack: list + fail list (failing run) + owner meta from failed file
    my $sl = capture(sub {
        $_[0]->_send_run_notification(
            'slack',
            {pass => 0, failed => [[undef, $file]]},
            settings(no_batch_slack => 0, slack => ['#c'], slack_fail => ['#f'], slack_owner => 1),
        );
    });
    is(scalar(@$sl), 1, "one slack run send");
    is($sl->[0]{to}, ['#c', '#f', '#owner-chan'], "slack run recipients: list + fail-list + owner meta");

    # email: passing run => only the base list, subject present
    my $em = capture(sub { $_[0]->_send_run_notification('email', {pass => 1, failed => []}, settings(no_batch_email => 0, email => ['e@x'])) });
    is(scalar(@$em), 1, "one email run send");
    is($em->[0]{to}, ['e@x'], "email run recipients: base list only on pass");
    is($em->[0]{subject}, "Tests passed on $HOST", "email run subject on pass");

    # email: owner meta on failure uses the 'owner' meta key
    my $emf = capture(sub {
        $_[0]->_send_run_notification(
            'email',
            {pass => 0, failed => [[undef, $file]]},
            settings(no_batch_email => 0, email => ['e@x'], email_owner => 1),
        );
    });
    is($emf->[0]{to}, ['e@x', 'owner@example.com'], "email run recipients include owner meta");
    is($emf->[0]{subject}, "Tests failed on $HOST", "email run subject on fail");

    # Ticket TODO-126: a failing run with ONLY --notify-email-fail configured (no
    # --notify-email / --notify-email-owner) must still fire the fail email.
    my $failonly = capture(sub {
        $_[0]->_send_run_notification('email', {pass => 0, failed => []}, settings(no_batch_email => 0, email_fail => ['dev@example.com']));
    });
    is(scalar(@$failonly), 1, "email_fail-only failing run sends exactly one email");
    is($failonly->[0]{to}, ['dev@example.com'], "fail email goes to the email_fail address");
    is($failonly->[0]{subject}, "Tests failed on $HOST", "fail email subject reflects failure");

    # ...and a passing run does NOT dispatch to the fail-only list.
    my $passonly = capture(sub {
        $_[0]->_send_run_notification('email', {pass => 1, failed => []}, settings(no_batch_email => 0, email_fail => ['dev@example.com']));
    });
    is($passonly, [], "email_fail is not notified on a passing run");
};

subtest 'all five gen_*_text delegator names survive (gen_text dispatch + text_module overrides)' => sub {
    my $n = notify;
    can_ok($n, [qw/gen_slack_job_text gen_email_job_text gen_slack_run_text gen_email_run_text gen_email_subject_run_text/],
        "named delegators present so gen_text name-dispatch and text_module overrides still resolve");
};

done_testing;
