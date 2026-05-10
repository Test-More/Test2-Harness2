use Test2::V0;
use File::Temp qw/tempfile/;

use App::Yath2::TestFile;

sub _tf {
    my ($content) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh $content;
    close $fh;
    return App::Yath2::TestFile->new(absolute => $path);
}

subtest 'no directive -> [<default>]' => sub {
    my $tf = _tf("use Test2::V0;\nok 1;\ndone_testing;\n");
    is($tf->preload_preferences, ['<default>'], 'default-only when no directive');
};

subtest 'colon-style directive parses' => sub {
    my $tf = _tf(<<'EOT');
# HARNESS-PRELOAD: Foo Bar <default>
use Test2::V0;
ok 1;
done_testing;
EOT
    is($tf->preload_preferences, ['Foo', 'Bar', '<default>'], 'parsed in order');
};

subtest 'no-colon style also works' => sub {
    my $tf = _tf(<<'EOT');
# HARNESS-PRELOAD Foo Bar
use Test2::V0;
ok 1;
done_testing;
EOT
    is($tf->preload_preferences, ['Foo', 'Bar'], 'no-colon variant works');
};

subtest '<no> alone parses' => sub {
    my $tf = _tf(<<'EOT');
# HARNESS-PRELOAD: <no>
use Test2::V0;
ok 1;
done_testing;
EOT
    is($tf->preload_preferences, ['<no>'], 'opt-out captured');
};

subtest 'invalid directive croaks via parse_preload_directive' => sub {
    my $tf = _tf(<<'EOT');
# HARNESS-PRELOAD: Foo <no> Bar
use Test2::V0;
ok 1;
done_testing;
EOT
    my $ok = eval { $tf->preload_preferences; 1 };
    ok(!$ok, 'invalid directive croaks');
    like($@, qr/<no>/, 'error mentions <no> placement rule');
};

done_testing;
