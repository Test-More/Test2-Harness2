use Test2::V0;

# Regression tests for ticket #144 (Finder/test-selection bundle):
#   58  - unchecked chdir in multi-project search (typo'd/deleted project dir)
#   G12 - File::Find follow (symlinked test SUBDIRs now discovered)
#   G13 - exclude-list raw-string mismatch (./, whitespace, .., symlink alias)
#   G15 - durations-vs-exclusion ordering (--durations honored + no-/only-long)
#   G16 - listed-vs-scanned dedup aliasing (realpath key)

use App::Yath2::Finder;

use Cwd qw/getcwd/;
use File::Temp qw//;
use File::Basename qw/basename/;
use Config qw/%Config/;

my $HAVE_SYMLINK = $Config{d_symlink} ? 1 : 0;

# ---------------------------------------------------------------------------
# Minimal settings stand-in. find_project_files only touches
# settings->check_group('run'), settings->run->author_testing (skipped when the
# 'run' group is absent), and settings->finder->durations_threshold.
{
    package MockGroup;
    sub new { my ($c, %p) = @_; bless {%p}, $c }
    sub durations_threshold { $_[0]->{durations_threshold} }
    sub author_testing      { $_[0]->{author_testing} }

    package MockSettings;
    sub new { my ($c, %p) = @_; bless {%p}, $c }
    sub finder      { $_[0]->{finder} }
    sub run         { $_[0]->{run} }
    sub check_group { $_[0]->{groups}->{$_[1]} ? 1 : 0 }
}

sub mk_settings {
    my %p = @_;
    return MockSettings->new(
        finder => MockGroup->new(durations_threshold => $p{durations_threshold}),
        run    => MockGroup->new(author_testing      => 0),
        groups => {},    # check_group('run') is false -> default_at_search unused
    );
}

sub mk_finder {
    my %p = @_;
    return App::Yath2::Finder->new(
        default_search           => $p{default_search}    // [],
        default_at_search        => [],
        extensions               => $p{extensions}        // ['t'],
        exclude_files            => $p{exclude_files}      // {},
        exclude_patterns         => $p{exclude_patterns}   // [],
        exclude_lists            => undef,
        no_long                  => $p{no_long}            // 0,
        only_long                => $p{only_long}          // 0,
        durations                => $p{durations},
        maybe_durations          => $p{maybe_durations},
        multi_project            => $p{multi_project}      // 0,
        changed_only             => 0,
        search                   => $p{search},
        rerun_plugins            => [],
        changes_filter_files     => [],
        changes_filter_patterns  => [],
        changes_exclude_files    => [],
        changes_exclude_patterns => [],
    );
}

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Could not write '$path': $!";
    print $fh ($content // "use Test2::V0;\nok(1);\ndone_testing;\n");
    close($fh);
}

# Run $code with cwd inside a fresh temp dir; always restore cwd.
sub in_tmp(&) {
    my ($code) = @_;
    my $orig = getcwd();
    my $tmp  = File::Temp->newdir();
    chdir($tmp->dirname) or die "chdir tmp: $!";
    my $dir = getcwd();    # canonical (symlink-resolved) path
    my $ok  = eval { $code->($dir); 1 };
    my $err = $@;
    chdir($orig) or die "restore cwd: $!";
    die $err unless $ok;
}

# Capture STDOUT+STDERR produced while $code runs. Localizing the typeglobs
# restores the originals automatically at block exit (no fd juggling).
sub capture(&) {
    my ($code) = @_;
    my ($out, $err) = ('', '');
    my $ok = eval {
        local *STDOUT;
        local *STDERR;
        open(STDOUT, '>', \$out) or die $!;
        open(STDERR, '>', \$err) or die $!;
        $code->();
        1;
    };
    my $e = $@;
    die $e unless $ok;
    return ($out, $err);
}

# ---------------------------------------------------------------------------
subtest g12_symlinked_subdir_discovered => sub {
    plan skip_all => "symlink not supported" unless $HAVE_SYMLINK;

    in_tmp(sub {
        mkdir 't'          or die $!;
        mkdir 'outside'    or die $!;
        write_file('t/a.t');
        write_file('outside/c.t');
        symlink('../outside', 't/link') or die "symlink link: $!";    # dir OUTSIDE t/
        symlink('.',          't/self') or die "symlink self: $!";    # loop
        symlink('nowhere',    't/dangle') or die "symlink dangle: $!"; # dangling

        my $finder = mk_finder();
        my $res;
        my ($out, $err) = capture { $res = $finder->find_project_files([], mk_settings(), ['t']) };

        my @names = sort map { basename($_->relative) } @$res;
        is(\@names, ['a.t', 'c.t'], "discovered a.t AND c.t (c.t only reachable via symlinked subdir); loop + dangling handled");
    });
};

subtest g12_symlink_as_search_path_and_empty_dir => sub {
    plan skip_all => "symlink not supported" unless $HAVE_SYMLINK;

    in_tmp(sub {
        mkdir 'real' or die $!;
        write_file('real/c.t');
        symlink('real', 'link') or die "symlink: $!";

        my $res;
        my ($out, $err) = capture { $res = mk_finder()->find_project_files([], mk_settings(), ['link']) };
        is(scalar(@$res), 1, "a symlink given as the only search path still discovers its tests");

        mkdir 'empty' or die $!;
        ($out, $err) = capture { $res = mk_finder()->find_project_files([], mk_settings(), ['empty']) };
        is(scalar(@$res), 0, "empty search dir yields no tests");
        like($out, qr/No tests found under '.*empty'/, "prints a per-dir zero-yield diagnostic");
    });
};

subtest g13_exclude_spelling_variants => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/x.t');

        for my $spelling (' t/x.t ', './t/x.t', 't/../t/x.t') {
            my $finder = mk_finder(exclude_files => {$spelling => 1});
            my $res;
            my ($out, $err) = capture { $res = $finder->find_project_files([], mk_settings(), ['t/x.t']) };
            is(scalar(@$res), 0, "exclude entry '$spelling' matched and excluded the file");
            like($err, qr/listed on the command line, but has been excluded/, "reported the listed-file exclusion");
        }
    });
};

subtest g13_exclude_symlink_alias => sub {
    plan skip_all => "symlink not supported" unless $HAVE_SYMLINK;

    in_tmp(sub {
        mkdir 'realdir' or die $!;
        write_file('realdir/y.t');
        symlink('realdir', 'aliasdir') or die "symlink: $!";

        my $finder = mk_finder(exclude_files => {'aliasdir/y.t' => 1});
        my $res;
        my ($out, $err) = capture { $res = $finder->find_project_files([], mk_settings(), ['realdir/y.t']) };
        is(scalar(@$res), 0, "exclude entry via a symlink-alias spelling excludes the real file");
    });
};

subtest g13_never_matched_warning => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/x.t');

        my $finder = mk_finder(exclude_files => {'t/nope.t' => 1}, search => ['t/x.t']);
        my $res;
        my ($out, $err) = capture { $res = $finder->find_files([], mk_settings()) };
        is(scalar(@$res), 1, "the discovered test still runs");
        like($err, qr/1 exclude entries never matched any discovered test file/, "warns about the unmatched exclude entry");
        like($err, qr{t/nope\.t}, "names the unmatched entry");
    });
};

subtest g15_explicit_durations_below_threshold => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/a.t');

        my $finder = mk_finder(durations => {'t/a.t' => 'long'});
        my $res;
        my ($out, $err) = capture {
            $res = $finder->find_project_files([], mk_settings(durations_threshold => 100), ['t/a.t']);
        };
        is(scalar(@$res), 1, "one test");
        is($res->[0]->check_duration, 'long', "explicit --durations honored even below durations-threshold");
        like($out, qr/Fetched duration data/, "fetched explicit durations");
    });
};

subtest g15_only_long_no_long_use_durations => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/slow.t');    # no duration header => defaults to medium

        my $only = mk_finder(durations => {'t/slow.t' => 'long'}, only_long => 1);
        my $r1;
        capture { $r1 = $only->find_project_files([], mk_settings(durations_threshold => 100), ['t/slow.t']) };
        is(scalar(@$r1), 1, "--only-long KEEPS a durations-file LONG test (inversion fixed)");

        my $no = mk_finder(durations => {'t/slow.t' => 'long'}, no_long => 1);
        my $r2;
        capture { $r2 = $no->find_project_files([], mk_settings(durations_threshold => 100), ['t/slow.t']) };
        is(scalar(@$r2), 0, "--no-long SKIPS a durations-file LONG test");
    });
};

subtest g16_dedup_aliased_listing => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/db.t');

        my $finder = mk_finder();
        my $res;
        my ($out, $err) = capture {
            $res = $finder->find_project_files([], mk_settings(), ['t/../t/db.t', 't/']);
        };
        is(scalar(@$res), 1, "'t/../t/db.t t/' queues db.t exactly once");
        like($out, qr/Skipping '.*db\.t': already queued as/, "printed the dedup notice (spellings differ)");

        # Listed-vs-listed duplication is a preserved feature (run-twice idiom).
        my $finder2 = mk_finder();
        my $res2;
        capture { $res2 = $finder2->find_project_files([], mk_settings(), ['t/db.t=a', 't/db.t=b']) };
        is(scalar(@$res2), 2, "'t/db.t=a t/db.t=b' still queues the file twice");
    });
};

subtest g13_changes_exclude_spelling => sub {
    in_tmp(sub {
        mkdir 't' or die $!;
        write_file('t/x.t');

        my $finder = App::Yath2::Finder->new(
            changed                  => ['t/x.t'],
            changes_exclude_files    => ['./t/x.t'],    # './'-spelled entry
            changes_filter_files     => [],
            changes_filter_patterns  => [],
            changes_exclude_patterns => [],
            rerun_plugins            => [],
        );

        my $map = $finder->find_changes([], mk_settings());
        is(scalar(keys %$map), 0, "a './'-spelled changes_exclude_files entry excludes the changed file");
    });
};

subtest bug58_multi_project_typo_dies => sub {
    in_tmp(sub {
        my $cwd_before = getcwd();

        my $finder = mk_finder(multi_project => 1, search => ['does_not_exist_xyz']);
        my $ok = eval { $finder->find_multi_project_files([], mk_settings()); 1 };
        my $err = $@;

        ok(!$ok, "a typo'd/deleted project dir dies instead of scanning cwd");
        like($err, qr/does not exist or is not a directory/, "names the bad path");
        is(getcwd(), $cwd_before, "cwd restored after the failure");
    });
};

done_testing;
