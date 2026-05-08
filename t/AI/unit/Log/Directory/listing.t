use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use App::Yath2::Log;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/services/preload-perl");
make_path("$dir/runs/0/services/run");
make_path("$dir/runs/0/jobs/0/0");
make_path("$dir/runs/0/jobs/0/1");
make_path("$dir/runs/0/jobs/1/0");
make_path("$dir/runs/2/jobs/0/0");

my $log = App::Yath2::Log->new(dir => $dir);

is([$log->services], ['harness', 'preload-perl'], 'global services alphabetical');
is([$log->services(0)], ['run'], 'run-scoped services');
is([$log->runs], [0, 2], 'runs ascending integer');
is([$log->jobs(0)], [0, 1], 'jobs ascending');
is([$log->tries(0, 0)], [0, 1], 'tries ascending');
is($log->last_try(0, 0), 1, 'last_try -> highest');
is($log->last_try(0, 1), 0, 'last_try when only one');

ok($log->has_run(0), 'has_run 0');
ok($log->has_run(2), 'has_run 2');
ok(!$log->has_run(7), '!has_run 7');
ok(!$log->has_run('garbage'), '!has_run on non-numeric');
ok($log->has_job(0, 0), 'has_job');
ok(!$log->has_job(0, 99), '!has_job 0/99');
ok($log->has_try(0, 0, 1), 'has_try');
ok(!$log->has_try(0, 0, 7), '!has_try');
ok($log->has_service('harness'), 'has_service harness');
ok($log->has_service('preload-perl'), 'has_service preload-perl');
ok(!$log->has_service('zzz'), '!has_service zzz');
ok($log->has_service('run', 0), 'has_service run @ run 0');
ok(!$log->has_service('run', 2), '!has_service run @ run 2');

# Throws on missing parent
like(dies { $log->jobs(99) },     qr/no such run/, 'jobs on missing run croaks');
like(dies { $log->tries(0, 99) }, qr/no such job/, 'tries on missing job croaks');
like(dies { $log->services(99) }, qr/no such run/, 'services on missing run croaks');

done_testing;
