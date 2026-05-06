use Test2::V0;
use File::Spec ();

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2::Run::Job;

subtest 'constructs with a TestFile' => sub {
    my $tf  = Test2::Harness2::TestFile->new(file => 't/foo.t');
    my $job = Test2::Harness2::Run::Job->new(
        job_id    => 7,
        test_file => $tf,
        run_id    => 1,
    );
    is($job->job_id,    7,    'job_id');
    is($job->test_file, $tf,  'test_file is the TestFile object');
    is($job->run_id,    1,    'run_id');
    is($job->job_try,   1,    'job_try defaults to 1');
};

subtest 'rejects bare path strings (rehydration happens at Run::from_files)' => sub {
    my $ok  = eval { Test2::Harness2::Run::Job->new(test_file => 't/foo.t', run_id => 1, job_id => 1); 1 };
    my $err = $@;
    ok(!$ok, 'path string no longer accepted');
    like($err, qr/Role::TestFile/, 'error mentions the role');
};

subtest 'job_id is required' => sub {
    my $tf  = Test2::Harness2::TestFile->new(file => 't/foo.t');
    my $ok  = eval { Test2::Harness2::Run::Job->new(test_file => $tf, run_id => 1); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without job_id');
    like($err, qr/job_id/, 'error mentions job_id');
};

subtest 'test_file is required' => sub {
    my $ok  = eval { Test2::Harness2::Run::Job->new(run_id => 1, job_id => 1); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without test_file');
    like($err, qr/test_file/, 'error mentions test_file');
};

subtest 'run_id is required' => sub {
    my $tf = Test2::Harness2::TestFile->new(file => 't/foo.t');
    my $ok  = eval { Test2::Harness2::Run::Job->new(test_file => $tf, job_id => 1); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without run_id');
    like($err, qr/run_id/, 'error mentions run_id');
};

subtest 'test_file_abs / test_file_rel shortcuts' => sub {
    my $tf  = Test2::Harness2::TestFile->new(file => 't/foo.t');
    my $job = Test2::Harness2::Run::Job->new(test_file => $tf, run_id => 1, job_id => 1);
    is($job->test_file_rel, 't/foo.t', 'test_file_rel is the relative path');
    like($job->test_file_abs, qr{\Qfoo.t\E\z}, 'test_file_abs ends with foo.t');
};

subtest 'rejects non-TestFile refs' => sub {
    my $ok = eval {
        Test2::Harness2::Run::Job->new(
            test_file => bless({}, 'Other::Thing'),
            run_id    => 1,
            job_id    => 0,
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaks on unrelated blessed ref');
    like($err, qr/Role::TestFile/);
};

subtest 'TO_JSON returns a plain hash; nested test_file is left to convert_blessed' => sub {
    my $tf  = Test2::Harness2::TestFile->new(file => 't/foo.t');
    my $job = Test2::Harness2::Run::Job->new(
        job_id    => 1,
        test_file => $tf,
        run_id    => 1,
    );
    my $h = $job->TO_JSON;
    is(ref($h), 'HASH', 'returns a hashref');
    is($h->{job_id}, 1, 'job_id present');
    is($h->{run_id}, 1, 'run_id present');
    ok(
        $h->{test_file}->can('TO_JSON'),
        'test_file remains blessed (convert_blessed handles it at encode time)',
    );
    is($h->{test_file}, $tf, 'test_file is the same blessed object');
    is($h->{job_try}, 1, 'job_try present');
};

done_testing;
