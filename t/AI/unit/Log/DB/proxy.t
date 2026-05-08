use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::Log::DB;

# Mock backend recording every method call. Consumes
# App::Yath2::Role::DB::Backend so the proxy's DOES check passes.
{
    package Test::ProxyBackend;
    use parent -norequire => 'Object::HashBase';
    use Object::HashBase qw{ <calls };
    use Role::Tiny::With;
    sub init   { $_[0]->{calls} //= [] }
    sub _record {
        my ($self, @a) = @_;
        push @{$self->{calls}}, [@a];
        return;
    }
    for my $m (qw{
        services runs jobs tries last_try
        has_service has_run has_job has_try
        artifacts event events end_of_events reset
        extract archive insert
    }) {
        no strict 'refs';
        *{$m} = sub { my $self = shift; $self->_record($m => @_); 'rv' };
    }
    for my $m (qw{ archives archive_count has_archive flavor dbh
                   _archive_id_or_die _artifact_rows_for_archive }) {
        no strict 'refs';
        *{$m} = sub { 'stub' };
    }
    sub scoped {
        my ($self, $uuid) = @_;
        push @{$self->{calls}}, [scoped => $uuid];
        # Return self so subsequent calls go through the same recorder.
        return $self;
    }
    with 'App::Yath2::Role::DB::Backend';
}

my $u = gen_uuid();
my $back = Test::ProxyBackend->new;
my $log = App::Yath2::Log::DB->new(backend => $back, uuid => $u);

# uuid required.
my $err = dies { App::Yath2::Log::DB->new(backend => $back) };
like($err, qr/'uuid' is required/, 'uuid required');

# backend required.
my $err2 = dies { App::Yath2::Log::DB->new(uuid => $u) };
like($err2, qr/'backend' is required/, 'backend required');

# backend must do the role.
{
    package Test::NotARoleConsumer;
    sub new { bless {}, shift }
    sub DOES { 0 }
}
my $err3 = dies { App::Yath2::Log::DB->new(backend => Test::NotARoleConsumer->new, uuid => $u) };
like($err3, qr/must consume App::Yath2::Role::DB::Backend/, 'role check enforced');

# 1:1 delegation.
$log->services(1, 2);
$log->runs;
my $calls = $back->calls;
is($calls->[0], [scoped => $u],     'first call produces scoped()');
is($calls->[1], [services => 1, 2], 'services delegated 1:1');
is($calls->[2], [runs => ()],       'runs delegated 1:1');

# scoped is cached: a second call doesn't re-scope.
my $count_before = scalar @$calls;
$log->jobs;
is($calls->[$count_before], [jobs => ()], 'next call goes via cached scoped');
my $rescopes = grep { $_->[0] eq 'scoped' } @$calls;
is($rescopes, 1, 'scoped() called exactly once across 3 group-A calls');

# is_live / static.
is($log->is_live, 0, 'is_live = 0');
is($log->static,  1, 'static  = 1');

done_testing;
