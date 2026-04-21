package App::Yath::Script::V2;
use strict;
use warnings;

use App::Yath2;

my $INSTANCE;

sub do_begin   { shift; $INSTANCE = App::Yath2->new(@_) }
sub do_runtime { shift; $INSTANCE->run() }

1;
