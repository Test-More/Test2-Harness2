package App::Yath2::DB::DBIC::Result::JobSpec;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('job_specs');

__PACKAGE__->add_columns(
    job_spec_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    job_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    test_file_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    absolute => {
        data_type   => 'text',
        is_nullable => 1,
    },
    category => {
        data_type   => 'text',
        is_nullable => 1,
    },
    duration => {
        data_type   => 'text',
        is_nullable => 1,
    },
    stage => {
        data_type   => 'text',
        is_nullable => 1,
    },
    features => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    switches => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    retry => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    retry_isolated => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    smoke => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    isolation => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    non_perl => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    is_binary => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    event_timeout => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    post_exit_timeout => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    min_slots => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    max_slots => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    ch_dir => {
        data_type   => 'text',
        is_nullable => 1,
    },
    extras => {
        data_type   => 'blob',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('job_spec_id');
__PACKAGE__->add_unique_constraint(job_specs_job_uk => ['job_id']);

__PACKAGE__->belongs_to(job       => 'App::Yath2::DB::DBIC::Result::Job',      'job_id');
__PACKAGE__->belongs_to(test_file => 'App::Yath2::DB::DBIC::Result::TestFile', 'test_file_id');

1;
