use Test2::V0;

ok(1, "pass one");
is(2 + 2, 4, "math works");
note("a note to stdout");
diag("a diag to stderr");

done_testing;
