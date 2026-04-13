use strict;
use warnings;
use Test2::V0;

use File::Spec;
use File::Temp qw/tempfile tempdir/;

use Test2::Harness2::TestFile;

my $FIXTURE = File::Spec->rel2abs('t/selftest/simple.t');

subtest 'basic construction' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => $FIXTURE);
    ok($tf, "created TestFile object");
    is($tf->file, $FIXTURE, "file attribute set");
    ok($tf->relative, "relative path is set");
};

subtest 'nonexistent file dies' => sub {
    ok(
        dies { Test2::Harness2::TestFile->new(file => '/does/not/exist/foo.t') },
        "dies with nonexistent file"
    );
};

subtest 'header scanning - HARNESS-DURATION and HARNESS-CATEGORY' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => $FIXTURE);
    $tf->scan;

    my $headers = $tf->headers;
    is($headers->{duration}, 'short',   "HARNESS-DURATION short parsed");
    is($headers->{category}, 'general', "HARNESS-CATEGORY general parsed");
};

subtest 'check_duration' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => $FIXTURE);
    is($tf->check_duration, 'short', "check_duration returns parsed value");

    # Test default (medium) via a temp file
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "use strict;\n1;\n";
    close $fh;
    my $tf2 = Test2::Harness2::TestFile->new(file => $filename);
    is($tf2->check_duration, 'medium', "check_duration defaults to 'medium'");
};

subtest 'check_category' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => $FIXTURE);
    is($tf->check_category, 'general', "check_category returns parsed value");

    # Test default (general) via a temp file
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "use strict;\n1;\n";
    close $fh;
    my $tf2 = Test2::Harness2::TestFile->new(file => $filename);
    is($tf2->check_category, 'general', "check_category defaults to 'general'");
};

subtest 'check_stage' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-STAGE MyStage\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->check_stage, 'MyStage', "check_stage returns parsed stage");

    # No stage set
    my ($fh2, $fname2) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh2 "use strict;\n1;\n";
    close $fh2;
    my $tf2 = Test2::Harness2::TestFile->new(file => $fname2);
    is($tf2->check_stage, undef, "check_stage returns undef when not set");
};

subtest 'shbang parsing' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "#!/usr/bin/perl -w -T\nuse strict;\n1;\n";
    close $fh;
    my $tf     = Test2::Harness2::TestFile->new(file => $filename);
    my $shbang = $tf->shbang;
    ok($shbang, "shbang parsed");
    is($shbang->{switches}, ['-w', '-T'], "switches parsed from shbang");
};

subtest 'switches method' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "#!/usr/bin/perl -w\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->switches, ['-w'], "switches returns parsed switches");

    # No shbang
    my ($fh2, $fname2) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh2 "use strict;\n1;\n";
    close $fh2;
    my $tf2 = Test2::Harness2::TestFile->new(file => $fname2);
    is($tf2->switches, [], "switches returns empty arrayref when no shbang");
};

subtest 'HARNESS-NO-TIMEOUT' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-NO-TIMEOUT\nuse strict;\n1;\n";
    close $fh;
    my $tf      = Test2::Harness2::TestFile->new(file => $filename);
    my $headers = $tf->headers;
    is($headers->{features}{timeout}, 0,      "HARNESS-NO-TIMEOUT sets timeout feature to 0");
    is($tf->check_duration,           'long', "no-timeout results in 'long' duration");
};

subtest 'HARNESS-RETRY' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-RETRY 3\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->retry, 3, "HARNESS-RETRY sets retry count");
};

subtest 'HARNESS-SMOKE' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-SMOKE\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->check_feature('smoke'), 1, "HARNESS-SMOKE sets smoke feature");
};

subtest 'HARNESS-CONFLICTS' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-CONFLICTS foo\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->conflicts_list, ['foo'], "HARNESS-CONFLICTS parsed");

    # Multiple conflicts on multiple lines
    my ($fh2, $fname2) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh2 "# HARNESS-CONFLICTS foo\n# HARNESS-CONFLICTS bar\nuse strict;\n1;\n";
    close $fh2;
    my $tf2 = Test2::Harness2::TestFile->new(file => $fname2);
    is($tf2->conflicts_list, ['foo', 'bar'], "multiple HARNESS-CONFLICTS lines parsed");
};

subtest 'rank' => sub {
    # smoke = 1
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-SMOKE\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->rank, 1, "smoke rank is 1");

    # short = 80
    my ($fh2, $fname2) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh2 "# HARNESS-DURATION short\nuse strict;\n1;\n";
    close $fh2;
    my $tf2 = Test2::Harness2::TestFile->new(file => $fname2);
    is($tf2->rank, 80, "short duration rank is 80");

    # long = 20
    my ($fh3, $fname3) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh3 "# HARNESS-DURATION long\nuse strict;\n1;\n";
    close $fh3;
    my $tf3 = Test2::Harness2::TestFile->new(file => $fname3);
    is($tf3->rank, 20, "long duration rank is 20");
};

subtest 'HARNESS-TIMEOUT' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-TIMEOUT EVENT 30\n# HARNESS-TIMEOUT POSTEXIT 15\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->event_timeout,     30, "event timeout parsed");
    is($tf->post_exit_timeout, 15, "postexit timeout parsed");
};

subtest 'HARNESS-META' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-META foo bar\nuse strict;\n1;\n";
    close $fh;
    my $tf   = Test2::Harness2::TestFile->new(file => $filename);
    my @vals = $tf->meta('foo');
    is(\@vals, ['bar'], "HARNESS-META parsed");
};

subtest 'HARNESS-JOB-SLOTS' => sub {
    my ($fh, $filename) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh "# HARNESS-JOB-SLOTS 2 4\nuse strict;\n1;\n";
    close $fh;
    my $tf = Test2::Harness2::TestFile->new(file => $filename);
    is($tf->check_min_slots, 2, "min slots parsed");
    is($tf->check_max_slots, 4, "max slots parsed");
};

done_testing;
