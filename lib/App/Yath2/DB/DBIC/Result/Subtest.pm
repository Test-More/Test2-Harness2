package App::Yath2::DB::DBIC::Result::Subtest;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('subtests');

__PACKAGE__->add_columns(
    subtest_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    job_try_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    pass => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    count_pass => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    count_fail => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    ord => {
        data_type   => 'integer',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('subtest_id');

__PACKAGE__->belongs_to(job_try => 'App::Yath2::DB::DBIC::Result::JobTry', 'job_try_id');

1;
