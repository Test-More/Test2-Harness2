package App::Yath2::Options::Yath;
use v5.38;

our $VERSION = '2.000000';

use Getopt::Yath;

# NOTE: In the full pre_ai distribution App::Yath::Options::Yath was a large
# option group that overlapped heavily with what is now provided by
# App::Yath2::Options::PreCommand and App::Yath2::Options::Debug (version,
# help, show-opts, dev-libs, etc). Porting it wholesale would duplicate those
# options. The DB/server/client commands only consume the 'project' and 'user'
# values from the 'yath' group.
#
# '--project' already belongs to App::Yath2::Options::PreCommand (group
# 'harness'); defining it here too would be a duplicate option form. So we mirror
# the harness value into a 'yath' group field via post-process instead of owning
# the CLI flag. Only 'user' (which has no other home) is a real option here.
option_group {group => 'yath', category => 'Yath Options'} => sub {
    option user => (
        type          => 'Scalar',
        description   => 'Username to associate with logs, database entries, and yath servers.',
        from_env_vars => [qw/YATH_USER USER/],
    );
};

option_post_process 0 => \&_mirror_project;

sub _mirror_project ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->check_group('yath');
    my $yath = $settings->yath;
    return if $yath->check_option('project');

    # Always create the field (even undef) so $settings->yath->project is a safe
    # read for consumers; value mirrors the canonical harness project.
    my $project = $settings->check_group('harness') ? $settings->harness->project : undef;
    $yath->create_option(project => $project);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Yath - Project/user options for Yath UI commands.

=head1 DESCRIPTION

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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
