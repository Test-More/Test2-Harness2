package App::Yath2UI::Schema::DBIC::PostgreSQL;
use utf8;
use strict;
use warnings;
use Carp();

our $VERSION = '2.000011';

eval { require DBD::Pg; 1 } or die "'DBD::Pg' must be installed, could not load: $@";
eval { require DateTime::Format::Pg; 1 } or die "'DateTime::Format::Pg' must be installed, could not load: $@";

Carp::confess("Already loaded schema '$App::Yath2UI::Schema::DBIC::LOADED'") if $App::Yath2UI::Schema::DBIC::LOADED;

$App::Yath2UI::Schema::DBIC::LOADED = "PostgreSQL";

require App::Yath2UI::Schema::DBIC;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2UI::Schema::DBIC::PostgreSQL - PostgreSQL connection module for the unified DBIC schema.

=cut
