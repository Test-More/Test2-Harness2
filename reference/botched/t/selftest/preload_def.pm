package t::selftest::preload_def;
use strict;
use warnings;
use Test2::Harness2::Preload;

stage 'default' => sub {
    default();
    preload 'Scalar::Util';
    preload 'List::Util';

    stage 'child' => sub {
        preload 'File::Spec';
    };
};

stage 'isolation' => sub {
    preload 'Carp';
};

1;
