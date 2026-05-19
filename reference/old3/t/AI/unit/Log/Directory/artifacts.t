use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Scalar::Util qw/blessed/;

use App::Yath2::Log;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/services/preload-perl");
make_path("$dir/runs/0/services/run");
make_path("$dir/runs/0/jobs/0/0");
make_path("$dir/runs/0/jobs/0/1");
make_path("$dir/runs/0/jobs/1/0");

my $log = App::Yath2::Log->new(dir => $dir);

# No args -> archive root handle.
{
    my $a = $log->artifacts();
    isa_ok($a, ['App::Yath2::Log::Artifact']);
    is($a->base, undef, 'no base');
}

# Service positional.
{
    my $a = $log->artifacts('harness');
    isa_ok($a, ['App::Yath2::Log::Artifact']);
    is($a->base, 'services/harness', 'global service base');
}

# Run positional.
{
    my $a = $log->artifacts(0);
    is($a->base, 'runs/0', 'run base');
}

# Run + service positional.
{
    my $a = $log->artifacts(0, 'run');
    is($a->base, 'runs/0/services/run', 'run-scoped service base');
}

# Run + job positional => default to highest try.
{
    my $a = $log->artifacts(0, 0);
    is($a->base, 'runs/0/jobs/0/1', 'highest try by default');
}

# Run + job + try positional.
{
    my $a = $log->artifacts(0, 0, 0);
    is($a->base, 'runs/0/jobs/0/0', 'specific try');
}

# Hashref form.
{
    my $a = $log->artifacts({service => 'preload-perl'});
    is($a->base, 'services/preload-perl', 'hashref service');

    my $b = $log->artifacts({run_id => 0, job_id => 0, job_try => 1});
    is($b->base, 'runs/0/jobs/0/1', 'hashref triple');
}

# Service names cannot start with a digit (E1 amendment).
like(
    dies { $log->artifacts({service => '0bad'}) },
    qr/cannot start with a digit/,
    'numeric-leading service name rejected',
);

# Throws on missing target.
like(dies { $log->artifacts(99) }, qr/no such run/, 'missing run croaks');
like(dies { $log->artifacts({service => 'does-not-exist'}) },
    qr/no such service/, 'missing service croaks');
like(dies { $log->artifacts(0, 99) },         qr/no such job/, 'missing job croaks');
like(dies { $log->artifacts(0, 0, 99) },      qr/no such try/, 'missing try croaks');

done_testing;
