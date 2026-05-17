package App::Yath2::Options::Runner;
use strict;
use warnings;

our $VERSION = '2.000013';

use Test2::Util qw/IS_WIN32/;

use Test2::Harness2::Util qw/mod2file fqmod clean_path/;

use Getopt::Yath;

include_options(
    'App::Yath2::Options::Tests',
);

option_group {group => 'runner', category => "Runner Options"} => sub {
    # This comment is not needed
    # NOTE: the legacy --preload / -P / --preload-early / --preload-retry-delay
    # options were removed when the staged-preload subsystem was
    # replaced. The new -P / --preload entry point lives in
    # App::Yath2::Options::Preload and feeds a Resource::Preload into
    # the harness's resource list.

    option class => (
        name    => 'runner',
        field   => 'class',
        type    => 'Scalar',

        default => sub { 'Test2::Harness2::Runner' },

        mod_adds_options => 1,
        long_examples    => [' MyRunner', ' +Test2::Harness2::Runner::MyRunner'],
        description      => 'Specify what Runner subclass to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness2::Runner::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'Test2::Harness2::Runner') },
    );

    option dump_depmap => (
        type        => 'Bool',
        default     => 0,
        description => "When using staged preload, dump the depmap for each stage as json files",
    );

    # Comments not needed
    # Legacy reload_* options removed: the modern reloader subsystem
    # ships via App::Yath2::Options::Reloader (--reloader=mstat|inotify|none)
    # and routes through Resource::Preload + PreloadService directly.
};


__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Runner - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

