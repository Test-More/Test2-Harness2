package App::Yath2::Options::Resource;
use strict;
use warnings;

our $VERSION = '2.000013';

use Test2::Harness2::Util qw/mod2file fqmod/;

use Getopt::Yath;

option_group {group => 'resource', category => "Resource Options"} => sub {
    option classes => (
        type  => 'Map',
        short => 'R',
        name  => 'resources',
        field => 'classes',
        alt   => ['resource'],

        description => 'Specify resources. Use "+" to give a fully qualified module name. Without "+" "App::Yath2::Resource::" and "Test2::Harness2::Resource::" will be searched for a matching resource module.',

        long_examples  => [' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],
        short_examples => ['MyResource',     ' +My::Resource', ' MyResource,MyOtherResource', ' MyResource=opt1,opt2', ' :{ MyResource :{ opt1 opt2 }: }:', '=:{ MyResource opt1,opt2,... }:'],

        normalize => sub { fqmod($_[0], ['App::Yath2::Resource', 'Test2::Harness2::Resource']), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,

        # --no-resource / --no-resources is the auto-generated clear
        # form. Record the clear so the post-process step below can
        # tell "user explicitly asked for no limiter" apart from "user
        # never specified one".
        trigger => sub {
            my $opt    = shift;
            my %params = @_;
            return unless $params{action} eq 'clear';
            $params{group}->{no_resource} = 1;
        },
    );

    option slots => (
        type           => 'Scalar',
        short          => 'j',
        alt            => ['jobs', 'job-count'],
        description    => 'Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.',
        notes          => "On Linux, if unset, no hard concurrency cap is applied; the default utilizer + throttle resources gate scheduling. On other platforms (where the utilizer/throttle stack is unavailable) an unset value auto-derives to half the logical CPU count (minimum 1), falling back to 2 when the count cannot be detected. Install System::Info for the most reliable cross-platform CPU count.",
        long_examples  => [' 4', ' 8:2'],
        short_examples => ['4',  '8:2'],
        from_env_vars  => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],

        default => sub { undef },

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            if ($params{action} eq 'set' || $params{action} eq 'initialize') {
                my ($val) = @{$params{val}};
                return unless $val && $val =~ m/:/;
                my ($jobs, $slots) = split /:/, $val;
                @{$params{val}} = ($jobs);
                $params{group}->{job_slots} = $slots;
            }
        },
    );

    option job_slots => (
        type  => 'Scalar',
        alt   => ['slots-per-job'],
        short => 'x',

        description    => "This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.",
        from_env_vars  => ['T2_HARNESS_JOB_CONCURRENCY'],
        clear_env_vars => ['T2_HARNESS_JOB_CONCURRENCY'],
        long_examples  => [' 2'],
        short_examples => ['2'],

        default => sub { 1 },
    );

    # The "no limiter at all, run with unlimited concurrency" opt-out
    # rides on the auto-generated --no-resource / --no-resources clear
    # form of the `classes` Map option above. Getopt::Yath registers
    # those automatically (every option gets a --no-X clear form, plus
    # one per `alt`). The `classes` option's trigger above records
    # whether a clear was requested in $group->{no_resource}; the
    # post-process step below honours that flag (and refuses to inject
    # the default JobCount).

    option utilize => (
        type           => 'Scalar',
        short          => 'U',
        description    => 'Percentage of system utilization (0 < pct < 100) at which any utilization-aware resources should signal temporarily-unavailable. Each resource that consumes the Test2::Harness2::Role::Resource::Utilizer role is given this percentage; once its monitored subsystem (CPU, memory, /tmp space, etc.) crosses the threshold the resource starts deferring new assignments. Pairs with a per-class spawn-throttle window (see POD).',
        long_examples  => [' 80', ' 50'],
        short_examples => [' 80', ' 50'],
        default        => sub { 75 },

        # The role implementations are not wired up yet; this option is
        # a stub that validates the input and propagates it through
        # settings so each resource can pick it up when the role
        # contract is implemented.
        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            return unless $params{action} eq 'set' || $params{action} eq 'initialize';

            my ($val) = @{$params{val}};
            return unless defined $val;

            die "--utilize must be a number\n"
                unless $val =~ m/^[0-9]+(?:\.[0-9]+)?\z/;

            die "--utilize must be greater than 0 and less than 100 (got '$val')\n"
                unless $val > 0 && $val < 100;
        },
    );

    option_post_process 50 => \&jobs_post_process;
};

sub jobs_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $resource = $settings->resource;

    $resource->option(job_slots => 1)  unless $resource->job_slots;
    $resource->option(classes   => {}) unless $resource->classes;

    my $slots     = $resource->slots;       # may be undef (user did not pass -j)
    my $job_slots = $resource->job_slots;

    if (defined $slots) {
        die "The slots per job (set to $job_slots) must not be larger than the total number of slots (set to $slots).\n"
            if $job_slots > $slots;
    }

    return if $resource->check_option('no_resource') && $resource->no_resource;

    # Inject default resources. //= preserves any class the user passed via -R.
    my $utilize = $resource->utilize;

    if ($^O eq 'linux') {
        my @util_args = (utilize_percent => $utilize);

        $resource->classes->{'Test2::Harness2::Resource::CPU'}        //= [@util_args];
        $resource->classes->{'Test2::Harness2::Resource::Memory'}     //= [@util_args];
        $resource->classes->{'Test2::Harness2::Resource::UnixLimits'} //= [@util_args];
        $resource->classes->{'Test2::Harness2::Resource::PipeLimits'} //= [@util_args];
        $resource->classes->{'Test2::Harness2::Resource::Throttle'}   //= ['1/core,100mb/1s'];
    }
    elsif (!defined $slots) {
        # The utilizer + throttle stack reads /proc on Linux; off-Linux
        # there is no portable equivalent. Fall back to a JobCount cap
        # derived from the CPU count: half the logical CPUs (minimum 1),
        # or 2 when the count cannot be detected.
        my $cpu = _detect_cpu_count();
        my $auto = $cpu ? (int($cpu / 2) || 1) : 2;
        $resource->option(slots => $auto);
        $slots = $auto;
    }

    # Disk gate on system tmpdir, derived from --utilize. Skipped when
    # Filesys::Df missing; auto-injecting it would croak with a confusing dep error.
    # orig_tmp captures the real tmpdir before yath rewrites TMPDIR to the per-run
    # workspace (see App::Yath2::Options::Workspace).
    if (eval { require Filesys::Df; 1 }) {
        require File::Spec;
        my $tmpdir  = ($settings->check_group('yath') ? $settings->yath->orig_tmp : undef) // File::Spec->tmpdir;
        my $min_pct = 100 - $utilize;
        $resource->classes->{'Test2::Harness2::Resource::Disk'} //= ["$tmpdir:${min_pct}%"];
    }

    # -j N (explicit or auto-derived): add JobCount as a hard cap.
    if (defined $slots) {
        $resource->classes->{'Test2::Harness2::Resource::JobCount'} //= [];
    }
}

# Best-effort cross-platform logical-CPU count. Returns undef when no
# detection path works.
#
# Order: System::Info (cross-platform CPAN dep when present), then
# POSIX sysconf (Linux/macOS/BSD), then Windows NUMBER_OF_PROCESSORS.
sub _detect_cpu_count {
    my $n = eval { require System::Info; System::Info->new->ncore };
    return $n if defined($n) && $n =~ /^\d+\z/ && $n > 0;

    if ($^O eq 'MSWin32') {
        $n = $ENV{NUMBER_OF_PROCESSORS};
        return $n if defined($n) && $n =~ /^\d+\z/ && $n > 0;
        return undef;
    }

    $n = eval {
        require POSIX;
        POSIX::sysconf(&POSIX::_SC_NPROCESSORS_ONLN);
    };
    return $n if defined($n) && $n =~ /^\d+\z/ && $n > 0;
    return undef;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Resource - Resource-related options for yath commands.

=head1 DESCRIPTION

Defines the C<--resource> / C<-R>, C<--slots> / C<-j>, C<--job-slots>
/ C<-x>, C<--no-resource>, and C<--utilize> / C<-U> options, and
post-processes them to auto-inject the default resource stack.

=head2 Linux defaults

On Linux, yath auto-injects the L<Test2::Harness2::Role::Resource::Utilizer>
stack: L<CPU|Test2::Harness2::Resource::CPU>,
L<Memory|Test2::Harness2::Resource::Memory>,
L<UnixLimits|Test2::Harness2::Resource::UnixLimits>,
L<PipeLimits|Test2::Harness2::Resource::PipeLimits>, and
L<Throttle|Test2::Harness2::Resource::Throttle>. Each consumes the
percentage from C<--utilize> as its "defer when subsystem busier than
this" threshold. With no C<-j> the scheduler runs no hard cap -- the
utilizer/throttle stack alone gates new launches.

Passing C<-j N> on Linux is supported: it adds
L<JobCount|Test2::Harness2::Resource::JobCount> as a hard cap I<in
addition to> the utilizer/throttle stack. Use this when you want a
firm upper bound on concurrency regardless of system load.

=head2 Non-Linux defaults

The utilizer/throttle stack samples C</proc> and is Linux-only. On
other platforms those resources are not auto-injected; yath falls
back to L<JobCount|Test2::Harness2::Resource::JobCount>. With no
C<-j>, the slot count is derived from the detected logical CPU
count (half, minimum 1), or C<2> when the count cannot be detected.
Pass C<-j N> to override.

CPU-count detection order: L<System::Info> (when installed), POSIX
C<sysconf(_SC_NPROCESSORS_ONLN)> (macOS/BSD/Solaris), then
C<%ENV{NUMBER_OF_PROCESSORS}> (Windows). Install L<System::Info> for
the most reliable cross-platform reading.

=head2 The --utilize / -U option

C<--utilize PCT> accepts a percentage strictly greater than C<0> and
strictly less than C<100>; values outside that range or non-numeric
values are rejected at option-parse time. The default is C<75>.

Every auto-injected resource that consumes
L<Test2::Harness2::Role::Resource::Utilizer> receives the percentage
as its C<utilize_percent> attribute. Each resource interprets that as
"this subsystem is too utilized; defer new assignments" against its
own monitored subsystem (CPU load, free memory, pipe pages, ulimit
headroom, etc.). C<--utilize> also feeds the Disk gate's
C<min_free_pct = 100 - utilize>.

=head2 Auto-injected Disk resource

When L<Filesys::Df> is installed, yath automatically injects
L<Test2::Harness2::Resource::Disk> targeting the system temporary
directory (C<File::Spec-E<gt>tmpdir>, typically F</tmp>). The minimum
free-space percentage is derived from C<--utilize>:
C<min_free_pct = 100 - utilize>. With the default C<--utilize 75>
that means at least 25% of the tmpdir must remain free before yath
will start another job.

If L<Filesys::Df> is not installed the Disk resource is silently
skipped; no error is raised. To disable disk gating explicitly, pass
C<--no-resource> and re-enable only the resources you want with
C<-R>.

To override the injected Disk settings (different mount, different
threshold), supply your own C<-R Disk=...> on the command line; the
user's entry wins via C<//=> and the auto-injected default is
discarded.

=head2 Spawn-throttle pairing

The percentage gate alone is not sufficient: a freshly spawned test
needs a moment to actually consume CPU/memory/disk before the
resource sample reflects it. Without throttling the harness would
launch a burst of tests against an apparently-idle system and only
notice the over-commit on the next sample.

L<Test2::Harness2::Resource::Throttle> pairs the percentage gate
with a sliding spawn-rate window. Each rule has a C<cap> and a
C<window> in seconds; an in-flight assignment occupies a slot until
its age (time since assignment) exceeds C<window>. New launches are
deferred while the in-window count is at or above C<cap>.

The default rule string is C<1/core,100mb/1s>: one slot per CPU
core, scaled adaptively against free RAM (one slot per 100 MiB free,
with halving fallbacks when memory is tight), measured over a
one-second window. See L<Test2::Harness2::Resource::Throttle> for
the full rule grammar.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

