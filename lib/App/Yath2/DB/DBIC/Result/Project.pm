package App::Yath2::DB::DBIC::Result::Project;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'DBIx::Class::Core';

__PACKAGE__->table('projects');

__PACKAGE__->add_columns(
    project_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('project_id');
__PACKAGE__->add_unique_constraint(projects_name_uk => ['name']);

__PACKAGE__->has_many(runs       => 'App::Yath2::DB::DBIC::Result::Run',      'project_id');
__PACKAGE__->has_many(test_files => 'App::Yath2::DB::DBIC::Result::TestFile', 'project_id');

1;
