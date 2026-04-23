package Test2::Harness2::TapParser;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::HashBase;

# Main entry point — parse a stdout TAP line.
# Returns a facet_data hashref or undef for non-TAP lines.
sub parse_tap_line {
    my ($self, $line) = @_;
    my $facet_data = $self->_parse_tap_line($line) or return undef;
    $facet_data->{from_tap} = {source => 'STDOUT', details => $line};
    return $facet_data;
}

# Parse a stderr line — only comments are recognised; they become DIAG.
sub parse_stderr_tap {
    my ($self, $line) = @_;

    return undef unless $line =~ m/^\s*#/;

    my $facet_data = $self->_parse_tap_comment($line, no_nest => 1) or return undef;
    $facet_data->{info}[-1]{tag}   = 'DIAG';
    $facet_data->{info}[-1]{debug} = 1;
    $facet_data->{from_tap}        = {source => 'STDERR', details => $line};
    return $facet_data;
}

# Internal dispatcher — strips indentation, dispatches to type parsers.
sub _parse_tap_line {
    my ($self, $line) = @_;
    chomp(my $str = $line);

    my ($nest) = (0);

    if ($str =~ m/^(\s+)\S/) {
        my $lead = $1;
        $str =~ s/^\Q$lead\E//mg;

        (my $normalised = $lead) =~ s/\t/    /g;
        my $lead_len = length($normalised);

        # indentation must be a multiple of 4
        return undef if $lead_len % 4;

        $nest = $lead_len / 4;
    }

    my @types = qw/subtest comment plan bail version/;
    for my $type (@types) {
        my $method     = "_parse_tap_$type";
        my $facet_data = $self->$method($str) or next;
        $facet_data->{trace}{nested} = $nest;
        $facet_data->{hubs}[0]{nested} = $nest;
        return $facet_data;
    }

    return undef;
}

# ok / not ok — with optional buffered-subtest detection
sub _parse_tap_subtest {
    my ($self, $line) = @_;

    # End of a buffered subtest
    return {parent => {}, harness => {subtest_end => 1}}
        if $line =~ m/^\}\s*$/;

    my $facet_data = $self->_parse_tap_ok($line) or return undef;

    # If description ends with '{' it's a subtest start
    if ($facet_data->{assert}{details} =~ s/\s*\{\s*$//g) {
        $facet_data->{parent} = {details => $facet_data->{assert}{details}};
        $facet_data->{harness}{subtest_start} = 1;
    }

    return $facet_data;
}

sub _parse_tap_ok {
    my ($self, $line) = @_;

    return undef unless $line =~ s/^(not )?ok\b//;
    my $pass = !$1;

    my @errors;

    push @errors, "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    my $num;
    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;
        push @errors, "Extra space after 'ok'"
            if length($space) > 1;
    }

    # Handle directives: TODO, SKIP, TODO & SKIP
    my ($todo, $skip);
    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors, "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors, "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    # Strip leading dash and surrounding whitespace from description
    $line =~ s/\s*-\s*//;
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $is_subtest = ($line =~ m/^Subtest:\s*(.*)$/) ? ($1 || 1) : undef;

    my $facet_data = {
        assert => {
            pass     => $pass ? 1 : 0,
            no_debug => 1,
            details  => $line,
            defined $num ? (number => $num) : (),
        },
    };

    $facet_data->{parent} = {details => $is_subtest}
        if defined $is_subtest;

    push @{$facet_data->{amnesty}}, {tag => 'SKIP', details => $skip}
        if defined $skip;

    push @{$facet_data->{amnesty}}, {tag => 'TODO', details => $todo}
        if defined $todo;

    push @{$facet_data->{info}}, {details => $_, debug => 1, tag => 'PARSER'} for @errors;

    return $facet_data;
}

sub _parse_tap_plan {
    my ($self, $line) = @_;

    return undef unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason) = ('', '');

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason    = $line;
                $line      = '';
            }
        }
        $directive ||= 'SKIP';
        $reason    ||= 'no reason given';
    }

    my $facet_data = {
        plan => {
            count   => $max,
            skip    => ($directive eq 'SKIP') ? 1 : 0,
            details => $reason,
        }
    };

    push @{$facet_data->{info}}, {details => 'Extra characters after plan.', debug => 1, tag => 'PARSER'}
        if $line =~ m/\S/;

    return $facet_data;
}

sub _parse_tap_bail {
    my ($self, $line) = @_;

    return undef unless $line =~ m/^Bail out!\s*(.*)$/;

    return {
        control => {
            halt    => 1,
            details => $1,
        }
    };
}

sub _parse_tap_comment {
    my ($self, $line, %params) = @_;

    return undef unless $line =~ m/^\s*#/;

    $line =~ s/^\s*# ?//msg unless $params{no_nest};

    return {
        info => [{
            details => $line,
            tag     => 'NOTE',
            debug   => 0,
        }]
    };
}

sub _parse_tap_version {
    my ($self, $line) = @_;

    return undef unless $line =~ m/^TAP version\s/;

    return {
        about => {details => $line},
        info  => [{
            tag     => 'INFO',
            debug   => 0,
            details => $line,
        }],
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TapParser - Parse TAP output lines into facet data

=head1 DESCRIPTION

Parses individual lines of TAP output into L<Test2::Event> facet data
hashrefs, including support for buffered subtests and indented (nested) TAP.

=head1 SYNOPSIS

    use Test2::Harness2::TapParser;

    my $parser = Test2::Harness2::TapParser->new();

    my $facet_data = $parser->parse_tap_line("ok 1 - basic test");
    # {
    #   assert   => { pass => 1, number => '1', details => 'basic test', no_debug => 1 },
    #   trace    => { nested => 0 },
    #   hubs     => [{ nested => 0 }],
    #   from_tap => { source => 'STDOUT', details => 'ok 1 - basic test' },
    # }

=head1 METHODS

=over 4

=item $parser = Test2::Harness2::TapParser->new()

Constructor.

=item $facet_data = $parser->parse_tap_line($line)

Main entry point for STDOUT TAP lines. Returns a facet_data hashref or undef
for lines that are not valid TAP.

=item $facet_data = $parser->parse_stderr_tap($line)

Parse a stderr line. Only comment lines (C<#...>) are recognised and they are
returned as C<DIAG> info entries.

=back

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
