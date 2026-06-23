use Test2::V0 -target => 'App::Yath2::Util::UUID';
use Test2::Tools::Spec;

use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

# ----------------------------------------------------------------------------
# Helpers: build/inspect v7 UUIDs with controlled bit patterns so we can drive
# the wrap path deterministically.
#
# Layout (big-endian 16 bytes):
#   [48b ts_ms][4b version=0111][12b rand_a][2b variant=10][62b rand_b]
# ----------------------------------------------------------------------------

# Build a canonical lowercase v7 UUID string from a 48-bit ts, 12-bit rand_a,
# and a 62-bit rand_b (given as an upper-30-bit chunk and a lower-32-bit chunk
# so we never need a >32-bit literal). Version (7) and variant (10) are forced.
sub make_v7 {
    my (%p) = @_;

    my $ts_hi = $p{ts_hi} // 0x0190;       # top 16 bits of the 48-bit ts
    my $ts_lo = $p{ts_lo} // 0x12345678;   # low 32 bits of the 48-bit ts
    my $rand_a = $p{rand_a} // 0x0abc;     # 12 bits

    # rand_b is 62 bits == (rb_hi << 32) | rb_lo, where rb_hi is 30 bits.
    my $rb_hi = $p{rb_hi} // 0x00000000;   # 30 bits (bits 61..32 of rand_b)
    my $rb_lo = $p{rb_lo} // 0x00000000;   # 32 bits (bits 31..0 of rand_b)

    # byte 6 = version(4) | rand_a high nibble
    my $b6 = (0x7 << 4) | (($rand_a >> 8) & 0x0F);
    my $b7 = $rand_a & 0xFF;

    # high 8 bytes: ts(48) + version/rand_a(16)
    my $high = pack('n N', $ts_hi, $ts_lo) . pack('C C', $b6, $b7);

    # low 8 bytes: variant(10) in top 2 bits, then 62 bits of rand_b.
    # high word = (variant << 30) | rb_hi(30 bits); variant=0b10 => 0x80000000.
    my $lo_hi = 0x80000000 | ($rb_hi & 0x3FFFFFFF);
    my $low   = pack('N N', $lo_hi, $rb_lo);

    my $hex = lc(unpack('H*', $high . $low));
    return join '-', (
        substr($hex,  0, 8),
        substr($hex,  8, 4),
        substr($hex, 12, 4),
        substr($hex, 16, 4),
        substr($hex, 20, 12),
    );
}

# Decode a UUID string -> { ts48, version, variant, rand_a, rb_hi (30b), rb_lo }
sub decode {
    my ($uuid) = @_;
    (my $hex = $uuid) =~ s/-//g;
    my $bytes = pack('H*', $hex);
    my ($ts_hi, $ts_lo, $b6, $b7) = unpack('n N C C', substr($bytes, 0, 8));
    my ($lo_hi, $lo_lo) = unpack('N N', substr($bytes, 8, 8));

    return {
        ts48    => sprintf('%04x%08x', $ts_hi, $ts_lo),
        version => ($b6 >> 4) & 0x0F,
        rand_a  => (($b6 & 0x0F) << 8) | $b7,
        variant => ($lo_hi >> 30) & 0x03,   # top 2 bits of byte 8
        rb_hi   => $lo_hi & 0x3FFFFFFF,      # 30 bits
        rb_lo   => $lo_lo,                   # 32 bits
    };
}

# ----------------------------------------------------------------------------

tests gen_uuid_is_lowercase => sub {
    for (1 .. 25) {
        my $u = gen_uuid();
        like($u, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, "gen_uuid is lowercase canonical: $u");
        is($u, lc($u), "gen_uuid has no uppercase chars");
    }
};

tests derive_zero_is_identity => sub {
    my $base = gen_uuid();
    is(derive_uuid($base, 0), $base, "derive(base, 0) == base");

    # Also for a crafted base.
    my $b2 = make_v7(rb_lo => 0x0000002a);
    is(derive_uuid($b2, 0), $b2, "derive(crafted, 0) == base");
};

tests derive_nonzero_differs => sub {
    my $base = gen_uuid();
    for my $k (1, 2, 5, 100, 1_000_000) {
        isnt(derive_uuid($base, $k), $base, "derive(base, $k) != base for k>=1");
    }
};

tests distinct_offsets_distinct_results => sub {
    my $base = gen_uuid();
    my %seen;
    for my $k (0 .. 50) {
        my $d = derive_uuid($base, $k);
        ok(!$seen{$d}++, "offset $k gives a result distinct from all prior offsets");
    }
};

tests simple_increment => sub {
    # rand_b low = 10 -> +5 = 15, nothing else moves.
    my $base = make_v7(rb_hi => 0x00000000, rb_lo => 0x0000000a);
    my $got  = derive_uuid($base, 5);

    my $bd = decode($base);
    my $gd = decode($got);

    is($gd->{rb_lo}, 0x0000000f, "rand_b low incremented by offset");
    is($gd->{rb_hi}, $bd->{rb_hi}, "rand_b high unchanged");
    is($gd->{version}, 7, "version still 7");
    is($gd->{variant}, 0b10, "variant still 10");
    is($gd->{ts48}, $bd->{ts48}, "timestamp unchanged");
    is($gd->{rand_a}, $bd->{rand_a}, "rand_a unchanged");
};

tests carry_between_words => sub {
    # rand_b low word at max -> +1 must carry into the high word, staying inside
    # the 62-bit field (does not touch the variant).
    my $base = make_v7(rb_hi => 0x00000000, rb_lo => 0xFFFFFFFF);
    my $got  = derive_uuid($base, 1);

    my $bd = decode($base);
    my $gd = decode($got);

    is($gd->{rb_lo}, 0x00000000, "low word wrapped to 0");
    is($gd->{rb_hi}, 0x00000001, "carry landed in rand_b high word");
    is($gd->{version}, 7, "version still 7 after carry");
    is($gd->{variant}, 0b10, "variant still 10 after carry");
    is($gd->{ts48}, $bd->{ts48}, "timestamp unchanged after carry");
    is($gd->{rand_a}, $bd->{rand_a}, "rand_a unchanged after carry");
};

tests wrap_at_rand_b_max => sub {
    # rand_b = 2^62 - 1 (all 62 bits set): rb_hi = 0x3FFFFFFF, rb_lo = 0xFFFFFFFF.
    # +1 must wrap to 0 within the 62-bit field WITHOUT changing the variant,
    # version, timestamp, or rand_a above it.
    my $base = make_v7(rb_hi => 0x3FFFFFFF, rb_lo => 0xFFFFFFFF);
    my $bd = decode($base);
    is($bd->{rb_hi}, 0x3FFFFFFF, "sanity: base rand_b high is max (30 bits)");
    is($bd->{rb_lo}, 0xFFFFFFFF, "sanity: base rand_b low is max (32 bits)");
    is($bd->{variant}, 0b10, "sanity: base variant is 10");

    my $got = derive_uuid($base, 1);
    my $gd  = decode($got);

    is($gd->{rb_hi}, 0x00000000, "rand_b high wrapped to 0");
    is($gd->{rb_lo}, 0x00000000, "rand_b low wrapped to 0");
    is($gd->{variant}, 0b10, "WRAP: variant bits untouched (still 10)");
    is($gd->{version}, 7, "WRAP: version untouched (still 7)");
    is($gd->{ts48}, $bd->{ts48}, "WRAP: timestamp untouched");
    is($gd->{rand_a}, $bd->{rand_a}, "WRAP: rand_a untouched");

    # And a larger wrap: max + 5 -> 4.
    my $got2 = derive_uuid($base, 5);
    my $gd2  = decode($got2);
    is($gd2->{rb_lo}, 0x00000004, "rand_b wraps mod 2^62 for offset 5 (=> 4)");
    is($gd2->{rb_hi}, 0x00000000, "rand_b high stays 0 on wrap");
    is($gd2->{variant}, 0b10, "WRAP(+5): variant still 10");
    is($gd2->{version}, 7, "WRAP(+5): version still 7");
};

tests deterministic => sub {
    my $base = gen_uuid();
    for my $k (0, 1, 7, 4242) {
        is(derive_uuid($base, $k), derive_uuid($base, $k), "same (base, $k) is deterministic");
    }

    # A fixed base must produce a fixed, reproducible result across runs.
    my $fixed = '0190abcd-1234-7abc-8000-00000000002a';
    is(derive_uuid($fixed, 1), '0190abcd-1234-7abc-8000-00000000002b', "fixed base+offset is reproducible");
};

tests result_is_lowercase => sub {
    # Even given an uppercase base, the derived result is canonical lowercase.
    my $base = uc(gen_uuid());
    my $got  = derive_uuid($base, 3);
    is($got, lc($got), "derived UUID is lowercase regardless of base case");
    like($got, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, "derived UUID is canonical");
};

tests input_validation => sub {
    like(dies { derive_uuid(undef, 0) }, qr/base UUID is required/, "base required");
    like(dies { derive_uuid('not-a-uuid', 0) }, qr/does not look like a UUID/, "bad base rejected");
    like(dies { derive_uuid(gen_uuid(), -1) }, qr/non-negative integer/, "negative offset rejected");
    like(dies { derive_uuid(gen_uuid(), 'x') }, qr/non-negative integer/, "non-integer offset rejected");
};

done_testing;
