package Test2::Harness2::Util::Directives;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

my %SIGIL_TRUE  = map { $_ => 1 } qw/@on @true @yes/;
my %SIGIL_FALSE = map { $_ => 1 } qw/@off @false @no/;

my %DEFAULTS = (
    preload => ['default', 0],
);

sub new {
    my ($class, %args) = @_;

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

sub parse_file {
    my ($invocant, $path, %args) = @_;
    open my $fh, '<', $path or croak "open '$path': $!";
    my $h = $invocant->parse_fh($fh, %args);
    close $fh;
    return $h;
}

sub parse_fh {
    my ($invocant, $fh, %args) = @_;
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        $self->parse_line($line);
    }
    return $self->finish;
}

sub parse_string {
    my ($invocant, $text, %args) = @_;
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    for my $line (split /\r?\n/, $text, -1) {
        $self->parse_line($line);
    }
    return $self->finish;
}

sub parse_line {
    my ($self, $line) = @_;
    $self->{line_no}++;

    croak "parse_line: embedded newline at line $self->{line_no}"
        if defined($line) && $line =~ /\n/;

    return unless defined $line;

    return $self->_parse_inside_block($line) if $self->{open_block};
    return $self->_parse_top_level($line);
}

sub _parse_inside_block {
    my ($self, $line) = @_;

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

sub _parse_top_level {
    my ($self, $line) = @_;

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

sub _record_value {
    my ($self, $key, $v) = @_;

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
}

sub finish {
    my $self = shift;

    if ($self->{open_block}) {
        croak "unclosed HARNESS2 block '$self->{open_block}{key}' at EOF";
    }

    $self->_prune($self->{result});
    return $self->{result};
}

sub _find_brace_idx {
    my ($self, $tokens) = @_;
    for my $i (0 .. $#$tokens) {
        return $i if $tokens->[$i] eq '{' || $tokens->[$i] eq '}';
    }
    return undef;
}

sub _tokenize {
    my ($self, $rest) = @_;

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
            my $j   = $i + 1;
            my $buf = '';
            my $closed = 0;
            while ($j < $len) {
                my $cc = substr($rest, $j, 1);
                if ($cc eq '\\' && $j + 1 < $len) {
                    $buf .= substr($rest, $j + 1, 1);
                    $j   += 2;
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

sub _validate_key {
    my ($self, $key) = @_;
    croak "empty key at line $self->{line_no}"
        unless defined($key) && length($key);
    croak "malformed key '$key' at line $self->{line_no}"
        unless $key =~ /\A[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*\z/;
}

sub _append_value {
    my ($self, $key, $val) = @_;
    my @parts = split /\./, $key;
    my $node  = $self->{result};
    my @path;

    for my $i (0 .. $#parts - 1) {
        my $p = $parts[$i];
        push @path, $p;
        if (exists $node->{$p}) {
            croak "key collision at line $self->{line_no}: '" . join('.', @path)
                . "' already holds values, cannot use as subtree for '$key'"
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
        croak "key collision at line $self->{line_no}: '" . join('.', @path)
            . "' already holds subtree, cannot use as leaf for '$key'"
            if ref($node->{$last}) ne 'ARRAY';
    }
    else {
        $node->{$last} = [];
    }
    push @{$node->{$last}}, $val;
}

sub _prune {
    my ($self, $node) = @_;
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
}

1;
