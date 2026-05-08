use Test2::V0;
use Test2::Require::Module 'DBD::Pg';

# Unit-style test for App::Yath2::DB::Internal::Postgres::preprocess_schema_sql.
# Does not start a real Postgres server; stubs _server_compression to
# simulate each branch.

use App::Yath2::DB;
use App::Yath2::DB::Internal::Postgres;
my $sample = <<'EOSQL';
CREATE TABLE t (
    a INT,
    b JSONB COMPRESSION zstd,
    c TEXT COMPRESSION zstd NOT NULL,
    d JSONB COMPRESSION zstd
);
EOSQL

# Bless directly to skip the DBH connection. Override
# _server_compression for the duration of $code so undef ('strip')
# is reachable (the production method's //= caches the do-block,
# bypassing pre-set undef slots).
sub with_compression {
    my ($algo, $code) = @_;
    my $db = bless {}, 'App::Yath2::DB::Internal::Postgres';
    no warnings 'redefine';
    local *App::Yath2::DB::Internal::Postgres::_server_compression = sub { $algo };
    $code->($db);
}

subtest zstd_supported_leaves_clauses_unchanged => sub {
    with_compression('zstd', sub {
        my $db = shift;
        my $out = $db->preprocess_schema_sql($sample);
        is($out, $sample, 'zstd schema passes through unchanged');
        my $count = () = $out =~ /COMPRESSION zstd\b/g;
        is($count, 3, 'all three COMPRESSION zstd clauses preserved');
    });
};

subtest lz4_only_downgrades_zstd_to_lz4 => sub {
    with_compression('lz4', sub {
        my $db = shift;
        my $out = $db->preprocess_schema_sql($sample);
        unlike($out, qr/COMPRESSION zstd/, 'no COMPRESSION zstd clauses remain');
        my $count = () = $out =~ /COMPRESSION lz4\b/g;
        is($count, 3, 'three COMPRESSION lz4 clauses present after rewrite');
        my $expected = $sample;
        $expected =~ s/COMPRESSION zstd/COMPRESSION lz4/g;
        is($out, $expected, 'output matches verbatim s/zstd/lz4/');
    });
};

subtest no_compression_strips_clauses => sub {
    with_compression(undef, sub {
        my $db = shift;
        my $out = $db->preprocess_schema_sql($sample);
        unlike($out, qr/COMPRESSION/i, 'no COMPRESSION clauses remain');
        like($out, qr/b JSONB[, ]/,                'column b still typed JSONB');
        like($out, qr/c TEXT NOT NULL/,            'column c keeps NOT NULL');
        like($out, qr/d JSONB[\s)]/,               'column d still typed JSONB');
        like($out, qr/CREATE TABLE t \(/,          'CREATE TABLE preserved');
    });
};

subtest case_insensitive_match => sub {
    with_compression('lz4', sub {
        my $db = shift;
        my $mixed = "x JSONB Compression ZSTD,\ny TEXT COMPRESSION zstd\n";
        my $out = $db->preprocess_schema_sql($mixed);
        unlike($out, qr/zstd/i, 'mixed-case zstd rewritten');
        # Both rewrites happen; original case of the COMPRESSION literal
        # is preserved by the capture group.
        my $count = () = $out =~ /COMPRESSION\s+lz4\b/gi;
        is($count, 2, 'both clauses rewritten regardless of original case');
    });
};

subtest leaves_other_compression_alone => sub {
    with_compression('lz4', sub {
        my $db = shift;
        my $sql = "x JSONB COMPRESSION pglz, y JSONB COMPRESSION zstd";
        my $out = $db->preprocess_schema_sql($sql);
        like($out,   qr/COMPRESSION pglz/, 'pglz clause untouched');
        like($out,   qr/COMPRESSION lz4/,  'zstd downgraded to lz4');
        unlike($out, qr/COMPRESSION zstd/, 'no zstd remains');
    });
};

done_testing;
