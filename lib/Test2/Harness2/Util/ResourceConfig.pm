package Test2::Harness2::Util::ResourceConfig;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::JSON qw/decode_json/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/
    slurp_json_config
    whitelist_keys
    validate_name
/;

# Open + slurp + decode a JSON config file with the shared error
# conventions used by every Resource::* class. Returns the decoded
# top-level hashref. Croaks (using $label as a prefix) on:
#   - missing file
#   - not readable
#   - open failure
#   - JSON parse failure
#   - non-object top-level
sub slurp_json_config {
    my ($path, $label) = @_;

    croak "$label: 'path' is required" unless defined $path && length $path;
    croak "$label: 'label' is required" unless defined $label && length $label;

    croak "$label config file '$path' does not exist"  unless -e $path;
    croak "$label config file '$path' is not readable" unless -r _;

    open my $fh, '<:raw', $path
        or croak "$label: cannot open config file '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data;
    my $ok  = eval { $data = decode_json($body); 1 };
    my $err = $@;
    croak "$label: cannot parse JSON in '$path': $err" unless $ok;

    croak "$label: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    return $data;
}

# Reject any key in $data that is not in $allowed. $allowed may be an
# arrayref or hashref (slot set). Iterates in sorted-key order so the
# first failure is deterministic. Croaks with $label and $path embedded
# in the message.
sub whitelist_keys {
    my ($data, $allowed, $path, $label) = @_;

    croak "whitelist_keys: 'data' must be a HASH ref" unless ref($data) eq 'HASH';

    my %allowed;
    if (ref($allowed) eq 'ARRAY') {
        %allowed = map { $_ => 1 } @$allowed;
    }
    elsif (ref($allowed) eq 'HASH') {
        %allowed = %$allowed;
    }
    else {
        croak "whitelist_keys: 'allowed' must be ARRAY or HASH ref";
    }

    for my $k (sort keys %$data) {
        croak "$label: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    return;
}

# Validate a "name" string: defined, non-ref, non-empty, whitespace-free.
# $where is an optional context suffix like " in '$path'" for file-load
# errors; pass undef (or omit) for inline-arg context. Returns the
# validated name unchanged.
sub validate_name {
    my ($name, $label, $where) = @_;

    croak "validate_name: 'label' is required" unless defined $label && length $label;

    my $loc = defined($where) ? $where : '';

    croak "$label: name$loc must be a non-empty whitespace-free string"
        unless defined($name) && !ref($name) && length($name) && $name !~ /\s/;

    return $name;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::ResourceConfig - Shared parsing helpers for Resource::* config files and inline options.

=head1 DESCRIPTION

Resource classes such as L<Test2::Harness2::Resource::CPU>,
L<Test2::Harness2::Resource::Memory>, L<Test2::Harness2::Resource::UnixLimits>,
L<Test2::Harness2::Resource::PipeLimits>, L<Test2::Harness2::Resource::Throttle>,
and L<Test2::Harness2::Resource::Disk> all parse a similar mix of inline
positional/keyed arguments and an optional C<@/path/to/config.json>
file. The mechanical bits of that work -- opening the file, decoding
the JSON, rejecting unknown keys, validating a C<name> string -- are
identical across all of them. This module provides those primitives so
each resource only has to express its own dimension-specific
validation.

=head1 FUNCTIONS

All functions are exported on request.

=over 4

=item $data = slurp_json_config($path, $label)

Returns the decoded top-level JSON object. Croaks with C<$label> as a
prefix when the file is missing, unreadable, fails to parse, or its
top level is not a JSON object.

=item whitelist_keys(\%data, \@allowed, $path, $label)

Croaks if any key in C<\%data> is outside C<\@allowed>. C<\@allowed>
may also be a hashref slot-set. The first offending key (sorted) is
reported.

=item $name = validate_name($name, $label, $where)

Returns C<$name> unchanged when it is a defined, non-ref, non-empty,
whitespace-free string. C<$where> is an optional context suffix like
C<" in '$path'"> appended to the error message.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
