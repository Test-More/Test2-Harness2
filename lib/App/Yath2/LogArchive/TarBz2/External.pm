package App::Yath2::LogArchive::TarBz2::External;
use strict;
use warnings;

use parent 'App::Yath2::LogArchive::Tar::External';

sub _list_flag { '-tjf' }
sub _read_flag { '-xjOf' }

1;
