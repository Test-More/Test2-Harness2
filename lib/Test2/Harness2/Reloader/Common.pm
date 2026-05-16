package Test2::Harness2::Reloader::Common;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Cwd qw/abs_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;

use Object::HashBase qw{
    <project_root
    +last_reload_at
    +last_error
    +churn_cache
};

# Reloader::Common -- shared base class for the reloader backends.
#
# Provides:
#   _project_root()          locate the project root by walking up from cwd.
#   _filter_inc()            arrayref of %INC entries inside the project root.
#   _attempt_in_place_reload reload one file; returns (ok, err).
#   find_churn / _attempt_churn_reload
#                            `HARNESS2: churn {` ... `HARNESS2: churn }` partial reload.
#   request_restart($svc)    send preload_restarting IPC + exec a fresh copy.
#
# Subclasses (HiResStat, INotify) supply watch_paths() + do_reload().

sub init {
    my $self = shift;
    $self->{+PROJECT_ROOT}    //= __PACKAGE__->_project_root();
    $self->{+LAST_RELOAD_AT}  //= 0;
    $self->{+CHURN_CACHE}     //= {};
}

# Walk up from cwd looking for a .yath.rc* file or a .git directory.
# Returns an absolute path (cwd if no marker found). The first marker
# hit wins; .yath.rc* takes precedence over .git only within the same
# directory.
sub _project_root {
    my ($class, $start) = @_;
    $start //= File::Spec->rel2abs('.');
    $start = abs_path($start) // $start;

    my @parts = File::Spec->splitdir($start);
    while (@parts) {
        my $dir = File::Spec->catdir(@parts);
        return $dir if defined _has_yath_rc($dir);
        return $dir if -d File::Spec->catdir($dir, '.git');
        pop @parts;
    }
    return $start;
}

sub _has_yath_rc {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return undef;
    while (defined(my $entry = readdir($dh))) {
        next unless $entry =~ /\A\.yath\.rc/;
        my $path = File::Spec->catfile($dir, $entry);
        if (-f $path) {
            closedir $dh;
            return $path;
        }
    }
    closedir $dh;
    return undef;
}

# Walk %INC, return the entries whose absolute file lives under
# project_root. Returns an arrayref of [$inc_key, $abs_path] pairs.
sub _filter_inc {
    my ($self, %opts) = @_;
    my $root = $opts{root} // $self->{+PROJECT_ROOT};
    return [] unless defined $root && length $root;

    # Normalize root with trailing separator so the prefix check does
    # not accept /foo/bar2 when root is /foo/bar.
    my $root_with_sep = $root;
    $root_with_sep .= '/' unless $root_with_sep =~ m{/\z};

    my @out;
    for my $key (keys %INC) {
        my $abs = $INC{$key};
        next unless defined $abs && !ref $abs && length $abs;
        my $resolved = abs_path($abs) // $abs;
        next unless 0 == index($resolved, $root_with_sep);
        push @out => [$key, $resolved];
    }
    return \@out;
}

# Attempt to reload a single file in place. Returns ($ok, $err):
#
#   ($ok, undef)    success.
#   (0,   $err)     failure with a descriptive error.
#
# Strategy:
#   1. Identify the inc_key for $file (from %INC reverse-lookup) when
#      possible.
#   2. Symbol-table sweep: clear the module's package stash. This
#      drops stale subs/constants/closures before we re-require.
#   3. Moose meta dance (when Class::MOP::class_of returns a meta):
#      reset_package, recompile, re-apply roles.
#   4. delete $INC{$file} + $INC{$inc_key}, then require $file.
#   5. Set %INC entries back.
#
# Compile errors are caught and surfaced as the $err return value
# (never re-thrown). Caller decides whether to flip the resource to
# transient broken or request a restart.
sub _attempt_in_place_reload {
    my ($self, $file) = @_;
    croak "_attempt_in_place_reload requires a file" unless defined $file && length $file;

    my $abs = abs_path($file) // $file;

    # Locate the %INC key (and module name when discoverable) for
    # this file via reverse lookup.
    my ($inc_key, $mod);
    for my $k (keys %INC) {
        my $v = $INC{$k};
        next unless defined $v;
        my $r = abs_path($v) // $v;
        next unless $r eq $abs;
        $inc_key = $k;
        last;
    }
    if (defined $inc_key) {
        my $stripped = $inc_key;
        $stripped =~ s{\.pm\z}{};
        $stripped =~ s{/}{::}g;
        $mod = $stripped if length $stripped;
    }

    # Moose meta snapshot (best-effort). reset_meta lets us discard
    # the existing class+role wiring so the require below can rebuild
    # it. We only attempt this when Class::MOP is loaded; otherwise
    # ignore.
    if ($mod && $INC{'Class/MOP.pm'}) {
        eval {
            require Class::MOP;
            if (my $meta = Class::MOP::class_of($mod)) {
                if ($meta->can('reset_package_cache_flag')) {
                    $meta->reset_package_cache_flag;
                }
            }
            1;
        };
    }

    # Symbol-table sweep: undef each non-namespace slot in the
    # module's stash before re-require so stale subs do not linger
    # if the new source removed them. Skip when no module name was
    # discoverable (.t script, non-perl file referenced via %INC,
    # etc.). `undef` on a glob name in the stash clears the CODE
    # slot specifically; `delete` on the stash hash leaves the
    # typeglob's CODE slot intact and require's redefine warning is
    # suppressed because perl thinks the sub still exists.
    if (defined $mod && length $mod) {
        no strict 'refs';
        my $stash = \%{"${mod}::"};
        my @syms = grep { !/::\z/ } keys %$stash;
        for my $sym (@syms) {
            undef *{"${mod}::${sym}"};
        }
    }

    delete $INC{$inc_key} if defined $inc_key;
    delete $INC{$file};
    delete $INC{$abs};

    my @warnings;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        local $.;
        require $abs;
        1;
    };
    my $err = $@;

    unless ($ok) {
        # Restore %INC mappings on failure so subsequent reloader
        # ticks can still locate this file as a "module under the
        # project root" candidate. Perl's failed require leaves
        # the slot as a non-creatable hash value (assigning to it
        # raises "Modification of non-creatable hash value"); delete
        # first and then re-set with the abs path.
        for my $k (grep { defined } $inc_key, $file, $abs) {
            delete $INC{$k};
            $INC{$k} = $abs;
        }

        $self->{+LAST_ERROR} = $err;
        return (0, $err);
    }

    # Restore inc entries.
    $INC{$inc_key} //= $abs if defined $inc_key;
    $INC{$file}    //= $abs;
    $INC{$abs}     //= $abs;

    $self->{+LAST_RELOAD_AT} = time;
    $self->{+LAST_ERROR}     = undef;
    return (1, undef);
}

# Send preload_restarting to the harness and exec a fresh copy of
# this process. Used when a structural change (role/inheritance/MRO)
# makes an in-place reload unsafe.
#
# Two-phase to keep tests honest: callers in unit tests inject an
# `exec_cb` so the test sees what argv would have been exec'd
# without actually replacing the process.
sub request_restart {
    my ($self, $svc, %opts) = @_;

    my $client = blessed($svc) && $svc->can('client') ? $svc->client : undef;
    my $name   = blessed($svc) && $svc->can('preload_name')
        ? $svc->preload_name
        : (blessed($svc) && $svc->can('name') ? $svc->name : undef);

    if ($client) {
        my %payload = (
            kind         => 'preload_restarting',
            (defined $name ? (preload_name => $name) : ()),
            ($svc->can('scope')  ? (scope  => $svc->scope)   : ()),
            ($svc->can('run_id') ? (run_id => $svc->run_id)  : ()),
        );
        eval { $client->send_message('harness', \%payload); 1 };
    }

    my $cb = $opts{exec_cb};
    if ($cb) {
        return $cb->([$^X, $0, @ARGV]);
    }

    exec($^X, $0, @ARGV) or die "exec failed in request_restart: $!";
}

# Find HARNESS2: churn { / HARNESS2: churn } block sections in
# $file. Returns a list of arrayrefs [$start_line, $body, $end_line]
# for each section. Used by the churn-only partial reload path.
sub find_churn {
    my ($self, $file) = @_;
    return () unless defined $file && length $file && -f $file;

    open(my $fh, '<', $file) or return ();

    my @out;
    my $active  = 0;
    my $line_no = 0;
    while (defined(my $line = <$fh>)) {
        $line_no++;

        if ($active) {
            if ($line =~ m{\A\s*(?:\#|//)\s*HARNESS2:\s*churn\s*\}\s*\z}) {
                $out[-1][2] = $line_no;
                $active = 0;
                next;
            }
            $out[-1][1] .= $line;
            next;
        }

        if ($line =~ m{\A\s*(?:\#|//)\s*HARNESS2:\s*churn\s*\{\s*\z}) {
            $active = 1;
            push @out => [$line_no, '', undef];
        }
    }
    close $fh;
    return @out;
}

# Attempt a churn-only partial reload: re-eval each CHURN block in
# the module's package with `no warnings 'redefine'`. Module-level
# state outside the CHURN blocks survives. Returns ($ok, $err).
sub _attempt_churn_reload {
    my ($self, $file) = @_;

    my @churn = $self->find_churn($file);
    return (0, "no CHURN sections in $file") unless @churn;

    my ($inc_key, $mod);
    my $abs = abs_path($file) // $file;
    for my $k (keys %INC) {
        my $v = $INC{$k};
        next unless defined $v;
        my $r = abs_path($v) // $v;
        next unless $r eq $abs;
        $inc_key = $k;
        last;
    }
    if (defined $inc_key) {
        my $stripped = $inc_key;
        $stripped =~ s{\.pm\z}{};
        $stripped =~ s{/}{::}g;
        $mod = $stripped if length $stripped;
    }
    return (0, "could not resolve module for $file") unless defined $mod && length $mod;

    for my $block (@churn) {
        my ($start, $body, $end) = @$block;
        my $sline = $start + 1;
        my $code = "package $mod;\n"
            . "use strict;\n"
            . "use warnings;\n"
            . "no warnings 'redefine';\n"
            . "#line $sline $abs\n"
            . $body
            . "\n;1;";

        my $ok = eval $code;
        unless ($ok) {
            my $err = $@;
            $self->{+LAST_ERROR} = $err;
            return (0, "churn block $abs lines $start-$end: $err");
        }
    }

    $self->{+LAST_RELOAD_AT} = time;
    $self->{+LAST_ERROR}     = undef;
    return (1, undef);
}

sub last_reload_at { $_[0]->{+LAST_RELOAD_AT} }
sub last_error     { $_[0]->{+LAST_ERROR} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Common - Shared base for reloader backends.

=head1 DESCRIPTION

Common implementation glue for the reloader subsystem. Holds:

=over 4

=item project_root

Result of C<_project_root()>: the absolute directory found by
walking up from cwd until a C<.yath.rc*> file or C<.git/> directory
is found.

=item last_reload_at

Unix epoch of the most recent successful reload (0 if none).

=item last_error

Stringified error from the most recent failed reload (undef on
success or no attempts).

=back

The class provides three reload entry points:

=over 4

=item ($ok, $err) = $rel->_attempt_in_place_reload($file)

Symbol-table sweep + Moose meta reset + require. Returns success
status. Compile errors are caught.

=item ($ok, $err) = $rel->_attempt_churn_reload($file)

For files containing C<HARNESS2: churn {> / C<HARNESS2: churn }>
sections, re-evals only those sections in the module's package with
C<no warnings 'redefine'>. Module-level state outside the sections
survives.

=item $rel->request_restart($svc, %opts)

Sends a C<preload_restarting> IPC to the harness, then C<exec()>s
C<$^X $0 @ARGV>. When C<%opts> contains an C<exec_cb> coderef the
callback receives the argv list instead of actually exec()ing -- used
by unit tests to verify the argv shape without replacing the process.

=back

Subclasses (L<Test2::Harness2::Reloader::HiResStat>,
L<Test2::Harness2::Reloader::INotify>) consume
L<Test2::Harness2::Role::Reloader> and provide C<watch_paths> +
C<do_reload>.

=cut
