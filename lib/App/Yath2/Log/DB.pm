package App::Yath2::Log::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <backend
    <uuid
    +_scoped
};

# Thin proxy: archive-shaped (matches App::Yath2::Log::Directory /
# App::Yath2::Log::TarZIdx) but every call delegates to a backend
# consuming App::Yath2::Role::DB::Backend.

sub init {
    my $self = shift;
    croak "'backend' is required" unless $self->{+BACKEND};
    croak "backend must consume App::Yath2::Role::DB::Backend"
        unless $self->{+BACKEND}->DOES('App::Yath2::Role::DB::Backend');
    croak "'uuid' is required for an archive-scoped Log::DB"
        unless defined $self->{+UUID};
    return;
}

sub is_live { 0 }
sub static  { 1 }

# uuid is fixed for the life of this object, so the scoped backend
# is invariant -- build once, reuse.
sub _backend {
    my $self = shift;
    return $self->{+_SCOPED}
        //= $self->{+BACKEND}->scoped($self->{+UUID});
}

# 1:1 delegation. Public surface matches Log::Directory / Log::TarZIdx
# so Log::DB instances are interchangeable with the other archive
# backends from a caller's view.
for my $m (qw{
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts event events end_of_events EOE reset
    list_files extract archive insert
}) {
    no strict 'refs';
    *{$m} = sub {
        my $self = shift;
        return $self->_backend->$m(@_);
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::DB - thin proxy for DB-backed yath log archives.

=head1 SYNOPSIS

    use App::Yath2::DB;
    use App::Yath2::Log::DB;

    my $db = App::Yath2::DB->open(file => '/tmp/runs.yath');
    for my $uuid ($db->archives) {
        my $log = App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
        ...;
    }

=head1 DESCRIPTION

Archive-shaped wrapper: same public surface as
L<App::Yath2::Log::Directory> and L<App::Yath2::Log::TarZIdx>. Every
call delegates to a backend consuming
L<App::Yath2::Role::DB::Backend>; backends are constructed via
L<App::Yath2::DB>.

The C<uuid> is fixed for this object's lifetime; the proxy caches the
scoped backend on first call.

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
