package App::Yath2::Command::qdb;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Spec ();
use POSIX ();

use App::Yath2::Log;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group    { 'database' }
sub summary  { "Open archives in a temporary DB and drop into its shell" }
sub cli_args { "[--] FLAVOR[-VERSION] ARCHIVE [ARCHIVE...]" }

sub args_include_tests { 0 }

sub description {
    return <<"    EOT";
Spin up a temporary database via DBIx::QuickDB, load one or more .yath
archive files into it, then drop into the flavor's interactive shell.
The temporary DB and its on-disk storage are torn down when the shell
exits.

Supported flavors: mariadb, mysql, percona, postgres / postgresql.

The bare flavor name uses the highest version of that flavor installed
under \$HOME/dbs/<prefix>-*. Pin a specific version with the
flavor-VERSION form, e.g. postgres-15 or mariadb-12.2. When ~/dbs has
no matching install, falls back to whatever's on the system PATH.

Multiple archives load into the same DB as distinct rows in the
archives table (multi-archive container behavior). Re-importing an
archive with the same uuid is refused.
    EOT
}

# Map a user-facing flavor token to internal driver / dir-prefix /
# shell-binary tuple. Returns:
#   ($driver, $prefix, $shell_bin, \@shell_alts, $db_flavor, $needs_create_db)
#
# $db_flavor is the canonical flavor token consumed by App::Yath2::DB
# ('mariadb', 'mysql', 'postgres'). $needs_create_db is 1 for
# MariaDB/MySQL/Percona where we have to CREATE DATABASE before
# bootstrapping schema, 0 for Postgres which uses the pre-created
# 'quickdb' database.
sub _flavor_meta {
    my ($flavor) = @_;

    if ($flavor eq 'mariadb') {
        return ('MariaDB', 'mariadb', 'mariadb', ['mysql'], 'mariadb', 1);
    }
    if ($flavor eq 'mysql') {
        # MySQLCom forces the Oracle/Community MySQL driver.
        # The plain 'MySQL' driver is an ANY-style picker that chooses
        # MariaDB first when a mariadbd binary is on PATH (system
        # /usr/bin/mariadbd is symlinked from mysqld on most distros).
        return ('MySQLCom', 'mysql', 'mysql', [], 'mysql', 1);
    }
    if ($flavor eq 'percona') {
        return ('Percona', 'percona', 'mysql', [], 'mysql', 1);
    }
    if ($flavor eq 'postgres' || $flavor eq 'postgresql') {
        return ('PostgreSQL', 'postgresql', 'psql', [], 'postgres', 0);
    }

    croak "yath db: unsupported flavor '$flavor' "
        . "(supported: mariadb, mysql, percona, postgres / postgresql)\n";
}

# Split FLAVOR-VERSION into ($flavor, $version). Splits on the FIRST
# `-` so that 'mariadb-12.2' -> ('mariadb', '12.2'), 'postgres-15' ->
# ('postgres', '15'), and a bare 'mariadb' -> ('mariadb', undef).
# Normalises 'postgresql' -> 'postgres' for internal lookup.
sub _parse_flavor {
    my ($arg) = @_;
    my ($flavor, $version);
    if ($arg =~ /\A([^-]+)-(.+)\z/) {
        ($flavor, $version) = ($1, $2);
    }
    else {
        $flavor = $arg;
    }
    $flavor = lc $flavor;
    return ($flavor, $version);
}

# Natural-version comparator for strings like '10.6', '12.2', '17.9'.
# Splits on non-digit runs and compares numerically component-by-
# component. Non-numeric components fall back to string comparison.
sub _versioncmp {
    my ($a, $b) = @_;
    my @ap = split /\D+/, $a;
    my @bp = split /\D+/, $b;
    my $n = @ap > @bp ? @ap : @bp;
    for my $i (0 .. $n - 1) {
        my $av = defined $ap[$i] && length $ap[$i] ? $ap[$i] : 0;
        my $bv = defined $bp[$i] && length $bp[$i] ? $bp[$i] : 0;
        if ($av =~ /\A\d+\z/ && $bv =~ /\A\d+\z/) {
            my $c = $av <=> $bv;
            return $c if $c;
        }
        else {
            my $c = $av cmp $bv;
            return $c if $c;
        }
    }
    return 0;
}

# Resolve a (prefix, version?) pair against ~/dbs/<prefix>-*.
# Returns the matching bin/ directory or undef if no ~/dbs entry
# matches and the version was unspecified (caller falls back to
# system PATH). Croaks when version was explicit and no install
# matches.
sub _resolve_bin_dir {
    my ($prefix, $version) = @_;

    my $home = $ENV{HOME};
    return undef unless defined $home && -d "$home/dbs";

    my $dh;
    opendir($dh, "$home/dbs") or return undef;
    my @hits;
    while (my $entry = readdir($dh)) {
        next if $entry =~ /\A\./;
        next unless $entry =~ /\A\Q$prefix\E-(.+)\z/;
        my $ver = $1;
        my $bin = "$home/dbs/$entry/bin";
        next unless -d $bin;
        push @hits => [$entry, $ver, $bin];
    }
    closedir $dh;

    return undef unless @hits;

    if (defined $version) {
        # Exact match wins.
        my @exact = grep { $_->[1] eq $version } @hits;
        if (@exact) {
            # Multiple exact matches shouldn't happen, but pick highest.
            @exact = sort { _versioncmp($b->[1], $a->[1]) } @exact;
            return $exact[0][2];
        }

        # Prefix match: '15' matches '15.17'. Constrain to a "version
        # boundary" so '1' doesn't match '15'.
        my @prefix = grep { $_->[1] =~ /\A\Q$version\E(?:[.\-_].*)?\z/ } @hits;
        if (@prefix) {
            @prefix = sort { _versioncmp($b->[1], $a->[1]) } @prefix;
            return $prefix[0][2];
        }

        my @available = sort map { $_->[0] } @hits;
        croak "yath db: no \$HOME/dbs entry matches '$prefix-$version'. "
            . "Available: " . join(', ', @available) . "\n";
    }

    # No version specified: pick highest natural version.
    my @sorted = sort { _versioncmp($b->[1], $a->[1]) } @hits;
    return $sorted[0][2];
}

# Build the destination Log handle and load each archive into it. The
# first archive's insert() triggers schema bootstrap; subsequent
# archives append as additional rows in the archives table.
#
# For MariaDB / MySQL / Percona we have to CREATE DATABASE first
# because QuickDB hands us an admin-level DSN with no default db. For
# Postgres the QuickDB driver pre-creates 'quickdb' so we can connect
# directly.
sub _load_archives {
    my ($db, $driver, $db_flavor, $needs_create_db, $archives) = @_;

    my $dsn;
    if ($needs_create_db) {
        my $dbname = 'yath_db';
        my $admin_dsn = $db->connect_string;
        require DBI;
        my $admin = DBI->connect(
            $admin_dsn, undef, undef,
            { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
        );
        unless ($admin) {
            no warnings 'once';
            croak "could not connect to admin DSN: "
                . ($DBI::errstr // 'unknown error');
        }
        $admin->do("CREATE DATABASE IF NOT EXISTS $dbname");
        $admin->disconnect;
        $dsn = $db->connect_string($dbname);
    }
    else {
        # QuickDB Postgres pre-creates 'quickdb' as the default db.
        $dsn = $db->connect_string;
    }

    require App::Yath2::DB;

    for my $path (@$archives) {
        my $src = App::Yath2::Log->new(auto => $path);
        my $dest = App::Yath2::DB->new(
            dsn     => $dsn,
            backend => 'sql',
            flavor  => $db_flavor,
        );
        $dest->insert($src);
    }

    return $dsn;
}

# Print a connection-info banner to STDERR. Defensive on optional
# accessors so a driver missing a method (e.g. socket) doesn't crash
# the command — the field is simply omitted.
sub _print_banner {
    my ($db, $driver, $bin_dir, $bin_label, $loaded_dsn, $archives, $shell_label) = @_;

    my $fh = \*STDERR;
    print {$fh} "\n";
    print {$fh} "yath db: temporary $driver instance ready.\n\n";

    my @rows;
    push @rows => ['Driver', $driver];
    push @rows => ['Version', $bin_label] if defined $bin_label;
    push @rows => ['Bin path', $bin_dir]  if defined $bin_dir;

    my $dir = eval { $db->dir };
    push @rows => ['Storage', $dir] if defined $dir;

    my $watcher = eval { $db->watcher };
    if ($watcher) {
        my $spid = eval { $watcher->server_pid };
        push @rows => ['Server PID', $spid] if defined $spid;
    }

    my $host = $db->can('host') ? eval { $db->host } : undef;
    my $port = $db->can('port') ? eval { $db->port } : undef;
    my $sock = $db->can('socket') ? eval { $db->socket } : undef;
    my $user = $db->can('username') ? eval { $db->username } : undef;
    $user = eval { $db->user }
        if (!defined $user || !length $user) && $db->can('user');
    my $pass = $db->can('password') ? eval { $db->password } : undef;

    push @rows => ['Host', $host] if defined $host && length $host;
    push @rows => ['Port', $port] if defined $port && length $port;
    push @rows => ['Socket', $sock] if defined $sock && length $sock;
    push @rows => ['User', (defined $user && length $user) ? $user : '<current>'];
    push @rows => ['Password', (defined $pass && length $pass) ? $pass : '<none>'];
    push @rows => ['DSN', $loaded_dsn];

    my $width = 0;
    for my $r (@rows) { $width = length $r->[0] if length $r->[0] > $width }
    for my $r (@rows) {
        printf {$fh} "  %-${width}s   %s\n", $r->[0] . ':', $r->[1];
    }

    print {$fh} "\nLoaded archives (", scalar(@$archives), "):\n";
    print {$fh} "  - $_\n" for @$archives;

    print {$fh} "\nDropping into $shell_label shell. Exit the shell to tear down the DB.\n\n";

    return;
}

# Resolve the actual shell binary, honouring fallbacks (e.g. mariadb
# falls back to mysql when only the latter is on PATH).
sub _resolve_shell_bin {
    my ($primary, $alts) = @_;
    return $primary if _which($primary);
    for my $alt (@$alts) {
        return $alt if _which($alt);
    }
    croak "yath db: could not find shell binary '$primary'"
        . (@$alts ? " (or alternatives: " . join(', ', @$alts) . ")" : '')
        . " on PATH\n";
}

sub _which {
    my ($name) = @_;
    return 0 unless defined $name && length $name;
    for my $dir (split /:/, $ENV{PATH} // '') {
        next unless length $dir;
        my $candidate = File::Spec->catfile($dir, $name);
        return 1 if -x $candidate;
    }
    return 0;
}

# Build the argv for invoking the shell against $db.
sub _build_shell_argv {
    my ($db, $driver, $shell_bin) = @_;

    my $host = $db->can('host') ? eval { $db->host } : undef;
    my $port = $db->can('port') ? eval { $db->port } : undef;
    my $sock = $db->can('socket') ? eval { $db->socket } : undef;
    my $user = $db->can('username') ? eval { $db->username } : undef;
    $user = eval { $db->user }
        if (!defined $user || !length $user) && $db->can('user');

    if ($driver eq 'PostgreSQL') {
        my $dbname = 'quickdb';
        my @argv = ($shell_bin);
        # Postgres uses unix socket from $db->dir on QuickDB; pass the
        # directory portion via -h (psql convention for socket path).
        my $sock_dir = $db->can('dir') ? eval { $db->dir } : undef;
        push @argv => ('-h', $sock_dir) if defined $sock_dir && length $sock_dir;
        push @argv => ('-p', $port)     if defined $port && length $port;
        push @argv => ('-U', $user)     if defined $user && length $user;
        push @argv => $dbname;
        return @argv;
    }

    # MySQL / MariaDB / Percona: mysql / mariadb client.
    my $dbname = 'yath_db';
    my @argv = ($shell_bin);
    if (defined $sock && length $sock && !-e ($host // '')) {
        push @argv => ('-S', $sock);
    }
    elsif (defined $host && length $host) {
        push @argv => ('-h', $host);
        push @argv => ('-P', $port) if defined $port && length $port;
    }
    elsif (defined $sock && length $sock) {
        push @argv => ('-S', $sock);
    }
    push @argv => ('-u', $user) if defined $user && length $user;
    push @argv => $dbname;
    return @argv;
}

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    die "yath db: missing FLAVOR argument\n" unless @$args;
    my $flavor_arg = shift @$args;
    die "yath db: at least one ARCHIVE argument is required\n" unless @$args;

    my @archives = @$args;
    for my $a (@archives) {
        die "yath db: archive '$a' does not exist\n" unless -e $a;
    }

    my ($flavor, $version) = _parse_flavor($flavor_arg);
    my ($driver, $prefix, $shell_bin, $shell_alts,
        $db_flavor, $needs_create_db) = _flavor_meta($flavor);

    my $bin_dir = _resolve_bin_dir($prefix, $version);
    my $bin_label;
    if (defined $bin_dir) {
        # Prepend the resolved bin/ to PATH so QuickDB and the shell
        # both see the requested install first.
        $ENV{PATH} = "$bin_dir:" . ($ENV{PATH} // '');
        # Derive a label like "postgresql-17.9" from the bin dir.
        my $parent = $bin_dir;
        $parent =~ s{/bin/?\z}{};
        my @parts = File::Spec->splitdir($parent);
        $bin_label = $parts[-1] if @parts;
    }

    require DBIx::QuickDB;
    my $db = DBIx::QuickDB->build_db(yath_db => {
        driver   => $driver,
        autostop => 1,
    });

    my $loaded_dsn = _load_archives($db, $driver, $db_flavor, $needs_create_db, \@archives);

    my $resolved_shell = _resolve_shell_bin($shell_bin, $shell_alts);
    _print_banner($db, $driver, $bin_dir, $bin_label, $loaded_dsn, \@archives, $resolved_shell);

    return _exec_shell($db, $driver, $resolved_shell);
}

sub _exec_shell {
    my ($db, $driver, $shell_bin) = @_;

    my @argv = _build_shell_argv($db, $driver, $shell_bin);

    my $child = fork;
    croak "fork: $!" unless defined $child;
    if ($child == 0) {
        exec({ $argv[0] } @argv) or do {
            print STDERR "exec @argv: $!\n";
            POSIX::_exit(127);
        };
    }
    waitpid($child, 0);
    my $status = $?;
    my $exit = ($status >> 8) & 0xff;
    return $exit;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
