package App::Yath2::DB::DBIC::Result::Archive;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('archives');

__PACKAGE__->add_columns(
    archive_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    archive_uuid => {
        data_type   => 'varchar',
        size        => 36,
        is_nullable => 0,
    },
    archive_version => {
        data_type   => 'text',
        is_nullable => 0,
    },
    sealed_at => {
        data_type   => 'text',
        is_nullable => 1,
    },
    host => {
        data_type   => 'text',
        is_nullable => 1,
    },
    user => {
        data_type     => 'text',
        is_nullable   => 1,
        accessor      => 'archive_user',
    },
    git_sha => {
        data_type   => 'text',
        is_nullable => 1,
    },
    project => {
        data_type   => 'text',
        is_nullable => 1,
    },
    yath_version => {
        data_type   => 'text',
        is_nullable => 1,
    },
    meta_extras => {
        data_type   => 'blob',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('archive_id');
__PACKAGE__->add_unique_constraint(archives_uuid_uk => ['archive_uuid']);

__PACKAGE__->has_many(runs      => 'App::Yath2::DB::DBIC::Result::Run',      'archive_id');
__PACKAGE__->has_many(services  => 'App::Yath2::DB::DBIC::Result::Service',  'archive_id');
__PACKAGE__->has_many(jobs      => 'App::Yath2::DB::DBIC::Result::Job',      'archive_id');
__PACKAGE__->has_many(artifacts => 'App::Yath2::DB::DBIC::Result::Artifact', 'archive_id');

1;
