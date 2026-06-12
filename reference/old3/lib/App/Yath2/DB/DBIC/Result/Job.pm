package App::Yath2::DB::DBIC::Result::Job;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('jobs');

__PACKAGE__->add_columns(
    job_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    archive_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    run_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    test_file_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    job_ord => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    pass => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    status => {
        data_type   => 'text',
        is_nullable => 1,
    },
    retry_count => {
        data_type   => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('job_id');
__PACKAGE__->add_unique_constraint(
    jobs_archive_run_ord_uk => ['archive_id', 'run_id', 'job_ord']
);

__PACKAGE__->belongs_to(archive   => 'App::Yath2::DB::DBIC::Result::Archive',  'archive_id');
__PACKAGE__->belongs_to(run       => 'App::Yath2::DB::DBIC::Result::Run',      'run_id');
__PACKAGE__->belongs_to(test_file => 'App::Yath2::DB::DBIC::Result::TestFile', 'test_file_id');

__PACKAGE__->has_many(tries     => 'App::Yath2::DB::DBIC::Result::JobTry',  'job_id');
__PACKAGE__->has_many(job_specs => 'App::Yath2::DB::DBIC::Result::JobSpec', 'job_id');

1;
