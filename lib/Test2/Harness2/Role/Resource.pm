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
    my $ref = $_[0]->{+IN_FLIGHT_REF};
    return defined($ref) ? ${$ref} : 0;
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
C<assign> on each; when the job finishes it calls C<release>. The
harness itself does not mandate any specific resource class. A harness
constructed with no resources at all is a valid (unlimited concurrency)
configuration. The C<yath test> command is the layer that injects a
default L<Test2::Harness2::Resource::JobCount> when the user has not
specified a resource on the command line.

Resources may also declare one or more supervised subprocesses via the
L</services> method. The harness instantiates and supervises each one;
the resource itself never forks. See L</SERVICES> below.

=head1 SYNOPSIS

    package My::Resource;
    use strict;
    use warnings;

    use Object::HashBase qw{
        <limit
        <used
        &Test2::Harness2::Role::Resource
    };

    sub available {
        my ($self, %p) = @_;
        my $need = $p{need} // 1;
        return 0 if ($self->{+LIMIT} - $self->{+USED}) < $need;
        return $need;
    }

    # Role provides assign / release / mark_paused / mark_resumed /
    # is_paused defaults; override only for richer bookkeeping.

    sub status { ... }

    sub services {
        my $self = shift;
        return (
            [ 'My::Resource::Daemon', name => 'mydaemon', config => $self->config ],
        );
    }

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

This resource can never satisfy the request (e.g. the run needs 8 slots but
only 4 exist). The job should be skipped, not deferred.

=item C<0>

Not available right now, try again later. No blocking state should be
implied.

=item C<E<gt> 0>

Resource is available; the integer is the amount granted (for
multi-unit resources this may be less than requested).

=back

C<%params> is free-form and depends on the resource. The scheduler passes
at least C<id> (assignment id) and C<job> (the L<Test2::Harness2::Run::Job>
object); resources may accept additional keys to express richer requests
(e.g. 'need => 2').

=item $resource->assign(%params)

Reserve the resource for a job. Called only after C<available> returned a
positive number. Receives the same C<%params> plus an C<env> hashref the
resource may populate with environment variables that should be exported to
the child process (see L<Test2::Harness2::Resource::JobCount> for an
example).

=item $resource->release(%params)

Release a previously-assigned resource. Receives at least the C<id> passed
to C<assign>.

=item $status = $resource->status

Return a hashref describing the resource's current state (useful for UI
display or the C<resources> status request). Format is resource-specific;
at minimum include enough to show the operator what is assigned and what is
free.

=back

=head1 PROVIDED METHODS

=over 4

=item $bool = $resource->needed(job =E<gt> $job)

Default: true. Override to opt this resource out for jobs that do not
need it -- the scheduler then skips every subsequent step
(brokenness/usable/available/assign/release) for that (resource, job)
pair.

=item $name = $resource->resource_name

Default: returns C<< $self->{+NAME} >> when set, otherwise the last
component of the class name, lowercased. The C<name> slot is declared
on the role itself, so consumers gain it through the L<Object::HashBase>
C<&> import; setting it at construction time (e.g. C<< MyRes->new(name => 'foo') >>)
gives the resource a custom identifier without overriding this method.

=item $bool = $resource->is_broken / is_permanent_broken / is_paused

Return whether the resource is in the corresponding state. A broken or
permanently-broken resource must not be assigned new work. A paused
resource should likewise refuse assignment but may resume later. The
role's default implementations read the C<broken>, C<permanent_broken>,
and C<paused> slots (all declared on the role itself); C<is_broken>
also returns true while C<permanent_broken> is set. Consumers gain the slots
through the L<Object::HashBase> C<&> import and rarely override the
accessors.

=item $bool = $resource->is_usable

True when none of broken / permanent_broken / paused are set.

=item $resource->mark_broken / mark_permanent_broken / mark_paused / mark_resumed

State-transition hooks. The role's defaults set / clear the
corresponding slot:

=over 4

=item *

C<mark_broken> sets C<broken>.

=item *

C<mark_permanent_broken> sets both C<broken> and C<permanent_broken>;
the permanent flag is sticky.

=item *

C<mark_paused> sets C<paused>.

=item *

C<mark_resumed> clears C<paused> and C<broken>, but leaves
C<permanent_broken> intact -- a permanently-broken resource stays
broken across resume.

=back

Consumers with extra bookkeeping (e.g. clearing per-mount sample
caches on resume, refusing transitions a backing service does not
support) override locally.

=item $bool = $resource->assign(%params) / release(%params)

Default implementations store / delete one record per assignment id
in the C<assignments> hash slot:

    $self->{assignments}->{$id} = { job => $job, assigned_at => $stamp }

The C<assignments> and C<paused> slots are declared on the role
itself, so consumers importing the role via the L<Object::HashBase>
C<&> prefix inherit both slots automatically. Resources with richer
bookkeeping (slot-count math, time-windowed queues, etc.) override
C<assign> / C<release> locally.

=item \@prefixes = $class->inline_key_prefixes

Arrayref of bare key tokens (without the trailing C<=>) that the
consumer's C<parse_options> recognises as inline key/value entries.
Defaults to C<[]>. Consumers with extra inline forms override.

=item $bool = $class->is_unknown_kv_arg($arg, $has_next)

Predicate for "is this C<$arg> the first half of an unknown
key=>value pair from the resource-group settings hash that should be
silently dropped?" The default returns true when C<$arg> is a plain
key-shaped token (not numeric, not C<@file>, not C<name=>, not in
C<inline_key_prefixes>) and there is a following value to pair it
with. Resources whose grammar does not fit this shape override
locally.

=item @entries = $resource->services

Return the list of supervised subprocesses this resource requires.
Each entry is an arrayref:

    [ $service_class, @construction_params ]

C<$service_class> must consume L<Test2::Harness2::Role::ResourceService>.
C<@construction_params> are passed verbatim to
C<< $service_class->new >>; the host adds C<name>, C<log_path>, and
C<ipcm_info> on top before construction.

Default: empty list. A resource that only needs supervision in certain
environments returns an empty list when no service is applicable; there
is no separate "applicable" hook.

=item $resource->teardown

Called when the resource is being retired (harness shutdown for global
resources, run completion for per-run resources). Default: no-op.

=back

=head1 SERVICES

A resource declares its supervised subprocesses via L</services>. Each
entry names a class that consumes L<Test2::Harness2::Role::ResourceService>
plus the constructor arguments for one instance of that class. The host
is responsible for instantiating the service, spawning it, tracking its
pid, and restarting or retiring it when it exits. The resource itself
never forks.

The first argument of each construction-params list B<must> be C<name>
(followed by the service's desired unique name within its scope). The
host reads the name to derive the service's log file path and to
enforce per-scope name uniqueness.

Every service instance is constructed as:

    $service_class->new(
        @construction_params,
        name      => $name,         # mandatory; first pair in @construction_params
        log_path  => $log_path,     # host-derived from name + scope
        ipcm_info => $ipcm_info,    # host's IPC::Manager info
    );

Any additional arguments the resource wants to pass go before C<name>
in the params list.

=head2 Restartability

L<Test2::Harness2::Role::ResourceService/restartable> controls the
host's behaviour when the service exits before shutdown. A
non-restartable service that exits flips the owning resource to
C<permanent_broken>; a restartable service is re-spawned, subject to
spiral protection (C<$host-E<gt>max_restart_attempts>,
C<$host-E<gt>restart_healthy_secs>).

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
