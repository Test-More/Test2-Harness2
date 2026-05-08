package App::Yath2::Log::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <db
    <uuid
};

# Thin wrapper around an App::Yath2::DB instance plus an archive UUID.
# Every Role::Log method is a one-liner delegating to $self->db with
# our cached uuid prepended.

sub init {
    my $self = shift;

    croak "'db' is required (must be an App::Yath2::DB instance)"
        unless defined $self->{+DB};
    croak "'db' must be an App::Yath2::DB instance"
        unless eval { $self->{+DB}->isa('App::Yath2::DB') };

    croak "'uuid' is required for an archive-scoped Log::DB"
        unless defined $self->{+UUID};

    return;
}

# Read methods: delegate to App::Yath2::DB with our cached uuid.

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

# Walker: App::Yath2::DB owns the depth-first event walker now. Each
# Log::DB instance carries its own scoped DB so walker state stays
# per-uuid (matches the role contract: each Log handle owns its own
# walker state).
sub event           { my $s = shift; $s->_scoped_db->event        ($s->{+UUID}, @_) }
sub events          { my $s = shift; $s->_scoped_db->events       ($s->{+UUID}, @_) }
sub end_of_events   { my $s = shift; $s->_scoped_db->end_of_events($s->{+UUID}) }
sub EOE             { my $s = shift; $s->_scoped_db->EOE          ($s->{+UUID}) }
sub reset           { my $s = shift; $s->_scoped_db->reset        ($s->{+UUID}) }

# Use a uuid-scoped clone of the underlying App::Yath2::DB so walker
# state lives in this Log::DB instance (rather than on the shared
# multi-archive DB). Lazy + cached.
sub _scoped_db {
    my $self = shift;
    return $self->{_scoped_db} //= $self->{+DB}->scoped($self->{+UUID});
}

# Write paths flow through App::Yath2::DB directly.
#
# extract: $log->extract($dir, %opts) -> App::Yath2::Log::Directory
# archive: $log->archive($out, %opts) -> sealed-form Log handle
# insert:  $log->insert($source, %opts) -> $new_archive_id (integer)
sub extract         { my $s = shift; $s->{+DB}->extract       ($s->{+UUID}, @_) }
sub archive         { my $s = shift; $s->{+DB}->archive_to    ($s->{+UUID}, @_) }
sub insert          { my $s = shift; $s->{+DB}->insert        (@_) }
sub _artifact_save  { my $s = shift; $s->{+DB}->save_artifact ($s->{+UUID}, @_) }

# Artifact factory: delegated to App::Yath2::DB. The Artifact handle
# returned binds to a uuid-scoped DB clone, so its private _artifact_*
# calls land on App::Yath2::DB without going through this Log::DB at
# all -- meaning bytes are returned in the canonical shapes the data
# layer produces.
sub artifacts       { my $s = shift; $s->{+DB}->artifacts      ($s->{+UUID}, @_) }

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
