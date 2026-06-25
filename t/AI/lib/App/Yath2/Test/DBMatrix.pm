package App::Yath2::Test::DBMatrix;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Temp();
use File::Spec();
use version();
use Scalar::Util qw/blessed/;

use Test2::V0 qw/subtest skip_all note diag ok/;
use Test2::IPC qw/cull/;    # forked-cell event culling (server cells fork)

use Importer 'Importer' => 'import';

our @EXPORT_OK = qw{
    db_matrix_sets
    for_each_db_set
    provision_db_set
    engine_meta
    load_ddl_into
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Test::DBMatrix - Test-only helper that drives the DB tests over every
installed flavor B<and> version (DB-3 / ticket #63).

=head1 DESCRIPTION

The DB layer ships five hand-written flavor DDLs (PostgreSQL / SQLite / MySQL /
MariaDB / Percona) reflected by L<DBIx::QuickORM> C<autofill>. A single ambient
server only proves one engine at one version; per-version SQL / typing drift (the
exact bug class the multi-engine port risks) hides behind that. This module
discovers B<every> versioned server install under C<~/dbs> (plus a system install
as a fallback when C<~/dbs> lacks a flavor) and yields a ready, schema-loaded
connection per C<(flavor, version)> cell so the existing assertions run against
each one.

It mirrors the discovery pattern in C<DBIx::QuickORM>'s own test helper
(C<t/lib/DBIx/QuickORM/Test.pm>): scan C<~/dbs/E<lt>engineE<gt>-E<lt>versionE<gt>>
for a C<bin/> holding the server binary, prepend that C<bin/> to C<PATH> so
L<DBIx::QuickDB> boots that exact version, and skip a single cell (never a whole
flavor) when neither C<~/dbs> nor a system binary can provide it.

=head2 WHY SERVER CELLS FORK

L<DBIx::QuickDB>'s per-engine drivers resolve their server/client binary paths
(C<initdb>/C<postgres>/C<mysqld>/...) into B<file-scoped lexicals at module load>,
once per process. Prepending C<PATH> only takes effect on the B<first> load of a
given driver, so running several versions of one flavor in a single process would
silently spin up whichever version loaded first for B<all> of them -- defeating
the entire point of a per-version matrix. Each server cell therefore runs in its
B<own forked process> (via L<Parallel::Runner>, like C<do_for_all_dbs>) so the
driver resolves that cell's PATH afresh. SQLite needs no server and runs inline.

SQLite is always on (a temp file). Server spin-up is gated on C<AUTHOR_TESTING> so
a default user install stays fast.

=head1 EXPORTS

=over 4

=item @sets = db_matrix_sets(%opts)

The set descriptors to run. Always includes the C<sqlite> set; includes the
server sets only under C<AUTHOR_TESTING>. C<servers_only =E<gt> 1> drops the
sqlite set (used by the cross-flavor sync coverage, whose source is a sqlite log).

=item for_each_db_set(\&cb, %opts)

Iterate the matrix, wrapping each set in a named C<subtest>. SQLite runs inline;
each server cell is provisioned in a forked process (an ephemeral L<DBIx::QuickDB>
server with the flavor DDL loaded) and torn down after. A cell is C<skip>ped --
with a reason naming the flavor+version -- when its server/driver cannot be
provided or its version is below the flavor minimum; a DDL/schema failure on a
B<supported> version is a real test failure, not a skip. The callback is invoked
as C<< cb($set, $prov) >> (see C<provision_db_set> for C<$prov>).

=item ($prov, $reason, $kind) = provision_db_set($set)

Provision one set. On success returns the provision hashref: C<con> (a live
L<App::Yath2::Schema> QuickORM connection), C<dsn> (the C<-L> logging target -- a
sqlite path or a C<dbi:...> DSN reachable by a forked logger), C<flavor>,
C<has_string_mirror>, C<json_autotype>, C<server>, C<qdb> (the QuickDB instance),
plus C<name>/C<version>. On failure returns C<(undef, $reason, $kind)> where
C<$kind> is C<'skip'> (server/driver unavailable -- not a failure) or C<'fail'>
(provisionable but the schema would not load -- a real defect).

=item %meta = engine_meta($flavor_name)

The per-flavor test metadata: C<has_string_mirror>, C<json_autotype>, C<dbd>, and
C<server>.

=item load_ddl_into($dbh, $flavor)

Apply a flavor's DDL to a live handle statement-by-statement. Returns the count.

=back

=cut

# Per-flavor test metadata. `dbd` (the gate driver) + `server` are fixed per
# flavor. has_string_mirror / json_autotype here are only initial hints: the
# authoritative values are DETECTED off the live autofilled schema in
# _detect_schema_shape (the JSON-autotype claim varies by the DBD a given QuickDB
# driver connects with, so a static guess desyncs the round-trip's marshalling --
# e.g. Percona's handle keeps `JSON` claimed while DBD::MariaDB reflects it as
# unclaimed LONGTEXT). native `uuid` engines (postgresql, mariadb) carry NO string
# mirror; BINARY(16)/BLOB(16) engines (mysql, percona, sqlite) do (§3b).
my %META = (
    sqlite     => {has_string_mirror => 1, json_autotype => 1, dbd => 'DBD::SQLite',  server => 0},
    postgresql => {has_string_mirror => 0, json_autotype => 1, dbd => 'DBD::Pg',      server => 1},
    mysql      => {has_string_mirror => 1, json_autotype => 0, dbd => 'DBD::mysql',   server => 1},
    mariadb    => {has_string_mirror => 0, json_autotype => 0, dbd => 'DBD::mysql',   server => 1},
    percona    => {has_string_mirror => 1, json_autotype => 0, dbd => 'DBD::mysql',   server => 1},
);

# Minimum server version the schema supports, so an older install present under
# ~/dbs is SKIPPED (not failed). PostgreSQL 10+ : GENERATED ALWAYS AS IDENTITY.
# MariaDB 10.7+ : native `uuid` type (R8). MySQL/Percona 8.0+ : enforced CHECK +
# native JSON. SQLite carries no version gate.
my %MIN_VERSION = (
    postgresql => '10',
    mariadb    => '10.7',
    mysql      => '8.0',
    percona    => '8.0',
);

# Maps a "~/dbs/<engine>-<version>" prefix to the server binary that must exist
# under its bin/ for the install to count (mirrors QuickORM's discovery).
my %SERVER_BIN = (
    postgresql => 'postgres',
    mariadb    => 'mariadbd',
    mysql      => 'mysqld',
    percona    => 'mysqld',
);

sub engine_meta {
    my ($name) = @_;
    my $m = $META{$name} or croak "unknown flavor '" . ($name // '<undef>') . "'";
    return %$m;
}

# Build a set descriptor for a flavor, merging the per-flavor metadata + the
# QuickDB driver token from the Flavor registry (single source of truth).
sub _set {
    my (%args) = @_;
    require App::Yath2::DB::Flavor;
    my $flavor = App::Yath2::DB::Flavor->by_name($args{flavor});
    my %m      = engine_meta($args{flavor});
    return {
        %m,
        %args,
        quickdb_driver => $flavor->quickdb_driver,
    };
}

# Discover every versioned server install under ~/dbs (mirrors QuickORM's
# discover_db_sets): a "<engine>-<version>" dir whose bin/ holds the server
# binary. That bin/ is prepended to PATH so QuickDB boots that exact version.
sub _discover_dbs_sets {
    my $root = "$ENV{HOME}/dbs";
    return () unless -d $root;

    opendir(my $dh, $root) or return ();
    my @dirs = sort readdir($dh);
    closedir($dh);

    my @sets;
    for my $dir (@dirs) {
        next unless $dir =~ m/^([a-z]+)-(\d+(?:\.\d+)*)$/;
        my ($engine, $version) = ($1, $2);
        next unless $SERVER_BIN{$engine};

        my $bin = "$root/$dir/bin";
        next unless -d $bin && -x "$bin/$SERVER_BIN{$engine}";

        my ($major) = split /\./, $version;

        push @sets => _set(
            flavor  => $engine,
            name    => $dir,
            version => $version,
            major   => $major,
            env     => {PATH => "$bin:$ENV{PATH}"},
        );
    }

    # Stable order: engine, then numeric major, then full name.
    return sort {
        $a->{flavor} cmp $b->{flavor}
            || ($a->{major} // 0) <=> ($b->{major} // 0)
            || $a->{name} cmp $b->{name}
    } @sets;
}

sub db_matrix_sets {
    my (%opts) = @_;

    my @sets;

    # SQLite: always on (no server), unless the caller wants servers only.
    push @sets => _set(flavor => 'sqlite', name => 'sqlite', version => undef, env => {})
        unless $opts{servers_only};

    # Servers: only under AUTHOR_TESTING (full sweep). Discover every ~/dbs
    # version; for any server flavor ~/dbs does not provide, add a single
    # system-install fallback set.
    if ($ENV{AUTHOR_TESTING}) {
        my @discovered = _discover_dbs_sets();
        push @sets => @discovered;

        my %have = map { $_->{flavor} => 1 } @discovered;
        for my $flavor (qw/postgresql mysql mariadb percona/) {
            next if $have{$flavor};
            push @sets => _set(flavor => $flavor, name => "system-$flavor", version => undef, env => {});
        }
    }

    return @sets;
}

sub load_ddl_into {
    my ($dbh, $flavor) = @_;
    open my $fh, '<', $flavor->ddl_path or croak "open DDL '" . $flavor->ddl_path . "': $!";
    my $ddl = do { local $/; <$fh> };
    close($fh);

    my @stmts = grep { /\S/ } split /;\s*\n/, $ddl;
    for my $stmt (@stmts) {
        local $SIG{__WARN__} = sub { };    # silence benign PostgreSQL NOTICEs
        $dbh->do($stmt);
    }
    return scalar @stmts;
}

# Is a column's QuickORM type the JSON autotype? autofill records it as the type
# class name (a string) or a blessed type object depending on path.
sub _is_json_type {
    my ($type) = @_;
    return 0 unless defined $type;
    return $type->isa('DBIx::QuickORM::Type::JSON') ? 1 : 0 if blessed($type);
    return 0 if ref $type;    # a scalar-ref like \'longtext' = not claimed
    return $type =~ /(?:^|::)Type::JSON$/ ? 1 : 0;
}

# Read the engine shape off the LIVE autofilled schema rather than guessing it
# per flavor: whether `runs` carries the lowercase string mirror, and whether the
# JSON columns are autotype-claimed (which differs by DBD -- e.g. DBD::MariaDB
# reflects MySQL `JSON` as LONGTEXT (unclaimed) while Percona's handle keeps it
# JSON (claimed)). Self-calibrating, so a per-DBD reflection quirk can't desync
# the round-trip's write/read marshalling.
sub _detect_schema_shape {
    my ($con) = @_;
    my $runs = $con->schema->table('runs');
    my %cols = map { $_->name => $_ } $runs->columns;

    my $has_string_mirror = $cols{run_uuid_string} ? 1 : 0;
    my $json_autotype     = $cols{parameters} ? _is_json_type($cols{parameters}->type) : 0;

    return ($has_string_mirror, $json_autotype);
}

# Is this set's version below the flavor minimum? (system installs carry no
# version and are assumed current.)
sub _below_min_version {
    my ($set) = @_;
    my $min = $MIN_VERSION{$set->{flavor}} or return undef;
    my $have = $set->{version} or return undef;
    return undef unless version->parse("v$have") < version->parse("v$min");
    return "$set->{name}: below the minimum supported $set->{flavor} ($min+ required)";
}

my $PROV_SEQ = 0;

# Provision a sqlite set: a fresh temp file, DDL bootstrapped by the production
# Connect path, returning a QuickORM connection + the path as the -L target.
sub _provision_sqlite {
    my ($set) = @_;

    eval { require DBD::SQLite;    1 } or return (undef, "DBD::SQLite not available", 'skip');
    eval { require DBIx::QuickORM; 1 } or return (undef, "DBIx::QuickORM not available", 'skip');

    require App::Yath2::DB::Connect;
    require App::Yath2::Schema;    # installs qorm() + the autorow namespace

    my $tmp  = File::Temp->newdir(CLEANUP => 1);
    my $path = "$tmp/yath_matrix_${$}_" . (++$PROV_SEQ) . ".sqlite";

    my ($con, $flavor) = App::Yath2::DB::Connect::build_connection($path);

    my ($mirror, $json_autotype) = _detect_schema_shape($con);

    return {
        %$set,
        con               => $con,
        dsn               => $path,    # a sqlite -L target is a plain path
        flavor            => $flavor,
        qdb               => undef,
        tmp               => $tmp,     # hold the tempdir alive
        has_string_mirror => $mirror,
        json_autotype     => $json_autotype,
    };
}

# Provision a server set: spin up an ephemeral QuickDB server of this exact
# version, load the flavor DDL, and attach a fresh QuickORM connection (autofill
# reflects the loaded schema). MUST run in its own process (see WHY SERVER CELLS
# FORK). Returns (undef, $reason, $kind): 'skip' when the server/driver is
# unavailable, 'fail' when a provisionable server cannot carry the schema.
sub _provision_server {
    my ($set) = @_;

    my $cell = $set->{name};

    eval { require DBIx::QuickDB;  1 } or return (undef, "[$cell] DBIx::QuickDB not available", 'skip');
    eval { require DBIx::QuickORM; 1 } or return (undef, "[$cell] DBIx::QuickORM not available", 'skip');

    (my $dbd_file = "$set->{dbd}.pm") =~ s{::}{/}g;
    eval { require $dbd_file; 1 } or return (undef, "[$cell] $set->{dbd} not available", 'skip');

    my $drv = "DBIx::QuickDB::Driver::$set->{quickdb_driver}";
    (my $drv_file = "$drv.pm") =~ s{::}{/}g;
    eval { require $drv_file; 1 } or return (undef, "[$cell] $drv not available", 'skip');

    my ($viable, $why) = $drv->viable({bootstrap => 1, autostart => 1});
    return (undef, "[$cell] not provisionable: " . ($why // 'unknown'), 'skip') unless $viable;

    require App::Yath2::DB::Flavor;
    require App::Yath2::DB::ORM;
    my $flavor = App::Yath2::DB::Flavor->by_name($set->{flavor});

    # Past here the server IS provisionable, so any failure is a real defect
    # ('fail'), not an environment skip. nocache + a unique name: every cell gets
    # its OWN server (a cached build_db would hand back a prior instance).
    my $prov;
    my $ok = eval {
        my $qdb = DBIx::QuickDB->build_db(
            "yath_matrix_${cell}_${$}_" . (++$PROV_SEQ) => {
                driver  => $set->{quickdb_driver},
                nocache => 1,
            },
        );

        my $connect_cb = sub {
            my $dbh = $qdb->connect('quickdb', AutoCommit => 1, RaiseError => 1, PrintError => 0);
            $flavor->post_connect($dbh);
            return $dbh;
        };

        # Load the DDL (build_connection only bootstraps DDL for sqlite; a server
        # DSN is assumed to already carry the schema, so we load it here).
        my $boot  = $connect_cb->();
        my $count = load_ddl_into($boot, $flavor);
        $boot->disconnect;
        die "DDL load produced no statements\n" unless $count > 0;

        my $name = "yath_matrix_$set->{flavor}_${$}_" . (++$PROV_SEQ);
        my $con  = App::Yath2::DB::ORM::connection($name, $flavor->dialect, 'quickdb', $connect_cb);

        my ($mirror, $json_autotype) = _detect_schema_shape($con);

        $prov = {
            %$set,
            con               => $con,
            dsn               => $qdb->connect_string('quickdb'),    # full dbi: DSN for -L / a forked logger
            flavor            => $flavor,
            qdb               => $qdb,
            has_string_mirror => $mirror,
            json_autotype     => $json_autotype,
        };
        1;
    };
    my $err = $@;
    return (undef, "[$cell] schema setup failed: $err", 'fail') unless $ok;

    return $prov;
}

sub provision_db_set {
    my ($set) = @_;
    return $set->{server} ? _provision_server($set) : _provision_sqlite($set);
}

# Stop the server (while its bin/ is still on PATH) and drop held temp handles.
sub _teardown {
    my ($prov) = @_;
    return unless $prov;
    if (my $qdb = $prov->{qdb}) {
        eval { $qdb->stop; 1 } or note("teardown: server stop failed: $@");
    }
    return;
}

# Run one cell as a named subtest: gate on min-version, provision, run the
# callback, tear down. A 'skip' provision skips the cell; a 'fail' provision
# fails it (the schema would not load on a supported server).
sub _run_cell {
    my ($cb, $set) = @_;
    subtest $set->{name} => sub {
        if (my $reason = _below_min_version($set)) {
            skip_all $reason;
            return;
        }

        local %ENV = (%ENV, %{$set->{env} // {}});

        my ($prov, $reason, $kind) = provision_db_set($set);
        unless ($prov) {
            $kind //= 'skip';
            if ($kind eq 'fail') {
                ok(0, $reason // "$set->{name}: provisioning failed");
            }
            else {
                skip_all $reason // "$set->{name} not provisionable";
            }
            return;
        }

        my $ok = eval { $cb->($set, $prov); 1 };
        my $err = $@;

        _teardown($prov);

        die $err unless $ok;
    };
}

sub for_each_db_set {
    my ($cb, %opts) = @_;
    croak "for_each_db_set requires a code ref" unless ref($cb) eq 'CODE';

    my @sets = db_matrix_sets(%opts);

    # SQLite (no server) runs inline. Server cells fork for process isolation
    # (each QuickDB driver caches its binary paths at first load per process).
    my @inline = grep { !$_->{server} } @sets;
    my @forked = grep { $_->{server} } @sets;

    _run_cell($cb, $_) for @inline;

    return unless @forked;

    require Parallel::Runner;
    my $max = $ENV{YATH_DB_MATRIX_CONCURRENCY} || 4;
    my $pr  = Parallel::Runner->new($max, iteration_callback => \&cull);

    for my $set (@forked) {
        cull();
        $pr->run(sub {
            # Re-seed: fork inherits Test2's deterministic srand, so sibling
            # children would otherwise generate identical File::Temp names and
            # collide on one server data dir.
            srand();
            _run_cell($cb, $set);
        }, 'force_fork');
    }

    $pr->finish;
    cull();

    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
