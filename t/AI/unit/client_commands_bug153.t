use Test2::V0;

# Regression tests for ticket #153 (web-client command bundle; web-parked,
# reworked in place):
#   91 (P2) client-recent: --max was parsed but the count was never appended to
#           the request URL, so the server's default count silently overrode it.
#   92 (P3) client-publish: a 200 response with a non-JSON (or non-object) body
#           died via an uncaught decode_json longmess / 'Not a HASH reference'
#           deref, and a missing run_uuid printed a broken 'View run at .../view/'.

use App::Yath2::Command::client::recent;
use App::Yath2::Command::client::publish;

use Getopt::Yath::Settings;

use File::Temp qw/tempdir/;

require HTTP::Tiny;
require HTTP::Response;

# Local STDOUT/STDERR capture (warn included) -- same idiom as Finder_bug144.t.
sub capture(&) {
    my ($code) = @_;
    my ($out, $err) = ('', '');
    my $ok = eval {
        local *STDOUT;
        local *STDERR;
        open(STDOUT, '>', \$out) or die $!;
        open(STDERR, '>', \$err) or die $!;
        $code->();
        1;
    };
    my $e = $@;
    die $e unless $ok;
    return ($out, $err);
}

# ---------------------------------------------------------------------------
# (91) client-recent appends the count segment to the request URL.
subtest recent_appends_count_segment => sub {
    my $captured_url;
    my $mock = mock 'HTTP::Tiny' => (
        override => [
            get => sub {
                my (undef, $url) = @_;
                $captured_url = $url;
                return {success => 1, content => '[]'};
            },
        ],
    );

    my $settings = Getopt::Yath::Settings->new(
        webclient => {url => 'http://server/'},
        yath      => {project => 'P', user => 'U'},
        recent    => {max => 3},
    );
    my $cmd = App::Yath2::Command::client::recent->new(settings => $settings, args => []);

    # Direct method: the count is the last URL segment (route is
    # /recent/:project/:user/:count).
    $cmd->get_from_http('proj', 7, 'bob');
    is($captured_url, 'http://server/recent/proj/bob/7', "count segment appended to URL");
};

# (91) End-to-end run() honors --max: the count reaches the server URL.
subtest recent_run_honors_max => sub {
    my $captured_url;
    my $row = {
        added => 't', duration => '1s', status => 'complete',
        passed => 1, failed => 0, retried => 0, run_id => 'RID',
    };
    my $mock = mock 'HTTP::Tiny' => (
        override => [
            get => sub {
                my (undef, $url) = @_;
                $captured_url = $url;
                return {success => 1, content => encode_json_row($row)};
            },
        ],
    );

    my $settings = Getopt::Yath::Settings->new(
        webclient => {url => 'http://server'},
        yath      => {project => 'myproj', user => 'me'},
        recent    => {max => 42},
    );
    my $cmd = App::Yath2::Command::client::recent->new(settings => $settings, args => []);

    my $ret;
    capture { $ret = $cmd->run };
    is($ret, 0, "run() succeeded");
    is($captured_url, 'http://server/recent/myproj/me/42', "--max (42) reached the server, no longer ignored");
};

# ---------------------------------------------------------------------------
# publish helpers: build a command wired to a canned LWP response.
sub mk_publish {
    my ($res) = @_;

    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/run.jsonl";
    open(my $fh, '>', $log) or die $!;
    print $fh "{}\n";
    close($fh);

    my $settings = Getopt::Yath::Settings->new(
        webclient => {url => 'http://server/', api_key => 'KEY'},
        yath      => {project => 'proj'},
        publish   => {mode => 'summary'},
    );

    my $cmd = App::Yath2::Command::client::publish->new(settings => $settings, args => [$log]);
    my $mock = mock 'LWP::UserAgent' => (override => [post => sub { return $res }]);

    return ($cmd, $mock);
}

# (92) A 200 with a text/HTML body exits 1 and shows the body -- no stack trace.
subtest publish_html_200_clean_error => sub {
    my $res = HTTP::Response->new(200, 'OK', ['Content-Type' => 'text/html'], "<html>maintenance</html>");
    my ($cmd, $mock) = mk_publish($res);

    my ($out, $err, $ret);
    ($out, $err) = capture { $ret = $cmd->run };

    is($ret, 1, "non-JSON 200 exits 1");
    like($err, qr/<html>maintenance<\/html>/, "raw body shown to the user");
    like($err, qr/200 OK/, "status line shown");
    unlike($err, qr/=======/,        "no decode_json longmess markers");
    unlike($err, qr/ at .+ line \d+/, "no stack trace leaked");
};

# (92) A 200 with a bare-scalar JSON body (allow_nonref) exits 1, not a deref die.
subtest publish_bare_scalar_200_clean_error => sub {
    my $res = HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '"oops"');
    my ($cmd, $mock) = mk_publish($res);

    my ($out, $err, $ret);
    ok(lives { ($out, $err) = capture { $ret = $cmd->run } }, "non-object JSON body does not die");
    is($ret, 1, "non-object JSON 200 exits 1");
    like($err, qr/"oops"/, "raw body shown");
};

# (92) A 200 JSON object without run_uuid warns, does not print a broken URL.
subtest publish_missing_run_uuid_warns => sub {
    my $res = HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"messages":["done"]}');
    my ($cmd, $mock) = mk_publish($res);

    my ($out, $err, $ret);
    ($out, $err) = capture { $ret = $cmd->run };

    is($ret, 0, "successful upload returns 0");
    like($out, qr/done/, "server messages printed");
    unlike($out, qr{View run at:.*/view/\s*$}m, "no broken empty-uuid view URL");
    like($err, qr/did not return a run_uuid/, "warns the run_uuid was absent");
};

# (92) A well-formed 200 with run_uuid prints the view URL.
subtest publish_success_prints_view_url => sub {
    my $res = HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"run_uuid":"abc-123","messages":[]}');
    my ($cmd, $mock) = mk_publish($res);

    my ($out, $err, $ret);
    ($out, $err) = capture { $ret = $cmd->run };

    is($ret, 0, "returns 0");
    like($out, qr{View run at: http://server/view/abc-123}, "view URL printed with run_uuid");
};

done_testing;

# Tiny JSON array encoder for the one canned recent row (avoids importing the
# whole encode surface just for a fixture).
sub encode_json_row {
    my ($row) = @_;
    require Test2::Harness2::Util::JSON;
    return Test2::Harness2::Util::JSON::encode_json([$row]);
}
