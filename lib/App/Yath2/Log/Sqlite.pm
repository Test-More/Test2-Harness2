package App::Yath2::Log::Sqlite;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <file
    <dbh
    <dsn
    <user
    <pass
    <attrs
    <uuid
};

# Stub backend (M2 step 10d). Loads cleanly so the dispatcher can
# return an instance, but every reader / writer method throws "not
# yet implemented".

sub init {
    my $self = shift;
    croak "Sqlite backend requires one of: file, dbh, dsn"
        unless defined $self->{+FILE}
        || defined $self->{+DBH}
        || defined $self->{+DSN};
    return;
}

sub is_live { 0 }
sub static  { 1 }

my $unimpl = sub {
    my ($name) = @_;
    return sub {
        croak "App::Yath2::Log::Sqlite->$name: not yet implemented (M2 step 10d)";
    };
};

for my $m (qw/
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts
    event events EOE end_of_events reset
    extract archive
/) {
    no strict 'refs';
    *{$m} = $unimpl->($m);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Sqlite - SQLite-backed Log reader (stub).

=head1 DESCRIPTION

Placeholder for the SQLite-backed Log reader. Implementation lands
in M2 step 10d. Every method throws C<not yet implemented>; the
class only exists so the dispatcher in L<App::Yath2::Log> can route
SQLite-detected archives without exploding at compile time.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
