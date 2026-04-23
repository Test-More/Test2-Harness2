package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000012';

use File::Spec;
use Carp qw/croak/;
use List::Util 1.45 qw/uniq/;

use Test2::Harness2::Util qw/open_file clean_path/;

use Test2::Harness2::Util::HashBase qw{
    <file
    +relative
    <_scanned
    <_headers
    +_shbang
    <is_binary
    +non_perl
    comment
    _category
    _stage
    _duration
    _min_slots
    _max_slots
};

sub init {
    my $self = shift;

    my $file = $self->{+FILE} or croak "file is required";

    # We want absolute path
    $file = clean_path($file, 0);
    $self->{+FILE} = $file;

    croak "Invalid test file '$file'" unless -f $file;

    if ($self->{+IS_BINARY} = -B $file && !-z $file) {
        $self->{+NON_PERL} = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }
}

sub relative {
    my $self = shift;
    return $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});
}

sub non_perl {
    my $self = shift;
    return $self->{+NON_PERL}     if exists $self->{+NON_PERL};
    return $self->{+NON_PERL} = 1 if $self->{+IS_BINARY};

    $self->scan();

    return $self->{+NON_PERL} ? 1 : 0;
}

my %DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    run       => 1,
    isolation => 0,
    smoke     => 0,
);

sub check_feature {
    my $self = shift;
    my ($feature, $default) = @_;

    $default = $DEFAULTS{$feature} unless defined $default;

    return $default unless defined $self->headers->{features}->{$feature};
    return 1 if $self->headers->{features}->{$feature};
    return 0;
}

sub check_stage {
    my $self = shift;

    return $self->{+_STAGE} if $self->{+_STAGE};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{stage} || undef;
}

sub check_min_slots {
    my $self = shift;

    return $self->{+_MIN_SLOTS} if $self->{+_MIN_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{min_slots} // undef;
}

sub check_max_slots {
    my $self = shift;

    return $self->{+_MAX_SLOTS} if $self->{+_MAX_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{max_slots} // undef;
}

sub meta {
    my $self = shift;
    my ($key) = @_;

    $self->_scan unless $self->{+_SCANNED};
    my $meta = $self->{+_HEADERS}->{meta} or return ();

    return () unless $key && $meta->{$key};

    return @{$meta->{$key}};
}

sub check_duration {
    my $self = shift;

    return $self->{+_DURATION} if $self->{+_DURATION};

    $self->_scan unless $self->{+_SCANNED};
    my $duration = $self->{+_HEADERS}->{duration};
    return $duration if $duration;

    my $timeout = $self->check_feature(timeout => 1);

    # 'long' for anything with no timeout
    return 'long' unless $timeout;

    return 'medium';
}

sub check_category {
    my $self = shift;

    return $self->{+_CATEGORY} if $self->{+_CATEGORY};

    $self->_scan unless $self->{+_SCANNED};
    my $category = $self->{+_HEADERS}->{category};

    return $category if $category;

    my $isolate = $self->check_feature(isolation => 0);

    # 'isolation' queue if isolation requested
    return 'isolation' if $isolate;

    return 'general';
}

sub event_timeout     { $_[0]->headers->{timeout}->{event} }
sub post_exit_timeout { $_[0]->headers->{timeout}->{postexit} }

sub conflicts_list {
    return $_[0]->headers->{conflicts} || [];
}

sub retry          { $_[0]->headers->{retry} }
sub retry_isolated { $_[0]->headers->{retry_isolated} }

sub headers {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_HEADERS};
    return {%{$self->{+_HEADERS}}};
}

sub shbang {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_SHBANG};
    return {%{$self->{+_SHBANG}}};
}

sub switches {
    my $self = shift;

    my $shbang   = $self->shbang       or return [];
    my $switches = $shbang->{switches} or return [];

    return $switches;
}

sub is_executable {
    my $self = shift;
    my ($file) = @_;
    $file //= $self->{+FILE};
    return -x $file;
}

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return if $self->{+IS_BINARY};

    my $fh      = open_file($self->{+FILE});
    my $comment = $self->{+COMMENT} // '#';

    my %headers;
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang) {
                $self->{+_SHBANG} = $shbang;

                if ($shbang->{non_perl}) {
                    $self->{+NON_PERL} = 1;
                }

                next;
            }
        }

        # Uhg, breaking encapsulation between yath and the harness
        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $headers{features}->{run} = 0;
            next;
        }

        next if $line =~ m/^\s*#/ && $line !~ m/^\s*#\s*HARNESS-.+/;    # Ignore commented lines which aren't HARNESS-?
        next if $line =~ m/^\s*(use|require|BEGIN|package)\b/;          # Only supports single line BEGINs
        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        my ($dir, $rest) = split /[-\s]+/, $1, 2;
        $dir = lc($dir);
        my @args;
        if ($dir eq 'meta') {
            @args = split /\s+/, $rest, 2;                           # Check for white space delimited
            @args = split(/[-]+/, $rest, 2) if scalar @args == 1;    # Check for dash delimited
            $args[1] =~ s/\s+(?:#.*)?$// if defined $args[1];        # Strip trailing white space and comment
        }
        elsif ($rest) {
            $rest =~ s/\s+(?:#.*)?$//;                               # Strip trailing white space and comment
            @args = split /[-\s]+/, $rest;
        }

        if ($dir eq 'no') {
            my $feature = lc(join '_' => @args);
            if ($feature eq 'retry') {
                $headers{retry} = 0;
            }
            else {
                $headers{features}->{$feature} = 0;
            }
        }
        elsif ($dir eq 'smoke') {
            $headers{features}->{smoke} = 1;
        }
        elsif ($dir eq 'retry') {
            $headers{retry} = 1 unless @args || defined $headers{retry};
            for my $arg (@args) {
                if ($arg =~ m/^\d+$/) {
                    $headers{retry} = int $arg;
                }
                elsif ($arg =~ m/^iso/i) {
                    $headers{retry} //= 1;
                    $headers{retry_isolated} = 1;
                }
                else {
                    warn "Unknown 'HARNESS-RETRY' argument '$arg' at $self->{+FILE} line $ln.\n";
                }
            }
        }
        elsif ($dir eq 'yes' || $dir eq 'use') {
            my $feature = lc(join '_' => @args);
            $headers{features}->{$feature} = 1;
        }
        elsif ($dir eq 'stage') {
            my ($name) = @args;
            $headers{stage} = $name;
        }
        elsif ($dir eq 'meta') {
            my ($key, $val) = @args;
            $key = lc($key);
            push @{$headers{meta}->{$key}} => $val;
        }
        elsif ($dir eq 'duration' || $dir eq 'dur') {
            my ($name) = @args;
            $name = lc($name);
            $headers{duration} = $name;
        }
        elsif ($dir eq 'category' || $dir eq 'cat') {
            my ($name) = @args;
            $name = lc($name);
            if ($name =~ m/^(long|medium|short)$/i) {
                $headers{duration} = $name;
            }
            else {
                $headers{category} = $name;
            }
        }
        elsif ($dir eq 'conflicts') {
            my @conflicts_array;

            foreach my $arg (@args) {
                push @conflicts_array, lc($arg);
            }

            # Allow multiple lines with # HARNESS-CONFLICTS FOO
            $headers{conflicts} ||= [];
            push @{$headers{conflicts}}, @conflicts_array;

            # Make sure no more than 1 conflict is ever present.
            @{$headers{conflicts}} = uniq @{$headers{conflicts}};
        }
        elsif ($dir eq 'timeout') {
            my ($type, $num, $extra) = @args;
            $type = lc($type);
            $num  = lc($num) if defined $num;

            ($type, $num) = ('postexit', $extra) if defined $type && defined $num && $type eq 'post' && $num eq 'exit';

            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n"
                unless $type =~ m/^(event|postexit)$/;

            $headers{timeout}->{$type} = $num;
        }
        elsif ($dir eq 'job' && $rest =~ m/slots(?:\s+(\d+)(?:\s+(\d+))?)?$/i) {
            $headers{min_slots} //= $1 // 1;
            $headers{max_slots} //= $2 ? $2 : -1;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    $self->{+_HEADERS} = \%headers;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    my $shbang_re = qr{
        ^
          \#!.*perl.*?           # the perl path
          (?: \s (-.+) )?        # the switches, maybe
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

my %RANK = (
    smoke      => 1,
    immiscible => 10,
    long       => 20,
    medium     => 50,
    short      => 80,
    isolation  => 100,
);

sub rank {
    my $self = shift;

    return $RANK{smoke} if $self->check_feature('smoke');

    my $rank = $RANK{$self->check_category};
    $rank ||= $RANK{$self->check_duration};
    $rank ||= 1;

    return $rank;
}

sub TO_JSON {
    my $self = shift;
    return {%$self};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TestFile - Represents a test file with HARNESS directive metadata

=head1 DESCRIPTION

Encapsulates a test file path and lazily scans the file for HARNESS-*
directives in comments. Used by the scheduler and harness to determine
test metadata such as duration, category, stage, retry settings, and more.

=head1 SYNOPSIS

    use Test2::Harness2::TestFile;

    my $tf = Test2::Harness2::TestFile->new(file => 't/foo.t');

    # Scheduling metadata
    my $duration = $tf->check_duration;  # 'short', 'medium', 'long'
    my $category = $tf->check_category;  # 'general', 'isolation', etc.
    my $rank     = $tf->rank;            # numeric scheduling priority

    # All parsed headers
    my $headers = $tf->headers;

=head1 HARNESS DIRECTIVES

The following directives are supported in test file comments:

=over 4

=item HARNESS-DURATION <short|medium|long>

=item HARNESS-CATEGORY <name>

=item HARNESS-STAGE <name>

=item HARNESS-SMOKE

=item HARNESS-RETRY [N] [iso]

=item HARNESS-NO-TIMEOUT

=item HARNESS-CONFLICTS <name>

=item HARNESS-TIMEOUT EVENT|POSTEXIT <seconds>

=item HARNESS-JOB-SLOTS [min [max]]

=item HARNESS-META <key> <value>

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
