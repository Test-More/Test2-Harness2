package Test2::Harness2::Util::Directives;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use parent 'Test2::Harness2::Util::Directives::Base';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Directives - Parser for C<HARNESS2:> in-file directives.

=head1 DESCRIPTION

Recognises lines matching C<< <comment> HARNESS2: <key> <values>... >> and
accumulates them into a nested hash. Supports block form (C<key {> ... C<key }>),
boolean sigils (C<@on>/C<@off>/C<@yes>/C<@no>/C<@true>/C<@false>), the
C<@default> sigil (expands per-key from an internal defaults table), dotted keys
(folded into a subtree), and double-quoted values.

This is a pure parser: it reads bytes a line at a time and builds a data
structure. It does not scan files for shebangs, classify tests, or know
anything about the harness. Producers (e.g. C<App::Yath2::TestFile>) drive it
and map its output onto their own state.

=head1 SYNOPSIS

    my $p = Test2::Harness2::Util::Directives->new(comments => ['#', '//']);
    my $result = $p->parse_file('t/some_test.t');
    # OR
    my $result = Test2::Harness2::Util::Directives->parse_file(
        't/some_test.t', comments => ['#'],
    );

=cut

my %SIGIL_TRUE  = map { $_ => 1 } qw/@on @true @yes/;
my %SIGIL_FALSE = map { $_ => 1 } qw/@off @false @no/;

my %DEFAULTS = (
    preload => ['default', 0],
);

=head1 PUBLIC METHODS

=cut

=over 4

=item $p = $class->new(comments => \@strings)

Construct a parser that recognises directive lines beginning with any of the
supplied comment leaders (e.g. C<['#']>, C<['#', '//']>). Croaks on a
missing / empty / non-string comment entry.

=item $result = $invocant->parse_file($path, %ctor_args)

=item $result = $invocant->parse_fh($fh, %ctor_args)

=item $result = $invocant->parse_string($text, %ctor_args)

Class or instance methods. Feed a file / filehandle / string through the parser
and return the C<finish> result. When called as a class method, a fresh parser
is constructed from C<%ctor_args> first. Inherited from
L<Test2::Harness2::Util::Directives::Base>.

=item $p->parse_line($line)

Feed one line into the parser. Tracks line numbers for error messages. Croaks
on an embedded newline. Inherited from
L<Test2::Harness2::Util::Directives::Base>, which dispatches to the private
C<_parse_line> interpreter below.

=item $result = $p->finish

Close the parser. Croaks if a block directive is still open at EOF, prunes empty
subtrees, and returns the accumulated result hashref.

=back

=cut

sub new ($class, %args) {
    my $comments = $args{comments}
        or croak "'comments' is required";
    croak "'comments' must be an array reference"
        unless ref($comments) eq 'ARRAY';
    croak "'comments' must not be empty"
        unless @$comments;
    for my $c (@$comments) {
        croak "'comments' entries must be non-empty strings"
            unless defined($c) && !ref($c) && length($c);
    }

    my @sorted = sort { length($b) <=> length($a) } @$comments;
    my $alt    = join '|', map { quotemeta } @sorted;

    return bless {
        comments   => [@$comments],
        comment_re => qr/\A\s*(?:$alt)\s*HARNESS2:\s*(.*?)\s*\z/,
        result     => {},
        open_block => undef,
        line_no    => 0,
    }, $class;
}

sub _parse_line ($self, $line) {
    return $self->_parse_inside_block($line) if $self->{open_block};
    return $self->_parse_top_level($line);
}

sub finish ($self) {
    if ($self->{open_block}) {
        croak "unclosed HARNESS2 block '$self->{open_block}{key}' at EOF";
    }

    $self->_prune($self->{result});
    return $self->{result};
}

=item $key = $p->open_block_key

The key of the currently-open block directive, or C<undef> if no block is open.
A producer driving the parser line-by-line uses this to know that an arbitrary
code line is inside a block body (and so must not terminate a header scan).

=cut

sub open_block_key ($self) {
    my $ob = $self->{open_block} or return undef;
    return $ob->{key};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_parse_line($line)

Interpret one already-guarded line (the C<_parse_line> hook the base driver
calls): dispatch to the in-block or top-level handler depending on whether a
block directive is currently open.

=item $self->_parse_inside_block($line)

Handle one line while a block directive is open: only the matching C<key }>
closer is accepted; an unrelated directive or a nested C<key {> croaks.

=item $self->_parse_top_level($line)

Top-level directive dispatch: open a block on C<key {>, record each value, and
croak on a stray C<key }> or an empty value list.

=item $self->_record_value($key, $value)

Store one value under C<$key>. Bare values append as-is; sigils expand to
booleans; C<@default> expands from the internal defaults table; unknown sigils
croak.

=item $idx = $self->_find_brace_idx(\@tokens)

Index of the first C<{> / C<}> token, or C<undef>.

=item @tokens = $self->_tokenize($rest)

Split the post-C<HARNESS2:> text into tokens, honoring double-quoted strings
with backslash escapes. Croaks on an unterminated quote.

=item $self->_validate_key($key)

Croak on an empty or malformed key.

=item $self->_append_value($key, $value)

Push C<$value> onto the leaf arrayref at the (possibly dotted) C<$key>, creating
intermediate subtrees and croaking on path/leaf collisions.

=back

=cut

sub _parse_inside_block ($self, $line) {
    return unless $line =~ $self->{comment_re};
    my $rest = $1;
    return unless length $rest;

    my @tokens = $self->_tokenize($rest);
    return unless @tokens;

    my ($key, @rest_tok) = @tokens;
    $self->_validate_key($key);

    my $brace_idx = $self->_find_brace_idx(\@rest_tok);
    if (defined $brace_idx && $rest_tok[$brace_idx] eq '}') {
        croak "block close marker must be last token at line $self->{line_no}"
            unless $brace_idx == $#rest_tok;
        croak "block close has extra tokens at line $self->{line_no}"
            if @rest_tok > 1;
        croak "block close key mismatch at line $self->{line_no}: opened '$self->{open_block}{key}', closed '$key'"
            unless $key eq $self->{open_block}{key};

        $self->_append_value($key, 1);
        $self->{open_block} = undef;
        return;
    }

    if (defined $brace_idx && $rest_tok[$brace_idx] eq '{') {
        croak "nested HARNESS2 block at line $self->{line_no}";
    }

    croak "HARNESS2 directive inside block at line $self->{line_no} (block '$self->{open_block}{key}' is open)";
}

sub _parse_top_level ($self, $line) {
    return unless $line =~ $self->{comment_re};
    my $rest = $1;
    return unless length $rest;

    my @tokens = $self->_tokenize($rest);
    return unless @tokens;

    my ($key, @values) = @tokens;
    $self->_validate_key($key);

    my $brace_idx = $self->_find_brace_idx(\@values);
    if (defined $brace_idx) {
        croak "block marker must be last token at line $self->{line_no}"
            unless $brace_idx == $#values;
        my $brace = $values[$#values];
        if ($brace eq '{') {
            croak "block-open '$key {' must not have other tokens at line $self->{line_no}"
                if @values > 1;
            $self->{open_block} = {key => $key};
            return;
        }
        croak "unexpected block-close '$key }' at line $self->{line_no} (no block open)";
    }

    croak "directive '$key' has no values at line $self->{line_no}"
        unless @values;

    $self->_record_value($key, $_) for @values;
    return;
}

sub _record_value ($self, $key, $v) {
    if ($v !~ /\A\@/) {
        $self->_append_value($key, $v);
        return;
    }

    if ($SIGIL_TRUE{$v}) {
        $self->_append_value($key, 1);
    }
    elsif ($SIGIL_FALSE{$v}) {
        $self->_append_value($key, 0);
    }
    elsif ($v eq '@default') {
        my $exp = $DEFAULTS{$key} // [];
        $self->_append_value($key, $_) for @$exp;
    }
    else {
        croak "unknown sigil '$v' at line $self->{line_no}";
    }

    return;
}

sub _find_brace_idx ($self, $tokens) {
    for my $i (0 .. $#$tokens) {
        return $i if $tokens->[$i] eq '{' || $tokens->[$i] eq '}';
    }
    return undef;
}

sub _tokenize ($self, $rest) {
    my @out;
    my $i   = 0;
    my $len = length $rest;

    while ($i < $len) {
        my $c = substr($rest, $i, 1);
        if ($c =~ /\s/) {
            $i++;
            next;
        }
        if ($c eq '"') {
            my $j      = $i + 1;
            my $buf    = '';
            my $closed = 0;
            while ($j < $len) {
                my $cc = substr($rest, $j, 1);
                if ($cc eq '\\' && $j + 1 < $len) {
                    $buf .= substr($rest, $j + 1, 1);
                    $j += 2;
                    next;
                }
                if ($cc eq '"') {
                    $closed = 1;
                    last;
                }
                $buf .= $cc;
                $j++;
            }
            croak "unterminated quote at line $self->{line_no}" unless $closed;
            push @out, $buf;
            $i = $j + 1;
            next;
        }

        my $j = $i;
        while ($j < $len) {
            my $cc = substr($rest, $j, 1);
            last if $cc =~ /\s/ || $cc eq '"';
            $j++;
        }
        push @out, substr($rest, $i, $j - $i);
        $i = $j;
    }

    return @out;
}

sub _validate_key ($self, $key) {
    croak "empty key at line $self->{line_no}"
        unless defined($key) && length($key);
    croak "malformed key '$key' at line $self->{line_no}"
        unless $key =~ /\A[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*\z/;
    return;
}

sub _append_value ($self, $key, $val) {
    my @parts = split /\./, $key;
    my $node  = $self->{result};
    my @path;

    for my $i (0 .. $#parts - 1) {
        my $p = $parts[$i];
        push @path, $p;
        if (exists $node->{$p}) {
            croak "key collision at line $self->{line_no}: '" . join('.', @path) . "' already holds values, cannot use as subtree for '$key'"
                if ref($node->{$p}) ne 'HASH';
        }
        else {
            $node->{$p} = {};
        }
        $node = $node->{$p};
    }

    my $last = $parts[-1];
    push @path, $last;
    if (exists $node->{$last}) {
        croak "key collision at line $self->{line_no}: '" . join('.', @path) . "' already holds subtree, cannot use as leaf for '$key'"
            if ref($node->{$last}) ne 'ARRAY';
    }
    else {
        $node->{$last} = [];
    }
    push @{$node->{$last}}, $val;

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
