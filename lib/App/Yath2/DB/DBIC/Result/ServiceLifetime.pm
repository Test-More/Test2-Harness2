package App::Yath2::DB::DBIC::Result::ServiceLifetime;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('service_lifetimes');

__PACKAGE__->add_columns(
    service_lifetime_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    service_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    lifetime_ord => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    status => {
        data_type   => 'text',
        is_nullable => 1,
    },
    type => {
        data_type   => 'text',
        is_nullable => 1,
    },
    id => {
        data_type   => 'text',
        is_nullable => 1,
    },
    service_name => {
        data_type   => 'text',
        is_nullable => 1,
    },
    stage_name => {
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
    exit => {
        data_type   => 'integer',
        is_nullable => 1,
        accessor    => 'lifetime_exit',
    },
    exit_decoded => {
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

__PACKAGE__->set_primary_key('service_lifetime_id');
__PACKAGE__->add_unique_constraint(
    service_lifetimes_ord_uk => ['service_id', 'lifetime_ord']
);

__PACKAGE__->belongs_to(service => 'App::Yath2::DB::DBIC::Result::Service', 'service_id');

1;
