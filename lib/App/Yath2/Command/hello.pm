package App::Yath2::Command::hello;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath2::Command';

sub args_include_tests { 0 }

sub group { 'misc' }

sub summary { "Print a hello message" }

sub description {
    return <<"    EOT";
Prints "hello test" and exits. Useful for smoke-testing the yath command dispatcher.
    EOT
}

sub run {
    print "hello test\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
