use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::Role::Reloader;

# Requires watch_paths + do_reload -- composing without them errors.
{
    eval {
        package WillFail::NoMethods;
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Reloader';
    };
    like($@, qr/watch_paths|do_reload/,
        'role composition errors when required methods missing');
}

# Minimal consumer that satisfies both required methods.
{
    package OK::Min;
    use Role::Tiny::With;
    sub watch_paths { [] }
    sub do_reload   { 1 }
    with 'Test2::Harness2::Role::Reloader';
}

is(OK::Min->debounce_secs, 0.25, 'debounce_secs default');
my $obj = bless {}, 'OK::Min';
is($obj->before_reload('svc', '/path'),         undef, 'before_reload no-op default');
is($obj->after_reload('svc', '/path', 1, undef), undef, 'after_reload no-op default');

# Consumer overrides win.
{
    package OK::Override;
    use Role::Tiny::With;
    our @CALLS;
    sub watch_paths    { [] }
    sub do_reload      { my @a = @_; push @CALLS, ['do_reload', @a[1..$#a]]; 1 }
    sub debounce_secs  { 0.5 }
    sub before_reload  { my @a = @_; push @CALLS, ['before_reload', @a[1..$#a]]; 1 }
    sub after_reload   { my @a = @_; push @CALLS, ['after_reload', @a[1..$#a]]; 1 }
    with 'Test2::Harness2::Role::Reloader';
}

is(OK::Override->debounce_secs, 0.5, 'consumer debounce override');
@OK::Override::CALLS = ();
my $o = bless {}, 'OK::Override';
$o->before_reload('svc', '/foo.pm');
$o->do_reload('svc');
$o->after_reload('svc', '/foo.pm', 1, undef);
is(\@OK::Override::CALLS, [
    ['before_reload', 'svc', '/foo.pm'],
    ['do_reload',     'svc'],
    ['after_reload',  'svc', '/foo.pm', 1, undef],
], 'overrides invoked in order with arguments threaded through');

done_testing;
