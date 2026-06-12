package App::Yath2UI::Schema::DBIC::MariaDB;
use utf8;
use strict;
use warnings;
use Carp();

our $VERSION = '2.000011';

eval { require DBD::mysql; 1 } or die "'DBD::mysql' must be installed, could not load: $@";
eval { require DateTime::Format::MySQL; 1 } or die "'DateTime::Format::MySQL' must be installed, could not load: $@";

Carp::confess("Already loaded schema '$App::Yath2UI::Schema::DBIC::LOADED'") if $App::Yath2UI::Schema::DBIC::LOADED;

$App::Yath2UI::Schema::DBIC::LOADED = "MariaDB";

require App::Yath2UI::Schema::DBIC;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2UI::Schema::DBIC::MariaDB - MariaDB connection module for the unified DBIC schema.

=cut
