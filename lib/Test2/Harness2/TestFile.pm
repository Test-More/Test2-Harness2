package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness2::Util qw/open_file/;

use Object::HashBase qw{
    <file <absolute <relative
    <_scanned <_shbang
    <features <switches
    <category <duration <stage
    <conflicts
    <retry <retry_isolated
    <non_perl <is_binary
    <event_timeout <post_exit_timeout
    <min_slots <max_slots
    <meta
    <comment
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::TestFile';

sub init {
    my $self = shift;
    croak "'file' is required" unless defined $self->{+FILE};
    $self->{+ABSOLUTE} //= File::Spec->rel2abs($self->{+FILE});
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});

    # HashBase slot accessors shadow the role's default methods. Seed every
    # slot the role documents a default for so the accessor returns that
    # default instead of undef.
    my $defaults = $self->defaults;
    for my $k (keys %$defaults) {
        $self->{$k} //= $defaults->{$k};
    }
}

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return unless -e $self->{+ABSOLUTE};

    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        return;
    }

    return if $self->{+IS_BINARY};

    my $comment = $self->{+COMMENT} // '#';

    my $fh = open_file($self->{+ABSOLUTE});
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang && %$shbang) {
                $self->{+_SHBANG}  = $shbang;
                $self->{+SWITCHES} = $shbang->{switches} if $shbang->{switches};
                $self->{+NON_PERL} = 1                   if $shbang->{non_perl};
                next;
            }
        }

        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $self->{+FEATURES}{run} = 0;
            next;
        }

        next if $line =~ m/^\s*\Q$comment\E/ && $line !~ m/^\s*\Q$comment\E\s*HARNESS-.+/;
        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;
        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        # Stages D-G will dispatch the matched directive here.
    }

    return;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    # NOTE: dashes are intentionally included with the switches.
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?     # the switches, maybe
          \s*
        $
    }xi;

    if ($line =~ $shbang_re) {
        my @switches;
        @switches         = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }
    elsif ($line =~ m/^#!/ && $line !~ m/perl/i) {
        $shbang{line}     = $line;
        $shbang{non_perl} = 1;
    }

    return \%shbang;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
