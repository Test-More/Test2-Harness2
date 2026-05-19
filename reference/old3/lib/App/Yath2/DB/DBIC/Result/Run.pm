package App::Yath2::DB::DBIC::Result::Run;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('runs');

__PACKAGE__->add_columns(
    run_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    archive_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    project_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    run_ord => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    run_uuid => {
        data_type   => 'varchar',
        size        => 36,
        is_nullable => 0,
    },
    status => {
        data_type   => 'text',
        is_nullable => 0,
    },
    pass => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    exit => {
        data_type     => 'integer',
        is_nullable   => 1,
        accessor      => 'run_exit',
    },
    exit_decoded => {
        data_type   => 'blob',
        is_nullable => 1,
    },
    aborted => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    timed_out => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    started_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    ended_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    total_jobs => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    passed_jobs => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    failed_jobs => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    aborted_jobs => {
        data_type   => 'integer',
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

__PACKAGE__->set_primary_key('run_id');
__PACKAGE__->add_unique_constraint(runs_archive_uuid_uk => ['archive_id', 'run_uuid']);
__PACKAGE__->add_unique_constraint(runs_archive_ord_uk  => ['archive_id', 'run_ord']);

__PACKAGE__->belongs_to(archive => 'App::Yath2::DB::DBIC::Result::Archive', 'archive_id');
__PACKAGE__->belongs_to(project => 'App::Yath2::DB::DBIC::Result::Project', 'project_id');

__PACKAGE__->has_many(services  => 'App::Yath2::DB::DBIC::Result::Service',  'run_id');
__PACKAGE__->has_many(jobs      => 'App::Yath2::DB::DBIC::Result::Job',      'run_id');
__PACKAGE__->has_many(artifacts => 'App::Yath2::DB::DBIC::Result::Artifact', 'run_id');

1;
