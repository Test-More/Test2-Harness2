package Test2::Harness2::Util::PreloadDirective;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Exporter qw/import/;

our @EXPORT_OK = qw/parse_preload_directive/;

# Parse a HARNESS-PRELOAD directive value into the normalized
# ordered preference list used by _resolve_preload_for_job.
#
# Rules (see AI_DOCS/2026-05-10-preload-rework-design.md S6.1):
#  - Whitespace-separated; bare names are preload names.
#  - <default> means "scope's default preload, with implicit <no>
#    fallback baked in". Must be last when present.
#  - <no> means "no preload acceptable". Must be last when present.
#  - <default> followed by <no> is normalized to just <default>.
#  - undef / empty / whitespace-only normalizes to ['<default>'].
sub parse_preload_directive {
    my ($raw) = @_;
    return ['<default>'] unless defined $raw;

    my @tokens = split /\s+/, $raw;
    @tokens = grep { length } @tokens;
    return ['<default>'] unless @tokens;

    my $seen_default = 0;
    my $seen_no      = 0;
    for my $i (0 .. $#tokens) {
        my $t = $tokens[$i];

        if ($t =~ /\A<(.+)>\z/) {
            my $kind = $1;
            croak "unknown preload directive token '$t'"
                unless $kind eq 'default' || $kind eq 'no';

            if ($kind eq 'default') {
                croak "duplicate '<default>' in HARNESS-PRELOAD directive"
                    if $seen_default;
                croak "'<default>' must be the last entry in HARNESS-PRELOAD"
                    unless $i == $#tokens || ($i == $#tokens - 1 && $tokens[-1] eq '<no>');
                $seen_default = 1;
            }
            else {    # <no>
                croak "'<no>' must be the last entry in HARNESS-PRELOAD"
                    unless $i == $#tokens;
                $seen_no = 1;
            }
            next;
        }

        croak "named preload '$t' cannot follow '<default>' or '<no>' in HARNESS-PRELOAD"
            if $seen_default || $seen_no;
    }

    # Normalize: <default> <no> -> <default> (the <no> is redundant
    # because <default> implies the same fallback).
    pop @tokens if $seen_default && $seen_no && $tokens[-1] eq '<no>';

    return [@tokens];
}

1;

__END__

=pod

=head1 NAME

Test2::Harness2::Util::PreloadDirective - Parse the
C<HARNESS-PRELOAD: ...> test-file directive into a normalized
ordered preference list.

=head1 SYNOPSIS

    use Test2::Harness2::Util::PreloadDirective qw/parse_preload_directive/;

    my $list = parse_preload_directive('Foo Bar <default>');
    # => ['Foo', 'Bar', '<default>']

    my $list = parse_preload_directive('<default> <no>');
    # => ['<default>']    (the trailing <no> is redundant)

    my $list = parse_preload_directive(undef);
    # => ['<default>']

=head1 DESCRIPTION

Sole entry point: C<parse_preload_directive($raw_string)>. Returns
an arrayref of tokens (bare preload names plus the special tokens
C<< <default> >> and C<< <no> >>) in the order they should be tried
by the scheduler's preload resolver.

Croaks on validation failure: tokens out of order (a name after
C<< <default> >> or C<< <no> >>), unknown C<< <token> >>, duplicate
C<< <default> >>.

=head1 SEMANTICS

See L<AI_DOCS/2026-05-10-preload-rework-design.md> sections 6.1 and
6.3 for the resolver semantics. The parser only enforces the
syntactic rules; the resolver itself decides what each token resolves
to at scheduling time.

=cut
