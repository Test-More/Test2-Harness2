use v5.38;

use Test2::V0;

use File::Temp qw/tempdir/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();

# Ticket TODO-136. Two behaviors are exercised here (the two P2 items):
#   (37) Runner::Preload::default_stage must return a stage NAME (string), and the
#        merge cache must only propagate an EXPLICIT default() -- so a no-default
#        lib never masks a later lib's explicit default (first-wins), and a stage
#        actually gets flagged default instead of falling to the alphabetical-first.
#   (38) Runner::Preloader::check blacklist propagation must key dep_map by the
#        RELATIVE require path so transitive dependents are actually blacklisted
#        (was keyed by the absolute watched path -> dead code, no propagation), and
#        must not die on an empty caller module ($mod ne '' guard before ->can).
# (Items 36 stop_stages removal and 21 Reloader stat-throttle are structural; they
#  are covered by grep/compile checks in the ticket verify line.)

sub new_preload { Test2::Harness2::Runner::Preload->new }

subtest default_stage_name_and_fallback => sub {
    my $pl = new_preload();
    $pl->build_stage(name => 'zeta',  code => sub { });
    $pl->build_stage(name => 'alpha', code => sub { });

    is($pl->default_stage, 'zeta', "no explicit default => first-DECLARED stage name (a string, not the alphabetical 'alpha', not an object)");
    ok(!blessed($pl->default_stage), "default_stage returns a plain string, not a StageConfig object");

    my $empty = new_preload();
    is($empty->default_stage, undef, "no stages => undef fallback (no ->name on empty list)");

    my $explicit = new_preload();
    $explicit->build_stage(name => 'first',  code => sub { });
    $explicit->build_stage(name => 'chosen', code => sub { });
    $explicit->set_default_stage('chosen');
    is($explicit->default_stage, 'chosen', "explicit default honored over the first-declared fallback");
};

subtest merge_first_wins_explicit_only => sub {
    # A lib with NO default() must not poison the merge cache and mask a later
    # lib's EXPLICIT default().
    my $nodef = new_preload();
    $nodef->build_stage(name => 'nd1', code => sub { });

    my $withdef = new_preload();
    $withdef->build_stage(name => 'wd1', code => sub { });
    $withdef->set_default_stage('wd1');

    my $merged = new_preload();
    $merged->merge($nodef);      # no-default lib merged FIRST
    $merged->merge($withdef);    # explicit-default lib merged SECOND
    is($merged->default_stage, 'wd1', "later lib's EXPLICIT default is not masked by an earlier no-default lib");

    # Two explicit defaults: the FIRST merged wins.
    my $a = new_preload();
    $a->build_stage(name => 'a1', code => sub { });
    $a->set_default_stage('a1');
    my $b = new_preload();
    $b->build_stage(name => 'b1', code => sub { });
    $b->set_default_stage('b1');

    my $merged2 = new_preload();
    $merged2->merge($a);
    $merged2->merge($b);
    is($merged2->default_stage, 'a1', "first explicit default wins (first-wins contract)");
};

subtest merge_normalizes_legacy_object => sub {
    # Defensive normalization: a legacy DEFAULT_STAGE holding a StageConfig object
    # must merge into a plain name string.
    my $src   = new_preload();
    my $stage = $src->build_stage(name => 'objdef', code => sub { });
    $src->{+Test2::Harness2::Runner::Preload::DEFAULT_STAGE()} = $stage;    # simulate a legacy object value
    ok(blessed($src->{+Test2::Harness2::Runner::Preload::DEFAULT_STAGE()}), "source default is an object");

    my $merged = new_preload();
    $merged->merge($src);
    is($merged->default_stage, 'objdef', "merge normalizes a blessed default to its name");
    ok(!blessed($merged->default_stage), "merged default is a plain string");
};

# Minimal fakes so we can drive Preloader::check's blacklist propagation path
# without a live stage host / DepTracer.
package FakeDtrace {
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub dep_map { $_[0]->{dep_map} }
    sub start   { }
    sub stop    { }
    sub loaded  { $_[0]->{loaded} // {} }
}
package FakeReloader {
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub reload_changes { $_[0]->{changes} }
    sub refresh { }
    sub reset   { }
}
package FakeState {
    sub new    { bless {}, shift }
    sub reload { }
}

subtest transitive_blacklist_propagation => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $pl  = Test2::Harness2::Runner::Preloader->new(dir => $dir, monitor => 1);

    # dep_map is keyed by the RELATIVE require path; values are loaded_by pairs
    # [caller_pkg, caller_file]. Leaf was loaded by Mid AND by the harness's own
    # Preloader (the top-level `preload 'My::Leaf'` machinery); Mid was loaded by
    # Top. The first entry has an EMPTY caller module to exercise the $mod ne ''
    # guard. My::Mid/My::Top are part of the traced preload graph (in `loaded`);
    # the harness Preloader is NOT (loaded before tracing) so it must NOT be
    # blacklisted even though it is a recorded dependent of the changed leaf.
    $pl->{+Test2::Harness2::Runner::Preloader::DTRACE()} = FakeDtrace->new(
        dep_map => {
            'My/Leaf.pm' => [
                ['', '/abs/unknown.pl'],
                ['Test2::Harness2::Runner::Preloader', '/abs/T2H2/Preloader.pm'],
                ['My::Mid', '/abs/My/Mid.pm'],
            ],
            'My/Mid.pm'  => [['My::Top', '/abs/My/Top.pm']],
        },
        loaded => {
            'My/Leaf.pm' => 1,
            'My/Mid.pm'  => 1,
            'My/Top.pm'  => 1,
            # NB: the harness Preloader is deliberately absent from `loaded`.
        },
    );

    # The changed file is the leaf dependency (absolute watched path + relative key).
    $pl->{+Test2::Harness2::Runner::Preloader::RELOADER()} = FakeReloader->new(
        changes => {
            '/abs/My/Leaf.pm' => {
                file     => '/abs/My/Leaf.pm',
                relative => 'My/Leaf.pm',
                module   => 'My::Leaf',
                reloaded => 0,          # not reloaded in place, no error => blacklist it
            },
        },
    );

    # %CNI (reverse %INC) is how ARRAY caller-files get normalized to relative keys.
    local $INC{'My/Leaf.pm'}                        = '/abs/My/Leaf.pm';
    local $INC{'My/Mid.pm'}                         = '/abs/My/Mid.pm';
    local $INC{'My/Top.pm'}                         = '/abs/My/Top.pm';
    local $INC{'Test2/Harness2/Runner/Preloader.pm'} = '/abs/T2H2/Preloader.pm';

    my $ret;
    my $ok = eval { $ret = $pl->check(FakeState->new); 1 };
    my $err = $@;
    ok($ok, "check() did not die on an empty caller module") or diag($err);
    is($ret, 1, "check() reported a change");

    open(my $fh, '<', "$dir/BLACKLIST") or die "Could not read BLACKLIST: $!";
    my %listed = map { $_ => 1 } grep { length } map { chomp; $_ } <$fh>;
    close($fh);

    ok($listed{'My::Leaf'}, "the changed leaf module is blacklisted");
    ok($listed{'My::Mid'},  "transitive dependent My::Mid is blacklisted (dep_map keyed by RELATIVE path)");
    ok($listed{'My::Top'},  "second-level transitive dependent My::Top is blacklisted");
    ok(!$listed{'Test2::Harness2::Runner::Preloader'}, "the harness's own loader (a dependent NOT in the traced-loaded set) is NOT blacklisted");
};

done_testing;
