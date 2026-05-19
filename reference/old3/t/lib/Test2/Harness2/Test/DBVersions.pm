package Test2::Harness2::Test::DBVersions;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer Importer => 'import';

use Test2::Tools::QuickDB ();

our @EXPORT_OK = qw/discover_db_versions for_each_db_version get_quiet_db for_each_log_db_backend/;

# Run $body once per backend, wrapped in a named subtest. Body
# receives the backend name as its only arg. The 'dbic' iteration is
# skipped when DBIx::Class isn't installed (so hosts without the
# optional dependency stay green).
#
# Backend names track the DB rebuild
# (AI_DOCS/2026-05-08-yath-db-rebuild.md). Phase 6 adds insert/extract/
# archive_to/save_artifact on App::Yath2::DB, so the test surface
# iterates the new ('sql', 'dbic') pair. The legacy 'internal' backend
# remains accepted as a deprecated alias for 'sql' until Phase 9.
sub for_each_log_db_backend {
    my ($body) = @_;
    require Test2::V0;
    # Test2::V0 seeds srand from local date for reproducibility, which
    # means parallel test workers all use the SAME random state and
    # File::Temp::tempfile() produces colliding paths across processes.
    # Re-seed with PID so each worker's temp paths are unique. The
    # backend-iteration tests do not depend on srand reproducibility
    # (no rand() in assertions), so this is safe.
    srand(time ^ ($$ + ($$ << 15)));
    for my $name (qw/sql dbic/) {
        if ($name eq 'dbic') {
            my $ok = eval { require DBIx::Class; 1 };
            unless ($ok) {
                Test2::V0::diag("skipping dbic backend: DBIx::Class not available");
                next;
            }
        }
        Test2::V0::subtest("backend=$name" => sub { $body->($name) });
    }
    return;
}

# Tracks DBs returned by get_quiet_db so we can call ->stop on them at
# process exit (END). $qdb->stop disconnects DBI handles owned by the
# test process before signaling the watcher, which lets postgres exit
# cleanly under SIGTERM ("smart" shutdown waits for clients) instead of
# timing out and getting SIGKILL'd. Without this, the implicit DESTROY
# path uses $watcher->eliminate (no DBI cleanup) and we get noisy
# "Server taking too long to shut down, sending SIGKILL" warnings plus
# "FATAL: terminating connection due to unexpected postmaster exit"
# messages from in-flight backends. Tracked per-pid so a forked subtest
# (see for_each_db_version) only stops DBs it actually created.
my %CLEANUP;

END {
    my $list = delete $CLEANUP{$$} or return;
    for my $db (@$list) {
        eval { $db->stop; 1 };
    }
}

# get_quiet_db(\%spec) — wraps Test2::Tools::QuickDB::get_db, injecting
# driver-specific config that suppresses startup chatter to STDERR and
# registering an END-block teardown that disconnects DBI handles before
# stopping the server (see %CLEANUP comment above).
#
# Postgres normally prints "listening on Unix socket ...", "redirecting
# log output to logging collector process", and "Future log output ..."
# at startup; under yath those land in the test's captured STDERR.
# log_min_messages='fatal' + logging_collector='off' keeps it quiet.
sub get_quiet_db {
    my $spec = ref($_[0]) eq 'HASH' ? {%{$_[0]}} : {@_};
    my $driver = $spec->{driver} // '';

    if ($driver =~ /(?:Postgres|^Pg$)/i) {
        $spec->{config} //= {};
        # 'panic' (not 'fatal') so postgres backends do not log the
        # transient "FATAL: the database system is starting up" line
        # during bootstrap retries. log_min_messages='fatal' still
        # logs FATAL; only 'panic' excludes it.
        $spec->{config}{log_min_messages}  //= "'panic'";
        $spec->{config}{logging_collector} //= "'off'";
    }

    my $db = Test2::Tools::QuickDB::get_db($spec);
    push @{$CLEANUP{$$} //= []}, $db;
    return $db;
}

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
            push @hits => [$entry, $bin, $prefix];
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
# $body is called with three args: ($version_name, $bin_path, $prefix).
# $prefix is the matched ~/dbs/<prefix>-* token (e.g. 'mysql' vs
# 'percona') so the body can pick a flavor-specific QuickDB driver. In
# fallback mode (no versions discovered), all three are passed as
# ('system', undef, undef) and the body runs in the parent process —
# preserving prior single-version behavior.
sub for_each_db_version {
    my ($prefixes, $body) = @_;
    my @versions = discover_db_versions(@$prefixes);

    if (!@versions) {
        $body->('system', undef, undef);
        return;
    }

    require Test2::IPC;
    require Test2::V0;
    require Test2::AsyncSubtest;
    for my $v (@versions) {
        my ($name, $bin, $prefix) = @$v;
        my $st = Test2::AsyncSubtest->new(name => $name);
        $st->run_fork(sub {
            local $ENV{PATH} = "$bin:$ENV{PATH}";
            $body->($name, $bin, $prefix);
        });
        $st->finish;
    }
    return;
}

1;
