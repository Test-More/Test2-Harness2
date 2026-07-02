use Test2::V0;

# Unit coverage for ticket #114 (fork A): `yath reload`'s no-preload gate and its
# exit-code contract, exercised WITHOUT starting a real runner. `run` is driven with
# a mocked App::Yath2::Pfile::find pointing at a temp workdir whose settings.json we
# control, so each exit code is reached deterministically:
#   0 -> runner has preload stages, blacklist cleared, SIGHUP delivered (requested)
#   1 -> runner found but settings.json missing/unreadable (a live runner has one)
#   2 -> runner.preloads is empty: nothing to reload, SIGHUP would be a no-op
# The pre-fix bug returned 0 in every one of these cases.

use File::Temp qw/tempdir/;
use File::Spec;

require App::Yath2::Command::reload;
require App::Yath2::Pfile;

# A minimal stand-in for a discovered persistent runner: reload.pm only reaches into
# ->data for {pid, dir}.
{
    package t::FakePfile;
    sub new  { bless {data => $_[1]}, $_[0] }
    sub data { $_[0]->{data} }
}

# Write a settings.json into a fresh workdir and return the workdir. $preloads is an
# arrayref (possibly empty), or undef to omit the runner group entirely, or the string
# 'MISSING' to skip writing settings.json at all (simulating an unreadable/absent file).
sub workdir_with {
    my ($preloads) = @_;
    my $dir = tempdir(CLEANUP => 1);

    unless (defined($preloads) && !ref($preloads) && $preloads eq 'MISSING') {
        my $json;
        if (!defined $preloads) {
            $json = '{}';    # no runner group at all
        }
        else {
            my $list = join(',', map { "\"$_\"" } @$preloads);
            $json = qq/{"runner":{"preloads":[$list]}}/;
        }

        open(my $fh, '>', File::Spec->catfile($dir, 'settings.json')) or die "settings.json: $!";
        print $fh $json;
        close($fh);
    }

    return $dir;
}

# Run reload.pm's ->run against a mocked find() returning a FakePfile for $dir/$pid,
# capturing STDOUT+STDERR. Returns ($exit_code, $stdout, $stderr).
sub run_reload {
    my ($dir, $pid) = @_;

    my $cmd = bless {settings => {}}, 'App::Yath2::Command::reload';

    my ($out, $err) = ('', '');
    my $ret;

    no warnings qw/redefine once/;
    local *App::Yath2::Pfile::find = sub { t::FakePfile->new({pid => $pid, dir => $dir, pfile_path => "$dir/link"}) };

    {
        local *STDOUT;
        local *STDERR;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        open(STDERR, '>', \$err) or die "STDERR: $!";
        my $ok = eval { $ret = $cmd->run; 1 };
        my $e  = $@;
        die $e unless $ok;
    }

    return ($ret, $out, $err);
}

subtest no_preloads_exit_2 => sub {
    my $dir = workdir_with([]);
    my ($ret, $out, $err) = run_reload($dir, $$);
    is($ret, 2, "empty preloads => exit 2 (nothing to reload)");
    like($err, qr/no preload stages/, "warns that there are no preload stages");
    like($err, qr/yath stop.*yath start/s, "tells the user to restart the runner");
};

subtest no_runner_group_exit_2 => sub {
    my $dir = workdir_with(undef);    # settings.json with no runner group
    my ($ret, $out, $err) = run_reload($dir, $$);
    is($ret, 2, "absent runner group is treated as no preloads => exit 2");
};

subtest missing_settings_exit_1 => sub {
    my $dir = workdir_with('MISSING');    # no settings.json written
    my ($ret, $out, $err) = run_reload($dir, $$);
    is($ret, 1, "unreadable/missing settings.json => exit 1 (fault, not silent success)");
    like($err, qr/Could not read the runner's settings file/, "names the settings file it could not read");
};

subtest preloads_exit_0 => sub {
    my $dir = workdir_with(['Some::Preload']);

    # kill('HUP', $$) must SUCCEED (return truthy) so the exit-0 path is reached, but
    # must not actually disturb this test process: ignore the signal we send ourselves.
    local $SIG{HUP} = 'IGNORE';

    my ($ret, $out, $err) = run_reload($dir, $$);
    is($ret, 0, "non-empty preloads + successful SIGHUP => exit 0 (reload dispatched)");
    like($out, qr/Reload requested/, "reports the reload as requested (asynchronous), not completed");
    is($err, '', "no error output on the success path");
};

done_testing;
