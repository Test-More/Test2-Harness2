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
    my ($name, $directive) = @_;
    my $path = File::Spec->catfile($tdir, $name);
    write_file($path, "#!/usr/bin/perl\n" . $directive . "\nuse strict;\n");
    return App::Yath2::TestFile->new(file => $path);
}

# Scanning must never trip the Stage D fall-through warn for any of
# the nine valid directives exercised below.
my @warns;
local $SIG{__WARN__} = sub { push @warns => $_[0] };

subtest 'HARNESS2: feature.timeout @off sets features->{timeout} = 0' => sub {
    my $tf = tf_for('no_timeout.t', '# HARNESS2: feature.timeout @off');
    $tf->scan;
    is($tf->feature('timeout'), 0, 'timeout feature flagged off');
};

subtest 'HARNESS2: feature.fork @off sets features->{fork} = 0' => sub {
    my $tf = tf_for('no_fork.t', '# HARNESS2: feature.fork @off');
    $tf->scan;
    is($tf->feature('fork'), 0, 'fork feature flagged off');
};

subtest 'HARNESS2: feature.preload @off sets features->{preload} = 0' => sub {
    my $tf = tf_for('no_preload.t', '# HARNESS2: feature.preload @off');
    $tf->scan;
    is($tf->feature('preload'), 0, 'preload feature flagged off');
};

subtest 'HARNESS2: feature.stream @off sets features->{stream} = 0' => sub {
    my $tf = tf_for('no_stream.t', '# HARNESS2: feature.stream @off');
    $tf->scan;
    is($tf->feature('stream'), 0, 'stream feature flagged off');
};

subtest 'HARNESS2: feature.run @off sets features->{run} = 0' => sub {
    my $tf = tf_for('no_run.t', '# HARNESS2: feature.run @off');
    $tf->scan;
    is($tf->feature('run'), 0, 'run feature flagged off');
};

subtest 'HARNESS2: feature.io-events @off collapses to features->{io_events} = 0' => sub {
    my $tf = tf_for('no_io_events.t', '# HARNESS2: feature.io-events @off');
    $tf->scan;
    is($tf->feature('io_events'), 0, 'IO-EVENTS collapses to io_events via lc(join _)');
};

subtest 'HARNESS2: feature.isolation @on sets features->{isolation} = 1' => sub {
    my $tf = tf_for('use_isolation.t', '# HARNESS2: feature.isolation @on');
    $tf->scan;
    is($tf->feature('isolation'), 1, 'isolation feature flagged on');
};

subtest 'HARNESS2: feature.stream @on sets features->{stream} = 1' => sub {
    my $tf = tf_for('yes_stream.t', '# HARNESS2: feature.stream @on');
    $tf->scan;
    is($tf->feature('stream'), 1, 'yes arm turns stream on');
};

subtest 'HARNESS2: retry.count 0 is special-cased into retry, not features' => sub {
    my $tf = tf_for('no_retry.t', '# HARNESS2: retry.count 0');
    $tf->scan;
    is($tf->retry, 0, 'retry slot set to 0');
    ok(!exists $tf->features->{retry}, 'features hash did not receive a retry key');
};

is(\@warns, [], 'no unknown-directive warnings across any valid NO/YES/USE form');

done_testing;
