use Test2::V0;
use warnings;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use App::Yath2::Log;
use App::Yath2::Command::archive;
use App::Yath2::Command::extract;
use Test2::Harness2::Util::Zstd qw/compress_blob compress_file_atomic open_zstd_writer/;

# Build a small logdir-shaped tree using the post-new_log_refactor
# layout: per-collector spec/events/report.jsonl(.zst), with no
# state.json.
sub _make_logdir {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services/harness");

    # spec.jsonl.zst with one row.
    my $w_spec = open_zstd_writer("$dir/services/harness/spec.jsonl.zst");
    $w_spec->say(qq[{"type":"Service","id":"harness","collector_pid":1234}]);
    $w_spec->close;

    # events.jsonl.zst with two rows.
    my $w_evt = open_zstd_writer("$dir/services/harness/events.jsonl.zst");
    $w_evt->say(qq[{"facet_data":{"harness":{"note":"a"}}}]);
    $w_evt->say(qq[{"facet_data":{"harness":{"note":"b"}}}]);
    $w_evt->close;

    # report.jsonl.zst with one row.
    my $w_rep = open_zstd_writer("$dir/services/harness/report.jsonl.zst");
    $w_rep->say(qq[{"exit":0}]);
    $w_rep->close;

    return $dir;
}

{
    package Fake::Yath;
    sub new              { bless { cwd => $_[1] // '/tmp/no-such-cwd' }, $_[0] }
    sub cwd              { $_[0]->{cwd} }
    sub project          { '__UNKNOWN__' }
    sub user             { 'fakeuser' }
sub orig_tmp         { undef }
    sub user_config_file { '' }
    sub config_file      { '' }

    package Fake::Extract;
    sub new           { bless { no_decompress => $_[1] // 0 }, $_[0] }
    sub no_decompress { $_[0]->{no_decompress} }

    package Fake::Settings;
    sub new {
        my ($class, %p) = @_;
        bless {
            yath    => Fake::Yath->new($p{cwd}),
            extract => Fake::Extract->new($p{no_decompress} // 0),
        }, $class;
    }
    sub yath    { $_[0]->{yath} }
    sub extract { $_[0]->{extract} }
}

sub _run_cmd {
    my ($class, @args) = @_;
    my %extras;
    @args = grep { !(ref($_) eq 'HASH' and %extras = (%extras, %$_)) } @args;
    my $cmd  = $class->new(args => [@args], settings => Fake::Settings->new(%extras));
    my $out  = '';
    my $orig = select;
    open(my $cap, '>', \$out) or die $!;
    select $cap;
    my $rc  = eval { $cmd->run };
    my $err = $@;
    select $orig;
    close $cap;
    return ($rc, $out, $err);
}

subtest 'archive + extract (default decompresses)' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');

    # .zst suffix stripped from output
    ok(-f "$dest/services/harness/spec.jsonl",   'spec extracted plaintext');
    ok(-f "$dest/services/harness/events.jsonl", 'events extracted plaintext');
    ok(-f "$dest/services/harness/report.jsonl", 'report extracted plaintext');
    ok(!-f "$dest/services/harness/spec.jsonl.zst",
        'no .zst suffix on extracted output');

    # The extracted tree is a valid sealed log.
    my $log = App::Yath2::Log->new(dir => $dest);
    isa_ok($log, ['App::Yath2::Log::Directory']);
    is([$log->services], ['harness'], 'extracted dir has harness service');

    # Bytes round-trip through Artifact API.
    my $a = $log->artifacts({service => 'harness'});
    like($a->events, qr/note":"a"/, 'events bytes contain note a');
};

subtest 'archive + extract --no-decompress preserves .zst' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored_raw";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', {no_decompress => 1}, $arc, $dest);
    is($err, '', 'extract: no exception');

    ok(-f "$dest/services/harness/spec.jsonl.zst",   'spec.jsonl.zst preserved');
    ok(-f "$dest/services/harness/events.jsonl.zst", 'events.jsonl.zst preserved');
    ok(!-f "$dest/services/harness/spec.jsonl",
        'no plaintext spec when --no-decompress');
};

done_testing;
