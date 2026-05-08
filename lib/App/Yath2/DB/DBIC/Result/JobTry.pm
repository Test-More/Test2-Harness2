package App::Yath2::DB::DBIC::Result::JobTry;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('job_tries');

__PACKAGE__->add_columns(
    job_try_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    job_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    try_ord => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    status => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pass => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    exit => {
        data_type   => 'integer',
        is_nullable => 1,
        accessor    => 'try_exit',
    },
    exit_decoded => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    queued_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    started_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    ended_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    pass_count => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    fail_count => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    assertion_count => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    plan => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    halt => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    times => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    child_times => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    child_wall => {
        data_type   => 'real',
        is_nullable => 1,
    },
    spec_extras => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    state_extras => {
        data_type   => 'blob',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('job_try_id');
__PACKAGE__->add_unique_constraint(job_tries_ord_uk => ['job_id', 'try_ord']);

__PACKAGE__->belongs_to(job => 'App::Yath2::DB::DBIC::Result::Job', 'job_id');

__PACKAGE__->has_many(subtests  => 'App::Yath2::DB::DBIC::Result::Subtest',  'job_try_id');
__PACKAGE__->has_many(artifacts => 'App::Yath2::DB::DBIC::Result::Artifact', 'job_try_id');

1;
