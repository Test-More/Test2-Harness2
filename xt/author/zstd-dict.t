use strict;
use warnings;

use Test2::Require::AuthorTesting;
use Test2::V0;

use Compress::Zstd qw/compress decompress/;
use Compress::Zstd::CompressionDictionary;
use Compress::Zstd::DecompressionDictionary;
use Compress::Zstd::CompressionContext;
use Compress::Zstd::DecompressionContext;

# Author tests run inside the dzil-built dist tree (share/ alongside
# lib/), so the dict file lives at a known relative path from the
# distribution root. Resolve relative to this test file rather than
# going through File::ShareDir, which only works post-install.
use FindBin ();
use File::Spec ();

my $path = File::Spec->catfile($FindBin::Bin, '..', '..', 'share', 'other', 'zstd.dict');
ok(-f $path,       "share/other/zstd.dict exists at $path");
ok(-s $path > 100, "share/other/zstd.dict is non-trivial");

my $cdict = Compress::Zstd::CompressionDictionary->new_from_file($path);
ok($cdict, "CompressionDictionary loaded");

my $ddict = Compress::Zstd::DecompressionDictionary->new_from_file($path);
ok($ddict, "DecompressionDictionary loaded");

my $cctx = Compress::Zstd::CompressionContext->new;
my $dctx = Compress::Zstd::DecompressionContext->new;

my $payload = qq[{"facet_data":{"harness":{"kind":"event","run_id":"abc","job_id":"j1"}}}\n];
my $frame   = $cctx->compress_using_dict($payload, $cdict);
my $back    = $dctx->decompress_using_dict($frame, $ddict);
is($back, $payload, "dict round-trip");

done_testing;
