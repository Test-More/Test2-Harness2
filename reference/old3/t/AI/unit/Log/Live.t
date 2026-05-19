use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use App::Yath2::Log;
use App::Yath2::Log::Live;

# Live backend is just a thin subclass of Directory that forces live=1.
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");

my $log = App::Yath2::Log->new(live => $dir);
isa_ok($log, ['App::Yath2::Log::Live']);
isa_ok($log, ['App::Yath2::Log::Directory']);
is($log->is_live, 1, 'is_live true');
is($log->static,  0, 'static false');

# Direct construction works too.
my $direct = App::Yath2::Log::Live->new(path => $dir);
isa_ok($direct, ['App::Yath2::Log::Live']);
is($direct->is_live, 1, 'direct: is_live true');

# Listing methods inherit from Directory.
is([$log->services], ['harness'], 'services inherited');

done_testing;
