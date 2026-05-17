package App::Yath2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Spec ();
use List::Util qw/any uniq/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/open_file clean_path/;
use Test2::Harness2::Util::Directives ();
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    +_scanned +_shbang
    <input <env_vars <test_args <job_class <queue_args
    &Test2::Harness2::Role::TestFile
};

# {{{ Construction

sub init {
    my $self = shift;

    # Accept a `file` argument for convenience; derive absolute + relative
    # from it and then discard the value (the slot no longer exists).
    my $file = delete $self->{file};

    # If neither absolute nor file was given there is nothing to work with.
    $file //= $self->{+ABSOLUTE} // $self->{+RELATIVE};
    croak "'file' (or 'absolute') is a required attribute"
        unless defined $file && length $file;

    # Canonicalize the path before storing so a later chdir does not
    # redirect the launch. clean_path returns an absolute, normalized
    # form. Mirrors reference/legacy/.../TestFile.pm:67-71.
    $file = clean_path($file, 0);

    croak "Invalid test file '$file'" unless -f $file;

    $self->{+ABSOLUTE} //= File::Spec->rel2abs($file);
    $self->{+RELATIVE} //= File::Spec->abs2rel($file);

    # is_binary classification needs to share a stat cache with the -f
    # check above. -B _ uses the cached stat from the most recent
    # filesystem test (the croak's -f leaves _ populated for us). The
    # is_executable check that follows derives from $self->{+ABSOLUTE},
    # which we just set above.
    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }

    $self->{+QUEUE_ARGS} //= [];

    # Seed every role default into the corresponding HashBase slot so
    # the slot reader returns the documented default instead of undef
    # when the caller does not supply one. defaults() builds fresh
    # sub-containers per call so each instance has its own arrayref /
    # hashref.
    my $defaults = $self->defaults;
    for my $k (keys %$defaults) {
        $self->{$k} //= $defaults->{$k};
    }
}

# }}} Construction

# {{{ Mutators
#
# Mirrors the legacy / old2 setter surface so finders, plugins, and
# CLI overrides can adjust scan results before queueing. Each mutator
# scans first (so the override is applied to fully-populated data)
# then writes the new value into the corresponding HashBase slot.

sub set_duration  { $_[0]->scan; $_[0]->{+DURATION}  = lc($_[1]) }
sub set_category  { $_[0]->scan; $_[0]->{+CATEGORY}  = lc($_[1]) }
sub set_stage     { $_[0]->scan; $_[0]->{+STAGE}     = $_[1] }
sub set_min_slots { $_[0]->scan; $_[0]->{+MIN_SLOTS} = $_[1] }
sub set_max_slots { $_[0]->scan; $_[0]->{+MAX_SLOTS} = $_[1] }

sub set_input      { $_[0]->{+INPUT}      = $_[1] }
sub set_env_vars   { $_[0]->{+ENV_VARS}   = $_[1] }
sub set_test_args  { $_[0]->{+TEST_ARGS}  = $_[1] }
sub set_job_class  { $_[0]->{+JOB_CLASS}  = $_[1] }
sub set_queue_args { $_[0]->{+QUEUE_ARGS} = $_[1] }

sub set_retry {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+RETRY} = $val;
}

sub set_retry_isolated {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+RETRY_ISOLATED} = $val;
}

sub set_smoke {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+FEATURES}{smoke} = $val;
}

# }}} Mutators

# {{{ check_feature override
#
# The role's check_feature is a pure data lookup. The scanner-aware
# override here adds a safety net: fork/preload need a perl interpreter
# and only switches that fork-safe perl can honor (-w). Mirrors the
# legacy / old2 logic that was previously baked into test_settings;
# current 2.0 hoisted it into check_feature.

sub check_feature {
    my ($self, $feature, $default) = @_;
    $self->scan;

    if (defined $feature && ($feature eq 'fork' || $feature eq 'preload')) {
        return 0 if $self->{+NON_PERL} || $self->{+IS_BINARY};
        return 0 if any { $_ !~ m/^-w$/ } @{$self->{+SWITCHES} || []};
    }

    # Defer to the role's pure-data lookup for the actual answer.
    return $self->Test2::Harness2::Role::TestFile::check_feature($feature, $default);
}

# Scanner-aware classifiers that mirror the legacy fallbacks (long
# duration when timeouts are off, isolation category when the
# isolation feature is set).

sub check_duration {
    my $self = shift;
    $self->scan;
    return $self->{+DURATION} if defined $self->{+DURATION};
    return 'long' unless $self->check_feature('timeout');
    return 'medium';
}

sub check_category {
    my $self = shift;
    $self->scan;
    return $self->{+CATEGORY} if defined $self->{+CATEGORY};
    return 'isolation'        if $self->check_feature('isolation');
    return 'general';
}

sub check_stage     { $_[0]->scan; $_[0]->{+STAGE} }
sub check_min_slots { $_[0]->scan; $_[0]->{+MIN_SLOTS} }
sub check_max_slots { $_[0]->scan; $_[0]->{+MAX_SLOTS} }

# }}} check_feature override

# {{{ Auto-scanning data accessors
#
# Override the role's scanned-data accessors to trigger scan() on
# first read, mirroring legacy / old2 lazy-scan semantics. Plain
# attribute slots (file, comment, env_vars, etc.) do not auto-scan;
# only the slots populated by the directive parser do.

sub meta {
    my $self = shift;
    $self->scan;
    return $self->{+META};
}

sub meta_get {
    my ($self, $key) = @_;
    $self->scan;
    my $hash = $self->{+META} // {};
    return () unless defined $key && $hash->{$key};
    return @{$hash->{$key}};
}

sub conflicts {
    my $self = shift;
    $self->scan;
    return $self->{+CONFLICTS};
}

sub features {
    my $self = shift;
    $self->scan;
    return $self->{+FEATURES};
}

sub switches {
    my $self = shift;
    $self->scan;
    return $self->{+SWITCHES};
}

sub retry             { $_[0]->scan; $_[0]->{+RETRY} }
sub retry_isolated    { $_[0]->scan; $_[0]->{+RETRY_ISOLATED} }
sub event_timeout     { $_[0]->scan; $_[0]->{+EVENT_TIMEOUT} }
sub post_exit_timeout { $_[0]->scan; $_[0]->{+POST_EXIT_TIMEOUT} }
sub non_perl          { $_[0]->scan; $_[0]->{+NON_PERL} }
sub is_binary         { $_[0]->scan; $_[0]->{+IS_BINARY} }
sub category          { $_[0]->scan; $_[0]->{+CATEGORY} }
sub duration          { $_[0]->scan; $_[0]->{+DURATION} }
sub stage             { $_[0]->scan; $_[0]->{+STAGE} }
sub min_slots         { $_[0]->scan; $_[0]->{+MIN_SLOTS} }
sub max_slots         { $_[0]->scan; $_[0]->{+MAX_SLOTS} }

sub preload_preferences {
    my $self = shift;
    $self->scan;
    return $self->{+PRELOAD_PREFERENCES} //= ['<default>'];
}

# }}} Auto-scanning data accessors

# {{{ Scanning

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

    my $comment = $self->comment // '#';

    my $parser = Test2::Harness2::Util::Directives->new(comments => [$comment]);
    my $directives_seen;

    my $fh = open_file($self->{+ABSOLUTE});
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang && %$shbang) {
                $self->{+_SHBANG}  = $shbang;
                $self->{+SWITCHES} = $shbang->{switches} if $shbang->{switches};
                $self->{+NON_PERL} = 1                   if $shbang->{non_perl};
                next;
            }
        }

        next if $line =~ m/^\s*$/;

        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $self->{+FEATURES}{run} = 0;
            next;
        }

        if ($line =~ m/^\s*\Q$comment\E\s*HARNESS2:/) {
            my $ok = eval { $parser->parse_line($line); 1 };
            unless ($ok) {
                my $err = $@;
                warn "Bad HARNESS2 directive at $self->{+ABSOLUTE} line $ln: $err";
                last;
            }
            $directives_seen = 1;
            next;
        }

        next if $line =~ m/^\s*\Q$comment\E/;
        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;
        last;
    }

    return unless $directives_seen;

    my $dirs;
    my $ok = eval { $dirs = $parser->finish; 1 };
    unless ($ok) {
        warn "HARNESS2 parser failure in $self->{+ABSOLUTE}: $@";
        return;
    }

    $self->_apply_directives($dirs);
    return;
}

# Map the Directives parser output hash into TestFile slots.
sub _apply_directives {
    my ($self, $dirs) = @_;

    if (my $list = $dirs->{slots}) {
        my ($min, $max) = @$list;
        $self->{+MIN_SLOTS} = $min if defined $min;
        $self->{+MAX_SLOTS} = defined($max) ? $max : $min;
    }

    if (my $list = $dirs->{duration}) {
        $self->{+DURATION} = lc($list->[0]) if defined $list->[0];
    }

    if (my $list = $dirs->{category}) {
        my $val = lc($list->[0] // '');
        if ($val =~ m/^(?:long|medium|short)$/) {
            $self->{+DURATION} = $val;
        }
        elsif (length $val) {
            $self->{+CATEGORY} = $val;
        }
    }

    if (my $list = $dirs->{stage}) {
        $self->{+STAGE} = $list->[0] if defined $list->[0];
    }

    if (my $list = $dirs->{conflicts}) {
        my @prev = @{$self->{+CONFLICTS} || []};
        push @prev, map { lc $_ } @$list;
        $self->{+CONFLICTS} = [uniq @prev];
    }

    if (my $list = $dirs->{preload}) {
        $self->{+PRELOAD_PREFERENCES} = _xlate_preload_list($list);
    }

    if (my $feat = $dirs->{feature}) {
        for my $name (keys %$feat) {
            my $v = $feat->{$name}->[-1];
            my $key = $name;
            $key =~ tr/-/_/;
            $self->{+FEATURES}{$key} = $v ? 1 : 0;
        }
    }

    if (my $tt = $dirs->{timeout}) {
        if (my $list = $tt->{event}) {
            $self->{+EVENT_TIMEOUT} = $list->[-1];
        }
        if (my $list = $tt->{postexit}) {
            $self->{+POST_EXIT_TIMEOUT} = $list->[-1];
        }
    }

    if (my $rt = $dirs->{retry}) {
        if (defined(my $count = ($rt->{count} // [])->[-1])) {
            $self->{+RETRY} = int $count;
        }
        if (defined(my $iso = ($rt->{isolated} // [])->[-1])) {
            $self->{+RETRY}          ||= 1 if $iso;
            $self->{+RETRY_ISOLATED} = $iso ? 1 : 0;
        }
    }

    if (my $meta = $dirs->{meta}) {
        for my $k (keys %$meta) {
            push @{$self->{+META}{lc $k}}, @{$meta->{$k}};
        }
    }

    return;
}

# Translate the Directives parser's preload value list into the
# internal preference list used by the harness resolver. Token
# rules:
#   - 'default' (from @default expansion) -> '<default>'
#   - 0         (from @off/@no/@false)    -> '<no>'
#   - any other string                    -> passthrough
# Then drop a trailing '<no>' immediately after '<default>' (the
# '<default>' token already implies the same fallback).
sub _xlate_preload_list {
    my ($arr) = @_;
    my @out;
    for my $v (@$arr) {
        if (defined($v) && !ref($v) && $v eq 'default') {
            push @out, '<default>';
        }
        elsif (defined($v) && !ref($v) && $v eq '0') {
            push @out, '<no>';
        }
        else {
            push @out, $v;
        }
    }
    pop @out
        if @out >= 2 && $out[-1] eq '<no>' && $out[-2] eq '<default>';
    return \@out;
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

# }}} Scanning

# {{{ Queue payload (queue_item)
#
# The yath-side equivalent of legacy's queue_item / old2's
# test_settings. Produces the runner-queue payload: classifiers,
# feature toggles, retry policy, env/input/test_args overrides, plus
# a fresh job_id (gen_uuid). Mirrors reference/legacy/.../TestFile.pm
# queue_item; env_vars merge order is preserved as-is (caller's env
# wins except where the test file defines the same key).

sub queue_item {
    my $self = shift;
    my ($job_name, $run_id, %inject) = @_;

    die "The '$self->{+ABSOLUTE}' test specifies that it should not be run by Test2::Harness.\n"
        unless $self->check_feature(run => 1);

    my $features = $self->_queue_item_features;
    my $env_vars = $self->_queue_item_merge_env(\%inject);

    return {
        binary    => $self->{+IS_BINARY} ? 1 : 0,
        category  => $self->check_category,
        conflicts => [$self->conflicts_list],
        duration  => $self->check_duration,
        file      => $self->absolute,
        rel_file  => $self->relative,
        job_id    => gen_uuid(),
        job_name  => $job_name,
        run_id    => $run_id,
        non_perl  => $self->{+NON_PERL}  ? 1 : 0,
        stage     => $self->check_stage,
        stamp     => time,
        switches  => $self->switches,

        use_fork    => $features->{fork},
        use_preload => $features->{preload},
        use_stream  => $features->{stream},
        use_timeout => $features->{timeout},

        smoke     => $features->{smoke},
        io_events => $features->{io_events},
        rank      => $self->rank,

        $self->_queue_item_optional_fields($env_vars),

        @{$self->{+QUEUE_ARGS}},

        %inject,
    };
}

# Collect the feature toggle defaults consumed by queue_item.
sub _queue_item_features {
    my $self = shift;
    return {
        smoke     => $self->check_feature(smoke     => 0),
        fork      => $self->check_feature(fork      => 1),
        preload   => $self->check_feature(preload   => 1),
        timeout   => $self->check_feature(timeout   => 1),
        stream    => $self->check_feature(stream    => 1),
        io_events => $self->check_feature(io_events => 1),
    };
}

# env_vars merge: caller's $inject{env_vars} provides the base,
# the test file's env_vars layered on top. The test file wins for
# any key it defines; everything else from the caller passes
# through. Mirrors reference/legacy/.../TestFile.pm:435-439 --
# keep this ordering as-is (Pitfall #10).
sub _queue_item_merge_env {
    my $self = shift;
    my ($inject) = @_;

    my $env_vars = $self->{+ENV_VARS};
    if ($env_vars) {
        my $mix = delete $inject->{env_vars};
        $env_vars = {%$mix, %$env_vars} if $mix;
    }
    return $env_vars;
}

# Build the variable-presence tail of the queue payload (fields only
# emitted when their value is defined).
sub _queue_item_optional_fields {
    my $self = shift;
    my ($env_vars) = @_;

    my $retry          = $self->retry;
    my $retry_isolated = $self->retry_isolated;
    my $et             = $self->event_timeout;
    my $pet            = $self->post_exit_timeout;
    my $min_slots      = $self->check_min_slots;
    my $max_slots      = $self->check_max_slots;
    my $job_class      = $self->{+JOB_CLASS};
    my $input          = $self->{+INPUT};
    my $test_args      = $self->{+TEST_ARGS};

    return (
        defined($input)          ? (input             => $input)          : (),
        defined($env_vars)       ? (env_vars          => $env_vars)       : (),
        defined($test_args)      ? (test_args         => $test_args)      : (),
        defined($job_class)      ? (job_class         => $job_class)      : (),
        defined($retry)          ? (retry             => $retry)          : (),
        defined($retry_isolated) ? (retry_isolated    => $retry_isolated) : (),
        defined($et)             ? (event_timeout     => $et)             : (),
        defined($pet)            ? (post_exit_timeout => $pet)            : (),
        defined($min_slots)      ? (min_slots         => $min_slots)      : (),
        defined($max_slots)      ? (max_slots         => $max_slots)      : (),
    );
}

# }}} Queue payload (queue_item)

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::TestFile - Yath-side, scanner-aware TestFile producer.

=head1 DESCRIPTION

C<App::Yath2::TestFile> is the producer-side TestFile object: it
scans the file's shebang and C<HARNESS2:> directives, applies CLI
overrides through a setter surface, and builds the runner-queue
payload. Yath constructs these instances at finder / queue time.
After scanning + override, instances are typically serialized to a
hashref via the role's L<TO_JSON|Test2::Harness2::Role::TestFile/TO_JSON>
and shipped to the harness, which rehydrates a static
L<Test2::Harness2::TestFile> on the receiving side.

The harness library does not depend on this class; it knows only
the role contract.

=head1 SYNOPSIS

    use App::Yath2::TestFile;

    my $tf = App::Yath2::TestFile->new(file => 't/foo.t');

    $tf->set_duration('short');           # CLI override
    $tf->set_retry(3);                    # CLI override

    my $payload = $tf->queue_item(undef, $run_id);

    # ... or hand off via TO_JSON for a serialized harness queue
    my $hash = $tf->TO_JSON;

=head1 ATTRIBUTES

In addition to every attribute documented on
L<Test2::Harness2::Role::TestFile/ATTRIBUTES>, this class carries
queue-time data that the harness itself never needs to see:

=over 4

=item input

Stdin to feed the test process.

=item env_vars

Hashref of extra environment variables for the test process. Merged
with caller-supplied env at C<queue_item> time; the test file wins
for any key it defines.

=item test_args

Arguments to pass to the test script after C<-->.

=item job_class

Alternate Job subclass for the runner.

=item queue_args

Arrayref of extra key/value pairs spliced into the queue payload.

=back

=head1 METHODS

=over 4

=item $tf->scan

Read the shebang and C<HARNESS2:> directives from the file. Idempotent;
results are cached.

=item $tf->set_duration($dur)

=item $tf->set_category($cat)

=item $tf->set_stage($stage)

=item $tf->set_min_slots($n)

=item $tf->set_max_slots($n)

=item $tf->set_retry($n?)

=item $tf->set_retry_isolated($bool?)

=item $tf->set_smoke($bool?)

CLI / plugin override hooks. Each calls C<scan> first (so the
override is applied to fully-populated data) then writes the new
value into the corresponding slot. C<set_retry>, C<set_retry_isolated>,
and C<set_smoke> default to C<1> when called with no argument.

=item $tf->set_input($val)

=item $tf->set_env_vars($hashref)

=item $tf->set_test_args($arrayref)

=item $tf->set_job_class($class)

=item $tf->set_queue_args($arrayref)

Plain setters for the queue-time slots; no scan side effect (these
do not influence directive parsing).

=item $hashref = $tf->queue_item($job_name, $run_id, %inject)

Build the runner-queue payload. Mints a fresh C<job_id> via
C<Test2::Util::UUID::gen_uuid>; merges caller-supplied env with the
test file's env (test file wins per key); splices in C<queue_args>
and C<%inject>. Dies if the test file's C<run> feature is set to a
falsy value.

=item $arrayref = $tf->preload_preferences

Scanner-aware accessor for the file's preload preference list. Calls
C<scan> first; returns C<['<default>']> when no preference was
declared. See L<Test2::Harness2::Role::TestFile/preload_preferences>
for the value semantics.

=back

=head2 Private helpers

=over 4

=item _apply_directives

Map the C<Test2::Harness2::Util::Directives> parser output into the
appropriate HashBase slots (slots, duration, category, stage,
conflicts, preload, feature, timeout, retry, meta).

=item _xlate_preload_list

Translate the directive parser's preload value list into the internal
preference tokens (C<'default'> -E<gt> C<'<default>'>, C<0> -E<gt>
C<'<no>'>, anything else passes through), and drop a trailing C<'<no>'>
that immediately follows C<'<default>'> (the default token already
implies the same fallback).

=item _queue_item_features

Snapshot the C<check_feature> defaults consumed by C<queue_item> into
a small hashref (smoke / fork / preload / timeout / stream / io_events).

=item _queue_item_merge_env

Merge the caller-supplied C<env_vars> base under the test file's
C<env_vars> overlay (test file wins per key); returns the resulting
hashref or undef. Removes C<env_vars> from the caller's inject hash.

=item _queue_item_optional_fields

Return the variable-presence tail of the queue payload as a flat list
of key/value pairs, emitting each entry only when its value is defined.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
