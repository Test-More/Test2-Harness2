package Test2::Harness2::Resource;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::HashBase;

sub can_use_globally { 0 }
sub can_use_per_run  { 0 }
sub available        { 1 }       # 1=ready, 0=temp unavail, -1=permanently broken
sub spawn_service    { undef }
sub applicable       { 1 }
sub assign           { }
sub release          { }

1;
