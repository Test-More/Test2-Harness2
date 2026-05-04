package Test2::Harness2::Test::Loggers;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    classic_harness_loggers
    classic_test_loggers
    classic_logger_specs
};

# Logger / observer plumbing was removed in the new_log_refactor
# (M2 step 4+5). The collector now writes spec / events / report
# directly; there are no longer any logger specs to assemble.
#
# These helpers are kept as no-op stubs returning empty lists so
# existing integration tests keep importing without failing the
# require, and any callers that still pass `loggers` / `test_loggers`
# end up with empty lists the harness silently accepts.

sub classic_harness_loggers { [] }
sub classic_test_loggers    { [] }
sub classic_logger_specs    { () }

1;
