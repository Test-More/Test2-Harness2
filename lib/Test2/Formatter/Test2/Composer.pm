package Test2::Formatter::Test2::Composer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Scalar::Util qw/blessed/;
use List::Util qw/first/;

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub render_one_line {
    my $class = shift;
    my $in   = shift;
    my $f    = blessed($in) ? $in->facet_data : $in;

    return [$f->{render}->[0]->{facet}, uc($f->{render}->[0]->{tag}), $f->{render}->[0]->{details}]
        if $f->{render} && @{$f->{render}};

    for my $type (qw/assert errors plan info about/) {
        next unless $f->{$type};
        my $m = "render_$type";
        my ($out) = $class->$m($f);
        return $out if defined $out;
    }

    return;
}

sub render_verbose {
    my $class = shift;
    my ($in) = @_;

    my $f = blessed($in) ? $in->facet_data : $in;

    return [map {[$_->{facet}, uc($_->{tag}), $_->{details}]} @{$f->{render}}]
        if $f->{render} && @{$f->{render}};

    my @out;

    push @out => $class->render_control($f) if $f->{control};
    push @out => $class->render_plan($f) if $f->{plan};

    if ($f->{assert}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f) unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $class->render_amnesty($f) if $f->{amnesty} && @{$f->{amnesty}};
    }

    push @out => $class->render_info($f)   if $f->{info};
    push @out => $class->render_errors($f) if $f->{errors};

    push @out => $class->render_about($f)
        if $f->{about} && !(@out || first { $f->{$_} } qw/stop plan info nest assert/);

    return \@out;
}

sub render_control {
    my $class = shift;
    my ($f) = @_;

    my @out;

    push @out => ['control', 'HALT', $f->{control}->{details}]
        if defined $f->{control}->{halt};

    return @out;
}

my %SHOW_BRIEF_TAGS = (
    'CRITICAL' => 1,
    'DEBUG'    => 1,
    'DIAG'     => 1,
    'ERROR'    => 1,
    'FAIL'     => 1,
    'FAILED'   => 1,
    'FATAL'    => 1,
    'HALT'     => 1,
    'PASSED'   => 1,
    'REASON'   => 1,
    'STDERR'   => 1,
    'TIMEOUT'  => 1,
    'WARN'     => 1,
    'WARNING'  => 1,
    'KILL'     => 1,
    'SKIPPED'  => 1,
);

my %SHOW_BRIEF_FACETS = (
    control => 1,
    error   => 1,
    trace   => 1,
);

sub render_brief {
    my $class = shift;
    my $in   = shift;
    my $f    = blessed($in) ? $in->facet_data : $in;

    if ($f->{render} && @{$f->{render}}) {
        my @show = grep { $SHOW_BRIEF_TAGS{uc($_->{tag})} || $SHOW_BRIEF_FACETS{lc($_->{facet})} } @{$f->{render}};
        return [map { [$_->{facet}, uc($_->{tag}), $_->{details}] } @show];
    }

    my @out;

    push @out => $class->render_control($f) if $f->{control};

    if ($f->{assert} && !$f->{assert}->{pass} && !$f->{amnesty}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f) unless $f->{assert}->{no_debug};
    }

    if ($f->{info}) {
        my $if = {%$f, info => [grep { $_->{debug} || $_->{important} || $_->{peek} } @{$f->{info}}]};
        push @out => $class->render_info($if) if @{$if->{info}};
    }

    push @out => $class->render_errors($f) if $f->{errors};

    return \@out;
}

sub render_plan {
    my $class = shift;
    my ($f) = @_;

    my $plan = $f->{plan};
    return ['plan', 'NO  PLAN', $f->{plan}->{details}] if $plan->{none};

    if ($plan->{skip}) {
        return ['plan', 'SKIP ALL', $f->{plan}->{details}]
            if $f->{plan}->{details};

        return ['plan', 'SKIP ALL', "No reason given"];
    }

    return ['plan', 'PLAN', "Expected assertions: $f->{plan}->{count}"];
}

sub render_assert {
    my $class = shift;
    my ($f) = @_;

    my $name = $f->{assert}->{details} || '<UNNAMED ASSERTION>';

    return ['assert', '! PASS !', $name]
        if $f->{amnesty} && @{$f->{amnesty}};

    return ['assert', 'PASS', $name]
        if $f->{assert}->{pass};

    return ['assert', 'FAIL', $name]
}

sub render_amnesty {
    my $class = shift;
    my ($f) = @_;

    my %seen;
    return map {
        $seen{join '' => map { $_ // '' } @{$_}{qw/tag details/}}++
            ? ()
            : ['amnesty', $_->{tag}, $_->{details}]
    } @{$f->{amnesty}};
}

sub render_debug {
    my $class = shift;
    my ($f) = @_;

    my $name  = $f->{assert}->{details};
    my $trace = $f->{trace};

    my $debug;
    if ($trace) {
        $debug = $trace->{details};
        if(!$debug && $trace->{frame}) {
            my $frame = $trace->{frame};
            $debug = "$frame->[1] line $frame->[2]";
        }
    }

    $debug ||= "[No trace info available]";

    chomp($debug);

    return ['trace', 'DEBUG', $debug];
}

# Turn a details value into a string for human display: refs are rendered via
# Data::Dumper (trailing newline chomped), everything else is returned as-is.
sub _render_details {
    my $class = shift;
    my ($details) = @_;

    return $details unless ref($details);

    require Data::Dumper;
    my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
    chomp(my $msg = $dumper->Dump);
    return $msg;
}

sub render_info {
    my $class = shift;
    my ($f) = @_;

    return map {
        my $details = $class->_render_details($_->{details} // '');
        ['info', $_->{tag}, $details, $_->{table} || ()]
    } @{$f->{info}};
}

sub render_about {
    my $class = shift;
    my ($f) = @_;

    return if $f->{about}->{no_display};
    return unless $f->{about} && $f->{about}->{details};

    my $type;
    if ($f->{about}->{package}) {
        $type = $f->{about}->{package};
        $type =~ s/^.*:://;
    }
    $type //= 'ABOUT';

    return ['about', $type, $f->{about}->{details}];
}

sub render_errors {
    my $class = shift;
    my ($f) = @_;

    return map {
        my $details = $class->_render_details($_->{details});
        my $tag = $_->{tag} || ($_->{fail} ? 'FATAL' : 'ERROR');
        ['error', $tag, $details]
    } @{$f->{errors}};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Test2::Composer - Compose output components from event facets

=head1 DESCRIPTION

This is used by L<Test2::Formatter::Test2> to turn events into output
components. This logic lives here instead of in the formatter because it is
also used by L<Test2::Harness2::UI>. Other tools may also find this conversion
useful.

=head1 SYNOPSIS

    use Test2::Formatter::Test2::Composer;

    # Note, all methods are class methods, this is just here for convenience.
    my $comp = Test2::Formatter::Test2::Composer->new();

    my $out = $comp->render_one_line($event);
    my ($facet_name, $tag_string, $text_for_humans) = @$out;
    ...

    for my $line ($comp->render_verbose($event)) {
        my ($facet_name, $tag_string, $text_for_humans) = @$line;
        ...,
    }

=head1 METHODS

All methods are class methods, but they also work just fine on a blessed
instance. There is no benefit to a blessed instance, but you can create one for
convenience if it makes you more comfortable.

=over 4

=item $inst = $class->new()

Create a blessed instance. This is here for convenience only. All methods are
class methods.

=item $arrayref = $class->render_one_line($event)

=item $arrayref = $class->render_one_line(\%facet_data)

    my $out = $comp->render_one_line($event);
    my ($facet_name, $tag_string, $text_for_humans) = @$out;

This will return a single line of output from the event, even if the event
would normally return multiple lines.

In order of priority:

=over 4

=item Custom 'render' facet

=item Assertion (pass/fail)

=item Error message

=item Plan

=item Info (note/diag)

=item About

=back

=item @lines = $class->render_verbose($event)

=item @lines = $class->render_verbose(\%facet_data)

This will verbosely render any event.

    for my $line ($comp->render_verbose($event)) {
        my ($facet_name, $tag_string, $text_for_humans) = @$line;
        ...,
    }

=back

=head2 FACET RENDERERS

With exception of C<render_control()> these are all the same. These all take
C<\%facet_data> as their only argument, and return a list of line-arrayrefs
C<[$facet, $tag, $text_for_humans]>.

=over 4

=item @lines = $class->render_control(\%facet_data)

This renders control facets (currently the C<halt>/bail-out line).

=item @lines = $class->render_brief(\%facet_data)

=item @lines = $class->render_plan(\%facet_data)

=item @lines = $class->render_assert(\%facet_data)

=item @lines = $class->render_amnesty(\%facet_data)

=item @lines = $class->render_debug(\%facet_data)

=item @lines = $class->render_info(\%facet_data)

=item @lines = $class->render_about(\%facet_data)

=item @lines = $class->render_errors(\%facet_data)

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
