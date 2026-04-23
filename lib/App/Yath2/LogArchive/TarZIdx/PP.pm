package App::Yath2::LogArchive::TarZIdx::PP;
use strict;
use warnings;

use parent 'App::Yath2::LogArchive::TarZIdx::External';

use App::Yath2::LogArchive::TarZIdx::Util qw/have_compress_zstd/;

sub viable { have_compress_zstd() }

1;
