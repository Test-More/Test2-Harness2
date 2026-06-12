use Test2::V0;
use Test2::Harness2;

{
    package X;
    sub name { $_[0]->{name} }
}

# Build a bare-bones object: only the field the handler reads.
my $svc = bless {
    resource_services => {
        $$         => { service_class => 'Test2::Harness2::PreloadService',    scope => 'global', name => 'preload-DEFAULT', pid => $$,       resource => bless({ name => 'DEFAULT' }, 'X') },
        '99999999' => { service_class => 'Test2::Harness2::PreloadService',    scope => 'global', name => 'preload-DEAD',    pid => 99999999, resource => bless({ name => 'DEAD' },    'X') },
        '12'       => { service_class => 'Test2::Harness2::Resource::JobCount', scope => 'global', name => 'jobcount',        pid => $$,       resource => bless({}, 'X') },
        '34'       => { service_class => 'Test2::Harness2::PreloadService',    scope => 'run',    name => 'preload-RUN',     pid => $$,       resource => bless({ name => 'RUN' }, 'X'), run => 'RID' },
    },
}, 'Test2::Harness2';

my $res = $svc->request_handler_list_preloads({}, undef);
ok($res->{ok}, 'handler returned ok=1') or diag explain $res;

my @names = sort map { $_->{name} } @{ $res->{preloads} };
is(\@names, ['preload-DEFAULT'], 'only live, global preload-services are returned');

done_testing;
