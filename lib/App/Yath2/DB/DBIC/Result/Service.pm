package App::Yath2::DB::DBIC::Result::Service;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('services');

__PACKAGE__->add_columns(
    service_id => {
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
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    role => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('service_id');

__PACKAGE__->belongs_to(archive => 'App::Yath2::DB::DBIC::Result::Archive', 'archive_id');
__PACKAGE__->belongs_to(
    run => 'App::Yath2::DB::DBIC::Result::Run',
    'run_id',
    { join_type => 'LEFT' },
);

__PACKAGE__->has_many(lifetimes => 'App::Yath2::DB::DBIC::Result::ServiceLifetime', 'service_id');
__PACKAGE__->has_many(artifacts => 'App::Yath2::DB::DBIC::Result::Artifact',        'service_id');

1;
