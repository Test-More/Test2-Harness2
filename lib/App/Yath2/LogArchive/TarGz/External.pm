package App::Yath2::LogArchive::TarGz::External;
use strict;
use warnings;

use parent 'App::Yath2::LogArchive::Tar::External';

sub _list_flag { '-tzf' }
sub _read_flag { '-xzOf' }

1;
