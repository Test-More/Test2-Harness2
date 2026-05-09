use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::Log::DB;

# Mock App::Yath2::DB recording every method call. Walker traffic now
# routes through an App::Yath2::DB::Iterator built by ->iterator($u);
# everything else lands on $self->db with our cached uuid prepended.
{
    package Test::IterStub;
    sub new { bless { calls => [], parent => $_[1] }, $_[0] }
    sub next  { push @{$_[0]{parent}{calls}}, ['event'];        'rv' }
    sub all   { push @{$_[0]{parent}{calls}}, ['events'];       ('rv') }
    sub EOE   { push @{$_[0]{parent}{calls}}, ['end_of_events']; 1 }
    sub reset { push @{$_[0]{parent}{calls}}, ['reset'];        'rv' }
    sub count { 0 }
}

{
    package Test::ProxyDB;
    use App::Yath2::DB;
    our @ISA = ('App::Yath2::DB');
    sub new { bless { calls => [], iterator_count => 0 }, shift }
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
        artifacts
    }) {
        no strict 'refs';
        *{$m} = sub { my $self = shift; $self->_record($m => @_); 'rv' };
    }
    sub iterator {
        my ($self, $uuid) = @_;
        $self->{iterator_count}++;
        $self->{last_iter_uuid} = $uuid;
        return Test::IterStub->new($self);
    }
}

my $u = gen_uuid();
my $db = Test::ProxyDB->new;
my $log = App::Yath2::Log::DB->new(db => $db, uuid => $u);

# uuid required.
my $err = dies { App::Yath2::Log::DB->new(db => $db) };
like($err, qr/'uuid' is required/, 'uuid required');

# db required.
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

# Walker methods (event/events/EOE/reset) route through an
# App::Yath2::DB::Iterator built lazily by ->iterator($u). The
# iterator is cached, so repeated walker calls only trigger one
# ->iterator($u) call.
$log->event;
$log->event;
is($db->{iterator_count}, 1, 'iterator() called exactly once for walker chain');
is($db->{last_iter_uuid}, $u, 'iterator built with our uuid');
my @walker_calls = grep { $_->[0] eq 'event' } @{$db->{calls}};
is(scalar(@walker_calls), 2, 'two event() delegations recorded on iterator stub');

# insert routes through App::Yath2::DB->insert (no uuid -- insert
# discovers / creates the archive).
$log->insert('source');
my $insert_call = $calls->[-1];
is($insert_call, [insert => 'source'], 'insert delegated to App::Yath2::DB->insert');

# artifacts() delegates to App::Yath2::DB->artifacts with uuid prepended.
$log->artifacts(2, 3, 4);
my $art_call = $calls->[-1];
is($art_call, [artifacts => $u, 2, 3, 4], 'artifacts delegated with uuid');

# is_live / static.
is($log->is_live, 0, 'is_live = 0');
is($log->static,  1, 'static  = 1');

done_testing;
