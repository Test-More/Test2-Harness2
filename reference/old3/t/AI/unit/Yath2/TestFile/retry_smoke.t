use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::TestFile;

my $tdir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} $content;
    close($fh);
    return $path;
}

sub tf_for {
    my ($name, @directives) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    my $body = "#!/usr/bin/perl\n" . join("\n", @directives) . "\nuse strict;\n";
    write_file($path, $body);
    return App::Yath2::TestFile->new(file => $path);
}

subtest 'HARNESS2: feature.smoke @on sets features->{smoke} = 1' => sub {
    my $tf = tf_for('smoke.t', '# HARNESS2: feature.smoke @on');
    $tf->scan;
    is($tf->feature('smoke'), 1, 'smoke feature flagged on');
};

subtest 'bare HARNESS2: retry.count 1 defaults retry to 1' => sub {
    my $tf = tf_for('retry_bare.t', '# HARNESS2: retry.count 1');
    $tf->scan;
    is($tf->retry,          1, 'retry defaults to 1');
    is($tf->retry_isolated, 0, 'retry_isolated stays 0');
};

subtest 'HARNESS2: retry.count 3 sets retry count to 3' => sub {
    my $tf = tf_for('retry_3.t', '# HARNESS2: retry.count 3');
    $tf->scan;
    is($tf->retry,          3, 'retry count honored');
    is($tf->retry_isolated, 0, 'retry_isolated stays 0');
};

subtest 'HARNESS2: retry.count 1\n# HARNESS2: retry.isolated @on sets retry=1, retry_isolated=1' => sub {
    my $tf = tf_for('retry_iso.t', '# HARNESS2: retry.count 1', '# HARNESS2: retry.isolated @on');
    $tf->scan;
    is($tf->retry,          1, 'retry defaults to 1 under ISO alone');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS2: retry.count 2\n# HARNESS2: retry.isolated @on preserves count and flags isolation' => sub {
    my $tf = tf_for('retry_2_iso.t', '# HARNESS2: retry.count 2', '# HARNESS2: retry.isolated @on');
    $tf->scan;
    is($tf->retry,          2, 'explicit count wins');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS2: retry.count 4\n# HARNESS2: retry.isolated @on is order-insensitive' => sub {
    my $tf = tf_for('retry_iso_4.t', '# HARNESS2: retry.count 4', '# HARNESS2: retry.isolated @on');
    $tf->scan;
    is($tf->retry,          4, 'explicit count overrides ISO default');
    is($tf->retry_isolated, 1, 'retry_isolated flagged on');
};

subtest 'HARNESS2: retry.count 0 then HARNESS2: retry.count 3 lets the count win' => sub {
    my $tf = tf_for('no_then_retry.t', '# HARNESS2: retry.count 0', '# HARNESS2: retry.count 3');
    $tf->scan;
    is($tf->retry, 3, 'explicit count overrides the prior NO-RETRY = 0');
};

subtest 'Multiple HARNESS2: retry.count 1 counts: later value wins' => sub {
    my $tf = tf_for('retry_twice.t', '# HARNESS2: retry.count 2', '# HARNESS2: retry.count 5');
    $tf->scan;
    is($tf->retry, 5, 'the final explicit count wins');
};

done_testing;
