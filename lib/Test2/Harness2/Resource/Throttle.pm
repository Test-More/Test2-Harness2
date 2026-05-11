package Test2::Harness2::Resource::Throttle;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Units qw/parse_duration/;

use Object::HashBase qw{
    <cap
    <window
    <assignments
    +name
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

# Test seam matching Resource::Disk's pattern. Tests local-bind
# $CLOCK to drive deterministic timelines; production code never
# touches it.
our $CLOCK = \&Time::HiRes::time;

sub _now { $CLOCK->() }

sub resource_name { $_[0]->{+NAME} // 'throttle' }

# Class method called by App::Yath2::Command::test::_build_resources
# and App::Yath2::Command::start::resources via the parse_options
# dispatch added in the Disk plan.
my %CTOR_KEYS = map { $_ => 1 } qw/cap window name/;

sub parse_options {
    my ($class, @args) = @_;

    my %ctor;
    my %file_vals;
    my @inline_rules;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # Drop unknown k=>v pairs from the resource-group settings.
        if (
               defined $arg
            && !ref($arg)
            && $arg !~ m{^[0-9]+(?:/|$)}    # not a rule (explicit or bare-cap)
            && $arg !~ m{^@}                # not a file
            && $arg !~ m{^name=}            # not a name= entry
            && $i + 1 < @args
            )
        {
            # Known ctor keys (programmatic call) flow through.
            $ctor{$arg} = $args[$i + 1] if exists $CTOR_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::Throttle: undef positional entry" unless defined $arg;
        croak "Resource::Throttle: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            my $path = $1;
            %file_vals = %{$class->_load_config_file($path)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            my $n = $1;
            croak "Resource::Throttle: empty name= entry '$arg'"
                unless defined $n && length $n;
            croak "Resource::Throttle: name='$n' must be a non-empty whitespace-free string"
                if $n =~ /\s/;
            $inline_name = $n;
        }
        elsif ($arg =~ m{^([0-9]+)/(.+)\z}) {
            my ($cap, $duration) = ($1, $2);
            croak "Resource::Throttle: cap in '$arg' must be a positive integer"
                unless $cap > 0;
            my $secs = eval { parse_duration($duration, name => 'window') };
            croak "Resource::Throttle: bad window in entry '$arg': $@" if $@;
            push @inline_rules, {cap => $cap + 0, window => $secs};
        }
        elsif ($arg =~ m{^([0-9]+)\z}) {
            # Bare-cap shorthand: <N> means <N>/1s (one-second window).
            my $cap = $1;
            croak "Resource::Throttle: cap in '$arg' must be a positive integer"
                unless $cap > 0;
            push @inline_rules, {cap => $cap + 0, window => 1};
        }
        else {
            croak "Resource::Throttle: unrecognised entry '$arg' " . "(expected CAP, CAP/DURATION, name=NAME, or \@/path/to/config.json)";
        }

        $i += 1;
    }

    croak "Resource::Throttle: only a single rule per instance is supported " . "(saw " . scalar(@inline_rules) . " rules)"
        if @inline_rules > 1;

    # Precedence: file values applied first, then inline overrides.
    if (%file_vals) {
        $ctor{cap}    = $file_vals{cap}    if exists $file_vals{cap};
        $ctor{window} = $file_vals{window} if exists $file_vals{window};
        $ctor{name}   = $file_vals{name}   if exists $file_vals{name};
    }
    if (@inline_rules) {
        my $r = $inline_rules[0];
        $ctor{cap}    = $r->{cap};
        $ctor{window} = $r->{window};
    }
    $ctor{name} = $inline_name if defined $inline_name;
    $ctor{name} //= 'throttle';

    return %ctor;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::Throttle config file '$path' does not exist"  unless -e $path;
    croak "Resource::Throttle config file '$path' is not readable" unless -r _;

    open my $fh, '<:raw', $path
        or croak "Resource::Throttle: cannot open config file '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data = eval { decode_json($body) };
    croak "Resource::Throttle: cannot parse JSON in '$path': $@" if $@;
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

    my $secs = eval { parse_duration($data->{window}, name => 'window') };
    croak "Resource::Throttle: bad window in '$path': $@" if $@;

    my %out = (cap => $cap + 0, window => $secs);
    if (defined $data->{name}) {
        my $n = $data->{name};
        croak "Resource::Throttle: name in '$path' must be a non-empty whitespace-free string"
            unless !ref($n) && length($n) && $n !~ /\s/;
        $out{name} = $n;
    }

    return \%out;
}

sub init {
    my $self = shift;

    $self->{+ASSIGNMENTS} //= {};
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
}

sub available {
    my ($self, %p) = @_;

    croak "'job' is required" unless defined $p{job};

    my $count = $self->_in_window_count;
    return $count < $self->{+CAP} ? 1 : 0;
}

# Walk assignments and count entries with (now - assigned_at) < window.
# A slot is occupied while age is strictly less than window seconds;
# at exactly age == window the slot has aged out (boundary-exclusive).
# O(in-flight) -- caps are typically small (<50) so this is cheap.
sub _in_window_count {
    my $self  = shift;
    my $now   = _now();
    my $win   = $self->{+WINDOW};
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
        assigned_at => _now(),
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

# State-transition methods. Throttle never enters a broken state at
# runtime, so only paused/resumed are supported. The role default
# implementations of mark_broken / mark_permanent_broken croak, which
# is correct for this resource (callers should never try to break it).
sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub status {
    my $self = shift;

    my $now = _now();
    my $win = $self->{+WINDOW};

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
            in_window   => ($age < $win) ? 1 : 0,
        };
    }

    return {
        resource          => $self->resource_name,
        cap               => $self->{+CAP},
        window            => $self->{+WINDOW},
        paused            => $self->is_paused,
        total_assignments => scalar(keys %{$self->{+ASSIGNMENTS}}),
        in_window_count   => $self->_in_window_count,
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

=head1 DESCRIPTION

A "slot" is occupied from the moment a test starts (C<assign>) until
B<either> the test releases B<or> C<window> seconds elapse, whichever
comes first. Cap is C<N> slots.

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
