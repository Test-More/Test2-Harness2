use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::Log::DB;

# Mock App::Yath2::DB recording every method call, plus a mock legacy
# backend it returns from _legacy_backend. Read methods land on the
# mock $db; legacy methods (event/insert/artifacts/etc) land on the
# scoped legacy backend.
{
    package Test::ProxyLegacy;
    sub new { bless { calls => [] }, shift }
    sub _record {
        my ($self, @a) = @_;
        push @{$self->{calls}}, [@a];
        return;
    }
    for my $m (qw{
        event events end_of_events reset
        artifacts extract archive insert
        _artifact_save
    }) {
        no strict 'refs';
        *{$m} = sub { my $self = shift; $self->_record($m => @_); 'rv' };
    }
}
{
    package Test::ProxyDB;
    use App::Yath2::DB;
    our @ISA = ('App::Yath2::DB');
    sub new { bless { calls => [], legacy => Test::ProxyLegacy->new, scoped_count => 0 }, shift }
    sub _record {
        my ($self, @a) = @_;
        push @{$self->{calls}}, [@a];
        return;
    }
    for my $m (qw{
        services runs jobs tries last_try
        has_service has_run has_job has_try
        list_files
        artifact_exists artifact_read artifact_iter_records
        artifact_list_dir artifact_open_fh
        absolute_path
        extract archive_to insert save_artifact
    }) {
        no strict 'refs';
        *{$m} = sub { my $self = shift; $self->_record($m => @_); 'rv' };
    }
    # Override legacy_scoped_for_uuid so we don't try to do real
    # archive_id resolution against the mock backend.
    sub legacy_scoped_for_uuid {
        my ($self, $uuid) = @_;
        $self->{scoped_count}++;
        push @{$self->{calls}}, [scoped => $uuid];
        return $self->{legacy};
    }
}

my $u = gen_uuid();
my $db = Test::ProxyDB->new;
my $log = App::Yath2::Log::DB->new(db => $db, uuid => $u);

# uuid required.
my $err = dies { App::Yath2::Log::DB->new(db => $db) };
like($err, qr/'uuid' is required/, 'uuid required');

# db (or backend) required.
my $err2 = dies { App::Yath2::Log::DB->new(uuid => $u) };
like($err2, qr/'db' is required/, 'db required');

# db must be an App::Yath2::DB.
{
    package Test::NotADB;
    sub new { bless {}, shift }
}
my $err3 = dies { App::Yath2::Log::DB->new(db => Test::NotADB->new, uuid => $u) };
like($err3, qr/must be an App::Yath2::DB instance/, 'db must be App::Yath2::DB');

# Read methods delegate to the App::Yath2::DB instance with our uuid prepended.
$log->services(2);
$log->runs;
my $calls = $db->{calls};
is($calls->[0], [services => $u, 2], 'services delegated with uuid');
is($calls->[1], [runs     => $u],    'runs delegated with uuid');

# Walker methods (event/events/EOE/reset) still route through
# _legacy_backend until Phase 7. Insert/extract/archive/_artifact_save
# (Phase 6) go directly through the App::Yath2::DB instance.
$log->event;
my $legacy_calls = $db->{legacy}{calls};
is($legacy_calls->[0], [event  => ()],         'event delegated to legacy');
is($db->{scoped_count}, 1, 'scoped() called once for the legacy walker chain');

# Phase 6: insert routes through App::Yath2::DB->insert (not legacy).
$log->insert('source');
my $insert_call = $calls->[-1];
is($insert_call, [insert => 'source'], 'insert delegated to App::Yath2::DB->insert');

# Back-compat: backend => $app_yath2_db keeps working (normalizes to db slot).
my $log2 = App::Yath2::Log::DB->new(backend => $db, uuid => $u);
is($log2->{db}, $db, 'backend => $db normalizes to db slot');

# Back-compat: backend => $role_consumer wraps in App::Yath2::DB.
{
    package Test::FakeBackend;
    use Role::Tiny::With;
    sub new { bless {}, shift }
    # Stub every required method. We only need DOES to pass; the
    # Log::DB constructor wraps and never calls into us.
    for my $m (qw{
        dbh flavor _archive_id_or_die
        services runs jobs tries last_try
        has_service has_run has_job has_try
        event events end_of_events reset
        extract archive insert
        archives archive_count has_archive scoped
        _artifact_rows_for_archive
    }) {
        no strict 'refs';
        *{$m} = sub { undef };
    }
    with 'App::Yath2::Role::DB::Backend';
}
my $fake = Test::FakeBackend->new;
my $log3 = App::Yath2::Log::DB->new(backend => $fake, uuid => $u);
isa_ok($log3->{db}, ['App::Yath2::DB'], 'role-doer backend wrapped in App::Yath2::DB');

# is_live / static.
is($log->is_live, 0, 'is_live = 0');
is($log->static,  1, 'static  = 1');

done_testing;
