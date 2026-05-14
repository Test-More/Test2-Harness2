package Test2::Harness2::Resource::Throttle;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use POSIX qw/floor/;

use Test2::Harness2::Util::Units qw/parse_duration parse_byte_size/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Object::HashBase qw{
    <cap
    <window
    <bases
    <core_count
    <assignments
    &Test2::Harness2::Role::Resource
};

# Test seams. Coderef override; undef = real detection.
our $DETECT_CORE_COUNT  = undef;
our $READ_MEMINFO_AVAIL = undef;

# Bespoke assign/release: kept for future per-completion bookkeeping (e.g. credit on early exit).

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

    my $has_ram_basis = grep { $_->{type} eq 'ram' } @{$self->{+BASES}};
    if ($has_ram_basis && !defined $READ_MEMINFO_AVAIL) {
        croak "Resource::Throttle: RAM basis requires Linux (/proc/meminfo); " . "this platform does not have /proc/meminfo"
            unless -e '/proc/meminfo';
    }

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
    # Read into a lexical, not $_. Callers may have $_ aliased to a
    # live list element (e.g. `map { $_->status } @{+RESOURCES}` in
    # request_handler_status); bare `<$fh>` would overwrite that
    # aliased $_ and replace the Throttle resource itself with the
    # last line read.
    while (defined(my $line = <$fh>)) {
        if ($line =~ /^MemAvailable:\s+(\d+)\s+kB/) {
            close $fh;
            return $1 * 1024;    # convert kB to bytes
        }
    }
    close $fh;
    croak "Resource::Throttle: MemAvailable not found in /proc/meminfo";
}

sub is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;
    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if $arg =~ m{^[0-9]+(?:/|$)};    # not a rule (explicit or bare-cap)
    return 0 if $arg =~ m{^@};                # not a file
    return 0 if $arg =~ m{^name=};            # not a name= entry
    return 1;
}

sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_vals;
    my @inline_rules;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if ($class->is_unknown_kv_arg($arg, $i + 1 < @args)) {
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
            $inline_name = $class->validate_name($1);
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

    my $data = $class->slurp_json_config($path);
    $class->whitelist_keys($data, [qw/cap window name/], $path);

    croak "Resource::Throttle: 'cap' is required in '$path'"
        unless defined $data->{cap};
    croak "Resource::Throttle: 'window' is required in '$path'"
        unless defined $data->{window};

    my $cap = $data->{cap};
    croak "Resource::Throttle: cap in '$path' must be a positive integer"
        unless $cap =~ m/^[0-9]+\z/ && $cap > 0;

    my $secs;
    my $ok  = eval { $secs = parse_duration($data->{window}, name => 'window'); 1 };
    my $err = $@;
    croak "Resource::Throttle: bad window in '$path': $err" unless $ok;

    my %out = (cap => $cap + 0, window => $secs);
    if (defined $data->{name}) {
        $out{name} = $class->validate_name($data->{name}, " in '$path'");
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

# See POD "Adaptive scaling" for the token / window algorithm.
sub _token_count {
    my $self = shift;

    my $bases = $self->{+BASES};
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

            my $tokens = ($basis_unit > $free_ram) ? 0 : floor($free_ram / $basis_unit);

            push @basis_tokens => $tokens;
        }
    }

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

    yath -D test -R Throttle=5/2s
    yath -D test -R Throttle=5             # shorthand: 5/1s
    yath -D test -R Throttle=10/500ms
    yath -D test -R Throttle=3/1m,name=db_throttle
    yath -D test -R Throttle=@/etc/yath/throttle.json

    # Multi-basis grammar:
    yath -D test -R Throttle=1/core/1s         # 1 slot per core, 1s window
    yath -D test -R Throttle=1/1gb/1s           # 1 slot per GB free RAM
    yath -D test -R Throttle=1/core,100mb/1s    # 1 slot per core AND per 100MB free
    yath -D test -R Throttle=1/core,500mb,1gb/2s

=head1 DESCRIPTION

A "slot" is occupied from the moment a test starts (C<assign>) until
B<either> the test releases B<or> C<window> seconds elapse, whichever
comes first. Cap is C<N> slots per window. This is a gate, not a
slot pool: every job is either allowed or deferred.

=head1 CLI

C<-R Throttle=ENTRY,ENTRY,...> -- entries:

=over 4

=item C<CAP/DURATION>

Positive integer cap. Duration accepts C<ms>/C<s>/C<m> suffixes;
bare number is seconds. e.g. C<5/2s>, C<10/500ms>, C<3/1m>.

=item C<CAP>

Shorthand for C<CAP/1s>.

=item C<CAP/BASIS[,BASIS...]/DURATION>

Multi-basis form (see L</BASIS> below).

=item C<name=STRING>

Cosmetic label (default C<"throttle">). Non-empty, whitespace-free.

=item C<@/path/to/file.json>

JSON config. Top-level keys: C<cap>, C<window>, C<name>.

=back

Later inline entries override earlier ones per-key. At most one rule
entry per Throttle instance.

=head2 BASIS

=over 4

=item C<core> or C<cores>

System core count (detected at startup; defaults to C<1> if neither
L<System::Info> nor C</proc/cpuinfo> is available).

=item C<NUMkb>, C<NUMmb>, C<NUMgb>, C<NUMtb>

A byte threshold. Free RAM (from C</proc/meminfo> C<MemAvailable>) is
divided by this unit to give the token count. RAM basis requires
Linux; specifying one on another platform croaks at construction.

=back

Token math: for each basis B with current resource value V,
C<tokens_for_basis = floor(V / B)>. The effective per-window token
count is C<cap * MIN(tokens_for_basis over all bases)>.

=head1 ADAPTIVE SCALING UNDER MEMORY PRESSURE

When a RAM basis is configured and free RAM falls below the basis
unit, the basis unit is halved and the window doubled (up to twice).
After two halvings the basis contributes zero tokens and the throttle
defers all new launches. Slots assigned under the original window
are counted against the (longer) effective window.

Example with 8-core system, C<1/core,100mb/1s>:

    Free RAM  | RAM basis  | Window mult | RAM tokens | Core tokens | Final tokens
    ----------+------------+-------------+------------+-------------+-------------
    4 GB      | 100mb      | 1x          | 40         | 8           | min(40,8)*1 = 8
    80 MB     | 50mb (1x)  | 2x (2s eff) | 1          | 8           | min(1,8)*1 = 1
    30 MB     | 25mb (2x)  | 4x (4s eff) | 1          | 8           | min(1,8)*1 = 1
    10 MB     | 25mb (cap) | 4x (4s eff) | 0 (defer)  | 8           | min(0,8)*1 = 0

=head1 LIMITATIONS

At most one Throttle instance per yath invocation. Layered rules
(multiple windows / classes) are not supported.

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
