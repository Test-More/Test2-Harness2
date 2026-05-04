use Test2::V0;

use Test2::Harness2::LogLayout qw/
    run_dir
    job_dir
    services_global_dir
    services_run_dir
    service_global_dir
    service_run_dir
    collector_base_dir
/;

is(run_dir(0), 'runs/0', 'run dir uses ord');
is(run_dir(1), 'runs/1', 'run dir 1');

# New layout: jobs/<id>/<try>/ (was tests/<job>/<try>/).
is(job_dir(0, 0, 0), 'runs/0/jobs/0/0', 'first try of job 0');
is(job_dir(0, 0, 1), 'runs/0/jobs/0/1', 'second try of job 0');
is(job_dir(1, 7, 2), 'runs/1/jobs/7/2', 'arbitrary triple');

is(services_global_dir(),    'services',         'global services dir');
is(services_run_dir(0),      'runs/0/services',  'per-run services dir');
is(service_global_dir('harness'), 'services/harness',     'global service dir');
is(service_run_dir(0, 'run'),     'runs/0/services/run',  'per-run service dir');

# Generic resolver
is(
    collector_base_dir(type => 'Service', id => 'harness'),
    'services/harness',
    'collector_base_dir global service',
);
is(
    collector_base_dir(type => 'Service', id => 'res', run_id => 0),
    'runs/0/services/res',
    'collector_base_dir run service',
);
is(
    collector_base_dir(type => 'Run', id => 0),
    'runs/0',
    'collector_base_dir run',
);
is(
    collector_base_dir(type => 'Job', id => 1, run_id => 0, job_try => 0),
    'runs/0/jobs/1/0',
    'collector_base_dir job',
);

# Required-arg checks.
like(dies { job_dir() },    qr/run_id is required/, 'job_dir croaks without run_id');
like(dies { job_dir(0) },   qr/job_id is required/, 'job_dir croaks without job_id');
like(
    dies { job_dir(0, 0) },
    qr/job_try is required/,
    'job_dir croaks without job_try',
);

like(
    dies { collector_base_dir(type => 'Bogus', id => 1) },
    qr/Unknown collector type 'Bogus'/,
    'collector_base_dir rejects unknown type',
);

done_testing;
