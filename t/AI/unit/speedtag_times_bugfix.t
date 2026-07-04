use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket TODO-149 (findings 70, 74, 100, 72):
#   70  - times sort_compare must honor a 'file' primary sort (the field lives on
#         the job, not in its per-phase 'time' hash) instead of silently no-op'ing.
#   74  - speedtag rewrites the source file atomically (tempfile + rename); an
#         injected write failure must leave the original file intact.
#   100 - speedtag recognizes the 'HARNESS-DUR-*' alias (Legacy.pm accepts it), so
#         a DUR-tagged file is updated in place with no stale/new duplicate pair.
#   72  - an invalid max_medium argument dies blaming "max medium duration".

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Command::times;
use App::Yath2::Command::speedtag;

subtest 'times sorts by file (finding 70)' => sub {
    my $cmd = App::Yath2::Command::times->new;
    $cmd->{fields} = ['file'];

    my @jobs = (
        {file => 'zebra.tx', time => {total => 1}},
        {file => 'apple.tx', time => {total => 99}},
        {file => 'mango.tx', time => {total => 50}},
    );

    @jobs = sort { $cmd->sort_compare($a, $b) } @jobs;

    is(
        [map { $_->{file} } @jobs],
        ['apple.tx', 'mango.tx', 'zebra.tx'],
        "rows are ordered by the 'file' field, not by 'total'",
    );
};

subtest 'speedtag recognizes the HARNESS-DUR alias (finding 100)' => sub {
    my $cmd = App::Yath2::Command::speedtag->new;

    # A stale short-form 'HARNESS-DUR-LONG' tag: it must be updated in place and
    # leave exactly one duration tag, not append a second conflicting line.
    my $in = ["# HARNESS-DUR-LONG\n", "use strict;\n", "print 1;\n"];
    my $out = $cmd->retag_lines($in, 'short');
    my $joined = join('', @$out);

    my $count = () = $joined =~ m/HARNESS-(?:DUR|DURATION|CAT|CATEGORY)-/g;
    is($count, 1, "exactly one duration/category tag remains (no duplicate pair)");
    like($joined, qr/^# HARNESS-DURATION-SHORT$/m, "the stale DUR tag was rewritten in place");
    unlike($joined, qr/HARNESS-DUR-LONG/, "the stale DUR-LONG line is gone");

    # The long-form 'HARNESS-DURATION-*' spelling still matches too.
    my $out2 = $cmd->retag_lines(["# HARNESS-DURATION-SHORT\n", "1;\n"], 'medium');
    like(join('', @$out2), qr/^# HARNESS-DURATION-MEDIUM$/m, "long-form DURATION tag still updates in place");
};

subtest 'speedtag write is atomic; failure leaves original intact (finding 74)' => sub {
    my $cmd = App::Yath2::Command::speedtag->new;
    my $dir = tempdir(CLEANUP => 1);

    my $file = File::Spec->catfile($dir, 'victim.tx');
    open(my $fh, '>', $file) or die "open: $!";
    print $fh "ORIGINAL\n";
    close($fh);

    # Happy path: the file is rewritten and the call reports success.
    ok($cmd->write_file_atomic($file, ["NEW LINE\n"]), "atomic write succeeds");
    is(_slurp($file), "NEW LINE\n", "file holds the new content");

    # Inject a failure by occupying the exact tempfile path with a directory, so
    # open('>', "$file.tmp$$") fails. The original must be left untouched.
    my $tmp = "$file.tmp$$";
    mkdir($tmp) or die "mkdir $tmp: $!";

    my $ok;
    my $warn = '';
    {
        local $SIG{__WARN__} = sub { $warn .= $_[0] };
        $ok = $cmd->write_file_atomic($file, ["CORRUPTED\n"]);
    }

    ok(!$ok, "atomic write reports failure when the tempfile cannot be created");
    like($warn, qr/temp file/, "a warning was emitted about the failure");
    is(_slurp($file), "NEW LINE\n", "original file is left fully intact after the failed write");

    rmdir($tmp);
};

subtest 'invalid max_medium dies with the right message (finding 72)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = File::Spec->catfile($dir, 'empty.jsonl');
    open(my $lfh, '>', $log) or die "open $log: $!";
    close($lfh);

    my $cmd = App::Yath2::Command::speedtag->new;
    $cmd->{args} = [$log, '10', 'notanint'];

    like(
        dies { $cmd->run },
        qr/max medium duration must be an integer, got 'notanint'/,
        "an invalid max_medium arg blames the medium (not short) threshold",
    );
};

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    local $/;
    return <$fh>;
}

done_testing;
