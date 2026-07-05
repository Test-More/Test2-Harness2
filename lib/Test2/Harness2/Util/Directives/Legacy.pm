package Test2::Harness2::Util::Directives::Legacy;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use List::Util qw/uniq/;

use parent 'Test2::Harness2::Util::Directives::Base';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Directives::Legacy - Compat parser for 1.0 C<HARNESS-…> directives.

=head1 DESCRIPTION

Parses the original Test2::Harness 1.0 C<< <comment> HARNESS-<NAME> ... >>
in-file directives and converts them into the SAME nested-hash internal
representation produced by L<Test2::Harness2::Util::Directives> (the C<HARNESS2:>
grammar parser). A producer (e.g. L<App::Yath2::TestFile>) can then map either
parser's output onto its harness fields with one C<_apply_directives>.

This module is used only when a file contains B<no> C<HARNESS2:> directives; a
file with any C<HARNESS2:> directive uses the new grammar and its C<HARNESS-…>
lines are ignored (newer wins, silently).

=head1 SYNOPSIS

    my $p = Test2::Harness2::Util::Directives::Legacy->new(comment => '#');
    my $result = $p->parse_file('t/some_test.t');
    # OR
    my $result = Test2::Harness2::Util::Directives::Legacy->parse_file(
        't/some_test.t', comment => '#',
    );

=cut

=head1 PUBLIC METHODS

=over 4

=item $p = $class->new(comment => '#')

Construct a parser for the supplied comment leader. Croaks on a missing / empty
comment.

=item $result = $invocant->parse_file($path, %ctor_args)

=item $result = $invocant->parse_fh($fh, %ctor_args)

=item $result = $invocant->parse_string($text, %ctor_args)

Class or instance methods. Feed a file / filehandle / string and return the
C<finish> result. As a class method a fresh parser is constructed first.
C<parse_fh> and C<parse_string> are inherited from
L<Test2::Harness2::Util::Directives::Base>; C<parse_file> is overridden here only
to thread the C<file> through for nicer warning locations.

=item $p->parse_line($line)

Feed one line into the parser. Tracks line numbers for warnings. Non-directive
lines are ignored. Inherited from L<Test2::Harness2::Util::Directives::Base>,
which dispatches to the private C<_parse_line> interpreter below.

=item $result = $p->finish

Return the accumulated nested-hash result (pruned of empties).

=back

=cut

sub new ($class, %args) {
    my $comment = $args{comment};
    $comment = '#' unless defined $comment && length $comment;

    return bless {
        comment => $comment,
        file    => $args{file},    # only for nicer warnings
        result  => {},
        line_no => 0,
    }, $class;
}

sub parse_file ($invocant, $path, %args) {
    open my $fh, '<', $path or croak "open '$path': $!";
    my $h = $invocant->parse_fh($fh, %args, file => $path);
    close $fh;
    return $h;
}

sub finish ($self) {
    $self->_prune($self->{result});
    return $self->{result};
}

sub _parse_line ($self, $line) {
    my $comment = $self->{comment};

    # Only HARNESS- comment lines carry directives. Anything else is ignored
    # here; the file-reading producer owns deciding when to stop scanning.
    return unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

    my $body = $1;
    $self->_record($body);
    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_parse_line($line)

Interpret one already-guarded line (the C<_parse_line> hook the base driver
calls): ignore anything that is not a C<HARNESS-…> comment line, otherwise hand
the directive body to C<_record>.

=item $self->_record($body)

Decode a single C<HARNESS-$body> directive body (the text after the
C<HARNESS-> leader): tokenize it into C<$dir> + C<@args> and dispatch to the
matching C<_dir_*> handler via the C<%HANDLER> table (with C<job … slots> as the
final C<$rest>-keyed fallthrough), folding the result into the same arrayref-leaf
nested-hash shape the C<HARNESS2:> grammar emits.

=item $self->_dir_*($dir, \@args)

Per-directive handlers (C<_dir_no>, C<_dir_retry>, C<_dir_feature>, C<_dir_stage>,
C<_dir_meta>, C<_dir_duration>, C<_dir_category>, C<_dir_conflicts>,
C<_dir_timeout>, C<_dir_smoke>) keyed from C<%HANDLER>; each validates its args
and folds one directive into the result.

=item $self->_set($key_path, @values)

Replace the leaf arrayref at the (possibly dotted) C<$key_path>.

=item $self->_append($key_path, @values)

Push values onto the leaf arrayref at the (possibly dotted) C<$key_path>.

=item $self->_loc

Return the C<< at FILE line N. >> suffix for a warning at the current line.

=back

=cut

# Dispatch table: lower-cased legacy directive word ($dir) -> handler method.
# Each handler receives ($dir, \@args) and folds its result into the nested tree.
# 'job' is deliberately absent: its dispatch keys off the raw $rest text (not
# just $dir), so it is handled as the final fallthrough in _record below.
my %HANDLER = (
    no        => '_dir_no',
    smoke     => '_dir_smoke',
    retry     => '_dir_retry',
    yes       => '_dir_feature',
    use       => '_dir_feature',
    stage     => '_dir_stage',
    meta      => '_dir_meta',
    duration  => '_dir_duration',
    dur       => '_dir_duration',
    category  => '_dir_category',
    cat       => '_dir_category',
    conflicts => '_dir_conflicts',
    timeout   => '_dir_timeout',
);

sub _record ($self, $body) {
    my ($dir, $rest) = split /[-\s]+/, $body, 2;
    $dir = lc($dir);

    my @args;
    if ($dir eq 'meta') {
        # Guard the meta-specific splits on a present body so a bare
        # 'HARNESS-META' does not split-on-undef (uninit warning); the empty
        # @args is caught by the key/value validation in _dir_meta.
        if (defined $rest && length $rest) {
            @args = split /\s+/, $rest, 2;                        # white space delimited
            @args = split(/[-]+/, $rest, 2) if scalar @args == 1; # dash delimited
            $args[1] =~ s/\s+(?:#.*)?$// if defined $args[1];     # strip trailing ws + comment
        }
    }
    elsif (defined $rest && length $rest) {
        $rest =~ s/\s+(?:#.*)?$//;                            # strip trailing ws + comment
        @args = split /[-\s]+/, $rest;
    }

    if (my $handler = $HANDLER{$dir}) {
        $self->$handler($dir, \@args);
        return;
    }

    # 'job ... slots N [M]' keys off the raw (comment-stripped) $rest rather than
    # $dir, so it stays out of %HANDLER and runs last, before the unknown warning.
    if ($dir eq 'job' && defined $rest && $rest =~ m/slots\s+(\d+)(?:\s+(\d+))?$/i) {
        my ($min, $max) = ($1, $2);
        $self->_set('slots', [$min, defined($max) ? $max : $min]);
        return;
    }

    warn "Unknown harness directive '$dir'" . $self->_loc . "\n";
    return;
}

sub _dir_no ($self, $dir, $args) {
    my $feature = lc(join '_' => @$args);
    unless (length $feature) {
        # Bare 'HARNESS-NO' would otherwise write an arrayref leaf at
        # feature.'' and corrupt the tree for a later feature directive.
        warn "'HARNESS-NO' requires a feature name" . $self->_loc . "\n";
        return;
    }
    if ($feature eq 'retry') {
        # 'NO-RETRY' -> retry count 0 (matches the nested retry.count path).
        $self->_set('retry.count', [0]);
    }
    else {
        $self->_set("feature.$feature", [0]);
    }
    return;
}

sub _dir_smoke ($self, $dir, $args) {
    $self->_set('feature.smoke', [1]);
    return;
}

sub _dir_retry ($self, $dir, $args) {
    my $have_count;
    for my $arg (@$args) {
        if ($arg =~ m/^\d+$/) {
            $self->_set('retry.count', [int $arg]);
            $have_count = 1;
        }
        elsif ($arg =~ m/^iso/i) {
            $self->_set('retry.isolated', [1]);
        }
        else {
            warn "Unknown 'HARNESS-RETRY' argument '$arg'" . $self->_loc . "\n";
        }
    }
    # Bare 'HARNESS-RETRY' (no count) means retry once.
    $self->_set('retry.count', [1]) unless $have_count || defined $self->_leaf('retry.count');
    return;
}

sub _dir_feature ($self, $dir, $args) {
    my $feature = lc(join '_' => @$args);
    unless (length $feature) {
        warn "'HARNESS-" . uc($dir) . "' requires a feature name" . $self->_loc . "\n";
        return;
    }
    $self->_set("feature.$feature", [1]);
    return;
}

sub _dir_stage ($self, $dir, $args) {
    my @list = @$args;

    # 'REQUIRE' is a reserved leading keyword: it marks the listed stages as
    # mandatory (no fallback) rather than advisory. Compute the flag but set
    # nothing until the stage list is confirmed non-empty, so a bare
    # 'HARNESS-STAGE-REQUIRE' leaves no dangling require_preload behind.
    my $require = (@list && uc($list[0]) eq 'REQUIRE') ? 1 : 0;
    shift @list if $require;

    unless (@list) {
        warn "'HARNESS-STAGE' requires at least one stage name" . $self->_loc . "\n";
        return;
    }

    $self->_set('require_preload', [1]) if $require;
    $self->_set('preload_list', [@list]);
    $self->_set('stage', [$list[0]]);
    return;
}

sub _dir_meta ($self, $dir, $args) {
    my ($key, $val) = @$args;
    unless (defined $key && length $key && defined $val && length $val) {
        warn "'HARNESS-META' requires a key and a value" . $self->_loc . "\n";
        return;
    }
    $key = lc($key);
    $self->_append("meta.$key", $val);
    return;
}

sub _dir_duration ($self, $dir, $args) {
    my ($name) = @$args;
    unless (defined $name && length $name) {
        warn "'HARNESS-" . uc($dir) . "' requires a duration name" . $self->_loc . "\n";
        return;
    }
    $self->_set('duration', [lc($name)]);
    return;
}

sub _dir_category ($self, $dir, $args) {
    my ($name) = @$args;
    unless (defined $name && length $name) {
        warn "'HARNESS-" . uc($dir) . "' requires a category name" . $self->_loc . "\n";
        return;
    }
    $name = lc($name);
    # The long/medium/short -> duration remap is intentional 1.0 compat and
    # stays here; category value LEGALITY belongs to the producer (TODO-118).
    if ($name =~ m/^(long|medium|short)$/) {
        $self->_set('duration', [$name]);
    }
    else {
        $self->_set('category', [$name]);
    }
    return;
}

sub _dir_conflicts ($self, $dir, $args) {
    unless (@$args) {
        warn "'HARNESS-CONFLICTS' requires at least one name" . $self->_loc . "\n";
        return;
    }
    my @add = map { lc $_ } @$args;
    my $cur = $self->_leaf('conflicts') // [];
    $self->_set('conflicts', [uniq(@$cur, @add)]);
    return;
}

sub _dir_timeout ($self, $dir, $args) {
    my ($type, $num, $extra) = @$args;
    $type = lc($type // '');
    $num  = lc($num  // '');

    ($type, $num) = ('postexit', $extra) if $type eq 'post' && $num eq 'exit';

    unless ($type =~ m/^(event|postexit)$/) {
        warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT'" . $self->_loc . "\n";
        return;
    }

    unless (defined $num && length $num) {
        warn "'HARNESS-TIMEOUT' requires a value" . $self->_loc . "\n";
        return;
    }

    $self->_set("timeout.$type", [$num]);
    return;
}

sub _at ($file, $ln) {
    return defined($file) ? " at $file line $ln." : " at line $ln.";
}

sub _loc ($self) {
    return _at($self->{file}, $self->{line_no});
}

# Split a dotted key path into non-empty segments. An empty segment (from a
# bare directive that reached a _set/_append with a dangling key like
# 'feature.') would silently corrupt the nested tree and later surface as a
# stripped-location 'Not a HASH reference' die -- croak clearly instead. The
# per-directive arg validation in _record should prevent this; this is the
# belt-and-braces backstop (and the guard that survives TODO-85's rework).
sub _split_key ($self, $key) {
    my @parts = split /\./, $key, -1;
    croak "Internal error: empty segment in directive key path '$key'"
        if !@parts || grep { !length } @parts;
    return @parts;
}

# Replace the (arrayref) leaf at a dotted key path, creating intermediate
# subtrees.
sub _set ($self, $key, $arrayref) {
    my @parts = $self->_split_key($key);
    my $node  = $self->{result};
    for my $p (@parts[0 .. $#parts - 1]) {
        $node->{$p} //= {};
        $node = $node->{$p};
    }
    $node->{$parts[-1]} = $arrayref;
    return;
}

# Get the raw leaf (arrayref) at a dotted key path, or undef.
sub _leaf ($self, $key) {
    my @parts = $self->_split_key($key);
    my $node  = $self->{result};
    for my $p (@parts) {
        return undef unless ref($node) eq 'HASH' && exists $node->{$p};
        $node = $node->{$p};
    }
    return $node;
}

# Push a value onto a (dotted) leaf arrayref, creating intermediate subtrees.
sub _append ($self, $key, $val) {
    my @parts = $self->_split_key($key);
    my $node  = $self->{result};
    for my $p (@parts[0 .. $#parts - 1]) {
        $node->{$p} //= {};
        $node = $node->{$p};
    }
    push @{$node->{$parts[-1]}}, $val;
    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
