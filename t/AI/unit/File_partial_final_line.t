use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::File::JSONL;
use Test2::Harness2::Util::JSON ();

# Regression coverage for #154 (finding 44): a final line without a trailing
# newline was silently dropped by every Stream/JSONL reader because `done` was
# never set. Bounded consumers now pass `done => 1` and surface (or, if the tail
# is undecodable, warn+skip) that final record instead of losing it.

my sub write_file {
    my ($body) = @_;
    my ($fh, $file) = tempfile("t154-jsonl-XXXXXX", SUFFIX => '.jsonl', TMPDIR => 1, UNLINK => 1);
    print $fh $body;
    close($fh);
    return $file;
}

# Three JSONL records, the LAST one with no trailing newline.
my $complete_tail = qq[{"n":1}\n{"n":2}\n{"n":3}];

subtest 'done => 1 surfaces the newline-less final record' => sub {
    my $file = write_file($complete_tail);

    my $r = Test2::Harness2::Util::File::JSONL->new(name => $file, done => 1);
    my @all;
    while (1) {
        my @got = $r->poll(max => 1000) or last;
        push @all, @got;
    }

    is(scalar(@all), 3, "read all 3 records including the newline-less final one");
    is($all[-1], {n => 3}, "final (newline-less) record decoded correctly");
};

subtest 'without done the final partial is withheld, and DESTROY warns' => sub {
    my $file = write_file($complete_tail);

    my @all;
    my $warnings = warnings {
        my $r = Test2::Harness2::Util::File::JSONL->new(name => $file);
        while (1) {
            my @got = $r->poll(max => 1000) or last;
            push @all, @got;
        }
        is(scalar(@all), 2, "guard intact: newline-less final record withheld for a live (non-done) reader");
        $r = undef;    # discard the reader while it still holds the partial
    };

    is(scalar(@$warnings), 1, "exactly one warning (from DESTROY)");
    like($warnings, [qr/reader discarded holding a partial/], "DESTROY warned the poll ended holding a partial line");
};

subtest 'done => 1 with a truncated (undecodable) final record warns+skips, no die' => sub {
    # Final line is HALF a JSON record with no trailing newline.
    my $file = write_file(qq[{"n":1}\n{"n":2}\n{"n": ]);

    my @all;
    my $warnings = warnings {
        my $r = Test2::Harness2::Util::File::JSONL->new(name => $file, done => 1);
        my $ok = eval {
            while (1) {
                my @got = $r->poll(max => 1000) or last;
                push @all, @got;
            }
            1;
        };
        ok($ok, "poll loop terminated cleanly (did not die on the truncated final record)");
    };

    is(scalar(@all), 2, "earlier complete records still returned");
    like($warnings, [qr/discarding truncated final record/], "warned about the truncated final record");
};

subtest 'a mid-file corrupt line still confesses without skip_bad_decode' => sub {
    # Corrupt line is in the MIDDLE and IS newline-terminated: the done-tail
    # special case must not mask ordinary mid-stream corruption.
    my $file = write_file(qq[{"n":1}\nNOT JSON\n{"n":3}\n]);

    my $r = Test2::Harness2::Util::File::JSONL->new(name => $file, done => 1);
    like(
        dies { while (my @got = $r->poll(max => 1000)) { } },
        qr/\Q$file\E/,
        "mid-file undecodable line still confesses (done does not mask it)"
    );
};

subtest 'consumer pin: stream_json_l_file counts a newline-less final job' => sub {
    my $file = write_file(
        qq[{"facet_data":{"harness_job_start":{"rel_file":"a.t"}}}\n]
      . qq[{"facet_data":{"harness_job_end":{"rel_file":"b.t","fail":0}}}]    # no trailing newline
    );

    my @seen;
    Test2::Harness2::Util::JSON::stream_json_l_file($file, sub { push @seen, $_[0] });

    is(scalar(@seen), 2, "stream_json_l_file surfaced both records including the newline-less final one");
    is($seen[-1]{facet_data}{harness_job_end}{rel_file}, "b.t", "final harness_job_end record decoded and counted");
};

done_testing;
