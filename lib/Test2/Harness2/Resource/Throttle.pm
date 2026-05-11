package Test2::Harness2::Resource::Throttle;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use POSIX qw/floor/;

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Units qw/parse_duration parse_byte_size/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Object::HashBase qw{
    <cap
    <window
    <assignments
    <bases
    <core_count
    +name
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

# Test seams for system detection. Tests override these package-level
# subs to inject deterministic values without touching /proc.
our $DETECT_CORE_COUNT  = undef;    # coderef override; undef = use real detection
our $READ_MEMINFO_AVAIL = undef;    # coderef override; undef = read /proc/meminfo

# Throttle keeps assign / release / paused bookkeeping bespoke rather
# than consuming Test2::Harness2::Role::Resource::Assignable. State-
# transition methods (is_paused / mark_paused / mark_resumed) follow
# the assignable shape so the role would fit; assign + release also
# follow the same shape today. The reason Throttle keeps its own
# copies is that the rate-limit semantics are likely to grow custom
# release behaviour (e.g. recording exit time alongside assigned_at
# so the sliding-window math can credit early completions) and
# inheriting from the role would have to be undone the moment that
# happens.

sub resource_name { $_[0]->{+NAME} // 'throttle' }
sub is_paused     { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused   { $_[0]->{+PAUSED} = 1 }
sub mark_resumed  { $_[0]->{+PAUSED} = 0 }

my %OPTION_KEYS = map { $_ => 1 } qw/cap window name bases core_count/;

sub init {
    my $self = shift;

    $self->{+ASSIGNMENTS} //= {};
    $self->{+BASES}       //= [];
    $self->{+NAME}        //= 'throttle';

    croak "Resource::Throttle: 'cap' must be a positive integer"
        unless defined $self->{+CAP}
        && $self->{+CAP} =~ m/^[0-9]+\z/
        && $self->{+CAP} > 0;

    croak "Resource::Throttle: 'window' must be a positive number"
        unless defined $self->{+WINDOW}
        && $self->{+WINDOW} =~ m/^[0-9]+(?:\.[0-9]+)?\z/
        && $self->{+WINDOW} > 0;

    croak "Resource::Throttle: 'name' must be a non-empty whitespace-free string"
        unless defined $self->{+NAME}
        && !ref($self->{+NAME})
        && length($self->{+NAME})
        && $self->{+NAME} !~ /\s/;

    # Validate bases entries if provided.
    if (my $bases = $self->{+BASES}) {
        croak "Resource::Throttle: 'bases' must be an arrayref"
            unless ref($bases) eq 'ARRAY';
        for my $b (@$bases) {
            croak "Resource::Throttle: each basis must be a hashref"
                unless ref($b) eq 'HASH';
            croak "Resource::Throttle: basis 'type' must be 'core' or 'ram'"
                unless $b->{type} eq 'core' || $b->{type} eq 'ram';
            croak "Resource::Throttle: RAM basis must have 'bytes'"
                if $b->{type} eq 'ram' && !$b->{bytes};
        }
    }

    # Check that /proc/meminfo is readable if RAM bases are specified, and
    # croak at init time on non-Linux to give a clear early error.
    my $has_ram_basis = grep { $_->{type} eq 'ram' } @{$self->{+BASES}};
    if ($has_ram_basis && !defined $READ_MEMINFO_AVAIL) {
        # Not on Linux (no /proc/meminfo) -- croak at init only when a RAM
        # basis was actually specified. Plain window-only throttle is fine.
        croak "Resource::Throttle: RAM basis requires Linux (/proc/meminfo); " . "this platform does not have /proc/meminfo"
            unless -e '/proc/meminfo';
    }

    # Detect and cache the core count once.
    $self->{+CORE_COUNT} //= _detect_core_count();
}

sub _detect_core_count {
    return $DETECT_CORE_COUNT->() if defined $DETECT_CORE_COUNT;

    # Try System::Info first (cross-platform, optional dep). Don't
    # gate on ->can('ncore') -- System::Info dispatches via a
    # platform-specific subclass and AUTOLOAD/delegation, so can()
    # returns false even though the call works. Just try it.
    my $loaded = eval { require System::Info; 1 };
    if ($loaded) {
        my $n;
        my $ok = eval { $n = System::Info->new->ncore; 1 };
        return $n if $ok && $n && $n > 0;
    }

    # Fall back to counting "processor" lines in /proc/cpuinfo (Linux).
    # The naive idiom `$count++ while <$fh> =~ /^processor/;` is wrong:
    # `while` exits the first time the regex fails to match, so the
    # very next non-processor line (vendor_id, cpu family, ...) ends
    # the loop with count=1 regardless of CPU count. Read every line
    # explicitly.
    if (-r '/proc/cpuinfo') {
        if (open my $fh, '<', '/proc/cpuinfo') {
            my $count = 0;
            while (my $line = <$fh>) {
                $count++ if $line =~ /^processor\s*:/;
            }
            close $fh;
            return $count if $count > 0;
        }
    }

    return 1;    # final fallback: assume 1 core
}

sub _read_meminfo_available {
    return $READ_MEMINFO_AVAIL->() if defined $READ_MEMINFO_AVAIL;

    open my $fh, '<', '/proc/meminfo'
        or croak "Resource::Throttle: cannot open /proc/meminfo: $!";
    while (<$fh>) {
        if (/^MemAvailable:\s+(\d+)\s+kB/) {
            close $fh;
            return $1 * 1024;    # convert kB to bytes
        }
    }
    close $fh;
    croak "Resource::Throttle: MemAvailable not found in /proc/meminfo";
}

sub _is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;
    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if $arg =~ m{^[0-9]+(?:/|$)};    # not a rule (explicit or bare-cap)
    return 0 if $arg =~ m{^@};                # not a file
    return 0 if $arg =~ m{^name=};            # not a name= entry
    return 1;
}

# Class method called by App::Yath2::Command::test::_build_resources
# and App::Yath2::Command::start::resources via the parse_options
# dispatch added in the Disk plan.
sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_vals;
    my @inline_rules;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if ($class->_is_unknown_kv_arg($arg, $i + 1 < @args)) {
            # Known ctor keys (programmatic call) flow through.
            $out{$arg} = $args[$i + 1] if exists $OPTION_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::Throttle: undef positional entry" unless defined $arg;
        croak "Resource::Throttle: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            $inline_name = $class->_parse_name_arg($arg, $1);
        }
        elsif ($arg =~ m{^[0-9]}) {
            push @inline_rules => $class->_parse_rule_entry($arg);
        }
        else {
            croak "Resource::Throttle: unrecognised entry '$arg' " . "(expected CAP, CAP/DURATION, CAP/BASIS[,BASIS...]/DURATION, name=NAME, or \@/path/to/config.json)";
        }

        $i += 1;
    }

    croak "Resource::Throttle: only a single rule per instance is supported " . "(saw " . scalar(@inline_rules) . " rules)"
        if @inline_rules > 1;

    # Precedence: file values applied first, then inline overrides.
    if (%file_vals) {
        $out{cap}    = $file_vals{cap}    if exists $file_vals{cap};
        $out{window} = $file_vals{window} if exists $file_vals{window};
        $out{name}   = $file_vals{name}   if exists $file_vals{name};
    }
    if (@inline_rules) {
        my $r = $inline_rules[0];
        $out{cap}    = $r->{cap};
        $out{window} = $r->{window};
        $out{bases}  = $r->{bases} if exists $r->{bases};
    }
    $out{name} = $inline_name if defined $inline_name;
    $out{name} //= 'throttle';

    return %out;
}

sub _parse_name_arg {
    my ($class, $orig, $name) = @_;
    croak "Resource::Throttle: empty name= entry '$orig'"
        unless defined $name && length $name;
    croak "Resource::Throttle: name='$name' must be a non-empty whitespace-free string"
        if $name =~ /\s/;
    return $name;
}

# Parse one rule entry: <CAP>/<BASIS,...>/<DURATION>, <CAP>/<DURATION>,
# or bare <CAP> (implicit 1-second window). Returns the rule hashref;
# croaks on any malformed component.
sub _parse_rule_entry {
    my ($class, $arg) = @_;

    if ($arg =~ m{^([0-9]+)/([^/]+)/(.+)\z}) {
        my ($cap, $basis_str, $duration) = ($1, $2, $3);
        croak "Resource::Throttle: cap in '$arg' must be a positive integer"
            unless $cap > 0;
        my $bases = $class->_parse_bases($basis_str, $arg);
        my $secs;
        eval { $secs = parse_duration($duration, name => 'window'); 1 }
            or croak "Resource::Throttle: bad window in entry '$arg': $@";
        return {cap => $cap + 0, window => $secs, bases => $bases};
    }

    if ($arg =~ m{^([0-9]+)/(.+)\z}) {
        my ($cap, $duration) = ($1, $2);
        croak "Resource::Throttle: cap in '$arg' must be a positive integer"
            unless $cap > 0;
        my $secs;
        eval { $secs = parse_duration($duration, name => 'window'); 1 }
            or croak "Resource::Throttle: bad window in entry '$arg': $@";
        return {cap => $cap + 0, window => $secs};
    }

    if ($arg =~ m{^([0-9]+)\z}) {
        # Bare-cap shorthand: <N> means <N>/1s (one-second window).
        my $cap = $1;
        croak "Resource::Throttle: cap in '$arg' must be a positive integer"
            unless $cap > 0;
        return {cap => $cap + 0, window => 1};
    }

    croak "Resource::Throttle: unrecognised rule entry '$arg' " . "(expected CAP, CAP/DURATION, or CAP/BASIS[,BASIS...]/DURATION)";
}

# Parse a basis string like "core" or "1gb,100mb" or "core,500mb,1gb".
# Returns an arrayref of basis hashrefs.
sub _parse_bases {
    my ($class, $basis_str, $orig_entry) = @_;

    croak "Resource::Throttle: empty basis in '$orig_entry'"
        unless defined $basis_str && length $basis_str;

    my @parts = split /,/, $basis_str;
    my @bases;

    for my $part (@parts) {
        $part =~ s/^\s+|\s+$//g;
        croak "Resource::Throttle: empty basis component in '$orig_entry'"
            unless length $part;

        if ($part =~ m{^cores?\z}i) {
            push @bases => {type => 'core'};
        }
        elsif ($part =~ m{^[0-9]+(?:\.[0-9]+)?(?:kb|mb|gb|tb)\z}i) {
            my $bytes;
            eval { $bytes = parse_byte_size($part); 1 }
                or croak "Resource::Throttle: invalid byte-size basis '$part' in '$orig_entry': $@";
            push @bases => {type => 'ram', bytes => $bytes};
        }
        else {
            croak "Resource::Throttle: unknown basis unit '$part' in '$orig_entry' " . "(expected 'core', 'cores', or a byte size like '100mb', '1gb')";
        }
    }

    croak "Resource::Throttle: no bases parsed from '$basis_str' in '$orig_entry'"
        unless @bases;

    return \@bases;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::Throttle config file '$path' does not exist"  unless -e $path;
    croak "Resource::Throttle config file '$path' is not readable" unless -r _;

    open my $fh, '<:raw', $path
        or croak "Resource::Throttle: cannot open config file '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data;
    eval { $data = decode_json($body); 1 }
        or croak "Resource::Throttle: cannot parse JSON in '$path': $@";
    croak "Resource::Throttle: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    my %allowed = map { $_ => 1 } qw/cap window name/;
    for my $k (sort keys %$data) {
        croak "Resource::Throttle: unknown key '$k' in '$path'"
            unless $allowed{$k};
    }

    croak "Resource::Throttle: 'cap' is required in '$path'"
        unless defined $data->{cap};
    croak "Resource::Throttle: 'window' is required in '$path'"
        unless defined $data->{window};

    my $cap = $data->{cap};
    croak "Resource::Throttle: cap in '$path' must be a positive integer"
        unless $cap =~ m/^[0-9]+\z/ && $cap > 0;

    my $secs;
    eval { $secs = parse_duration($data->{window}, name => 'window'); 1 }
        or croak "Resource::Throttle: bad window in '$path': $@";

    my %out = (cap => $cap + 0, window => $secs);
    if (defined $data->{name}) {
        my $n = $data->{name};
        croak "Resource::Throttle: name in '$path' must be a non-empty whitespace-free string"
            unless !ref($n) && length($n) && $n !~ /\s/;
        $out{name} = $n;
    }

    return \%out;
}

sub available {
    my ($self, %p) = @_;

    croak "'job' is required" unless defined $p{job};

    my ($tokens, $eff_window) = $self->_token_count();
    my $count = $self->_in_window_count($eff_window);
    return $count < $tokens ? 1 : 0;
}

# _token_count() computes (tokens_per_window, effective_window).
#
# Token math (from spec):
#   For each basis B with current resource value V:
#       tokens_for_basis = floor(V / B_unit)
#   tokens_per_window = cap × MIN_over_bases(tokens_for_basis)
#
# When no bases specified: tokens_per_window = cap (original behaviour).
#
# Adaptive scaling (RAM bases only):
#   basis_unit  = original_unit
#   window_mult = 1
#   halvings    = 0
#   while basis_unit > free_ram and halvings < 2:
#       basis_unit  /= 2
#       window_mult *= 2
#       halvings    += 1
#   # After 2 halvings: stop. If still > free_ram: that basis => 0 tokens.
#
# Effective window = original_window × MAX(window_mult across all RAM bases).
sub _token_count {
    my $self = shift;

    my $bases = $self->{+BASES};

    # No bases: preserve original behaviour (tokens = cap, window unchanged).
    return ($self->{+CAP}, $self->{+WINDOW}) unless @$bases;

    my $free_ram     = undef;    # lazily fetched
    my $max_win_mult = 1;
    my @basis_tokens;

    for my $b (@$bases) {
        if ($b->{type} eq 'core') {
            my $cores  = $self->{+CORE_COUNT};
            my $tokens = floor($cores);          # cores is integer but floor for safety
            push @basis_tokens => $tokens;
        }
        elsif ($b->{type} eq 'ram') {
            # Fetch free RAM once per _token_count() call.
            $free_ram //= _read_meminfo_available();

            my $basis_unit  = $b->{bytes};
            my $window_mult = 1;
            my $halvings    = 0;

            while ($basis_unit > $free_ram && $halvings < 2) {
                $basis_unit  /= 2;
                $window_mult *= 2;
                $halvings++;
            }

            $max_win_mult = $window_mult if $window_mult > $max_win_mult;

            my $tokens;
            if ($basis_unit > $free_ram) {
                # Even after 2 halvings, basis > free RAM: contribute 0 tokens.
                $tokens = 0;
            }
            else {
                $tokens = floor($free_ram / $basis_unit);
            }

            push @basis_tokens => $tokens;
        }
    }

    # tokens_per_window = cap × MIN_over_bases(tokens_for_basis)
    my $min_tokens = $basis_tokens[0];
    for my $t (@basis_tokens) {
        $min_tokens = $t if $t < $min_tokens;
    }

    my $total_tokens = $self->{+CAP} * $min_tokens;
    my $eff_window   = $self->{+WINDOW} * $max_win_mult;

    return ($total_tokens, $eff_window);
}

# Walk assignments and count entries with (now - assigned_at) < window.
# A slot is occupied while age is strictly less than window seconds;
# at exactly age == window the slot has aged out (boundary-exclusive).
# O(in-flight) -- caps are typically small (<50) so this is cheap.
sub _in_window_count {
    my ($self, $win) = @_;
    $win //= $self->{+WINDOW};
    my $now   = hi_res_time();
    my $count = 0;
    for my $entry (values %{$self->{+ASSIGNMENTS}}) {
        $count++ if ($now - $entry->{assigned_at}) < $win;
    }
    return $count;
}

sub assign {
    my ($self, %p) = @_;

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";
    croak "'env' hashref is required" unless ref($p{env}) eq 'HASH';

    croak "Resource::Throttle: duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};

    $self->{+ASSIGNMENTS}->{$id} = {
        job         => $job,
        assigned_at => hi_res_time(),
    };

    return 1;
}

sub release {
    my ($self, %p) = @_;

    my $id = $p{id} or croak "'id' is required";

    delete $self->{+ASSIGNMENTS}->{$id}
        or croak "Resource::Throttle: invalid release id '$id'";

    return 1;
}

sub status {
    my $self = shift;

    my $now = hi_res_time();
    my ($tokens, $eff_window) = $self->_token_count();

    my @assignments;
    for my $id (sort keys %{$self->{+ASSIGNMENTS}}) {
        my $a   = $self->{+ASSIGNMENTS}->{$id};
        my $age = $now - $a->{assigned_at};
        my $tf  = $a->{job}->test_file;
        push @assignments => {
            id          => $id,
            test        => $tf->relative,
            assigned_at => $a->{assigned_at},
            age         => $age,
            in_window   => ($age < $eff_window) ? 1 : 0,
        };
    }

    return {
        resource          => $self->resource_name,
        cap               => $self->{+CAP},
        window            => $self->{+WINDOW},
        effective_window  => $eff_window,
        tokens_per_window => $tokens,
        paused            => $self->is_paused,
        total_assignments => scalar(keys %{$self->{+ASSIGNMENTS}}),
        in_window_count   => $self->_in_window_count($eff_window),
        assignments       => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Throttle - Limit how many tests can be in their just-spawned phase at once.

=head1 SYNOPSIS

    yath -D test -j16 -R Throttle=5/2s
    yath -D test -j16 -R Throttle=5             # shorthand: 5/1s
    yath -D test -j16 -R Throttle=10/500ms
    yath -D test -j16 -R Throttle=3/1m,name=db_throttle
    yath -D test -j16 -R Throttle=@/etc/yath/throttle.json

    # Multi-basis grammar (new):
    yath -D test -j16 -R Throttle=1/core/1s         # 1 slot per core, 1s window
    yath -D test -j16 -R Throttle=1/1gb/1s           # 1 slot per GB free RAM
    yath -D test -j16 -R Throttle=1/core,100mb/1s    # 1 slot per core AND per 100MB free
    yath -D test -j16 -R Throttle=1/core,500mb,1gb/2s

=head1 DESCRIPTION

A "slot" is occupied from the moment a test starts (C<assign>) until
B<either> the test releases B<or> C<window> seconds elapse, whichever
comes first. Cap is C<N> slots per window.

Use case: a fragile shared resource (DB pool, port binding, license
server, GPU bootstrap) cannot tolerate dozens of tests racing through
their setup phase at once, but is fine with the same number running
concurrently after their initial ramp-up.

This resource is a I<gate>, not a slot pool: every job is either
allowed or deferred. C<assign> and C<release> exist only to satisfy
the resource contract and to populate C<status> with the list of jobs
running under the gate; no per-test units are reserved.

=head1 CLI

C<-R Throttle=ENTRY,ENTRY,...> -- entries are:

=over 4

=item C<CAP/DURATION>

The rule. C<CAP> is a positive integer. C<DURATION> accepts
C<ms>/C<s>/C<m> suffixes; bare number is seconds. e.g. C<5/2s>,
C<10/500ms>, C<3/1m>.

=item C<CAP>

Shorthand for C<CAP/1s> (one-second window). e.g. C<-R Throttle=5> is
equivalent to C<-R Throttle=5/1s>.

=item C<CAP/BASIS[,BASIS...]/DURATION>

Multi-basis form. C<BASIS> elements are separated by commas and must be
one of:

=over 4

=item C<core> or C<cores>

The system core count (detected once at startup). This basis divides the
core count by 1, so C<1/core/1s> on an 8-core machine grants 8 tokens per
window.

=item C<NUMkb>, C<NUMmb>, C<NUMgb>, C<NUMtb>

A byte threshold. Free RAM (from C</proc/meminfo> C<MemAvailable>) is
divided by this unit to give the token count. e.g. C<1/100mb/1s> on a
system with 400MB free grants 4 tokens per window.

=back

Token math: for each basis B with current resource value V,
C<tokens_for_basis = floor(V / B)>. The effective per-window token count
is C<cap * MIN(tokens_for_basis over all bases)>.

=item C<name=STRING>

Optional cosmetic label (default C<"throttle">). Used by C<status()>
and (when supported) to disambiguate multiple instances. Must be
non-empty and whitespace-free.

=item C<@/path/to/file.json>

Optional config file. Top-level keys: C<cap> (required positive
integer), C<window> (required duration string), C<name> (optional
string).

=back

Inline entries override file entries per-key (later wins). At most
one rule entry (explicit or shorthand) per Throttle instance.

=head1 ADAPTIVE SCALING UNDER MEMORY PRESSURE

When a RAM basis is configured and free RAM falls below the configured
basis unit, the throttle applies adaptive scaling:

=over 4

=item *

On each call to C<available()>, free RAM is sampled from C</proc/meminfo>.

=item *

If free RAM < basis unit: the basis unit is halved and the window is
doubled. This can happen at most twice (2 halvings, giving 4x the
original window).

=item *

After 2 halvings (basis at 1/4 original): if the system is still below
the halved basis, that basis contributes 0 tokens, causing the throttle
to defer all new jobs.

=item *

The effective window is C<original_window * window_multiplier> where
C<window_multiplier> is the largest multiplier from any RAM basis.
Slots assigned under the original window are counted against the
(longer) effective window, so tightening under pressure retroactively
holds those slots longer.

=back

Example with 8-core system, C<1/core,100mb/1s>:

    Free RAM  | RAM basis  | Window mult | RAM tokens | Core tokens | Final tokens
    ----------+------------+-------------+------------+-------------+-------------
    4 GB      | 100mb      | 1x          | 40         | 8           | min(40,8)*1 = 8
    80 MB     | 50mb (1x)  | 2x (2s eff) | 1          | 8           | min(1,8)*1 = 1
    30 MB     | 25mb (2x)  | 4x (4s eff) | 1          | 8           | min(1,8)*1 = 1
    10 MB     | 25mb (cap) | 4x (4s eff) | 0 (defer)  | 8           | min(0,8)*1 = 0

=head1 PLATFORM NOTES

The C<core> basis works on any platform where C<System::Info> is
installed or where C</proc/cpuinfo> is readable. On systems where
neither is available, the core count defaults to 1 (a low but
functional cap).

The C<NUMmb>/C<NUMgb>/etc. RAM basis requires Linux C</proc/meminfo>.
Specifying a RAM basis on a non-Linux system causes an exception at
resource construction time. Plain C<CAP/DURATION> (without a basis)
works everywhere.

=head1 LIMITATIONS

A single yath invocation supports at most one Throttle instance.
C<App::Yath2::Options::Resource>'s C<--resource> Map is keyed by the
resolved class name, so a second C<-R Throttle=...> (in any spelling)
clobbers the first. Layered Throttle rules (multiple windows /
classes) are out of scope for this initial implementation.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

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

See L<https://dev.perl.org/licenses/>

=cut
