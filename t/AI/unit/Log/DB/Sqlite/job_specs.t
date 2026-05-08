use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;
use App::Yath2::Log::DB;

# Helper: override App::Yath2::Log::build_archive_meta to inject a
# specific project name.
my $real_build_archive_meta = App::Yath2::Log->can('build_archive_meta');
sub with_project {
    my ($project_name, $code) = @_;
    no warnings 'redefine';
    local *App::Yath2::Log::build_archive_meta = sub {
        my ($class, %p) = @_;
        my $meta = $real_build_archive_meta->($class, %p);
        $meta->{project} = $project_name;
        return $meta;
    };
    use warnings 'redefine';
    $code->();
}

# Build a synthetic log directory. The spec.jsonl for the job try
# contains a full set of TestFile-like keys.
sub build_log_with_spec {
    my (%spec_override) = @_;
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    for my $base ('services/harness', 'runs/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    {
        my $w = open_zstd_writer("$src/runs/0/jobs/0/0/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    my %spec = (
        relative          => 't/unit/foo.t',
        absolute          => '/home/user/t/unit/foo.t',
        category          => 'medium',
        duration          => 'long',
        stage             => 'default',
        features          => ['feature_a'],
        switches          => ['-w'],
        retry             => 1,
        retry_isolated    => 0,
        smoke             => 0,
        isolation         => 0,
        non_perl          => 0,
        is_binary         => 0,
        event_timeout     => 60,
        post_exit_timeout => 15,
        min_slots         => 1,
        max_slots         => 1,
        ch_dir            => undef,
        # extras: keys not in @JOB_SPECS_PROMOTED_KEYS and not 'relative'
        comment           => 'a test comment',
        meta              => { some => 'data' },
        started_at        => '2026-01-01T00:00:00Z',
        %spec_override,
    );

    {
        my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
        $w->say(encode_json(\%spec));
        $w->close;
    }

    return ($src, \%spec);
}

# --- Part 1: @JOB_SPECS_PROMOTED_KEYS constant ---

my @promoted = @App::Yath2::Log::DB::JOB_SPECS_PROMOTED_KEYS;
ok(scalar @promoted > 0, '@JOB_SPECS_PROMOTED_KEYS is non-empty');
ok((grep { $_ eq 'absolute'  } @promoted), 'absolute in promoted keys');
ok((grep { $_ eq 'category'  } @promoted), 'category in promoted keys');
ok((grep { $_ eq 'duration'  } @promoted), 'duration in promoted keys');
ok((grep { $_ eq 'switches'  } @promoted), 'switches in promoted keys');
ok(!(grep { $_ eq 'relative' } @promoted),
    'relative is NOT in promoted keys (goes to test_files.relative)');

# --- Part 2: full insert() integration with job_specs ---

my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $db_path;
my $db  = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
$db->bootstrap_schema;
my $dbh = $db->dbh;

my ($src1, $spec1) = build_log_with_spec();

my $aid1;
with_project('myproj', sub {
    $aid1 = $db->insert(App::Yath2::Log->new(dir => $src1));
});
ok(defined $aid1, 'insert() succeeded');

# job_specs: one row.
my ($js_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM job_specs');
is($js_count, 1, 'one job_specs row after insert');

my $js = $dbh->selectrow_hashref('SELECT * FROM job_specs');
ok(defined $js, 'job_specs row retrieved');

# Promoted fields match spec.
is($js->{absolute},          $spec1->{absolute},          'job_specs.absolute correct');
is($js->{category},          $spec1->{category},          'job_specs.category correct');
is($js->{duration},          $spec1->{duration},          'job_specs.duration correct');
is($js->{stage},             $spec1->{stage},             'job_specs.stage correct');
is($js->{retry},             $spec1->{retry},             'job_specs.retry correct');
is($js->{event_timeout},     $spec1->{event_timeout},     'job_specs.event_timeout correct');
is($js->{post_exit_timeout}, $spec1->{post_exit_timeout}, 'job_specs.post_exit_timeout correct');
is($js->{min_slots},         $spec1->{min_slots},         'job_specs.min_slots correct');
is($js->{max_slots},         $spec1->{max_slots},         'job_specs.max_slots correct');

# Boolean/integer flags.
is($js->{retry_isolated}, 0, 'job_specs.retry_isolated = 0');
is($js->{smoke},          0, 'job_specs.smoke = 0');
is($js->{isolation},      0, 'job_specs.isolation = 0');
is($js->{non_perl},       0, 'job_specs.non_perl = 0');
is($js->{is_binary},      0, 'job_specs.is_binary = 0');

# JSON-encoded array fields.
ok(defined $js->{features}, 'job_specs.features is set');
ok(defined $js->{switches}, 'job_specs.switches is set');
my $features = decode_json($js->{features});
is($features, ['feature_a'], 'job_specs.features decoded correctly');
my $switches = decode_json($js->{switches});
is($switches, ['-w'], 'job_specs.switches decoded correctly');

# extras should contain 'comment', 'meta', 'started_at' (not a promoted key).
ok(defined $js->{extras}, 'job_specs.extras is set');
my $extras = decode_json($js->{extras});
ok(defined $extras->{comment},    'extras.comment present');
ok(defined $extras->{meta},       'extras.meta present');
ok(defined $extras->{started_at}, 'extras.started_at present');
ok(!exists $extras->{relative},   'extras does not contain relative (consumed)');
ok(!exists $extras->{absolute},   'extras does not contain absolute (promoted)');
ok(!exists $extras->{category},   'extras does not contain category (promoted)');

# test_file_id FK: job_specs.test_file_id should match test_files row for t/unit/foo.t.
my $tf = $dbh->selectrow_hashref(
    q{SELECT * FROM test_files WHERE relative = ?}, undef, 't/unit/foo.t',
);
ok(defined $tf, 'test_files row for t/unit/foo.t exists');
is($js->{test_file_id}, $tf->{test_file_id},
    'job_specs.test_file_id FK matches test_files row');

# --- Part 3: re-inserting same suite does NOT duplicate job_specs rows ---

my ($src2, $spec2) = build_log_with_spec();
my $aid2;
with_project('myproj', sub {
    $aid2 = $db->insert(App::Yath2::Log->new(dir => $src2));
});
ok(defined $aid2, 'second insert (re-run same suite) succeeded');

($js_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM job_specs');
is($js_count, 2, '2 job_specs rows after second insert (one per job)');

# --- Part 4: two different test files in same project ---

my ($src3, $spec3) = build_log_with_spec(relative => 't/unit/bar.t',
                                          absolute => '/home/user/t/unit/bar.t');
my $aid3;
with_project('myproj', sub {
    $aid3 = $db->insert(App::Yath2::Log->new(dir => $src3));
});
ok(defined $aid3, 'third insert (different test file) succeeded');

($js_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM job_specs');
is($js_count, 3, '3 job_specs rows total');

my ($tf_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM test_files');
is($tf_count, 2, '2 test_files rows: t/unit/foo.t and t/unit/bar.t');

my $bar_tf = $dbh->selectrow_hashref(
    q{SELECT * FROM test_files WHERE relative = ?}, undef, 't/unit/bar.t',
);
ok(defined $bar_tf, 'test_files row for t/unit/bar.t exists');

my $bar_js = $dbh->selectrow_hashref(
    q{SELECT js.* FROM job_specs js
        JOIN jobs j     ON js.job_id  = j.job_id
        JOIN runs r     ON j.run_id   = r.run_id
       WHERE r.archive_id = ?},
    undef, $aid3,
);
ok(defined $bar_js, 'job_specs row for t/unit/bar.t archive');
is($bar_js->{test_file_id}, $bar_tf->{test_file_id},
    'bar.t job_specs.test_file_id matches bar.t test_files row');

# --- Part 5: job without a spec.jsonl (or one lacking 'relative') is rejected ---
# jobs.test_file_id is NOT NULL; insert() must croak if it cannot resolve a
# test_file_id for a job before inserting the jobs row.

my $src_nospec = tempdir(CLEANUP => 1);
make_path("$src_nospec/services/harness");
make_path("$src_nospec/runs/0");
make_path("$src_nospec/runs/0/jobs/0/0");

for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
    my $w = open_zstd_writer("$src_nospec/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}

# Insert should die because the job has no spec.jsonl with a 'relative' key.
my $err;
with_project('myproj', sub {
    eval { $db->insert(App::Yath2::Log->new(dir => $src_nospec)) };
    $err = $@;
});
ok(defined $err && length $err,
    'insert() croaks when job has no spec.jsonl with relative key');
like($err, qr/test_file_id/,
    'error message mentions test_file_id');

done_testing;
