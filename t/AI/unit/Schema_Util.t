use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD
#
# Unit coverage for the pure helpers in App::Yath2::Schema::Util. These are
# DB-free functions (duration formatting/parsing, subtest-name validation,
# driver-name mapping) so no database is required.

use strict;
use warnings;

# Util pulls in Test2::Harness2::Util (mod2file); gate cleanly if missing.
BEGIN {
    eval { require Test2::Harness2::Util; 1 } or plan skip_all => "Test2::Harness2::Util required: $@";
}

use App::Yath2::Schema::Util qw{
    format_duration parse_duration is_invalid_subtest_name
    qdb_driver dbd_driver format_driver
};

subtest format_duration => sub {
    is(format_duration(0),  '00.0000s', "zero seconds");
    is(format_duration(1),  '01.0000s', "one second");
    is(format_duration(1.5), '01.5000s', "fractional seconds preserved");
    is(format_duration(59), '59.0000s', "just under a minute is seconds-only");

    is(format_duration(60),   '01m:00.0000s', "one minute rolls over");
    is(format_duration(90),   '01m:30.0000s', "90s == 1m30s");
    is(format_duration(3600), '01h:00m:00.0000s', "one hour");
    is(format_duration(3661), '01h:01m:01.0000s', "1h1m1s");
    is(format_duration(86400),'01d:00h:00m:00.0000s', "one day");
    is(format_duration(90061),'01d:01h:01m:01.0000s', "1d1h1m1s");
};

subtest parse_duration => sub {
    is(parse_duration(undef), 0, "undef parses to 0");
    is(parse_duration(0),     0, "zero parses to 0");
    is(parse_duration('') + 0, 0, "empty string parses to 0");

    # A bare number (no unit suffix) is returned as-is.
    is(parse_duration(42),   42,   "bare number passes through");
    is(parse_duration(3.14), 3.14, "bare fractional number passes through");

    is(parse_duration('30s'), 30,   "seconds");
    is(parse_duration('1m'),  60,   "minutes");
    is(parse_duration('1h'),  3600, "hours");
    is(parse_duration('1d'),  86400,"days");

    is(parse_duration('01m:30s'),          90,    "minutes + seconds");
    is(parse_duration('01h:01m:01s'),      3661,  "hours + minutes + seconds");
    is(parse_duration('01d:01h:01m:01s'),  90061, "days through seconds");
};

subtest 'format_duration / parse_duration round-trip' => sub {
    for my $secs (0.5, 1, 59, 60, 90, 3600, 3661, 86400, 90061, 123456.5) {
        my $formatted = format_duration($secs);
        my $parsed    = parse_duration($formatted);
        is($parsed, $secs, "round-trip $secs -> '$formatted' -> $parsed");
    }
};

subtest is_invalid_subtest_name => sub {
    ok(is_invalid_subtest_name('__ANON__'),            "__ANON__ is invalid");
    ok(is_invalid_subtest_name('unnamed'),             "'unnamed' is invalid");
    ok(is_invalid_subtest_name('unnamed subtest'),     "'unnamed subtest' is invalid");
    ok(is_invalid_subtest_name('unnamed summary'),     "'unnamed summary' is invalid");
    ok(is_invalid_subtest_name('<UNNAMED ASSERTION>'), "'<UNNAMED ASSERTION>' is invalid");

    ok(!is_invalid_subtest_name('my real subtest'),    "a real name is valid");
    ok(!is_invalid_subtest_name(''),                   "empty string is valid (returns 0)");
    is(is_invalid_subtest_name('whatever'), 0, "valid name returns 0, not undef");
};

subtest 'driver name mapping' => sub {
    # qdb_driver: schema name -> DBIx::QuickDB driver
    is(qdb_driver('SQLite'),     'SQLite',     "SQLite -> SQLite (qdb)");
    is(qdb_driver('PostgreSQL'), 'PostgreSQL', "PostgreSQL -> PostgreSQL (qdb)");
    is(qdb_driver('MySQL'),      'MySQL',      "MySQL -> MySQL (qdb)");
    is(qdb_driver('MariaDB'),    'MariaDB',    "MariaDB -> MariaDB (qdb)");
    is(qdb_driver('Percona'),    'Percona',    "Percona -> Percona (qdb)");
    is(qdb_driver('Pg'),         'PostgreSQL', "Pg alias -> PostgreSQL (qdb)");

    # base_name strips trailing digits / .sql and lowercases, so 'SQLite.sql'
    # and 'PostgreSQL2' must resolve.
    is(qdb_driver('SQLite.sql'), 'SQLite',     "trailing .sql stripped");
    is(qdb_driver('PostgreSQL9'),'PostgreSQL', "trailing digits stripped");

    # dbd_driver: schema name -> DBD::* driver
    is(dbd_driver('SQLite'),     'DBD::SQLite', "SQLite -> DBD::SQLite");
    is(dbd_driver('PostgreSQL'), 'DBD::Pg',     "PostgreSQL -> DBD::Pg");
    is(dbd_driver('MySQL'),      'DBD::mysql',  "MySQL -> DBD::mysql");

    # format_driver: schema name -> DateTime::Format::*
    is(format_driver('SQLite'),     'DateTime::Format::SQLite', "SQLite format driver");
    is(format_driver('PostgreSQL'), 'DateTime::Format::Pg',     "Pg format driver");
    is(format_driver('MySQL'),      'DateTime::Format::MySQL',  "MySQL format driver");

    is(qdb_driver('nonsense'), undef, "unknown driver -> undef");
};

done_testing;
