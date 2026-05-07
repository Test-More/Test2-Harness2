package Test2::Harness2::Test::DBVersions;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';

our @EXPORT_OK = qw/discover_db_versions for_each_db_version/;

# discover_db_versions(@prefixes) — returns a list of [name, bin_path]
# for every directory matching ~/dbs/<prefix>-* whose bin/ subdir
# exists. Multiple prefixes can be passed (e.g. mysql + percona for
# the AnyMySQL-style fallback). Order: prefixes searched in the order
# given; within a prefix, directories are returned sorted by name
# (so mariadb-10.6 < mariadb-12.2 by string sort, which is "good
# enough" — perfect natural-version sort isn't required).
sub discover_db_versions {
    my @prefixes = @_;
    my @found;
    my $home = $ENV{HOME};
    return () unless defined $home && -d "$home/dbs";

    for my $prefix (@prefixes) {
        my $dh;
        opendir($dh, "$home/dbs") or next;
        my @hits;
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            next unless $entry =~ /\A\Q$prefix\E-/;
            my $bin = "$home/dbs/$entry/bin";
            next unless -d $bin;
            push @hits => [$entry, $bin];
        }
        closedir $dh;
        push @found => sort { $a->[0] cmp $b->[0] } @hits;
    }

    return @found;
}

# for_each_db_version(\@prefixes, $body)
#
# Discovers all matching DB versions in ~/dbs. For each, runs $body
# inside a forked subtest named after the version, with $ENV{PATH}
# localized so the version's bin is first. When no versions are
# found, runs $body once at top level with the original $ENV{PATH}
# unchanged — falls back to whatever's installed system-wide.
#
# Forking is required because DBIx::QuickDB and its drivers cache
# resolved binary paths at the package level (e.g. MySQL.pm's
# %PROVIDER_CACHE, PostgreSQL.pm's BEGIN-time $INITDB / $POSTGRES /
# etc.), which would otherwise pin the first-found version for the
# rest of the process and silently invalidate later subtests. Each
# fork starts with fresh package state.
#
# $body is called with two args: ($version_name, $bin_path). In
# fallback mode (no versions discovered), $version_name = 'system'
# and $bin_path = undef, and the body runs in the parent process —
# preserving prior single-version behavior.
sub for_each_db_version {
    my ($prefixes, $body) = @_;
    my @versions = discover_db_versions(@$prefixes);

    if (!@versions) {
        $body->('system', undef);
        return;
    }

    require Test2::IPC;
    require Test2::V0;
    require Test2::AsyncSubtest;
    for my $v (@versions) {
        my ($name, $bin) = @$v;
        my $st = Test2::AsyncSubtest->new(name => $name);
        $st->run_fork(sub {
            local $ENV{PATH} = "$bin:$ENV{PATH}";
            $body->($name, $bin);
        });
        $st->finish;
    }
    return;
}

1;
