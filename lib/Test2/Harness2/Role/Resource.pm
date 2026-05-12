package Test2::Harness2::Role::Resource;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::JSON qw/decode_json/;

# Role::Tiny must mark this as a role before HashBase loads.
use Role::Tiny;
use Object::HashBase qw{+paused +name +in_flight_ref +broken +permanent_broken};

requires 'available';
requires 'status';

sub needed { 1 }

sub resource_name {
    my $self = shift;
    if (ref $self) {
        my $n = $self->{+NAME};
        return $n if defined $n && length $n;
    }
    my $class = ref($self) || $self;
    $class =~ s/^.*:://;
    return lc($class);
}

sub is_broken           { $_[0]->{+BROKEN} || $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN}                     ? 1 : 0 }
sub is_paused           { $_[0]->{+PAUSED}                               ? 1 : 0 }

sub is_usable {
    my $self = shift;
    return 0 if $self->is_broken;
    return 0 if $self->is_permanent_broken;
    return 0 if $self->is_paused;
    return 1;
}

sub mark_broken           { $_[0]->{+BROKEN} = 1 }
sub mark_permanent_broken { $_[0]->{+BROKEN} = $_[0]->{+PERMANENT_BROKEN} = 1 }
sub mark_paused           { $_[0]->{+PAUSED} = 1 }

# Clear transient broken + paused; preserve permanent_broken.
sub mark_resumed {
    my $self = shift;
    $self->{+PAUSED} = 0;
    $self->{+BROKEN} = 0 unless $self->{+PERMANENT_BROKEN};
}

# No-op defaults. Resources that need per-assignment state (Throttle's
# timestamp window, JobCount's slot math) override locally. The
# scheduler maintains the aggregate in-flight count; resources read
# it via in_flight() which dereferences the shared scalar ref the
# scheduler installs at registration time.
sub assign {
    my ($self, %p) = @_;
    croak "'id' is required"           unless $p{id};
    croak "'job' is required"          unless $p{job};
    croak "'env' hashref is required"  unless ref($p{env}) eq 'HASH';
    return 1;
}

sub release {
    my ($self, %p) = @_;
    croak "'id' is required" unless $p{id};
    return 1;
}

# Install a scalar ref the resource will deref to read the current
# in-flight count. Called once by the scheduler when the resource is
# registered. The scheduler mutates the underlying scalar directly;
# resources see updates without per-resource notification.
sub set_in_flight_ref {
    my ($self, $ref) = @_;
    croak "set_in_flight_ref: scalar ref required"
        unless ref($ref) eq 'SCALAR';
    $self->{+IN_FLIGHT_REF} = $ref;
    return;
}

sub in_flight {
    my $ref = $_[0]->{+IN_FLIGHT_REF}
        or croak ref($_[0]) . ": in_flight called before scheduler installed in_flight_ref";
    return ${$ref};
}

sub inline_key_prefixes { [] }

# True when $arg is an unknown key= token paired with a following value (caller advances past both).
sub is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;

    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if $arg =~ m{^[0-9]};
    return 0 if $arg =~ m{^@};
    return 0 if $arg =~ m{^name=};

    my $prefixes = $class->inline_key_prefixes;
    croak ref($class) || $class, ": inline_key_prefixes must return an ARRAY ref"
        unless ref($prefixes) eq 'ARRAY';

    for my $p (@$prefixes) {
        return 0 if $arg =~ m{^\Q$p\E=};
    }

    return 1;
}

sub services { () }
sub teardown { }

# Shared option-parsing helpers. Error-message prefix derives from
# the consumer's class via label() below. See POD.

sub label {
    my $class = ref($_[0]) || $_[0];
    $class =~ s/^Test2::Harness2:://;
    return $class;
}

# Slurp + decode JSON config. Croaks (with label prefix) on missing/unreadable/parse-fail/non-object.
sub slurp_json_config {
    my ($class, $path) = @_;

    my $label = $class->label;

    croak "$label: 'path' is required" unless defined $path && length $path;

    croak "$label config file '$path' does not exist"  unless -e $path;
    croak "$label config file '$path' is not readable" unless -r _;

    open my $fh, '<:raw', $path
        or croak "$label: cannot open config file '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data;
    my $ok  = eval { $data = decode_json($body); 1 };
    my $err = $@;
    croak "$label: cannot parse JSON in '$path': $err" unless $ok;

    croak "$label: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    return $data;
}

# Croak on any key in $data outside $allowed (arrayref or hashref). Sorted: deterministic first failure.
sub whitelist_keys {
    my ($class, $data, $allowed, $path) = @_;

    croak $class->label, ": whitelist_keys: 'data' must be a HASH ref"
        unless ref($data) eq 'HASH';

    my %allowed;
    if (ref($allowed) eq 'ARRAY') {
        %allowed = map { $_ => 1 } @$allowed;
    }
    elsif (ref($allowed) eq 'HASH') {
        %allowed = %$allowed;
    }
    else {
        croak $class->label, ": whitelist_keys: 'allowed' must be ARRAY or HASH ref";
    }

    my $label = $class->label;
    for my $k (sort keys %$data) {
        croak "$label: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    return;
}

# Croak unless $name is a defined, non-ref, non-empty, whitespace-free string. $where appends context.
sub validate_name {
    my ($class, $name, $where) = @_;

    my $loc = defined($where) ? $where : '';

    croak $class->label, ": name$loc must be a non-empty whitespace-free string"
        unless defined($name) && !ref($name) && length($name) && $name !~ /\s/;

    return $name;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource - Role for harness resources (job slots,
shared state, memory/disk gating, etc.)

=head1 DESCRIPTION

Resources gate whether a job is allowed to start. The scheduler walks
every resource per-job in a fixed order:

=over 4

=item 1. C<needed(job =E<gt> $job)>

If false, the resource is skipped entirely for this job (no brokenness
check, no C<available> call, no C<assign>).

=item 2. C<is_permanent_broken>

If true, the job is marked to be skipped -- no version of this resource
can ever satisfy it.

=item 3. C<is_usable>

If false (resource is transiently broken or paused), the job is
deferred and retried on a later tick.

=item 4. C<available(job =E<gt> $job)>

Only called when the resource is needed AND usable. Returns C<-1> to
skip the job, C<0> to defer, or a positive integer to grant that many
units.

=back

If every needed resource returns a positive grant, the scheduler calls
C<assign> on each; when the job finishes it calls C<release>. A harness
with no resources is a valid (unlimited concurrency) configuration.
L<App::Yath2::Options::Resource> handles the default auto-inject when
yath is run on the command line.

Resources may also declare supervised subprocesses via L</services>;
the harness owns the fork/supervise/restart loop, the resource never
forks. See L</SERVICES>.

=head1 SYNOPSIS

    package My::Resource;

    use Object::HashBase qw{
        <limit <used
        &Test2::Harness2::Role::Resource
    };

    sub available {
        my ($self, %p) = @_;
        my $need = $p{need} // 1;
        return 0 if ($self->{+LIMIT} - $self->{+USED}) < $need;
        return $need;
    }

    sub status { ... }

=head1 REQUIRED METHODS

Consumers must implement these. The role applies C<requires> to
C<available> and C<status>. C<assign> and C<release> have default
implementations (see L</PROVIDED METHODS>) but most consumers will
either rely on those or implement their own.

=over 4

=item $n = $resource->available(%params)

Only called by the scheduler after C<needed> returned true and the
resource is usable (see L</DESCRIPTION>). The implementation does B<not>
need to re-check brokenness or paused state. Return value is a
three-way signal:

=over 4

=item C<-1>

Resource can never satisfy this job; skip.

=item C<0>

Not available now; defer.

=item C<E<gt> 0>

Granted; the integer is the amount.

=back

C<%params> always includes C<id> and C<job>; resources may accept
additional keys (e.g. C<need =E<gt> 2>).

=item $resource->assign(%params)

Reserve the resource for a job. Receives C<%params> plus an C<env>
hashref the resource may populate with environment variables
exported to the child process.

=item $resource->release(%params)

Release a previously-assigned resource. Receives at least C<id>.

=item $status = $resource->status

Return a hashref describing the resource's current state. Format is
resource-specific.

=back

=head1 PROVIDED METHODS

=over 4

=item $bool = $resource->needed(job =E<gt> $job)

Default: true. Override to opt out per-job; the scheduler then skips
every other check for that pair.

=item $name = $resource->resource_name

Defaults to C<< $self->{+NAME} >> when set, otherwise the lowercased
last component of the class name. Pass C<< name => 'foo' >> at
construction to override.

=item $bool = $resource->is_broken / is_permanent_broken / is_paused

Each accessor returns true iff the corresponding slot is set, except
C<is_broken> also returns true while C<permanent_broken> is set.
Defaults are slot-backed; consumers rarely override.

=item $bool = $resource->is_usable

True when none of broken / permanent_broken / paused are set.

=item $resource->mark_broken / mark_permanent_broken / mark_paused / mark_resumed

Defaults set or clear the corresponding slot. C<mark_permanent_broken>
sets both C<broken> and C<permanent_broken> (sticky). C<mark_resumed>
clears C<paused> and C<broken> but preserves C<permanent_broken>.
Consumers with extra bookkeeping override locally.

=item $bool = $resource->assign(%params) / release(%params)

Defaults validate required keys (C<id>, C<job>, C<env> hashref for
C<assign>; C<id> for C<release>) and return C<1>; no per-id state
is kept. Override for richer bookkeeping.

=item $resource->set_in_flight_ref(\$counter)

Installed once by the scheduler at registration time. Resources
should not call this themselves.

=item $n = $resource->in_flight

Current in-flight job count. Croaks if called before
C<set_in_flight_ref>.

=item \@prefixes = $class->inline_key_prefixes

Bare key tokens (without C<=>) that this class's C<parse_options>
recognises as inline key/value entries. Defaults to C<[]>; override
to extend.

=item $bool = $class->is_unknown_kv_arg($arg, $has_next)

True when C<$arg> looks like an unknown C<key=value> token from the
resource-group settings hash. Used by C<parse_options> to silently
drop unknown keys it did not request.

=item @entries = $resource->services

List of supervised subprocesses, each an arrayref
C<[ $service_class, @construction_params ]>. C<$service_class> must
consume L<Test2::Harness2::Role::ResourceService>. Default: empty
list. See L</SERVICES>.

=item $resource->teardown

Called when the resource is being retired (harness shutdown for
global resources, run completion for per-run resources). Default:
no-op.

=back

=head1 SERVICES

A resource declares supervised subprocesses via L</services>. The
host instantiates each one, supervising its lifecycle; the resource
never forks. Each entry's construction-params list must include
C<name => $name> so the host can derive the service's log path and
enforce per-scope name uniqueness. The host appends C<log_path> and
C<ipcm_info> before calling C<< $service_class->new >>.

Restart behaviour is controlled by
L<Test2::Harness2::Role::ResourceService/restartable>; see that
role for the spiral-protection knobs.

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
