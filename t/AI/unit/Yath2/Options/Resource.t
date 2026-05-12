use Test2::V0;
use File::Spec;

# Verify the Resource option group correctly parses every form of the
# -j (slots) and -x (job_slots) flags, including the combined -j N:M
# syntax that the trigger splits, every long alias, and the env var
# fallbacks documented on each option.
#
# Also verifies the default resource injection behaviour:
#   - No -j, no -R: CPU + Memory + UnixLimits + PipeLimits + Throttle + Disk*
#     (* Disk only when Filesys::Df is installed; no JobCount)
#   - -j N: same set plus JobCount
#   - -R ...: merges with defaults; user's per-class args win via //=
#   - --no-resource: empty classes hash
#
# Filesys::Df is an optional dependency. When absent, Disk is silently
# skipped. Tests below gate Disk-specific assertions accordingly.

my $HAS_FILESYS_DF = eval { require Filesys::Df; 1 } ? 1 : 0;

package TestResource {
    use Getopt::Yath;
    include_options('App::Yath2::Options::Resource');
}

sub parse {
    my @argv = @_;
    local %ENV = %ENV;
    delete @ENV{qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT T2_HARNESS_JOB_CONCURRENCY/};
    my $state = TestResource::parse_options([@argv]);
    return $state->{settings}->resource;
}

sub parse_with_env {
    my ($env, @argv) = @_;
    local %ENV = (%ENV, %$env);
    my $state = TestResource::parse_options([@argv]);
    return $state->{settings}->resource;
}

subtest '-j N short form' => sub {
    my $r = parse('-j', '8');
    is($r->slots,     8, 'slots from -j');
    is($r->job_slots, 1, 'job_slots default 1');
};

subtest '-j N:M combined form' => sub {
    my $r = parse('-j', '8:2');
    is($r->slots,     8, 'slots from N portion');
    is($r->job_slots, 2, 'job_slots from M portion');
};

subtest '--slots N' => sub {
    my $r = parse('--slots', '6');
    is($r->slots,     6, 'slots from --slots');
    is($r->job_slots, 1, 'job_slots default 1');
};

subtest '--jobs N alias' => sub {
    my $r = parse('--jobs', '4');
    is($r->slots, 4, 'slots from --jobs');
};

subtest '--job-count N alias' => sub {
    my $r = parse('--job-count', '5');
    is($r->slots, 5, 'slots from --job-count');
};

subtest '-x M short form' => sub {
    my $r = parse('-j', '6', '-x', '3');
    is($r->slots,     6, 'slots');
    is($r->job_slots, 3, 'job_slots from -x');
};

subtest '--slots-per-job M alias' => sub {
    my $r = parse('-j', '6', '--slots-per-job', '2');
    is($r->job_slots, 2, 'job_slots from --slots-per-job');
};

subtest '--job-slots M long form' => sub {
    my $r = parse('-j', '4', '--job-slots', '2');
    is($r->job_slots, 2, 'job_slots from --job-slots');
};

subtest 'YATH_JOB_COUNT env var' => sub {
    my $r = parse_with_env({YATH_JOB_COUNT => 7});
    is($r->slots, 7, 'slots from YATH_JOB_COUNT');
};

subtest 'T2_HARNESS_JOB_COUNT env var' => sub {
    my $r = parse_with_env({T2_HARNESS_JOB_COUNT => 9});
    is($r->slots, 9, 'slots from T2_HARNESS_JOB_COUNT');
};

subtest 'HARNESS_JOB_COUNT env var' => sub {
    my $r = parse_with_env({HARNESS_JOB_COUNT => 3});
    is($r->slots, 3, 'slots from HARNESS_JOB_COUNT');
};

subtest 'T2_HARNESS_JOB_CONCURRENCY env var for job_slots' => sub {
    my $r = parse_with_env({YATH_JOB_COUNT => 8, T2_HARNESS_JOB_CONCURRENCY => 4});
    is($r->slots,     8, 'slots from YATH_JOB_COUNT');
    is($r->job_slots, 4, 'job_slots from T2_HARNESS_JOB_CONCURRENCY');
};

subtest '-j N:M overrides -x argument order' => sub {
    # -j parses second; trigger writes group->{job_slots}=2 directly
    my $r = parse('-x', '5', '-j', '8:2');
    is($r->slots,     8, 'slots from N');
    is($r->job_slots, 2, 'N:M trigger overrides earlier -x');
};

subtest 'job_slots > slots is rejected' => sub {
    my $err = dies { parse('-j', '4', '-x', '8') };
    like(
        $err,
        qr/slots per job .* must not be larger than .* total number of slots/,
        'post-process rejects job_slots > slots',
    );
};

subtest '-j is undef when not supplied' => sub {
    my $r = parse();
    ok(!defined $r->slots, 'slots is undef when -j not given');
};

subtest 'default resource set (no -j, no -R): utilizers + throttle + Disk*, no JobCount' => sub {
    my $r       = parse();
    my $classes = $r->classes;

    ok(exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU auto-injected');
    ok(exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory auto-injected');
    ok(exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits auto-injected');
    ok(exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits auto-injected');
    ok(exists $classes->{'Test2::Harness2::Resource::Throttle'},   'Throttle auto-injected');
    ok(!exists $classes->{'Test2::Harness2::Resource::JobCount'},  'JobCount NOT injected without -j');

    if ($HAS_FILESYS_DF) {
        ok(exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk auto-injected (Filesys::Df present)');
        is(scalar keys %$classes, 6, 'exactly six default resources (with Disk)');
    }
    else {
        ok(!exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk NOT injected (Filesys::Df absent)');
        is(scalar keys %$classes, 5, 'exactly five default resources (no Filesys::Df)');
    }
};

subtest '-j N adds JobCount to default set' => sub {
    my $r       = parse('-j', '4');
    my $classes = $r->classes;

    ok(exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU present with -j');
    ok(exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory present with -j');
    ok(exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits present with -j');
    ok(exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits present with -j');
    ok(exists $classes->{'Test2::Harness2::Resource::Throttle'},   'Throttle present with -j');
    ok(exists $classes->{'Test2::Harness2::Resource::JobCount'},   'JobCount auto-injected when -j given');

    if ($HAS_FILESYS_DF) {
        ok(exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk auto-injected with -j (Filesys::Df present)');
        is(scalar keys %$classes, 7, 'seven resources when -j is given (with Disk)');
    }
    else {
        ok(!exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk NOT injected (Filesys::Df absent)');
        is(scalar keys %$classes, 6, 'six resources when -j is given (no Filesys::Df)');
    }
};

subtest '--utilize defaults to 75' => sub {
    my $r = parse();
    is($r->utilize, 75, 'utilize defaults to 75');
};

subtest '--utilize value flows into utilizer args' => sub {
    my $r = parse('-U', '60');
    is($r->utilize, 60, '-U 60 stored');

    my $classes = $r->classes;
    is(
        $classes->{'Test2::Harness2::Resource::CPU'},
        [utilize_percent => 60],
        'CPU args contain utilize_percent => 60',
    );
    is(
        $classes->{'Test2::Harness2::Resource::Memory'},
        [utilize_percent => 60],
        'Memory args contain utilize_percent => 60',
    );
};

subtest '--utilize default 75 flows into utilizer args' => sub {
    my $r       = parse();
    my $classes = $r->classes;
    is(
        $classes->{'Test2::Harness2::Resource::CPU'},
        [utilize_percent => 75],
        'CPU args contain default utilize_percent => 75',
    );
};

subtest 'explicit -R merges with defaults; user class wins' => sub {
    # -R JobCount alone: JobCount gets user's (empty) args; all four utilizers,
    # Throttle, and (when Filesys::Df is present) Disk are still injected via
    # //= since the user didn't supply them.
    my $r       = parse('-R', '+Test2::Harness2::Resource::JobCount');
    my $classes = $r->classes;

    ok(exists $classes->{'Test2::Harness2::Resource::JobCount'},   'explicit -R resource present');
    ok(exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU still injected alongside -R');
    ok(exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory still injected alongside -R');
    ok(exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits still injected alongside -R');
    ok(exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits still injected alongside -R');
    ok(exists $classes->{'Test2::Harness2::Resource::Throttle'},   'Throttle still injected alongside -R');

    if ($HAS_FILESYS_DF) {
        ok(exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk still injected alongside -R (Filesys::Df present)');
        is(scalar keys %$classes, 7, 'seven classes: six defaults plus user-supplied JobCount');
    }
    else {
        ok(!exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk NOT injected (Filesys::Df absent)');
        is(scalar keys %$classes, 6, 'six classes: five defaults plus user-supplied JobCount');
    }
};

subtest '-R Throttle=10/2s: user Throttle args win, other defaults still present' => sub {
    my $r       = parse('-R', '+Test2::Harness2::Resource::Throttle=10/2s');
    my $classes = $r->classes;

    ok(exists $classes->{'Test2::Harness2::Resource::Throttle'}, 'Throttle present');
    is(
        $classes->{'Test2::Harness2::Resource::Throttle'},
        ['10/2s'],
        'user Throttle args win over default 1/core,100mb/1s',
    );
    ok(exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits still injected');
    ok(!exists $classes->{'Test2::Harness2::Resource::JobCount'},  'JobCount NOT injected without -j');

    if ($HAS_FILESYS_DF) {
        ok(exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk auto-injected (Filesys::Df present)');
        is(scalar keys %$classes, 6, 'six classes total (Throttle overridden, Disk injected, no JobCount)');
    }
    else {
        ok(!exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk NOT injected (Filesys::Df absent)');
        is(scalar keys %$classes, 5, 'five classes total (Throttle overridden, no Disk, no JobCount)');
    }
};

subtest '-R Disk=/tmp:25%: user Disk args win over auto-injected default' => sub {
    # Disk is now part of the default set (when Filesys::Df is available).
    # The user's -R Disk entry is set before post-process runs, so the //=
    # auto-inject is a no-op; user args are preserved.  Whether or not
    # Filesys::Df is installed, the count is 6: user Disk + 5 auto-injected
    # defaults (CPU, Memory, UnixLimits, PipeLimits, Throttle).
    my $r       = parse('-R', '+Test2::Harness2::Resource::Disk=/tmp:25%');
    my $classes = $r->classes;

    ok(exists $classes->{'Test2::Harness2::Resource::Disk'}, 'Disk present');
    is(
        $classes->{'Test2::Harness2::Resource::Disk'},
        ['/tmp:25%'],
        'user Disk args win (not overridden by auto-inject)',
    );
    ok(exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits still injected');
    ok(exists $classes->{'Test2::Harness2::Resource::Throttle'},   'Throttle still injected');
    ok(!exists $classes->{'Test2::Harness2::Resource::JobCount'},  'JobCount NOT injected without -j');
    is(scalar keys %$classes, 6, 'six classes: 5 defaults + Disk (user-supplied or auto-injected)');
};

subtest 'Throttle default arg is 1/core,100mb/1s' => sub {
    my $r = parse();
    is(
        $r->classes->{'Test2::Harness2::Resource::Throttle'},
        ['1/core,100mb/1s'],
        'Throttle default arg is 1/core,100mb/1s',
    );
};

subtest '--no-resource disables all auto-injection' => sub {
    my $r = parse('--no-resource');
    is(
        scalar keys %{$r->classes},
        0,
        '--no-resource leaves classes empty (unlimited concurrency)',
    );
    ok($r->check_option('no_resource'), 'no_resource flag recorded by classes trigger');
    ok($r->no_resource,                 'no_resource setting reflects opt-in');
};

subtest '--no-resources (plural) also disables auto-injection' => sub {
    my $r = parse('--no-resources');
    is(scalar keys %{$r->classes}, 0, '--no-resources leaves classes empty');
    ok($r->check_option('no_resource'), 'plural form sets the same flag');
};

subtest '--no-resource followed by -R: explicit -R entries survive, but no defaults injected' => sub {
    # --no-resource clears classes and sets no_resource=1.
    # -R then adds its class back.
    # post-process sees no_resource=1 and returns early -- so no defaults
    # are injected. The result is only the explicitly -R-supplied class.
    my $r       = parse('--no-resource', '-R', '+Test2::Harness2::Resource::JobCount');
    my $classes = $r->classes;

    ok(
        exists $classes->{'Test2::Harness2::Resource::JobCount'},
        '-R after --no-resource still wires the resource through',
    );
    ok(!exists $classes->{'Test2::Harness2::Resource::CPU'},      'CPU NOT injected (no_resource early-return)');
    ok(!exists $classes->{'Test2::Harness2::Resource::Throttle'}, 'Throttle NOT injected (no_resource early-return)');
    is(scalar keys %$classes, 1, 'only the -R-supplied class, no defaults');
};

subtest '--utilize accepts valid percentages' => sub {
    my $r = parse('-U', '50');
    is($r->utilize, 50, '-U 50 stored');

    my $r2 = parse('--utilize', '99.5');
    is($r2->utilize, 99.5, '--utilize 99.5 stored');
};

subtest '--utilize rejects out-of-range and non-numeric values' => sub {
    like(dies { parse('-U', '0') },     qr/--utilize must be greater than 0/);
    like(dies { parse('-U', '100') },   qr/--utilize must be greater than 0/);
    like(dies { parse('-U', '-5') },    qr/--utilize must be a number/);
    like(dies { parse('-U', 'fifty') }, qr/--utilize must be a number/);
};

# -------------------------------------------------------------------------
# Disk auto-injection subtests
# -------------------------------------------------------------------------

subtest 'Disk auto-inject: default --utilize 75 => min_free 25%' => sub {
    if (!$HAS_FILESYS_DF) {
        skip_all 'Filesys::Df not installed; Disk auto-inject skipped';
    }

    my $tmpdir = File::Spec->tmpdir;
    my $r      = parse();
    is(
        $r->classes->{'Test2::Harness2::Resource::Disk'},
        ["$tmpdir:25%"],
        'Disk default targets tmpdir with utilize-derived min_free (75 => 25%)',
    );
};

subtest 'Disk auto-inject: -U 80 => min_free 20%' => sub {
    if (!$HAS_FILESYS_DF) {
        skip_all 'Filesys::Df not installed; Disk auto-inject skipped';
    }

    my $tmpdir = File::Spec->tmpdir;
    my $r      = parse('-U', '80');
    is(
        $r->classes->{'Test2::Harness2::Resource::Disk'},
        ["$tmpdir:20%"],
        'Disk min_free is 20% when --utilize is 80',
    );
};

subtest 'Disk auto-inject: -U 50 => min_free 50%' => sub {
    if (!$HAS_FILESYS_DF) {
        skip_all 'Filesys::Df not installed; Disk auto-inject skipped';
    }

    my $tmpdir = File::Spec->tmpdir;
    my $r      = parse('-U', '50');
    is(
        $r->classes->{'Test2::Harness2::Resource::Disk'},
        ["$tmpdir:50%"],
        'Disk min_free is 50% when --utilize is 50',
    );
};

subtest 'user -R Disk=... overrides auto-injected default (args win, not merged)' => sub {
    if (!$HAS_FILESYS_DF) {
        skip_all 'Filesys::Df not installed; Disk auto-inject skipped';
    }

    # When the user supplies a Disk entry, //= in post-process is a no-op.
    # The user gets exactly /tmp:10% — NOT the tmpdir:25% that would have
    # been auto-injected.
    my $r = parse('-R', '+Test2::Harness2::Resource::Disk=/tmp:10%');
    is(
        $r->classes->{'Test2::Harness2::Resource::Disk'},
        ['/tmp:10%'],
        'user -R Disk args win: /tmp:10%',
    );
};

subtest 'user -R Disk=/var:5gb replaces auto-inject entirely (no tmpdir added)' => sub {
    if (!$HAS_FILESYS_DF) {
        skip_all 'Filesys::Df not installed; Disk auto-inject skipped';
    }

    # The user gets exactly one Disk entry (/var:5gb).  The tmpdir default
    # is NOT merged in — user's args are the whole Disk config.
    my $r    = parse('-R', '+Test2::Harness2::Resource::Disk=/var:5gb');
    my $disk = $r->classes->{'Test2::Harness2::Resource::Disk'};
    is($disk, ['/var:5gb'], 'user Disk entry is /var:5gb only (no tmpdir merged in)');
};

subtest 'non-Linux fallback: no utilizer stack, JobCount derived from CPU count' => sub {
    no warnings 'redefine';
    local $^O = 'darwin';
    local *App::Yath2::Options::Resource::_detect_cpu_count = sub { 8 };

    my $r       = parse();
    my $classes = $r->classes;

    ok(!exists $classes->{'Test2::Harness2::Resource::CPU'},        'CPU not injected off-Linux');
    ok(!exists $classes->{'Test2::Harness2::Resource::Memory'},     'Memory not injected off-Linux');
    ok(!exists $classes->{'Test2::Harness2::Resource::UnixLimits'}, 'UnixLimits not injected off-Linux');
    ok(!exists $classes->{'Test2::Harness2::Resource::PipeLimits'}, 'PipeLimits not injected off-Linux');
    ok(!exists $classes->{'Test2::Harness2::Resource::Throttle'},   'Throttle not injected off-Linux');
    ok(exists $classes->{'Test2::Harness2::Resource::JobCount'},    'JobCount auto-injected off-Linux');
    is($r->slots, 4, 'slots = half of CPU count (8 / 2 = 4)');
};

subtest 'non-Linux fallback: CPU count undetected falls back to 2' => sub {
    no warnings 'redefine';
    local $^O = 'darwin';
    local *App::Yath2::Options::Resource::_detect_cpu_count = sub { undef };

    my $r = parse();
    is($r->slots, 2, 'slots = 2 when CPU count is unobtainable');
    ok(exists $r->classes->{'Test2::Harness2::Resource::JobCount'}, 'JobCount auto-injected');
};

subtest 'non-Linux fallback: half of 1 CPU rounds up to 1' => sub {
    no warnings 'redefine';
    local $^O = 'darwin';
    local *App::Yath2::Options::Resource::_detect_cpu_count = sub { 1 };

    my $r = parse();
    is($r->slots, 1, 'slots = 1 when CPU count is 1 (floor 1, not 0)');
};

subtest 'non-Linux: explicit -j overrides auto-derived cap' => sub {
    no warnings 'redefine';
    local $^O = 'darwin';
    local *App::Yath2::Options::Resource::_detect_cpu_count = sub { 16 };

    my $r = parse('-j', '3');
    is($r->slots, 3, 'user-supplied -j wins over auto-derive');
    ok(exists $r->classes->{'Test2::Harness2::Resource::JobCount'}, 'JobCount injected from user -j');
};

done_testing;
