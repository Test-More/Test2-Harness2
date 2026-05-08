use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::Log::DB;

# Mock App::Yath2::DB recording every method call. Phase 7 ditched the
# legacy backend chain: walker, write, and artifacts traffic now all
# land on $self->db with our cached uuid prepended.
{
    package Test::ProxyDB;
    use App::Yath2::DB;
    our @ISA = ('App::Yath2::DB');
    sub new { bless { calls => [], scoped_count => 0 }, shift }
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
    # scoped() returns a uuid-bound sibling that records walker calls
    # back into the parent so the test can assert on them.
    sub scoped {
        my ($self, $uuid) = @_;
        $self->{scoped_count}++;
        my $sib = bless { parent => $self, uuid => $uuid }, ref($self);
        return $sib;
    }
    # Walker delegates: record on the parent (so the test's $db->{calls}
    # captures everything from one place).
    for my $m (qw{event events end_of_events EOE reset}) {
        no strict 'refs';
        *{$m} = sub {
            my $self = shift;
            my $target = $self->{parent} // $self;
            $target->_record($m => @_);
            return 'rv';
        };
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

# Walker methods (event/events/EOE/reset) route through a uuid-scoped
# clone of the App::Yath2::DB. The clone is cached, so repeated walker
# calls only trigger one ->scoped() call.
$log->event;
$log->event;
is($db->{scoped_count}, 1, 'scoped() called exactly once for walker chain');
my @walker_calls = grep { $_->[0] eq 'event' } @{$db->{calls}};
is(scalar(@walker_calls), 2, 'two event() delegations recorded');
is($walker_calls[0], [event => $u], 'event delegated with uuid');

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
