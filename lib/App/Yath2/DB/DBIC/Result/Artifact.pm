package App::Yath2::DB::DBIC::Result::Artifact;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('artifacts');

__PACKAGE__->add_columns(
    artifact_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    archive_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    artifact_uuid => {
        data_type   => 'varchar',
        size        => 36,
        is_nullable => 0,
    },
    run_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    service_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    job_try_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    artifact_kind => {
        data_type   => 'text',
        is_nullable => 0,
    },
    format => {
        data_type   => 'text',
        is_nullable => 0,
    },
    name => {
        data_type   => 'text',
        is_nullable => 1,
    },
    compressed => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    payload => {
        data_type   => 'blob',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'text',
        is_nullable => 0,
    },
    sealed => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('artifact_id');
__PACKAGE__->add_unique_constraint(
    artifacts_archive_uuid_uk => ['archive_id', 'artifact_uuid']
);

__PACKAGE__->belongs_to(archive => 'App::Yath2::DB::DBIC::Result::Archive', 'archive_id');
__PACKAGE__->belongs_to(
    run => 'App::Yath2::DB::DBIC::Result::Run',
    'run_id',
    { join_type => 'LEFT' },
);
__PACKAGE__->belongs_to(
    service => 'App::Yath2::DB::DBIC::Result::Service',
    'service_id',
    { join_type => 'LEFT' },
);
__PACKAGE__->belongs_to(
    job_try => 'App::Yath2::DB::DBIC::Result::JobTry',
    'job_try_id',
    { join_type => 'LEFT' },
);

1;
