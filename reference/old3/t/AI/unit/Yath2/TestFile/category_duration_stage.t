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

subtest 'HARNESS2: duration long sets duration = long' => sub {
    my $tf = tf_for('dur_long.t', '# HARNESS2: duration long');
    $tf->scan;
    is($tf->duration, 'long', 'duration lowercased to long');
    is($tf->category, undef,  'category untouched');
};

subtest 'HARNESS2: duration short (alias) sets duration = short' => sub {
    my $tf = tf_for('dur_short.t', '# HARNESS2: duration short');
    $tf->scan;
    is($tf->duration, 'short', 'dur alias accepted');
};

subtest 'HARNESS2: duration medium (space form) sets duration = medium' => sub {
    my $tf = tf_for('dur_medium.t', '# HARNESS2: duration medium');
    $tf->scan;
    is($tf->duration, 'medium', 'space-separated form accepted');
};

subtest 'HARNESS2: category io sets category = io' => sub {
    my $tf = tf_for('cat_io.t', '# HARNESS2: category io');
    $tf->scan;
    is($tf->category, 'io',  'category lowercased to io');
    is($tf->duration, undef, 'duration untouched');
};

subtest 'HARNESS2: category network (alias) sets category = network' => sub {
    my $tf = tf_for('cat_network.t', '# HARNESS2: category network');
    $tf->scan;
    is($tf->category, 'network', 'cat alias accepted');
};

subtest 'HARNESS2: duration long is sugar for HARNESS2: duration long' => sub {
    my $tf = tf_for('cat_as_dur.t', '# HARNESS2: duration long');
    $tf->scan;
    is($tf->duration, 'long', 'long/medium/short under CATEGORY routed to duration');
    is($tf->category, undef,  'category stays undef');
};

subtest 'HARNESS2: stage DBStage preserves case' => sub {
    my $tf = tf_for('stage.t', '# HARNESS2: stage DBStage');
    $tf->scan;
    is($tf->stage, 'DBStage', 'stage name case-preserved');
};

subtest 'no directive leaves category / duration / stage undef' => sub {
    my $tf = tf_for('plain.t');
    $tf->scan;
    is($tf->category, undef, 'category undef without directive');
    is($tf->duration, undef, 'duration undef without directive');
    is($tf->stage,    undef, 'stage undef without directive');
};

done_testing;
