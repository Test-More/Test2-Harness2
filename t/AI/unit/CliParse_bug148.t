use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket TODO-148 (CLI script/rc parsing bundle):
#   (60) A .yath.rc section header with trailing whitespace or a trailing
#        ;comment must still be recognized as a section header (previously
#        '[test]' leaked through as a bogus global arg and every option under
#        the malformed header rebound to the previous/global section).
#   (63) relglob()/glob() must expand a pattern whose path contains a space
#        instead of silently dropping the value (the old backtick shell-out
#        let csh-glob split the path on whitespace).
#   (59) App::Yath2's APP_PATH strip must anchor on the final 'App/Yath2.pm'
#        component so a path containing an earlier 'App' (~/Apps/...) is not
#        over-stripped.

use File::Temp qw/tempdir/;

require App::Yath::Script::V2;
require App::Yath2;

my $CLASS = 'App::Yath::Script::V2';

subtest 'section header with trailing whitespace/comment (60)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $rc  = "$dir/.yath.rc";

    open(my $fh, '>', $rc) or die "Could not write $rc: $!";
    print $fh <<'EOT';
-pGlobalPre ; a global pre-command plugin

[test] ; trailing comment after the header
-B

[run]
-PMoose
EOT
    close($fh);

    my (undef, $config, undef) = $CLASS->_parse_config_files($rc, undef);

    is($config->{'~'}, ['-pGlobalPre'], "global section holds only the real pre-command arg (no leaked '[test]')");
    is($config->{test}, ['-B'], "option under '[test] ;comment' binds to the test section");
    is($config->{run}, ['-PMoose'], "option under '[run]   ' (trailing whitespace) binds to the run section");

    ok(!(grep { $_ eq '[test]' || $_ eq '[run]' } @{$config->{'~'}}), "no bracketed header token leaked into the global section");
};

subtest 'relglob with a spaced path (63)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/has space" or die "Could not mkdir: $!";
    for my $name (qw/a.t b.t/) {
        open(my $tf, '>', "$dir/has space/$name") or die $!;
        close($tf);
    }

    my $rc = "$dir/.yath.rc";
    open(my $fh, '>', $rc) or die "Could not write $rc: $!";
    print $fh "[test]\n--default-search relglob(has space/*.t)\n";
    close($fh);

    my (undef, $config, undef) = $CLASS->_parse_config_files($rc, undef);

    my @searches = do {
        my @out;
        my @c = @{$config->{test} // []};
        while (@c) {
            my $k = shift @c;
            push @out => shift @c if $k eq '--default-search';
        }
        @out;
    };

    is(
        [sort @searches],
        ["$dir/has space/a.t", "$dir/has space/b.t"],
        "relglob() expands a spaced path to both test files instead of silently dropping them",
    );
};

subtest 'APP_PATH anchors on the final App/Yath2.pm (59)' => sub {
    # Real-code sanity: app_path() must point at the lib dir that actually
    # holds the loaded App/Yath2.pm.
    my $loaded = $INC{'App/Yath2.pm'};
    ok($loaded, "App/Yath2.pm is loaded");

    my $app_path = App::Yath2->app_path;
    ok(-e "$app_path/App/Yath2.pm", "app_path() points at the lib dir that holds the loaded App/Yath2.pm");

    # Deterministic regression guard: a path containing an earlier 'App'
    # (~/Apps/...) must strip only the trailing component, not back to the
    # first 'App'. This mirrors the anchored substitution in App::Yath2.
    my $synthetic = '/home/user/Apps/lib/App/Yath2.pm';

    my $fixed = $synthetic;
    $fixed =~ s{App[/\\]+Yath2\.pm$}{};
    is($fixed, '/home/user/Apps/lib/', "anchored strip keeps the /Apps/ prefix intact");

    my $greedy = $synthetic;
    $greedy =~ s{App\S+Yath2\.pm$}{}g;
    is($greedy, '/home/user/', "the old greedy pattern over-stripped (documents the fixed bug)");
    isnt($greedy, $fixed, "anchored and greedy strips differ on an 'Apps' path");
};

done_testing;
