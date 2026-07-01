package App::Yath2::Command::list;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath2::Discovery();

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary  { "List all live persistent test runners" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
List every live persistent runner this user can discover, by enumerating all
candidate discovery symlinks (under --persist-dir / \$YATH_PERSISTENCE_DIR / the
system temp dir, plus the cwd-walk fallback) and probing each for liveness.

Note: only PERSISTENT runners are discoverable. A one-off `yath test` run has a
workdir socket but no well-known discovery symlink, so it is not listed here.

Runners owned by other users are shown as "inaccessible" when their socket cannot
be reached; their stale links are never cleaned (only this user's own dangling
links are cleaned up).
    EOT
}

sub run {
    my $self = shift;

    my @records = App::Yath2::Discovery->list($self->settings);

    unless (@records) {
        print "\nNo persistent runners were found.\n\n";
        return 0;
    }

    my @live         = grep { $_->{state} eq 'live' } @records;
    my @inaccessible = grep { $_->{state} eq 'inaccessible' } @records;

    if (@live) {
        print "\nPersistent runners:\n";
        for my $rec (sort { $a->{link} cmp $b->{link} } @live) {
            my $pid = defined($rec->{pid}) && length($rec->{pid}) ? $rec->{pid} : 'unknown';
            print "\n  Link: $rec->{link}\n";
            print "   PID: $pid\n";
            print "   Dir: $rec->{workdir}\n" if defined $rec->{workdir};
        }
        print "\n";
    }

    if (@inaccessible) {
        print "\nInaccessible runners (owned by another user):\n";
        for my $rec (sort { $a->{link} cmp $b->{link} } @inaccessible) {
            print "\n  Link: $rec->{link}\n";
            print "   (socket present but not reachable -- permission denied)\n";
        }
        print "\n";
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::list - List all live persistent test runners

=head1 DESCRIPTION

List every live persistent runner this user can discover, by enumerating all
candidate discovery symlinks and probing each for liveness.

Only B<persistent> runners are discoverable: a one-off C<yath test> run has a
workdir socket but no well-known discovery symlink, so it is not listed.

=head1 USAGE

    $ yath [YATH OPTIONS] list

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
