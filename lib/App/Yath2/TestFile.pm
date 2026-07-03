package App::Yath2::TestFile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Time::HiRes qw/time/;

use List::Util 1.45 qw/uniq/;

use Test2::Harness2::Util qw/open_file clean_path/;

use Test2::Harness2::Runner::Constants qw/CATEGORIES DURATIONS DURATION_MAX_SHORT DURATION_MAX_MEDIUM/;

use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::Directives();
use Test2::Harness2::Util::Directives::Legacy();

use File::Spec;

use Test2::Harness2::Util::HashBase qw{
    <file +relative <_scanned <_headers +_shbang <is_binary <non_perl
    +_directive_error
    input env_vars test_args
    queue_args
    job_class
    comment
    _category _stage _duration _min_slots _max_slots
    _no_preload _require_preload _preload_list
};

# True (the error message) when this file's in-file directives failed to parse
# (E1). Reading it forces a scan so callers do not need to scan first.
sub directive_error ($self) {
    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_DIRECTIVE_ERROR};
}

# Programmatic duration setter (durations file/URL, plugin duration_data,
# munge_files). Machine-generated timing data is naturally numeric, so a bare
# number of seconds is coerced into a scheduling label; a label is accepted
# as-is; anything else warns (naming the test) and is ignored, leaving the
# scan-derived duration untouched -- advisory scheduling data must never fail a
# job. (#118)
sub set_duration ($self, $val) {
    my $dur = $self->_coerce_duration($val);
    return unless defined $dur;
    $self->set__duration($dur);
}

sub _coerce_duration ($self, $val) {
    return undef if !defined($val) || ref($val);

    my $dur = lc($val);
    return $dur if DURATIONS->{$dur};

    if ($dur =~ m/^\d+(?:\.\d+)?$/) {
        return 'short'  if $dur < DURATION_MAX_SHORT;
        return 'medium' if $dur < DURATION_MAX_MEDIUM;
        return 'long';
    }

    warn "Invalid duration value '$val' for test '$self->{+FILE}' (expected long|medium|short or a number of seconds); ignoring.\n";
    return undef;
}

# Programmatic category setter. A category encodes concurrency-safety intent, so
# a bad value here is a plugin/code bug, not user data: croak so it attributes
# the caller rather than silently downgrading an isolation requirement. (#118)
sub set_category ($self, $val) {
    my $cat = lc($val);
    croak "'$cat' is not a valid category, must be one of: general, isolation, immiscible"
        unless CATEGORIES->{$cat};
    $self->set__category($cat);
}

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

# Safety ceiling: never scan more than this many lines looking for the header
# block. Matches the historical O(1) header scan: directives live at the top of
# a test file, so a real code line (outside an open HARNESS2 block) ends the
# scan well before this -- the ceiling is only a safeguard for a pathological
# file that is all comments / an unterminated block.
use constant HEADER_LINE_CEILING => 500;

sub _scan ($self) {
    return if $self->{+_SCANNED}++;
    return if $self->{+IS_BINARY};

    my $fh      = open_file($self->{+FILE});
    my $comment = $self->{+COMMENT} // '#';

    # Two parsers fed from one O(1) header scan. We do not yet know which to
    # honor: a file with ANY 'HARNESS2:' directive uses the new grammar and its
    # legacy 'HARNESS-' lines are ignored (silently, E2); otherwise the legacy
    # compat parser is used. Both build the SAME nested-hash representation that
    # _apply_directives consumes.
    my $new    = Test2::Harness2::Util::Directives->new(comments => [$comment]);
    my $legacy = Test2::Harness2::Util::Directives::Legacy->new(comment => $comment, file => $self->{+FILE});

    my $saw_harness2;

    my %headers;
    my $err;
    my $ok = eval {
        for (my $ln = 1; my $line = <$fh>; $ln++) {
            last if $ln > HEADER_LINE_CEILING;

            chomp($line);

            # Always feed the line to the new-grammar parser so it tracks block
            # state ('key { ... key }') across non-directive lines; non-matching
            # lines are a no-op for it.
            $new->parse_line($line);

            # Feed EVERY line to the legacy parser too (it ignores non-directive
            # lines) so its internal line_no equals the real file line -- warnings
            # from bad legacy directives then point at the right line.
            $legacy->parse_line($line);
            $saw_harness2 = 1 if $line =~ m/^\s*\Q$comment\E\s*HARNESS2:/;

            next if $line =~ m/^\s*$/;

            if ($ln == 1 && $line =~ m/^#!/) {
                # _parse_shbang always returns a hashref for a '#!' line.
                my $shbang = $self->_parse_shbang($line);
                $self->{+_SHBANG} = $shbang;
                $self->{+NON_PERL} = 1 if $shbang->{non_perl};
                next;
            }

            # Uhg, breaking encapsulation between yath and the harness
            if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
                $headers{features}->{run} = 0;
                next;
            }

            # A HARNESS2: directive line -> feed the new parser (done above).
            if ($line =~ m/^\s*\Q$comment\E\s*HARNESS2:/) {
                next;
            }

            # A legacy HARNESS- directive line (already fed to the legacy parser
            # above).
            if ($line =~ m/^\s*\Q$comment\E\s*HARNESS-.+/) {
                next;
            }

            # Plain comment lines are skipped (neither HARNESS2 nor HARNESS-).
            next if $line =~ m/^\s*#/;

            # Single-line use/require/BEGIN/package preamble is skipped.
            next if $line =~ m/^\s*(use|require|BEGIN|package)\b/;

            # The first real code line ends the header scan -- UNLESS a HARNESS2
            # block is still open (block bodies are arbitrary code spanning to
            # the matching 'key }' closer).
            last unless $new->open_block_key;
        }
        1;
    };
    $err = $@ unless $ok;

    close($fh);

    # E1: a HARNESS2 grammar error (bad quote, unterminated/mismatched block,
    # key collision, ...) is caught here, the file is marked invalid (the error
    # stored), and queueing it emits a synthetic harness-visible FAILURE rather
    # than aborting discovery / the run.
    if (!$ok) {
        $self->{+_DIRECTIVE_ERROR} = _clean_err($err);
        $self->{+_HEADERS} = {};
        return;
    }

    my $dirs;
    if ($saw_harness2) {
        $ok = eval { $dirs = $new->finish; 1 };
    }
    else {
        $ok = eval { $dirs = $legacy->finish; 1 };
    }

    unless ($ok) {
        $self->{+_DIRECTIVE_ERROR} = _clean_err($@);
        $self->{+_HEADERS} = {};
        return;
    }

    # E1: value-domain errors (an unknown category, a non-label duration) raised
    # by _apply_directives route through the SAME synthetic-FAILURE machinery a
    # grammar error already uses -- one failed job, not an aborted run. Wrapping
    # the call here (it runs outside the two _scan evals above) also contains any
    # OTHER die inside the mapper against a malformed directive subtree.
    $ok = eval { $self->_apply_directives($dirs, \%headers); 1 };
    unless ($ok) {
        $self->{+_DIRECTIVE_ERROR} = _clean_err($@);
        $self->{+_HEADERS} = {};
        return;
    }

    $self->{+_HEADERS} = \%headers;
    return;
}

# Strip Carp's trailing ' at <file> line N.' source location, keeping the
# parser's own (HARNESS2: "... at line N") message that points at the test file.
sub _clean_err ($err) {
    my $msg = "$err";
    $msg =~ s/ at \S+ line \d+\.?\s*\z//;
    chomp $msg;
    return $msg;
}

# Map the (field-agnostic) nested-hash directive output -- produced by either
# Test2::Harness2::Util::Directives (HARNESS2 grammar) or its ::Legacy compat
# (HARNESS- lines) -- onto the %headers shape the rest of this class reads via
# the check_* / queue_item accessors.
sub _apply_directives ($self, $dirs, $headers) {
    # slots: [min, max]
    if (my $list = $dirs->{slots}) {
        my ($min, $max) = @$list;
        $headers->{min_slots} //= $min          if defined $min;
        $headers->{max_slots} //= defined($max) ? $max : $min;
    }

    # duration: scheduling label. An inline directive is hand-written grammar --
    # long|medium|short only; a number there is likely a timeout confusion, so
    # reject it loudly (E1) rather than guess. (#118)
    if (my $list = $dirs->{duration}) {
        if (defined $list->[0]) {
            my $val = lc($list->[0]);
            die "'$val' is not a valid duration, must be one of: long, medium, short\n"
                unless DURATIONS->{$val};
            $headers->{duration} = $val;
        }
    }

    # category: a long|medium|short value is a duration; anything else must be a
    # real category. A category encodes concurrency-safety intent, so an unknown
    # token (e.g. '# HARNESS-CATEGORY-NETWORK') fails the job (E1) rather than
    # silently downgrading to 'general' and risking a parallel run of a
    # must-be-serialized test. (#118)
    if (my $list = $dirs->{category}) {
        my $val = lc($list->[0] // '');
        if ($val =~ m/^(?:long|medium|short)$/) {
            $headers->{duration} = $val;
        }
        elsif (length $val) {
            die "'$val' is not a valid category, must be one of: general, isolation, immiscible (did you mean a HARNESS-CONFLICTS-... directive?)\n"
                unless CATEGORIES->{$val};
            $headers->{category} = $val;
        }
    }

    # Preload: the legacy compat hands back the already-resolved
    # preload_list / require_preload / stage; the HARNESS2 grammar hands back a
    # 'preload' token list ('default'/0/<stage-names>). Honor whichever shape
    # arrived.
    if (defined(my $list = $dirs->{preload_list})) {
        $headers->{preload_list} = [@$list];
    }
    elsif (my $pl = $dirs->{preload}) {
        my @stages = grep { defined && !ref && $_ ne 'default' && $_ ne '0' } @$pl;
        $headers->{preload_list} = \@stages;
        # 'preload @off' / '... 0' -> no preload.
        $headers->{features}->{preload} = 0
            if grep { defined && !ref && $_ eq '0' } @$pl and !@stages;
    }

    if (my $rp = $dirs->{require_preload}) {
        $headers->{require_preload} = (ref($rp) eq 'ARRAY' ? $rp->[-1] : $rp) ? 1 : 0;
    }

    if (my $st = $dirs->{stage}) {
        $headers->{stage} = ref($st) eq 'ARRAY' ? $st->[0] : $st;
    }
    elsif ($headers->{preload_list} && @{$headers->{preload_list}}) {
        # Keep the legacy single-stage header populated for back-compat.
        $headers->{stage} //= $headers->{preload_list}->[0];
    }

    # conflicts: flat lowercased unique list.
    if (my $list = $dirs->{conflicts}) {
        my @prev = @{$headers->{conflicts} || []};
        push @prev, map { lc $_ } @$list;
        $headers->{conflicts} = [uniq @prev];
    }

    # features: feature.<name> subtree -> features hash (last value wins).
    if (my $feat = $dirs->{feature}) {
        if (ref($feat) eq 'HASH') {
            for my $name (keys %$feat) {
                my $key = $name;
                $key =~ tr/-/_/;
                $headers->{features}->{$key} = $feat->{$name}->[-1] ? 1 : 0;
            }
        }
    }

    # Well-known feature toggles written as bare top-level HARNESS2 keys
    # (e.g. '# HARNESS2: smoke @on', '# HARNESS2: fork @off') -- the HARNESS2
    # equivalent of the legacy 'HARNESS-SMOKE' / 'HARNESS-NO-FORK'. The legacy
    # compat parser routes these through feature.* already; here we pick up the
    # grammar's bare form.
    for my $f (qw/timeout fork preload stream run isolation smoke io_events/) {
        next unless defined(my $list = $dirs->{$f});
        next unless ref($list) eq 'ARRAY' && @$list;
        $headers->{features}->{$f} = $list->[-1] ? 1 : 0;
    }

    # timeout.event / timeout.postexit.
    if (my $tt = $dirs->{timeout}) {
        if (ref($tt) eq 'HASH') {
            $headers->{timeout}->{event}    = $tt->{event}->[-1]    if $tt->{event};
            $headers->{timeout}->{postexit} = $tt->{postexit}->[-1] if $tt->{postexit};
        }
    }

    # retry: nested (retry.count / retry.isolated) or a bare 'retry N' list.
    if (exists $dirs->{retry}) {
        my $rt = $dirs->{retry};
        if (ref($rt) eq 'HASH') {
            if (defined(my $count = ($rt->{count} // [])->[-1])) {
                $headers->{retry} = int $count;
            }
            if (($rt->{isolated} // [])->[-1]) {
                $headers->{retry} //= 1;
                $headers->{retry_isolated} = 1;
            }
        }
        elsif (ref($rt) eq 'ARRAY') {
            # Bare 'HARNESS2: retry N' -> retry count.
            if (defined(my $count = $rt->[-1])) {
                $headers->{retry} = int $count;
            }
        }
        else {
            $headers->{retry} = int($rt // 0);
        }
    }

    # meta.<key> subtree -> meta hash of arrayrefs.
    if (my $meta = $dirs->{meta}) {
        if (ref($meta) eq 'HASH') {
            for my $k (keys %$meta) {
                push @{$headers->{meta}->{lc $k}}, @{$meta->{$k}};
            }
        }
    }

    return;
}

sub _parse_shbang ($self, $line) {
    return {} if !defined $line;

    my %shbang;

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

# The always-present base task fields, shared by both queue_item() return
# paths. Centralizing the shape here means a new task field is added in one
# place, not remembered in two: an omission would otherwise ship error-queued
# tasks an incomplete shape (a missing key the runner reads as undef). The
# defaults below are the minimal/safe values used verbatim by the
# directive-error branch; the normal branch spreads these and overrides each
# field with its scanned/computed value.
sub _task_base ($self, $job_name, $run_id) {
    return (
        binary          => 0,
        non_perl        => 0,
        category        => 'general',
        duration        => 'medium',
        conflicts       => [],
        switches        => [],
        file            => $self->file,
        rel_file        => $self->relative,
        job_id          => gen_uuid(),
        job_name        => $job_name,
        run_id          => $run_id,
        stamp           => time,
        rank            => 1,
        use_fork        => 0,
        use_preload     => 0,
        use_stream      => 1,
        use_timeout     => 1,
        io_events       => 1,
        smoke           => 0,
        no_preload      => 1,
        require_preload => 0,
        preload_list    => [],
        stage           => undef,
    );
}

sub queue_item ($self, $job_name = undef, $run_id = undef, %inject) {
    # E1: a file whose in-file directives failed to parse is invalid. We still
    # queue it (discovery / the run continue), but the queued task carries a
    # directive_error so it runs as a synthetic harness-visible FAILURE (see
    # Test2::Harness2::Runner::Job::collector_target) rather than running the
    # real test with mis-parsed directives.
    $self->_scan unless $self->{+_SCANNED};
    if (defined $self->{+_DIRECTIVE_ERROR}) {
        return {
            $self->_task_base($job_name, $run_id),

            directive_error => $self->{+_DIRECTIVE_ERROR},

            @{$self->{+QUEUE_ARGS}},
            %inject,
        };
    }

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
        $self->_task_base($job_name, $run_id),

        binary          => $binary,
        non_perl        => $non_perl,
        category        => $category,
        duration        => $duration,
        conflicts       => $self->conflicts_list,
        switches        => $self->switches,
        stage           => $stage,
        no_preload      => $no_preload,
        require_preload => $require_preload,
        preload_list    => $preload_list,
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
reader lives in C<App::Yath2>. The runner consumes the raw task hash produced by
C<queue_item()> directly. L<Test2::Harness2::TestFile> is the runner-side,
file-free, state-only counterpart that can wrap that same payload, but
production code does not currently instantiate it.

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

=item $n = $tf->check_min_slots()

=item $tf->set_min_slots($n)

=item $n = $tf->check_max_slots()

=item $tf->set_max_slots($n)

The minimum and maximum number of job slots this test occupies
(C<# HARNESS-JOB-SLOTS min max>, or the HARNESS2 C<slots> directive). Like
C<set_stage()>, the setters are a plugin-facing override seam: a plugin may
assign them during C<munge_files>, and C<queue_item()> reads them back through
the C<check_*> accessors when building the task payload.

=item $n = $tf->retry()

=item $tf->set_retry($n)

=item $bool = $tf->retry_isolated()

=item $tf->set_retry_isolated($bool)

How many times a failing run of this test is retried, and whether the retry runs
in isolation (C<# HARNESS-RETRY N> / C<# HARNESS-RETRY-ISO>). These setters are a
plugin-facing override seam; the values ride along in the queued task payload.

=item ($no_preload, $require_preload, $preload_list) = $tf->validate_preload()

Resolve the three preload fields (directives, with plugin overrides applied)
and enforce the rule that C<no_preload> implies C<require_preload> off and an
empty C<preload_list>. Croaks on a conflicting combination. Called by
C<queue_item()>.

=item $bool = $tf->check_feature($name)

=item $bool = $tf->check_feature($name, $default)

Return the boolean state (C<1> or C<0>) of a named feature toggle: C<timeout>,
C<fork>, C<preload>, C<stream>, C<run>, C<isolation>, C<smoke>, or C<io_events>.
The feature is read from the file's directives -- either the legacy
C<# HARNESS-NO-NAME> / C<# HARNESS-USE-NAME> / C<# HARNESS-YES-NAME> form or the
newer HARNESS2 grammar (e.g. C<# HARNESS2: fork @off>); C<NO> / C<@off> yields
C<0>, and C<YES> / C<USE> / C<@on> yields C<1> (see #58 for the two grammars).

When the file declares no directive for the feature the returned value is a
default rather than undef: the optional C<$default> argument if given, otherwise
a per-feature built-in default (C<0> for C<isolation> and C<smoke>, C<1> for the
rest). For a known feature it never returns undef.

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

This returns the data used to add the test file to the runner queue: the
serialized, file-free state carried in the task payload. The runner consumes
this raw hash directly, without re-reading the file. L<Test2::Harness2::TestFile>
can wrap the same payload (via C<from_task()>) as a state-only accessor object,
but production code does not currently do so.

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
