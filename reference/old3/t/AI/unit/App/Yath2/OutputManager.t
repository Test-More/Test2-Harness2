use Test2::V0;

use App::Yath2::OutputManager;
use App::Yath2::Filter;

my $CLASS = 'App::Yath2::OutputManager';

{
    package MockRenderer;

    sub new {
        bless {events => [], started => 0, finished => 0, signals => []}, shift;
    }

    sub desired_filters { () }
    sub start           { $_[0]->{started}++ }
    sub finish          { $_[0]->{finished}++ }
    sub signal          { push @{$_[0]->{signals}} => $_[1] }
    sub end_of_events   { $_[0]->{eoe}++ }
    sub render_event    { push @{$_[0]->{events}} => $_[1] }
}

{
    package DropFilter;
    use parent -norequire, 'App::Yath2::Filter';

    sub filter_event {
        my ($self, $event) = @_;
        return undef if ($event->{event_id} // '') =~ /^drop-/;
        return $event;
    }
}

{
    package FilteringRenderer;
    use parent -norequire, 'MockRenderer';
    sub desired_filters { ('DropFilter') }
}

subtest 'constructs with empty pipeline list' => sub {
    my $om = $CLASS->new;
    is(ref $om->pipelines, 'ARRAY', 'pipelines is arrayref');
    is(scalar @{$om->pipelines}, 0, 'empty by default');
};

subtest 'add_renderer calls start immediately' => sub {
    my $om = $CLASS->new;
    my $r  = MockRenderer->new;
    is($r->{started}, 0, 'not started before add_renderer');
    $om->add_renderer($r);
    is($r->{started}, 1, 'started after add_renderer');
};

subtest 'add_renderer builds pipeline with no filters for plain renderer' => sub {
    my $om = $CLASS->new;
    my $r  = MockRenderer->new;
    $om->add_renderer($r);

    is(scalar @{$om->pipelines},               1, 'one pipeline');
    is(scalar @{$om->pipelines->[0]{filters}}, 0, 'no filters');
    is(scalar @{$om->pipelines->[0]{renderers}}, 1, 'one renderer in pipeline');
};

subtest 'dispatch reaches renderer when no filters' => sub {
    my $om = $CLASS->new;
    my $r  = MockRenderer->new;
    $om->add_renderer($r);

    my @events = map { {event_id => "e$_"} } 1 .. 3;
    $om->dispatch($_) for @events;

    is(scalar @{$r->{events}}, 3, '3 events received');
    is($r->{events}[0]{event_id}, 'e1', 'first event correct');
    is($r->{events}[2]{event_id}, 'e3', 'last event correct');
};

subtest 'filter drops events matching its rule' => sub {
    my $om = $CLASS->new;
    my $r  = FilteringRenderer->new;
    $om->add_renderer($r);

    is(scalar @{$om->pipelines->[0]{filters}}, 1, 'one filter in chain');

    my @events = (
        {event_id => 'keep-1'},
        {event_id => 'drop-1'},
        {event_id => 'keep-2'},
        {event_id => 'drop-2'},
    );
    $om->dispatch($_) for @events;

    is(scalar @{$r->{events}}, 2, 'only 2 events reached renderer');
    is($r->{events}[0]{event_id}, 'keep-1', 'first kept');
    is($r->{events}[1]{event_id}, 'keep-2', 'second kept');
};

subtest 'two renderers with different filter chains get separate pipelines' => sub {
    my $om = $CLASS->new;
    my $r1 = MockRenderer->new;
    my $r2 = FilteringRenderer->new;

    $om->add_renderer($r1);
    $om->add_renderer($r2);

    is(scalar @{$om->pipelines}, 2, 'two independent pipelines');

    my @events = ({event_id => 'keep-x'}, {event_id => 'drop-x'});
    $om->dispatch($_) for @events;

    is(scalar @{$r1->{events}}, 2, 'unfiltered renderer sees both events');
    is(scalar @{$r2->{events}}, 1, 'filtered renderer sees only one');
    is($r2->{events}[0]{event_id}, 'keep-x', 'correct event through');
};

subtest 'two renderers with the same filter chain share one pipeline' => sub {
    my $om = $CLASS->new;
    my $r1 = FilteringRenderer->new;
    my $r2 = FilteringRenderer->new;

    $om->add_renderer($r1);
    $om->add_renderer($r2);

    is(scalar @{$om->pipelines}, 1, 'one shared pipeline');
    is(scalar @{$om->pipelines->[0]{renderers}}, 2, 'both renderers in it');

    my @events = ({event_id => 'keep-1'}, {event_id => 'drop-1'});
    $om->dispatch($_) for @events;

    is(scalar @{$r1->{events}}, 1, 'r1 sees only kept event');
    is(scalar @{$r2->{events}}, 1, 'r2 sees only kept event');
    is($r1->{events}[0]{event_id}, 'keep-1', 'r1 got correct event');
    is($r2->{events}[0]{event_id}, 'keep-1', 'r2 got correct event');
};

subtest 'finish is called via DESTROY and is idempotent' => sub {
    my ($r1, $r2);
    {
        my $om = $CLASS->new;
        $r1 = MockRenderer->new;
        $r2 = MockRenderer->new;
        $om->add_renderer($r1);
        $om->add_renderer($r2);
        $om->finish;     # explicit call
        # $om goes out of scope here — DESTROY should not double-fire
    }

    is($r1->{finished}, 1, 'r1 finished exactly once');
    is($r2->{finished}, 1, 'r2 finished exactly once');
};

subtest 'signal and end_of_events reach all renderers' => sub {
    my $om = $CLASS->new;
    my $r1 = MockRenderer->new;
    my $r2 = MockRenderer->new;

    $om->add_renderer($r1);
    $om->add_renderer($r2);

    $om->signal('TERM');
    $om->end_of_events;

    is($r1->{signals}, ['TERM'], 'r1 received signal');
    is($r1->{eoe},     1,        'r1 end_of_events');
    is($r2->{signals}, ['TERM'], 'r2 received signal');
};

done_testing;
