package Test2::Harness2::Util::Directives::Legacy;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use List::Util qw/uniq/;

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

=item $p->parse_line($line)

Feed one line into the parser. Tracks line numbers for warnings. Non-directive
lines are ignored.

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

sub parse_fh ($invocant, $fh, %args) {
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        $self->parse_line($line);
    }
    return $self->finish;
}

sub parse_string ($invocant, $text, %args) {
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    for my $line (split /\r?\n/, $text, -1) {
        $self->parse_line($line);
    }
    return $self->finish;
}

sub finish ($self) {
    $self->_prune($self->{result});
    return $self->{result};
}

sub parse_line ($self, $line) {
    $self->{line_no}++;

    croak "parse_line: embedded newline at line $self->{line_no}"
        if defined($line) && $line =~ /\n/;

    return unless defined $line;

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

=item $self->_record($body)

Decode a single C<HARNESS-$body> directive body (the text after the
C<HARNESS-> leader) and fold it into the nested result, in the same
arrayref-leaf nested-hash shape the C<HARNESS2:> grammar emits.

=item $self->_set($key_path, @values)

Replace the leaf arrayref at the (possibly dotted) C<$key_path>.

=item $self->_append($key_path, @values)

Push values onto the leaf arrayref at the (possibly dotted) C<$key_path>.

=item $self->_prune($node)

Recursively drop empty subtrees / empty leaf arrays.

=back

=cut

sub _record ($self, $body) {
    my ($dir, $rest) = split /[-\s]+/, $body, 2;
    $dir = lc($dir);

    my @args;
    if ($dir eq 'meta') {
        # Guard the meta-specific splits on a present body so a bare
        # 'HARNESS-META' does not split-on-undef (uninit warning); the empty
        # @args is caught by the key/value validation in the meta handler below.
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

    my $ln   = $self->{line_no};
    my $file = $self->{file};

    if ($dir eq 'no') {
        my $feature = lc(join '_' => @args);
        unless (length $feature) {
            # Bare 'HARNESS-NO' would otherwise write an arrayref leaf at
            # feature.'' and corrupt the tree for a later feature directive.
            warn "'HARNESS-NO' requires a feature name" . _at($file, $ln) . "\n";
            return;
        }
        if ($feature eq 'retry') {
            # 'NO-RETRY' -> retry count 0 (matches the nested retry.count path).
            $self->_set('retry.count', [0]);
        }
        else {
            $self->_set("feature.$feature", [0]);
        }
    }
    elsif ($dir eq 'smoke') {
        $self->_set('feature.smoke', [1]);
    }
    elsif ($dir eq 'retry') {
        my $have_count;
        for my $arg (@args) {
            if ($arg =~ m/^\d+$/) {
                $self->_set('retry.count', [int $arg]);
                $have_count = 1;
            }
            elsif ($arg =~ m/^iso/i) {
                $self->_set('retry.isolated', [1]);
            }
            else {
                warn "Unknown 'HARNESS-RETRY' argument '$arg'" . _at($file, $ln) . "\n";
            }
        }
        # Bare 'HARNESS-RETRY' (no count) means retry once.
        $self->_set('retry.count', [1]) unless $have_count || defined $self->_leaf('retry.count');
    }
    elsif ($dir eq 'yes' || $dir eq 'use') {
        my $feature = lc(join '_' => @args);
        unless (length $feature) {
            warn "'HARNESS-" . uc($dir) . "' requires a feature name" . _at($file, $ln) . "\n";
            return;
        }
        $self->_set("feature.$feature", [1]);
    }
    elsif ($dir eq 'stage') {
        my @list = @args;

        # 'REQUIRE' is a reserved leading keyword: it marks the listed stages as
        # mandatory (no fallback) rather than advisory. Compute the flag but set
        # nothing until the stage list is confirmed non-empty, so a bare
        # 'HARNESS-STAGE-REQUIRE' leaves no dangling require_preload behind.
        my $require = (@list && uc($list[0]) eq 'REQUIRE') ? 1 : 0;
        shift @list if $require;

        unless (@list) {
            warn "'HARNESS-STAGE' requires at least one stage name" . _at($file, $ln) . "\n";
            return;
        }

        $self->_set('require_preload', [1]) if $require;
        $self->_set('preload_list', [@list]);
        $self->_set('stage', [$list[0]]);
    }
    elsif ($dir eq 'meta') {
        my ($key, $val) = @args;
        unless (defined $key && length $key && defined $val && length $val) {
            warn "'HARNESS-META' requires a key and a value" . _at($file, $ln) . "\n";
            return;
        }
        $key = lc($key);
        $self->_append("meta.$key", $val);
    }
    elsif ($dir eq 'duration' || $dir eq 'dur') {
        my ($name) = @args;
        unless (defined $name && length $name) {
            warn "'HARNESS-" . uc($dir) . "' requires a duration name" . _at($file, $ln) . "\n";
            return;
        }
        $self->_set('duration', [lc($name)]);
    }
    elsif ($dir eq 'category' || $dir eq 'cat') {
        my ($name) = @args;
        unless (defined $name && length $name) {
            warn "'HARNESS-" . uc($dir) . "' requires a category name" . _at($file, $ln) . "\n";
            return;
        }
        $name = lc($name);
        # The long/medium/short -> duration remap is intentional 1.0 compat and
        # stays here; category value LEGALITY belongs to the producer (#118).
        if ($name =~ m/^(long|medium|short)$/) {
            $self->_set('duration', [$name]);
        }
        else {
            $self->_set('category', [$name]);
        }
    }
    elsif ($dir eq 'conflicts') {
        unless (@args) {
            warn "'HARNESS-CONFLICTS' requires at least one name" . _at($file, $ln) . "\n";
            return;
        }
        my @add = map { lc $_ } @args;
        my $cur = $self->_leaf('conflicts') // [];
        $self->_set('conflicts', [uniq(@$cur, @add)]);
    }
    elsif ($dir eq 'timeout') {
        my ($type, $num, $extra) = @args;
        $type = lc($type // '');
        $num  = lc($num  // '');

        ($type, $num) = ('postexit', $extra) if $type eq 'post' && $num eq 'exit';

        unless ($type =~ m/^(event|postexit)$/) {
            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT'" . _at($file, $ln) . "\n";
            return;
        }

        unless (defined $num && length $num) {
            warn "'HARNESS-TIMEOUT' requires a value" . _at($file, $ln) . "\n";
            return;
        }

        $self->_set("timeout.$type", [$num]);
    }
    elsif ($dir eq 'job' && defined $rest && $rest =~ m/slots\s+(\d+)(?:\s+(\d+))?$/i) {
        my ($min, $max) = ($1, $2);
        $self->_set('slots', [$min, defined($max) ? $max : $min]);
    }
    else {
        warn "Unknown harness directive '$dir'" . _at($file, $ln) . "\n";
    }

    return;
}

sub _at ($file, $ln) {
    return defined($file) ? " at $file line $ln." : " at line $ln.";
}

# Split a dotted key path into non-empty segments. An empty segment (from a
# bare directive that reached a _set/_append with a dangling key like
# 'feature.') would silently corrupt the nested tree and later surface as a
# stripped-location 'Not a HASH reference' die -- croak clearly instead. The
# per-directive arg validation in _record should prevent this; this is the
# belt-and-braces backstop (and the guard that survives #85's rework).
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

sub _prune ($self, $node) {
    for my $k (keys %$node) {
        my $v = $node->{$k};
        if (ref($v) eq 'HASH') {
            $self->_prune($v);
            delete $node->{$k} unless keys %$v;
        }
        elsif (ref($v) eq 'ARRAY') {
            delete $node->{$k} unless @$v;
        }
    }

    return;
}

1;

__END__

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
