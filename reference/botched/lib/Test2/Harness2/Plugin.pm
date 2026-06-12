package Test2::Harness2::Plugin;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::HashBase;

sub can_use_globally { 0 }
sub can_use_per_run  { 0 }
sub setup            { }
sub teardown         { }
sub tick             { }
sub on_job_queued    { }
sub on_job_complete  { }
sub on_run_queued    { }
sub on_run_complete  { }

1;
