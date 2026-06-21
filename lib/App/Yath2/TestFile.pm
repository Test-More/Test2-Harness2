package App::Yath2::TestFile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Time::HiRes qw/time/;

use List::Util 1.45 qw/uniq/;

use Test2::Harness2::Util qw/open_file clean_path/;

use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::TestFile();

use File::Spec;

use Test2::Harness2::Util::HashBase qw{
    <file +relative <_scanned <_headers +_shbang <is_binary <non_perl
    input env_vars test_args
    queue_args
    job_class
    comment
    _category _stage _duration _min_slots _max_slots
    _no_preload _require_preload _preload_list
};

sub set_duration ($self, $val) { $self->set__duration(lc($val)) }
sub set_category ($self, $val) { $self->set__category(lc($val)) }

sub set_stage     ($self, $val) { $self->set__stage($val) }
sub set_min_slots ($self, $val) { $self->set__min_slots($val) }
sub set_max_slots ($self, $val) { $self->set__max_slots($val) }

sub set_no_preload      ($self, $val = 1) { $self->set__no_preload($val      ? 1 : 0) }
sub set_require_preload ($self, $val = 1) { $self->set__require_preload($val ? 1 : 0) }
sub set_preload_list    ($self, $list) { $self->set__preload_list([@$list]) }

sub retry ($self) { $self->headers->{retry} }
sub set_retry ($self, $val = 1) {
    $self->scan;

    $self->{+_HEADERS}->{retry} = $val;
}

sub retry_isolated ($self) { $self->headers->{retry_isolated} }
sub set_retry_isolated ($self, $val = 1) {
    $self->scan;

    $self->{+_HEADERS}->{retry_isolated} = $val;
}

sub set_smoke ($self, $val = 1) {
    $self->scan;

    $self->{+_HEADERS}->{features}->{smoke} = $val;
}

sub init ($self) {
    my $file = $self->file;

    # We want absolute path
    $file = clean_path($file, 0);
    $self->{+FILE} = $file;

    $self->{+QUEUE_ARGS} ||= [];

    croak "Invalid test file '$file'" unless -f $file;

    if($self->{+IS_BINARY} = -B $file && !-z $file) {
        $self->{+NON_PERL} = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }
}

sub relative ($self) {
    return $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});
}

my %DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    run       => 1,
    isolation => 0,
    smoke     => 0,
    io_events => 1,
);

sub check_feature ($self, $feature, $default = undef) {
    $default = $DEFAULTS{$feature} unless defined $default;

    return $default unless defined $self->headers->{features}->{$feature};
    return 1 if $self->headers->{features}->{$feature};
    return 0;
}

sub check_stage ($self) {
    return $self->{+_STAGE} if $self->{+_STAGE};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{stage} || undef;
}

sub check_no_preload ($self) {
    return $self->{+_NO_PRELOAD} if defined $self->{+_NO_PRELOAD};

    # '# HARNESS-NO-PRELOAD' parses through the generic NO-<feature> handler
    # into features.preload=0; map that to the no_preload field.
    return $self->check_feature(preload => 1) ? 0 : 1;
}

sub check_require_preload ($self) {
    return $self->{+_REQUIRE_PRELOAD} if defined $self->{+_REQUIRE_PRELOAD};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{require_preload} ? 1 : 0;
}

sub check_preload_list ($self) {
    return [@{$self->{+_PRELOAD_LIST}}] if $self->{+_PRELOAD_LIST};

    $self->_scan unless $self->{+_SCANNED};
    my $list = $self->{+_HEADERS}->{preload_list} or return [];
    return [@$list];
}

sub check_min_slots ($self) {
    return $self->{+_MIN_SLOTS} if $self->{+_MIN_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{min_slots} // undef;
}

sub check_max_slots ($self) {
    return $self->{+_MAX_SLOTS} if $self->{+_MAX_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{max_slots} // undef;
}

sub meta ($self, $key = undef) {
    $self->_scan unless $self->{+_SCANNED};
    my $meta = $self->{+_HEADERS}->{meta} or return ();

    return () unless $key && $meta->{$key};

    return @{$meta->{$key}};
}

sub check_duration ($self) {
    return $self->{+_DURATION} if $self->{+_DURATION};

    $self->_scan unless $self->{+_SCANNED};
    my $duration = $self->{+_HEADERS}->{duration};
    return $duration if $duration;

    my $timeout = $self->check_feature(timeout => 1);

    # 'long' for anything with no timeout
    return 'long' unless $timeout;

    return 'medium';
}

sub check_category ($self) {
    return $self->{+_CATEGORY} if $self->{+_CATEGORY};

    $self->_scan unless $self->{+_SCANNED};
    my $category = $self->{+_HEADERS}->{category};

    return $category if $category;

    my $isolate = $self->check_feature(isolation => 0);

    # 'isolation' queue if isolation requested
    return 'isolation' if $isolate;

    return 'general';
}

sub validate_preload ($self) {
    my $no_preload      = $self->check_no_preload      ? 1 : 0;
    my $require_preload = $self->check_require_preload ? 1 : 0;
    my $preload_list    = $self->check_preload_list;

    if ($no_preload && ($require_preload || @$preload_list)) {
        croak "Test '$self->{+FILE}' cannot combine a no-preload directive with a preload stage requirement or list (no_preload requires require_preload off and an empty preload_list).";
    }

    return ($no_preload, $require_preload, $preload_list);
}

sub event_timeout     ($self) { $self->headers->{timeout}->{event} }
sub post_exit_timeout ($self) { $self->headers->{timeout}->{postexit} }

sub conflicts_list ($self) {
    return $self->headers->{conflicts} || [];    # Assure conflicts is always an array ref.
}

sub headers ($self) {
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_HEADERS};
    return {%{$self->{+_HEADERS}}};
}

sub shbang ($self) {
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_SHBANG};
    return {%{$self->{+_SHBANG}}};
}

sub switches ($self) {
    my $shbang   = $self->shbang       or return [];
    my $switches = $shbang->{switches} or return [];

    return $switches;
}

sub is_executable ($self, $file = undef) {
    $file //= $self->{+FILE};
    return -x $file;
}

sub scan ($self) {
    $self->_scan();
    return;
}

sub _scan ($self) {
    return if $self->{+_SCANNED}++;
    return if $self->{+IS_BINARY};

    my $fh = open_file($self->{+FILE});
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
            @args = split /\s+/, $rest, 2;                              # Check for white space delimited
            @args = split(/[-]+/, $rest, 2) if scalar @args == 1;       # Check for dash delimited
            $args[1] =~ s/\s+(?:#.*)?$// if defined $args[1];             # Strip trailing white space and comment if present
        }
        elsif ($rest) {
            $rest =~ s/\s+(?:#.*)?$//;                                  # Strip trailing white space and comment if present
            @args = split /[-\s]+/, $rest;
        }

        if ($dir eq 'no') {
            my $feature = lc(join '_' => @args);
            if ($feature eq 'retry') {
                $headers{retry} = 0
            } else {
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
            my @list = @args;

            # 'REQUIRE' is a reserved leading keyword: it marks the listed
            # stages as mandatory (no fallback) rather than advisory.
            # See ARCHITECTURE.md §4.7a "Directive syntax note".
            if (@list && uc($list[0]) eq 'REQUIRE') {
                shift @list;
                $headers{require_preload} = 1;
            }

            $headers{preload_list} = [@list];

            # Keep the legacy single-stage header populated for back-compat.
            $headers{stage} = $list[0];
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
            $num = lc($num);

            ($type, $num) = ('postexit', $extra) if $type eq 'post' && $num eq 'exit';

            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n"
                unless $type =~ m/^(event|postexit)$/;

            $headers{timeout}->{$type} = $num;
        }
        elsif ($dir eq 'job' && $rest =~ m/slots\s+(\d+)(?:\s+(\d+))?$/i) {
            $headers{min_slots} //= $1;
            $headers{max_slots} //= $2 ? $2 : $1;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    $self->{+_HEADERS} = \%headers;
}

sub _parse_shbang ($self, $line) {
    return {} if !defined $line;

    my %shbang;

    # NOTE: Test this, the dashes should be included with the switches
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?       # the switches, maybe
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

sub queue_item ($self, $job_name = undef, $run_id = undef, %inject) {
    die "The '$self->{+FILE}' test specifies that it should not be run by Test2::Harness2.\n"
        unless $self->check_feature(run => 1);

    my $category  = $self->check_category;
    my $duration  = $self->check_duration;
    my $stage     = $self->check_stage;
    my $min_slots = $self->check_min_slots;
    my $max_slots = $self->check_max_slots;

    my ($no_preload, $require_preload, $preload_list) = $self->validate_preload;

    # The runner still reads the legacy single-stage 'stage' field until the
    # consumer side migrates to the three preload fields, so a plugin that set
    # only the list still routes.
    $stage //= $preload_list->[0];

    my $smoke     = $self->check_feature(smoke     => 0);
    my $fork      = $self->check_feature(fork      => 1);
    my $preload   = $self->check_feature(preload   => 1);
    my $timeout   = $self->check_feature(timeout   => 1);
    my $stream    = $self->check_feature(stream    => 1);
    my $io_events = $self->check_feature(io_events => 1);

    my $binary   = $self->{+IS_BINARY} ? 1 : 0;
    my $non_perl = $self->{+NON_PERL}  ? 1 : 0;

    # The inject env_vars is consumed (merged over the file's env_vars) only
    # when the file declares env_vars; otherwise it passes through %inject.
    my $env_mix = $self->env_vars ? delete $inject{env_vars} : undef;

    my %optional = $self->_optional_task_fields($env_mix, $min_slots, $max_slots);

    return {
        binary          => $binary,
        category        => $category,
        conflicts       => $self->conflicts_list,
        duration        => $duration,
        file            => $self->file,
        rel_file        => $self->relative,
        job_id          => gen_uuid(),
        job_name        => $job_name,
        run_id          => $run_id,
        non_perl        => $non_perl,
        stage           => $stage,
        no_preload      => $no_preload,
        require_preload => $require_preload,
        preload_list    => $preload_list,
        stamp           => time,
        switches        => $self->switches,
        use_fork        => $fork,
        use_preload     => $preload,
        use_stream      => $stream,
        use_timeout     => $timeout,
        smoke           => $smoke,
        io_events       => $io_events,
        rank            => $self->rank,

        %optional,

        @{$self->{+QUEUE_ARGS}},

        %inject,
    };
}

sub _optional_task_fields ($self, $env_mix, $min_slots, $max_slots) {
    my $env_vars = $self->env_vars;
    $env_vars = {%$env_mix, %$env_vars} if $env_vars && $env_mix;

    my %optional = (
        input             => $self->input,
        env_vars          => $env_vars,
        test_args         => $self->test_args,
        job_class         => $self->job_class,
        retry             => $self->retry,
        retry_isolated    => $self->retry_isolated,
        event_timeout     => $self->event_timeout,
        post_exit_timeout => $self->post_exit_timeout,
        min_slots         => $min_slots,
        max_slots         => $max_slots,
    );

    delete @optional{grep { !defined $optional{$_} } keys %optional};
    return %optional;
}

my %RANK = (
    smoke      => 1,
    immiscible => 10,
    long       => 20,
    medium     => 50,
    short      => 80,
    isolation  => 100,
);

sub rank ($self) {
    return $RANK{smoke} if $self->check_feature('smoke');

    my $rank = $RANK{$self->check_category};
    $rank ||= $RANK{$self->check_duration};
    $rank ||= 1;

    return $rank;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::TestFile - Reader that scans a test file for its meta-data.

=head1 DESCRIPTION

When yath finds test files to run each one gets an instance of this class to
represent it. This class will scan test files to find important meta data
(binary vs script, inline harness directives, etc). The meta-data this class
can find helps yath decide when and how to run the test.

Reading and scanning test files is an input/user-interface concern, so this
reader lives in C<App::Yath2>. The runner-side, file-free state representation
of a queued test is L<Test2::Harness2::TestFile>, built from the task payload
this class produces via C<queue_item()>.

If you write a custom L<App::Yath2::Finder> or use some
L<App::Yath2::Plugin> callbacks you may have to use, or even construct
instances of this class.

=head1 SYNOPSIS

    use App::Yath2::TestFile;

    my $tf = App::Yath2::TestFile->new(file => "path/to/file.t");

    # For an example 1, 1 works, but normally they are job_name and run_id.
    my $meta_data = $tf->queue_item(1, 1);


=head1 ATTRIBUTES

=over 4

=item $filename = $tf->file

Set during object construction, and cannot be changed.

=item $bool = $tf->is_binary

Automatically set during construction, cannot be changed or set manually.

=item $bool = $tf->non_perl

Automatically set during construction, cannot be changed or set manually.

=item $string = $tf->comment

=item $tf->set_comment($string)

Defaults to '#' can be set during construction, or changed if needed.

This is used to tell yath what character(s) are used to denote a comment. This
is necessary for finding harness directives. In perl the '#' character is used,
and that is the default value. This is here to support non-perl tests.

=item $class = $tf->job_class

=item $tf->set_job_class($class)

Default it undef (let the runner pick). You can change this if you want the
test to run with a custom job subclass.

=item $arrayref = $tf->queue_args

=item $tf->set_queue_args(\@ARGS)

Key/Value pairs to append to the queue_item() data.

=back

=head1 METHODS

=over 4

=item $cat = $tf->check_category()

=item $tf->set_category($cat)

This is how you find the category for a file. You can use C<set_category()> to
assign/override a category.

=item $dur = $tf->check_duration()

=item $tf->set_duration($dur)

Get the duration of the test file ('LONG', 'MEDIUM', 'SHORT'). You can override
with C<set_duration()>.

=item $stage = $tf->check_stage()

=item $tf->set_stage($stage)

Get the preload stage the test file thinks it should be run in. You can
override with C<set_stage()>. This is the legacy single-stage value; the
ordered preference list is C<check_preload_list()>.

=item $bool = $tf->check_no_preload()

=item $tf->set_no_preload($bool)

True when the test cannot run under a preload (C<# HARNESS-NO-PRELOAD>). A
plugin may set or clear this during C<munge_files>.

=item $bool = $tf->check_require_preload()

=item $tf->set_require_preload($bool)

True when the listed preload stages are mandatory with no fallback
(C<# HARNESS-STAGE-REQUIRE A B C>).

=item $arrayref = $tf->check_preload_list()

=item $tf->set_preload_list(\@stages)

The ordered list of preferred preload stages (C<# HARNESS-STAGE A B C>). A
single C<# HARNESS-STAGE Foo> yields a one-element list. Empty means the
default stage.

=item ($no_preload, $require_preload, $preload_list) = $tf->validate_preload()

Resolve the three preload fields (directives, with plugin overrides applied)
and enforce the rule that C<no_preload> implies C<require_preload> off and an
empty C<preload_list>. Croaks on a conflicting combination. Called by
C<queue_item()>.

=item $bool = $tf->check_feature($name)

This checks for the C<# HARNESS-NO-NAME> or C<# HARNESS-USE-NAME> or
C<# HARNESS-YES-NAME> directives. C<NO> will result in a false boolean. C<YES>
and C<USE> will result in a ture boolean. If no directive is found then
C<undef> will be returned.

=item $arrayref = $tf->conflicts_list()

Get a list of conflict markers.

=item $seconds = $tf->event_timeout()

If they test specifies an event timeout this will return it.

=item %headers = $tf->headers()

This returns the header data from the test file.

=item $bool = $tf->is_executable()

Check if the test file is executable or not.

=item $data = $tf->meta($key)

Get the meta-data for the specific key.

=item $seconds = $tf->post_exit_timeout()

If the test file has a custom post-exit timeout, this will return it.

=item $hashref = $tf->queue_item($job_name, $run_id)

This returns the data used to add the test file to the runner queue. This is the
serialized, file-free state carried in the task payload; the runner rebuilds it
as a L<Test2::Harness2::TestFile> via C<from_task()> without re-reading the file.

=item $int = $tf->rank()

Returns an integer value used to sort tests into an efficient run order.

=item $path = $tf->relative()

Relative path to the test file.

=item $tf->scan()

Scan the file and populate the header data. Return nothing, takes no arguments.
Automatically run by things that require the scan data. Results are cached.

=item $tf->set_smoke($bool)

Set smoke status. Smoke tests go to the front of the line when tests are
sorted.

=item $hashref = $tf->shbang()

Get data gathered from parsing the tests shbang line.

=item $arrayref = $tf->switches()

A list of switches passed to perl, usually from the shbang line.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
