package App::Yath2::Command::db::importer;
use strict;
use warnings;

our $VERSION = '2.000000';

sub name        { "db-importer" }
sub summary     { "Start an importer process that will wait for uploaded logs to import" }
sub description { "Start an importer process that will wait for uploaded logs to import" }
sub group       { "database" }

use App::Yath2::Schema::Util qw/schema_config_from_settings/;
use App::Yath2::Schema::Importer;

use parent 'App::Yath2::Command';
use Getopt::Yath;

include_options(
    'App::Yath2::Options::DB',
);

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $config = schema_config_from_settings($settings);

    $SIG{INT}  = sub { exit 0 };
    $SIG{TERM} = sub { exit 0 };

    App::Yath2::Schema::Importer->new(config => $config)->run;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
