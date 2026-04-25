use Test2::V0;

use File::Spec ();
BEGIN { @INC = map { File::Spec->rel2abs($_) } @INC }

use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;

use App::Yath2::Command::archive;
use App::Yath2::Command::extract;
use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/writer_class_for/;

my $HAVE_TAR_ZIDX = eval { writer_class_for('tar.zidx'); 1 };
my $HAVE_TAR_BZ2  = eval { writer_class_for('tar.bz2');  1 };

sub _make_logdir {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/services" or die $!;
    open my $fh, '>', "$dir/services/harness.jsonl" or die $!;
    print $fh qq{{"event":"hi"}\n};
    close $fh;
    open $fh, '>', "$dir/artifacts.json" or die $!;
    print $fh qq[{"services/harness.jsonl":"X"}];
    close $fh;
    return $dir;
}

sub _run_cmd {
    my ($class, @args) = @_;
    my $cmd = $class->new(args => [@args], settings => {});
    my $out = '';
    my $orig = select;
    open(my $cap, '>', \$out) or die $!;
    select $cap;
    my $rc = eval { $cmd->run };
    my $err = $@;
    select $orig;
    close $cap;
    return ($rc, $out, $err);
}

subtest 'archive: explicit format works and round-trips through extract' => sub {
    plan skip_all => 'tar.zidx writer not viable (need Compress::Zstd or zstd binary)'
        unless $HAVE_TAR_ZIDX;

    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.tar.zidx";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive',
        $logdir, $arc, 'tar.zidx');
    is($err, '', 'archive: no exception');
    is($rc,  0,  'archive: rc=0');
    ok(-s $arc, 'archive: output file non-empty');
    like($out, qr/Wrote archive/, 'archive: wrote message');

    my $dest = "$work/restored";
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');
    is($rc,  0,  'extract: rc=0');
    ok(-d $dest, 'extract: destination created');

    open my $rfh, '<', "$dest/services/harness.jsonl" or die $!;
    is(scalar(<$rfh>), qq{{"event":"hi"}\n}, 'extract: file contents intact');
};

subtest 'archive: default filename when only logdir given' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $orig_cwd = getcwd();
    chdir $work or die "chdir: $!";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', $logdir);
    chdir $orig_cwd;

    is($err, '', 'no exception');
    is($rc,  0,  'rc=0');
    my @yath = glob "$work/*.yath";
    is(scalar(@yath), 1, 'one .yath file produced');
    like($yath[0], qr{/\d{8}-\d{6}\.yath\z}, 'name matches date-time pattern');
};

subtest 'archive: missing logdir errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive');
    like($err, qr/logdir is required/, 'logdir required');
};

subtest 'archive: bad logdir errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive', '/no/such/logdir');
    like($err, qr/is not a directory/, 'bad logdir rejected');
};

subtest 'archive: invalid format errors' => sub {
    my $logdir = _make_logdir();
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive',
        $logdir, 'foo.out', 'made.up');
    like($err, qr/format 'made\.up' is not viable/, 'bad format rejected');
};

subtest 'extract: missing archive errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract');
    like($err, qr/archive_filename is required/, 'archive required');
};

subtest 'extract: nonexistent archive errors' => sub {
    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', '/no/such/file');
    like($err, qr/does not exist/, 'missing archive rejected');
};

subtest 'extract: existing destination errors' => sub {
    plan skip_all => 'tar.bz2 writer not viable'
        unless $HAVE_TAR_BZ2;

    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.tar.bz2";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive',
        $logdir, $arc, 'tar.bz2');
    is($err, '', 'archive ok');

    mkdir "$work/dest" or die $!;
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc, "$work/dest");
    like($err, qr/already exists/, 'pre-existing destination rejected');
};

subtest 'extract: default destination is ./logs' => sub {
    plan skip_all => 'tar.bz2 writer not viable'
        unless $HAVE_TAR_BZ2;

    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.tar.bz2";

    my ($rc, $out, $err) = _run_cmd('App::Yath2::Command::archive',
        $logdir, $arc, 'tar.bz2');
    is($err, '', 'archive ok');

    my $orig_cwd = getcwd();
    chdir $work or die "chdir: $!";
    ($rc, $out, $err) = _run_cmd('App::Yath2::Command::extract', $arc);
    chdir $orig_cwd;

    is($err, '', 'no exception');
    ok(-d "$work/logs", 'created ./logs');
    ok(-f "$work/logs/services/harness.jsonl", 'extracted into ./logs');
};

done_testing;
