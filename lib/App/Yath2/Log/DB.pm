package App::Yath2::Log::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <db
    <uuid
    +_legacy_scoped
};

# Thin wrapper around an App::Yath2::DB instance plus an archive UUID.
# Phase 4 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md §6)
# reroutes every read method through $self->db (the new
# App::Yath2::DB API). Methods that App::Yath2::DB does not yet
# implement natively (event/events/EOE/reset, artifacts factory,
# extract/archive/insert/_artifact_save) keep delegating through the
# legacy `$self->db->_legacy_backend->scoped($uuid)` chain until
# Phases 6 and 7 reroute them.

sub init {
    my $self = shift;

    # Accept both shapes during the rebuild's middle phases:
    #   - db => $app_yath2_db          (preferred; new shape)
    #   - backend => $obj              (back-compat; $obj is either an
    #                                   App::Yath2::DB or a doer of
    #                                   App::Yath2::Role::DB::Backend)
    if (defined $self->{+DB}) {
        croak "'db' must be an App::Yath2::DB instance"
            unless eval { $self->{+DB}->isa('App::Yath2::DB') };
    }
    elsif (defined (my $bk = delete $self->{backend})) {
        if (eval { $bk->isa('App::Yath2::DB') }) {
            $self->{+DB} = $bk;
        }
        elsif (eval { $bk->DOES('App::Yath2::Role::DB::Backend') }) {
            require App::Yath2::DB;
            $self->{+DB} = App::Yath2::DB->new(backend_instance => $bk);
        }
        else {
            croak "'backend' must be an App::Yath2::DB or "
                . "App::Yath2::Role::DB::Backend doer";
        }
    }
    else {
        croak "'db' is required (or 'backend' for back-compat)";
    }

    croak "'uuid' is required for an archive-scoped Log::DB"
        unless defined $self->{+UUID};

    return;
}

# Read methods: delegate to App::Yath2::DB with our cached uuid.
# Each is one line; the dispatch is explicit (not for-loop generated)
# so a future grep for `services` / `runs` / etc. on Log::DB lands on
# something readable.

sub services        { my $s = shift; $s->{+DB}->services       ($s->{+UUID}, @_) }
sub runs            { my $s = shift; $s->{+DB}->runs           ($s->{+UUID}, @_) }
sub jobs            { my $s = shift; $s->{+DB}->jobs           ($s->{+UUID}, @_) }
sub tries           { my $s = shift; $s->{+DB}->tries          ($s->{+UUID}, @_) }
sub last_try        { my $s = shift; $s->{+DB}->last_try       ($s->{+UUID}, @_) }
sub has_service     { my $s = shift; $s->{+DB}->has_service    ($s->{+UUID}, @_) }
sub has_run         { my $s = shift; $s->{+DB}->has_run        ($s->{+UUID}, @_) }
sub has_job         { my $s = shift; $s->{+DB}->has_job        ($s->{+UUID}, @_) }
sub has_try         { my $s = shift; $s->{+DB}->has_try        ($s->{+UUID}, @_) }
sub list_files      { my $s = shift; $s->{+DB}->list_files     ($s->{+UUID}, @_) }

sub absolute_path   { my $s = shift; $s->{+DB}->absolute_path  (@_) }

sub _artifact_exists       { my $s = shift; $s->{+DB}->artifact_exists       ($s->{+UUID}, @_) }
sub _artifact_read         { my $s = shift; $s->{+DB}->artifact_read         ($s->{+UUID}, @_) }
sub _artifact_iter_records { my $s = shift; $s->{+DB}->artifact_iter_records ($s->{+UUID}, @_) }
sub _artifact_list_dir     { my $s = shift; $s->{+DB}->artifact_list_dir     ($s->{+UUID}, @_) }
sub _artifact_open_fh      { my $s = shift; $s->{+DB}->artifact_open_fh      ($s->{+UUID}, @_) }

# Methods that App::Yath2::DB does not yet implement natively. These
# go through the legacy backend chain (scoped to our uuid) until the
# remaining rebuild phases (6 for write paths, 7 for the event walker
# and artifacts factory) lift them onto App::Yath2::DB. The legacy
# scoped backend is invariant for our uuid -- build once, reuse.
sub _legacy_scoped {
    my $self = shift;
    return $self->{+_LEGACY_SCOPED}
        //= $self->{+DB}->legacy_scoped_for_uuid($self->{+UUID});
}

sub event           { my $s = shift; $s->_legacy_scoped->event        (@_) }
sub events          { my $s = shift; $s->_legacy_scoped->events       (@_) }
sub end_of_events   { my $s = shift; $s->_legacy_scoped->end_of_events(@_) }
sub reset           { my $s = shift; $s->_legacy_scoped->reset        (@_) }
sub extract         { my $s = shift; $s->_legacy_scoped->extract      (@_) }
sub archive         { my $s = shift; $s->_legacy_scoped->archive      (@_) }
sub insert          { my $s = shift; $s->_legacy_scoped->insert       (@_) }
sub _artifact_save  { my $s = shift; $s->_legacy_scoped->_artifact_save(@_) }

# artifacts() factory mirrors Role::DB::Backend's default but binds
# the resulting App::Yath2::Log::Artifact to $self (a Log::DB) instead
# of the legacy backend. Without this override, the Artifact handle
# would dispatch _artifact_* back into the legacy chain and bypass the
# new App::Yath2::DB read paths -- meaning meta.json reconstruction
# (and similar) would still come back in legacy DB-native shapes
# rather than the canonical forms App::Yath2::DB returns. Phase 7
# moves the factory onto App::Yath2::DB itself; until then this
# override keeps reads consistent.
sub artifacts {
    my $self = shift;
    require Test2::Harness2::LogLayout;

    return $self->_artifacts_from_args($_[0]) if @_ == 1 && ref($_[0]) eq 'HASH';
    return $self->_artifacts_root             unless @_;

    my @args = @_;
    if (@args == 1) {
        my $arg = $args[0];
        if (defined $arg && $arg =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $arg});
        }
        if (defined $arg && $self->has_service($arg)) {
            return $self->_artifacts_from_args({service => $arg});
        }
        return $self->_artifacts_from_args({run_id => $arg});
    }
    if (@args == 2) {
        my ($run_id, $second) = @args;
        if (defined $second && $second =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $run_id, job_id => $second});
        }
        return $self->_artifacts_from_args({run_id => $run_id, service => $second});
    }
    if (@args == 3) {
        my ($run_id, $job_id, $job_try) = @args;
        return $self->_artifacts_from_args({
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job_try,
        });
    }
    croak "artifacts() got too many positional arguments";
}

sub _artifacts_root {
    my $self = shift;
    require App::Yath2::Log::Artifact;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => undef,
        base => undef,
        live => 0,
    );
}

sub _make_artifact {
    my ($self, $base) = @_;
    require App::Yath2::Log::Artifact;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => undef,
        base => $base,
        live => 0,
    );
}

sub _artifacts_from_args {
    my ($self, $args) = @_;
    require Test2::Harness2::LogLayout;
    my $service = $args->{service};
    my $run_id  = $args->{run_id};
    my $job_id  = $args->{job_id};
    my $job_try = $args->{job_try};

    croak "service name cannot start with a digit"
        if defined $service && $service =~ /^\d/;

    if (defined $service) {
        if (defined $run_id) {
            croak "no such run: $run_id" unless $self->has_run($run_id);
            croak "no such service: $service in run $run_id"
                unless $self->has_service($service, $run_id);
            return $self->_make_artifact(
                Test2::Harness2::LogLayout::service_run_dir($run_id, $service));
        }
        croak "no such service: $service"
            unless $self->has_service($service);
        return $self->_make_artifact(
            Test2::Harness2::LogLayout::service_global_dir($service));
    }

    if (defined $job_id) {
        croak "run_id is required when job_id is given"
            unless defined $run_id;
        croak "no such run: $run_id"          unless $self->has_run($run_id);
        croak "no such job: $run_id/$job_id"  unless $self->has_job($run_id, $job_id);

        if (!defined $job_try) {
            my $lt = $self->last_try($run_id, $job_id);
            croak "no tries for job $run_id/$job_id"
                unless defined $lt;
            $job_try = $lt;
        }
        croak "no such try: $run_id/$job_id/$job_try"
            unless $self->has_try($run_id, $job_id, $job_try);

        return $self->_make_artifact(
            Test2::Harness2::LogLayout::job_dir($run_id, $job_id, $job_try));
    }

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        return $self->_make_artifact(
            Test2::Harness2::LogLayout::run_dir($run_id));
    }

    return $self->_artifacts_root;
}

# Apply the Log role after our own methods are installed so role
# defaults (which would otherwise be installed first and then
# clobbered, generating redefine warnings) yield to our definitions.
use Role::Tiny::With;
with 'App::Yath2::Role::Log';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::DB - thin wrapper for DB-backed yath log archives.

=head1 SYNOPSIS

    use App::Yath2::DB;
    use App::Yath2::Log::DB;

    my $db = App::Yath2::DB->new(file => '/tmp/runs.yath');
    for my $uuid ($db->archives) {
        my $log = App::Yath2::Log::DB->new(db => $db, uuid => $uuid);
        ...;
    }

=head1 DESCRIPTION

Archive-shaped wrapper: same public surface as
L<App::Yath2::Log::Directory> and L<App::Yath2::Log::TarZIdx>. Read
methods delegate to L<App::Yath2::DB> with the cached C<uuid>.

The C<uuid> is fixed for this object's lifetime.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
