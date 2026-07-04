use Test2::V0;
use v5.38;

use Test2::Formatter::Test2::Composer;

my $C = 'Test2::Formatter::Test2::Composer';

# Cleanup TODO-64 step 3: the Tier-2 deliberate output changes to the Composer.
# These were latent upstream bugs where a rendered string was computed but the
# raw value was emitted instead.

subtest 'render_info renders ref details as a string (was: raw ref leaked)' => sub {
    my ($line) = $C->render_info({info => [{tag => 'DIAG', details => {a => 1, b => 2}}]});

    is($line->[0], 'info', "facet is info");
    is($line->[1], 'DIAG', "tag preserved");
    ok(!ref($line->[2]), "details rendered to a plain string, not a ref");
    like($line->[2], qr/"a"/, "dumped string contains the hash key");
    unlike($line->[2], qr/^HASH\(/, "not the default ref stringification");
};

subtest 'render_info passes plain (non-ref) details through unchanged' => sub {
    my ($line) = $C->render_info({info => [{tag => 'NOTE', details => "hello\n"}]});
    is($line->[2], "hello\n", "non-ref details are untouched (no chomp)");
};

subtest 'render_info still forwards a table and honors peek in render_brief' => sub {
    my ($line) = $C->render_info({info => [{tag => 'X', details => 'd', table => {t => 1}}]});
    is($line->[3], {t => 1}, "table passes through");

    # TODO-64 step 1 port: peek info items now render in brief mode.
    my $brief = $C->render_brief({info => [{tag => 'P', details => 'peeked', peek => 1}]});
    is(scalar(@$brief), 1, "peek info item is included in the brief render");
    is($brief->[0][2], 'peeked', "peek item details rendered");
};

subtest 'render_errors renders ref details as a string with a fallback tag' => sub {
    my ($line) = $C->render_errors({errors => [{details => {x => 9}, fail => 1}]});

    is($line->[0], 'error', "facet is error");
    is($line->[1], 'FATAL', "fail => 1 gives the FATAL fallback tag");
    ok(!ref($line->[2]), "details rendered to a plain string, not a ref");
    like($line->[2], qr/"x"/, "dumped string contains the hash key");

    my ($soft) = $C->render_errors({errors => [{details => 'boom'}]});
    is($soft->[1], 'ERROR', "non-fail error uses the ERROR fallback tag");
    is($soft->[2], 'boom', "plain error details pass through unchanged");
};

subtest 'render_about derives the tag from the package (was: always ABOUT)' => sub {
    my ($line) = $C->render_about({about => {package => 'Foo::Bar::Baz', details => 'about it'}});
    is($line->[1], 'Baz', "tag is the last package component, not a hardcoded ABOUT");
    is($line->[2], 'about it', "details preserved");

    my ($plain) = $C->render_about({about => {details => 'no pkg'}});
    is($plain->[1], 'ABOUT', "falls back to ABOUT when there is no package");
};

subtest 'render_amnesty de-dups without warning on undef tag/details' => sub {
    my $warned = 0;
    local $SIG{__WARN__} = sub { $warned++ };

    my @lines = $C->render_amnesty({amnesty => [
        {tag => undef, details => undef},
        {tag => undef, details => undef},    # duplicate of the first
        {tag => 'TODO', details => 'later'},
    ]});

    is($warned, 0, "no 'uninitialized value' warning from the seen-key join");
    is(scalar(@lines), 2, "the duplicate undef/undef entry is collapsed");
};

subtest 'render_one_line no longer dispatches a phantom times renderer' => sub {
    # Before TODO-64, 'times' was in the dispatch list and would call the
    # nonexistent render_times; a bare times facet must now just be ignored.
    my $out;
    my $ok = eval { $out = $C->render_one_line({times => {total => 1}}); 1 };
    my $err = $@;
    ok($ok, "render_one_line does not die on a bare times facet") or diag($err);
    is($out, undef, "no line produced for an unrenderable facet");
};

done_testing;
