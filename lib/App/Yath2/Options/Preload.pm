package App::Yath2::Options::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Getopt::Yath;

option_group {group => 'preload', category => "Preload Options"} => sub {
    option modules => (
        type           => 'List',
        short          => 'P',
        alt            => ['preload'],
        field          => 'modules',

        description => 'Pre-load one or more Perl modules in a long-lived preload service; tests then run as forks of that service with %INC already populated. Repeat -P (or comma-separate) for multiple modules. The "default" preload (a single Resource::Preload spawning one PreloadService) carries every bare module supplied on the command line.',

        long_examples  => [' Moose', ' My::Heavy::Module', ' Foo,Bar,Baz'],
        short_examples => [' Moose', ' My::Heavy::Module', ' Foo,Bar,Baz'],

        normalize => sub {
            my ($v) = @_;
            return ref($v) ? @$v : split(/,/, $v);
        },
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Preload - C<-P> / C<--preload> CLI options.

=head1 DESCRIPTION

Defines the C<--preload> / C<-P> option group. Modules listed via
this option are loaded by a long-lived preload service so that tests
launched by the harness run as forks of the preload process and
inherit the pre-populated C<%INC>.

The classification + resource-construction helpers used by C<test>,
C<start>, and C<run> live in L<App::Yath2::Preload>.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

See L<https://dev.perl.org/licenses/>

=cut
