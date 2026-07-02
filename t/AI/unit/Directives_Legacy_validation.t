use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::Directives::Legacy;
use App::Yath2::TestFile;

# Regression coverage for #154 findings 45 (bare-directive corruption) and 46
# (wrong warning line numbers). A bare legacy directive used to corrupt the
# result tree and later die 'Not a HASH reference'; it must now warn once with a
# clear message + _at() location and leave the tree unpolluted.

my $C = 'Test2::Harness2::Util::Directives::Legacy';

# Parse a block of legacy directive lines; return (result, \@warnings).
my sub parse {
    my ($text) = @_;
    my $result;
    my $warnings = warnings { $result = $C->parse_string($text, comment => '#', file => 'fake.t') };
    return ($result, $warnings);
}

subtest 'bare HARNESS-META warns once and leaves the tree empty' => sub {
    my ($r, $w) = parse("# HARNESS-META");
    is($r, {}, "result tree unpolluted");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'HARNESS-META' requires a key and a value at fake\.t line 1\./, "clear message + _at location");
};

subtest 'HARNESS-META with a key but no value warns' => sub {
    my ($r, $w) = parse("# HARNESS-META key");
    is($r, {}, "tree unpolluted");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'HARNESS-META' requires a key and a value/, "message");
};

subtest 'bare HARNESS-NO warns' => sub {
    my ($r, $w) = parse("# HARNESS-NO");
    is($r, {}, "tree unpolluted");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'HARNESS-NO' requires a feature name/, "message");
};

subtest 'bare HARNESS-CAT warns' => sub {
    my ($r, $w) = parse("# HARNESS-CAT");
    is($r, {}, "tree unpolluted");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'HARNESS-CAT' requires a category name/, "message");
};

subtest 'bare HARNESS-TIMEOUT warns' => sub {
    my ($r, $w) = parse("# HARNESS-TIMEOUT");
    is($r, {}, "tree unpolluted");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/is not a valid timeout type/, "message");
};

subtest 'HARNESS-TIMEOUT BOGUS 5 warns and sets nothing' => sub {
    my ($r, $w) = parse("# HARNESS-TIMEOUT BOGUS 5");
    is($r, {}, "tree unpolluted (invalid type is skipped, not set as timeout.bogus)");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'BOGUS' is not a valid timeout type/, "message names the bad type");
};

subtest 'bare HARNESS-STAGE-REQUIRE warns and leaves no dangling require_preload' => sub {
    my ($r, $w) = parse("# HARNESS-STAGE-REQUIRE");
    is($r, {}, "tree unpolluted (no dangling require_preload)");
    is(scalar(@$w), 1, "exactly one warning");
    like($w->[0], qr/'HARNESS-STAGE' requires at least one stage name/, "message");
};

subtest 'kill-shot: bare HARNESS-META then a valid one parses without dying' => sub {
    my ($r, $w);
    ok(lives { ($r, $w) = parse("# HARNESS-META\n# HARNESS-META foo bar") }, "no 'Not a HASH reference' die");
    is($r, {meta => {foo => ['bar']}}, "the valid meta directive is recorded, tree not corrupted");
    like($w->[0], qr/'HARNESS-META' requires a key and a value/, "the bare directive warned");
};

subtest 'kill-shot: bare HARNESS-NO then HARNESS-SMOKE parses without dying' => sub {
    my ($r, $w);
    ok(lives { ($r, $w) = parse("# HARNESS-NO\n# HARNESS-SMOKE") }, "no 'Not a HASH reference' die");
    is($r, {feature => {smoke => [1]}}, "smoke feature recorded, tree not corrupted");
    like($w->[0], qr/'HARNESS-NO' requires a feature name/, "the bare directive warned");
};

subtest 'hardening: an empty key-path segment croaks clearly (backstop)' => sub {
    my $p = $C->new(comment => '#');
    like(
        dies { $p->_set('feature.', [1]) },
        qr/empty segment in directive key path 'feature\.'/,
        "_set croaks on a dangling dotted key path instead of silently corrupting the tree"
    );
};

subtest 'valid legacy directives still parse (behavior-preservation pin)' => sub {
    my ($r, $w) = parse(
        "# HARNESS-CAT isolation\n"
      . "# HARNESS-DURATION-SHORT\n"
      . "# HARNESS-META author exodist\n"
      . "# HARNESS-CONFLICTS db\n"
      . "# HARNESS-STAGE-REQUIRE foo bar\n"
      . "# HARNESS-TIMEOUT EVENT 30\n"
    );
    is(scalar(@$w), 0, "no spurious warnings for valid directives");
    is(
        $r,
        {
            category       => ['isolation'],
            duration       => ['short'],
            meta           => {author => ['exodist']},
            conflicts      => ['db'],
            require_preload => [1],
            preload_list   => ['foo', 'bar'],
            stage          => ['foo'],
            timeout        => {event => ['30']},
        },
        "valid directives produce the expected nested-hash shape"
    );
};

# Finding 46: with every scanned header line fed to the legacy parser, its
# internal line_no equals the real file line, so a warning points at the right
# line even when preceded by blank/comment/preamble lines.
subtest 'TestFile: a bad directive warning reports the real file line' => sub {
    my ($fh, $file) = tempfile("t154-testfile-XXXXXX", SUFFIX => '.t', TMPDIR => 1, UNLINK => 1);
    print $fh "\n";                    # line 1
    print $fh "# a comment\n";         # line 2
    print $fh "\n";                    # line 3
    print $fh "# another comment\n";   # line 4
    print $fh "use strict;\n";         # line 5
    print $fh "\n";                    # line 6
    print $fh "# HARNESS-META\n";      # line 7  <-- bad directive
    print $fh "1;\n";                  # line 8
    close($fh);

    my $tf = App::Yath2::TestFile->new(file => $file);
    my $warnings = warnings { $tf->directive_error };

    is(scalar(@$warnings), 1, "exactly one warning from the bad directive");
    like($warnings->[0], qr/'HARNESS-META' requires a key and a value/, "clear message");
    like($warnings->[0], qr/line 7\./, "warning reports the real file line (7), not the directive-count line");
};

done_testing;
