package Test2::Harness2::Collector::Parser::TAPParser;
use v5.38;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Collector::Parser::IOParser';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Parser::TAPParser - IOParser subclass that
recognizes TAP.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Collector::Parser::IOParser> that adds TAP
line recognition. Used by collectors driving a test job that emits plain TAP
(rather than structured events through L<Test2::Formatter::Stream2>).

For STDOUT, the parser recognizes plan lines (C<1..N>, including the
skip-everything form), assertions (C<ok> / C<not ok> with optional TODO /
SKIP / TODO&SKIP directives), buffered subtests, comments, C<Bail out!>, and
the C<TAP version> preamble. Indentation in multiples of four columns becomes
subtest nesting depth.

For STDERR, only comment lines (matching C</^\s*#/>) are TAP-parsed; the
resulting C<info> entry is tagged C<DIAG> and marked C<debug = 1>. Non-comment
STDERR lines fall back to the base C<IOParser> behavior.

Lines that do not match any TAP construct fall through to the base
implementation, which wraps them in C<from_stream> + C<info> facets.

=head1 SYNOPSIS

    use Test2::Harness2::Collector;

    my $exit = Test2::Harness2::Collector->start(
        is_test      => 1,
        events_file  => "$dir/events.jsonl.zst",
        parser       => 'Test2::Harness2::Collector::Parser::TAPParser',
        exec_command => [$^X, 'legacy_tap_test.t'],
    );

=head1 PUBLIC METHODS

=cut

=over 4

=item $parser->parse_stream_line(\%io, $event)

Try TAP recognition first; on success, set C<< $event->{facet_data} >> to the
TAP-derived facet hash (which carries a C<from_tap> facet recording the
original line and source stream). On miss, delegate to the base
L<Test2::Harness2::Collector::Parser::IOParser/parse_stream_line>.

=back

=cut

sub parse_stream_line ($self, $io, $event) {
    my $ucstream = uc($io->{stream});
    my $line     = $io->{line};

    my $facet_data =
          $ucstream eq 'STDERR'
        ? $self->_parse_stderr_tap($line)
        : $self->_parse_stdout_tap($line);

    if ($facet_data) {
        $event->{facet_data} = $facet_data;
        return;
    }

    $self->SUPER::parse_stream_line($io, $event);
    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $facet_data = $self->_parse_stdout_tap($line)

Parse a STDOUT line as TAP, attaching a C<from_tap> facet on success.
Returns C<undef> when the line is not TAP.

=item $facet_data = $self->_parse_stderr_tap($line)

Parse a STDERR comment line as TAP diagnostics (tagged C<DIAG>, C<debug = 1>).
Returns C<undef> for non-comment STDERR lines.

=back

=cut

sub _parse_stdout_tap ($self, $line) {
    my $facet_data = $self->_parse_tap_line($line) or return undef;
    $facet_data->{from_tap} = {source => 'STDOUT', details => $line};
    return $facet_data;
}

sub _parse_stderr_tap ($self, $line) {
    return undef unless $line =~ m/^\s*#/;

    my $facet_data = $self->_parse_tap_line($line) or return undef;
    $facet_data->{info}->[-1]->{tag}   = 'DIAG';
    $facet_data->{info}->[-1]->{debug} = 1;
    $facet_data->{from_tap}            = {source => 'STDERR', details => $line};

    return $facet_data;
}

=over 4

=item $facet_data = $self->_parse_tap_line($line)

Strip leading whitespace into a nesting depth (rejecting non-multiple-of-four
indentation) and dispatch the remaining text through the recognizers in
order. Stamps the resulting facets with C<trace.nested> / C<hubs[0].nested>.
Returns C<undef> when nothing matches.

=back

=cut

sub _parse_tap_line ($self, $line) {
    chomp($line);

    my ($lead, $lead_len, $nest, $str) = ('', 0, 0, $line);
    if ($line =~ m/^(\s+)\S/) {
        $lead = $1;
        $str =~ s/^\Q$lead\E//mg;

        $lead =~ s/\t/    /g;
        $lead_len = length($lead);

        return undef if $lead_len % 4;

        $nest = $lead_len / 4;
    }

    my @types = qw/buffered_subtest comment plan bail version/;
    for my $type (@types) {
        my $sub        = "_parse_tap_$type";
        my $facet_data = $self->$sub($str) or next;
        $facet_data->{trace}->{nested} = $nest;
        $facet_data->{hubs}->[0]->{nested} = $nest;
        return $facet_data;
    }

    return undef;
}

=over 4

=item $facet_data = $self->_parse_tap_buffered_subtest($line)

Recognize the buffered-subtest close (C<}>) and the C<ok ... {> open, marking
C<harness.subtest_start> / C<harness.subtest_end> accordingly.

=item $facet_data = $self->_parse_tap_ok($line)

Parse an C<ok> / C<not ok> assertion line, including the assertion number,
TODO / SKIP directives, and the C<Subtest:> marker, into an C<assert> facet
(plus C<amnesty> / C<info> as needed).

=back

=cut

sub _parse_tap_buffered_subtest ($self, $line) {
    return {parent => {}, harness => {subtest_end => 1}} if $line =~ m/^\}\s*$/;

    my $facet_data = $self->_parse_tap_ok($line) or return undef;
    return $facet_data unless $facet_data->{assert}->{details} =~ s/\s*\{\s*$//g;

    $facet_data->{parent} = {details => $facet_data->{assert}->{details}};
    $facet_data->{harness}->{subtest_start} = 1;

    return $facet_data;
}

sub _parse_tap_ok ($self, $line) {
    my ($pass, $todo, $skip, $num, @errors);

    return undef unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space after 'ok'"
            if length($space) > 1;
    }

    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors => "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors => "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    $line =~ s/\s*-\s*//;
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $is_subtest = ($line =~ m/^Subtest:\s*(.*)$/) ? ($1 or 1) : undef;

    my $facet_data = {
        assert => {
            pass     => $pass,
            no_debug => 1,
            details  => $line,
            defined $num ? (number => $num) : (),
        },
    };

    $facet_data->{parent} = {details => $is_subtest}
        if defined $is_subtest;

    push @{$facet_data->{amnesty}} => {tag => 'SKIP', details => $skip}
        if defined $skip;
    push @{$facet_data->{amnesty}} => {tag => 'TODO', details => $todo}
        if defined $todo;

    push @{$facet_data->{info}} => {details => $_, debug => 1, tag => 'PARSER'} for @errors;

    return $facet_data;
}

=over 4

=item $facet_data = $self->_parse_tap_version($line)

Recognize the C<TAP version N> preamble into C<about> + C<info> facets.

=item $facet_data = $self->_parse_tap_plan($line)

Recognize a C<1..N> plan (including the C<1..0 # SKIP> skip-everything form)
into a C<plan> facet.

=item $facet_data = $self->_parse_tap_bail($line)

Recognize C<Bail out!> into a C<control> facet with C<halt = 1>.

=item $facet_data = $self->_parse_tap_comment($line, %params)

Recognize a comment line (C</^\s*#/>) into a C<NOTE> C<info> entry. With
C<< no_nest => 1 >> the leading C<# > is left in place.

=back

=cut

sub _parse_tap_version ($self, $line) {
    return undef unless $line =~ m/^TAP version\s/;

    return {
        about => {details => $line},
        info  => [{tag => 'INFO', debug => 0, details => $line}],
    };
}

sub _parse_tap_plan ($self, $line) {
    return undef unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason) = ("", "");

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason    = $line;
                $line      = "";
            }
        }
        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $facet_data = {
        plan => {
            count   => $max,
            skip    => ($directive eq 'SKIP') ? 1 : 0,
            details => $reason,
        },
    };

    push @{$facet_data->{info}} => {
        details => 'Extra characters after plan.',
        debug   => 1,
        tag     => 'PARSER',
    } if $line =~ m/\S/;

    return $facet_data;
}

sub _parse_tap_bail ($self, $line) {
    return undef unless $line =~ m/^Bail out!\s*(.*)$/;

    return {control => {halt => 1, details => $1}};
}

sub _parse_tap_comment ($self, $line, %params) {
    return undef unless $line =~ m/^\s*#/;

    $line =~ s/^\s*# ?//msg unless $params{no_nest};

    return {info => [{details => $line, tag => 'NOTE', debug => 0}]};
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
