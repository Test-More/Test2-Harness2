package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Spec ();

use Object::HashBase qw{
    &Test2::Harness2::Role::TestFile
};

sub init {
    my $self = shift;

    # Accept a `file` argument for convenience; derive absolute + relative
    # from it and then discard the value (the slot no longer exists).
    if (my $file = delete $self->{file}) {
        $self->{+ABSOLUTE} //= File::Spec->rel2abs($file);
        $self->{+RELATIVE} //= File::Spec->abs2rel($file);
    }

    croak "'absolute' (or 'file') is required"
        unless defined $self->{+ABSOLUTE} && length $self->{+ABSOLUTE};

    # Ensure both derived forms are present even when only one was supplied.
    $self->{+ABSOLUTE} //= File::Spec->rel2abs($self->{+RELATIVE});
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+ABSOLUTE});

    # HashBase slot accessors shadow the role's default methods. Seed
    # every slot the role documents a default for so the accessor
    # returns that default instead of undef. The role's defaults()
    # builds fresh sub-containers per call so different objects do not
    # share arrayrefs / hashrefs.
    my $defaults = $self->defaults;
    for my $k (keys %$defaults) {
        $self->{$k} //= $defaults->{$k};
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TestFile - Static value object describing a single
test file for the harness.

=head1 DESCRIPTION

C<Test2::Harness2::TestFile> is the harness-side, B<static> value
object for one test file. Every attribute is set at construction;
nothing on this class scans the file, reads its shebang, parses
C<HARNESS2:> directives, validates C<-f> / C<-x>, mints job_ids,
or otherwise touches the filesystem. The harness rehydrates these
objects from log payloads when replaying or analysing runs, where the
file may not even exist on the local machine.

The producer side -- reading shebangs, parsing C<HARNESS2:>
directives, applying CLI overrides, building queue payloads -- lives
in L<App::Yath2::TestFile>. The harness library does B<not> load
yath; producers are responsible for handing the harness a fully-built
TestFile (or a hashref of the same shape via the role's C<TO_JSON> /
C<rehydrate> contract).

This class consumes L<Test2::Harness2::Role::TestFile> for its
interface and uses L<Object::HashBase> for storage. The role's
per-attribute defaults are seeded into the HashBase slots during
C<init> so a HashBase slot reader (which shadows the role's default
method) returns the documented default when the caller did not
supply a value.

=head1 SYNOPSIS

    use Test2::Harness2::TestFile;

    my $tf = Test2::Harness2::TestFile->new(
        file      => 't/foo.t',   # convenience: derives absolute + relative
        category  => 'general',
        duration  => 'short',
        conflicts => ['db'],
        features  => {fork => 0},
    );

    # Rehydrate from a logged TO_JSON payload
    my $rehydrated = Test2::Harness2::TestFile->rehydrate($payload);

=head1 ATTRIBUTES

See L<Test2::Harness2::Role::TestFile/ATTRIBUTES> for the full list.
This class implements every attribute the role documents.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
