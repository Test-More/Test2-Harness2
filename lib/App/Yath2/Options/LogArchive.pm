package App::Yath2::Options::LogArchive;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use App::Yath2::Util qw/share_file/;

use Getopt::Yath;

option_group {group => 'log_archive', category => "Log Archive Options"} => sub {
    option zstd_dict => (
        type        => 'Scalar',
        description => 'Path to a zstd dictionary file used when compressing files in the log directory and the resulting archive. Defaults to the dictionary shipped with this distribution under share/other/zstd.dict.',

        # Resolved lazily so '--no-zstd-dict' wins without forcing
        # the share lookup to succeed.
        default => sub {
            my $path = eval { share_file('other/zstd.dict') };
            return $path if defined $path && -f $path;
            return undef;
        },

        long_examples => [' /path/to/custom.dict'],
    );

    option no_zstd_dict => (
        type        => 'Bool',
        description => 'Disable the zstd dictionary entirely. Files in the log directory and the resulting archive are still zstd-compressed, just without a pre-trained dictionary. Mutually exclusive with --zstd-dict.',
        default     => 0,
    );
};

# Resolve the effective dictionary path for the run, honouring the
# --no-zstd-dict toggle. Returns undef in dict-less mode.
#
# Callers should use this rather than reading the option directly so
# the precedence rules between --zstd-dict and --no-zstd-dict stay in
# one place.
sub resolve_dict_path {
    my ($class, $settings) = @_;

    my $opts = $settings->log_archive;

    if ($opts->no_zstd_dict) {
        croak "--no-zstd-dict is mutually exclusive with --zstd-dict"
            if $opts->zstd_dict;
        return undef;
    }

    return $opts->zstd_dict;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::LogArchive - Log archive / zstd dictionary options for yath commands.

=head1 DESCRIPTION

Defines the C<--zstd-dict> and C<--no-zstd-dict> options used by every
yath command that touches a log directory or an archive (C<run>,
C<test>, C<archive>, C<extract>, C<replay>, ...).

C<--zstd-dict PATH> overrides the default install-shipped dictionary
at C<share/other/zstd.dict>. C<--no-zstd-dict> disables dictionary use
entirely; files are still zstd-compressed but without a pre-trained
dictionary.

=head1 PUBLIC INTERFACE

=over 4

=item $path = App::Yath2::Options::LogArchive->resolve_dict_path($settings)

Returns the resolved dictionary path for the run, or C<undef> for a
dict-less run. Croaks if both C<--zstd-dict> and C<--no-zstd-dict>
are supplied.

=back

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
