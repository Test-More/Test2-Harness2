package App::Yath2::DB::DBIC::Result::TestFile;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('test_files');

__PACKAGE__->add_columns(
    test_file_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    project_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    relative => {
        data_type   => 'text',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('test_file_id');
__PACKAGE__->add_unique_constraint(
    test_files_project_relative_uk => ['project_id', 'relative']
);

__PACKAGE__->belongs_to(project => 'App::Yath2::DB::DBIC::Result::Project', 'project_id');

__PACKAGE__->has_many(jobs      => 'App::Yath2::DB::DBIC::Result::Job',     'test_file_id');
__PACKAGE__->has_many(job_specs => 'App::Yath2::DB::DBIC::Result::JobSpec', 'test_file_id');

1;
