use Test2::V0;

use File::Find;
use Test2::Harness2;
use Test2::Harness2::Util qw/file2mod/;

find(\&wanted, 'lib/');

sub wanted {
    my $file = $File::Find::name;
    return unless $file =~ m/\.pm$/;

    $file =~ s{^.*lib/}{}g;

    # The App::Yath2::Schema layer is driver-dispatched: Schema.pm and the
    # per-driver/Result/Overlay classes deliberately croak unless a specific
    # driver (App::Yath2::Schema::<Driver>) was loaded first to set $LOADED,
    # and only one driver can be loaded per process. They are therefore not
    # standalone-loadable by a generic require() walk. Schema loading +
    # deployment is covered by t/AI/unit/Schema_RunProcessor.t instead.
    return if $file =~ m{^App/Yath2/Schema\.pm$};
    return if $file =~ m{^App/Yath2/Schema/(SQLite|MySQL|MariaDB|Percona|PostgreSQL)\.pm$};
    return if $file =~ m{^App/Yath2/Schema/(Result|Overlay|SQLite|MySQL|MariaDB|Percona|PostgreSQL)/};

    my $ok = eval { require($file); 1 };
    my $err = $@;
    ok($ok, "require $file", $ok ? () : $err);

    my $mod = file2mod($file);
    my $sym = "$mod\::VERSION";
    no strict 'refs';
    is($$sym, $Test2::Harness2::VERSION, "Package $mod ($file) has the version number");
};

done_testing;
