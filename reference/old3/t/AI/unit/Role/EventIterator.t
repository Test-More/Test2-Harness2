use Test2::V0;

use App::Yath2::Role::EventIterator;
use App::Yath2::DB::Iterator;
use App::Yath2::Log::Iterator::JSONL;

use Role::Tiny ();

# Role identity.
ok(Role::Tiny->is_role('App::Yath2::Role::EventIterator'),
    'EventIterator is a Role::Tiny role');

# Required-method list matches the spec exactly.
{
    my %req = map { $_ => 1 }
        @{ $Role::Tiny::INFO{'App::Yath2::Role::EventIterator'}{requires} // [] };
    is(\%req, { next => 1, EOE => 1, reset => 1, count => 1 },
        'requires next, EOE, reset, count');
}

# Provided-method list includes all and first.
{
    my $provided = $Role::Tiny::INFO{'App::Yath2::Role::EventIterator'}{methods} || {};
    ok(exists $provided->{all},
        'role provides all()');
    ok(exists $provided->{first},
        'role provides first()');
}

# Both consumers DOES the role.
ok(Role::Tiny::does_role('App::Yath2::DB::Iterator', 'App::Yath2::Role::EventIterator'),
    'App::Yath2::DB::Iterator DOES App::Yath2::Role::EventIterator');
ok(Role::Tiny::does_role('App::Yath2::Log::Iterator::JSONL', 'App::Yath2::Role::EventIterator'),
    'App::Yath2::Log::Iterator::JSONL DOES App::Yath2::Role::EventIterator');

# Both consumers can() every required + provided method.
for my $consumer (qw/App::Yath2::DB::Iterator App::Yath2::Log::Iterator::JSONL/) {
    for my $m (qw/next EOE reset count all first/) {
        ok($consumer->can($m), "$consumer can $m");
    }
}

done_testing;
