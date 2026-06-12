package TestBadPreload;
use strict;
use warnings;

use Test2::Harness2::Preload;

stage BAD => sub {
  default;
  preload "Test2::Harness2::Preload::Does::Not::Exist";
};

1;
