use Test2::V0;

# Ticket TODO-152:
#   finding 89 -- ensure_sqlite_db's bootstrap was non-atomic. Statements were
#     written straight into $path under autocommit, so (a) an interrupt after the
#     first committed DDL left a partial, non-empty file that the `-s` "already
#     exists" check trusted forever ('no such table: runs'), and (b) two processes
#     first-opening a SHARED results DB both ran CREATE TABLE against the same
#     handle and the loser died on a duplicate table. The fix bootstraps into a
#     private temp + atomic rename, and decides "already bootstrapped" by a
#     schema_meta MARKER, not by size.
#   finding 90 -- require_db_modules swallowed the real load error: an installed
#     but BROKEN DBIx::QuickORM / DBD was misreported as "not installed", hiding
#     the actual compile failure. It now appends the captured error unless the
#     failure is a top-level "Can't locate <that module>" (genuinely absent).

use File::Temp qw/tempdir/;
use POSIX ();

use App::Yath2::DB::Connect qw/ensure_sqlite_db/;
use App::Yath2::DB::Flavor;

my $flavor = App::Yath2::DB::Flavor->by_name('sqlite');

# ---------------------------------------------------------------------------
# finding 90: _load_failure_detail classifies a require() failure.
# (No DB deps needed -- pure string logic over a real captured $@.)
# ---------------------------------------------------------------------------
subtest 'finding 90: broken module surfaces the load error; absent stays quiet' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # A genuinely-absent module: a top-level "Can't locate" -> stay quiet, the
    # "install X" hint already covers it.
    my $absent;
    { local @INC = @INC; eval { require No::Such::Yath::Mod::Xyz; 1 } or $absent = $@; }
    like($absent, qr/Can't locate/, "absent module really Can't-locates");
    is(
        App::Yath2::DB::Connect::_load_failure_detail('No/Such/Yath/Mod/Xyz.pm', $absent),
        '',
        "a genuinely-absent module appends NO detail (install hint suffices)",
    );

    # An installed-but-BROKEN module: a real compile error the user must see.
    mkdir "$dir/Broken";
    open(my $bfh, '>', "$dir/Broken/Mod.pm") or die $!;
    print $bfh "package Broken::Mod;\nthis is not valid perl (\n1;\n";
    close($bfh);

    my $broken;
    { local @INC = ($dir, @INC); eval { require Broken::Mod; 1 } or $broken = $@; }
    ok($broken, "the broken fixture really fails to load");
    my $detail = App::Yath2::DB::Connect::_load_failure_detail('Broken/Mod.pm', $broken);
    ok(length $detail, "a broken (installed) module DOES append the real error");
    like($detail, qr/actual load error/, "the appended detail is labelled");

    # A module whose OWN dependency Can't-locates is a broken install, not the
    # module-absent case -- the error names a DIFFERENT module, so it surfaces.
    my $dep_err = "Can't locate Some/Dependency.pm in \@INC (\@INC entries...) at Broken/Mod.pm line 2.\n";
    ok(
        length App::Yath2::DB::Connect::_load_failure_detail('Broken/Mod.pm', $dep_err),
        "a dependency Can't-locate (different module) surfaces -- it's a broken install",
    );
};

# The remaining subtests bootstrap real sqlite files.
skip_all "DBD::SQLite not available" unless eval { require DBD::SQLite; 1 };

# ---------------------------------------------------------------------------
# finding 89: an interrupt during the DDL never leaves a half-built $path.
# ---------------------------------------------------------------------------
subtest 'finding 89: a die mid-DDL leaves NO $path (self-heals on retry)' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/interrupted.sqlite";

    {
        no warnings 'redefine';
        local *App::Yath2::DB::Connect::_load_ddl = sub { die "injected mid-DDL failure\n" };
        my $ok = eval { ensure_sqlite_db($path, $flavor); 1 };
        my $err = $@;
        ok(!$ok, "the interrupted bootstrap propagated the failure");
        like($err, qr/injected mid-DDL/, "the real DDL error is not swallowed");
    }

    ok(!-e $path, "\$path was NEVER created -- no partial file to trust later");

    # And a real retry heals cleanly.
    my $ret = ensure_sqlite_db($path, $flavor);
    is($ret, $path, "a retry bootstraps successfully");
    ok(_schema_meta_rows($path) == 1, "the healed DB carries exactly one schema_meta marker row");
};

# ---------------------------------------------------------------------------
# finding 89: a non-zero file WITHOUT the schema marker is rebuilt, not trusted.
# ---------------------------------------------------------------------------
subtest 'finding 89: a markerless (partial) file is rebuilt, not trusted by size' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/partial.sqlite";

    # A VALID sqlite file with a stray table but NO schema_meta -- the exact shape
    # a bootstrap interrupted before the runs/schema_meta rows would leave. It is
    # non-empty, so the old `-s` check trusted it.
    my $dbh = DBI->connect($flavor->dbd_dsn_prefix . $path, '', '', $flavor->connect_attrs);
    $dbh->do("CREATE TABLE stray (x INTEGER)");
    $dbh->disconnect;
    ok(-s $path, "the partial file is non-empty (would fool a size-only check)");

    ensure_sqlite_db($path, $flavor);

    ok(_schema_meta_rows($path) == 1, "the markerless file was rebuilt with a real schema");
};

# ---------------------------------------------------------------------------
# finding 89: two concurrent first-opens of a SHARED path both succeed.
# ---------------------------------------------------------------------------
subtest 'finding 89: concurrent first-opens all succeed (no duplicate-table race)' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/shared.sqlite";

    my $n = 5;

    # A barrier: every child blocks reading one byte, then the parent releases them
    # together so they genuinely race on the same fresh $path.
    pipe(my $rd, my $wr) or die "pipe: $!";

    my @kids;
    for (1 .. $n) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        unless ($pid) {
            srand();                    # forks inherit Test2's deterministic srand
            close($wr);
            sysread($rd, my $go, 1);    # wait for the start signal
            my $ok = eval { ensure_sqlite_db($path, $flavor); 1 };
            POSIX::_exit($ok ? 0 : 1);
        }
        push @kids, $pid;
    }
    close($rd);
    syswrite($wr, 'x' x $n);            # release them all at once
    close($wr);

    my $failures = 0;
    for my $pid (@kids) {
        waitpid($pid, 0);
        $failures++ if $?;
    }

    is($failures, 0, "all $n concurrent bootstraps succeeded (no duplicate-table die)");
    ok(-e $path, "the shared DB was published");
    is(_schema_meta_rows($path), 1, "exactly one schema_meta row -- one winner, no double-INSERT");
};

# schema_meta row count for a bootstrapped sqlite file (0 if the table is absent).
sub _schema_meta_rows {
    my ($path) = @_;
    require DBI;
    my $n = -1;
    eval {
        my $dbh = DBI->connect($flavor->dbd_dsn_prefix . $path, '', '', $flavor->connect_attrs(read_only => 1));
        ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM schema_meta");
        $dbh->disconnect;
        1;
    };
    return $n;
}

done_testing;
