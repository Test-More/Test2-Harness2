package App::Yath2::DB;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Test2::Harness2::Util qw/mod2file/;

# open(file => $path, backend => 'internal'|'dbic')
# open(dsn  => $dsn,  user => $u, pass => $p, attrs => \%a, backend => ...)
# open(dbh  => $dbh,  backend => ...)
#
# Returns a Role::DB::Backend doer with no uuid set (multi-archive
# capable). Use ->scoped($uuid) or wrap in App::Yath2::Log::DB to
# scope to one archive.
sub open {
    my ($class, %args) = @_;

    croak "App::Yath2::DB->open requires one of: file, dsn, dbh"
        unless defined $args{file}
        || defined $args{dsn}
        || defined $args{dbh};

    my $backend = delete $args{backend} // 'internal';
    my $impl = _backend_class($backend, %args);

    my $file = mod2file($impl);
    my $ok = eval { require $file; 1 };
    my $err = $@;
    croak "could not load backend '$impl': $err" unless $ok;

    return $impl->new(%args);
}

sub _backend_class {
    my ($name, %args) = @_;
    return 'App::Yath2::DB::DBIC' if $name eq 'dbic';
    if ($name eq 'internal') {
        my $flavor = _detect_flavor(%args);
        return "App::Yath2::DB::Internal::\u${flavor}"
            if $flavor =~ /^(sqlite|postgres|mariadb|mysql)$/;
        croak "unknown internal flavor '$flavor'";
    }
    croak "unknown backend '$name' (expected 'internal' or 'dbic')";
}

# Detect flavor from open() inputs. Caller may also pass flavor =>
# explicitly to override.
sub _detect_flavor {
    my %args = @_;
    return $args{flavor} if defined $args{flavor};

    if (defined $args{dsn}) {
        my $dsn = $args{dsn};
        return 'postgres' if $dsn =~ /^dbi:Pg:/i;
        return 'mariadb'  if $dsn =~ /^dbi:MariaDB:/i;
        return 'mysql'    if $dsn =~ /^dbi:mysql:/i;
        return 'sqlite'   if $dsn =~ /^dbi:SQLite:/i;
        croak "could not detect flavor from DSN: $dsn";
    }

    if (defined $args{dbh}) {
        my $name = $args{dbh}->{Driver}{Name} // '';
        return 'sqlite'   if $name eq 'SQLite';
        return 'postgres' if $name eq 'Pg';
        return 'mariadb'  if $name eq 'MariaDB';
        return 'mysql'    if $name eq 'mysql';
        croak "could not detect flavor from dbh (DBI driver: $name)";
    }

    if (defined $args{file}) {
        # File path: only sqlite is supported as a single-file flavor.
        # New file (does not exist) is assumed sqlite (we'll create it).
        my $f = $args{file};
        return 'sqlite' unless -e $f;

        require App::Yath2::Log;
        my $kind = App::Yath2::Log->_detect_file_kind($f);
        return 'sqlite' if $kind eq 'sqlite';
        croak "file '$f' is not a SQLite database";
    }

    croak "no flavor source available (no file/dbh/dsn)";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB - top-level entry point for yath DB-archive backends.

=head1 SYNOPSIS

    use App::Yath2::DB;

    my $db = App::Yath2::DB->open(file => '/tmp/runs.yath');

    my $db = App::Yath2::DB->open(
        dsn  => 'dbi:Pg:dbname=yath',
        user => 'yath',
        pass => 'yath',
        backend => 'dbic',
    );

    for my $uuid ($db->archives) {
        my $log = App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
        ...
    }

=head1 BACKENDS

Two implementations of L<App::Yath2::Role::DB::Backend>:

=over 4

=item C<backend =E<gt> 'internal'> (default)

L<App::Yath2::DB::Internal>. Raw SQL, per-flavor subclasses
(C<App::Yath2::DB::Internal::{Sqlite,Postgres,MariaDB,MySQL}>).

=item C<backend =E<gt> 'dbic'>

L<App::Yath2::DB::DBIC>. Single class wrapping a
L<DBIx::Class::Schema>; flavor handled by storage detection.

=back

Both consume L<App::Yath2::Role::DB::Backend>. Bootstrap is always
driven by C<share/schema/$flavor.sql>; DBIC's C<deploy()> is never
called.

=cut
