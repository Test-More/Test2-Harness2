**Superseded by `AI_DOCS/2026-05-08-yath-db-rebuild.md`.** Decisions in
this document are historical; the architecture they describe was
replaced by the DB rebuild (App::Yath2::DB::Internal* deleted in favor
of App::Yath2::DB + App::Yath2::DB::SQL + App::Yath2::DB::DBIC). See
the rebuild plan for current state.

----
(original content below)

# Yath DB Namespace — Design Spec

**Status:** approved 2026-05-08
**Branch / worktree:** `yath-db-schema` (under `.claude/worktrees/`)
**Replaces:** the planned-but-unimplemented `App::Yath2DB` namespace.

## Goal

Reshape the DB-backed log-archive code so:

1. `App::Yath2::Log::DB` becomes a thin **proxy** that matches the
   archive-shaped public surface of `App::Yath2::Log::Directory` /
   `App::Yath2::Log::TarZIdx`.
2. All DB-interaction logic lives under a new top-level
   **`App::Yath2::DB`** namespace.
3. A role — `App::Yath2::Role::DB::Backend` — defines the contract
   `Log::DB` consumes. Two implementations satisfy it:
   - `App::Yath2::DB::Internal` — raw SQL + per-flavor subclasses.
   - `App::Yath2::DB::DBIC` — single-class DBIx::Class wrapper.
4. The multi-archive container (`App::Yath2::LogDB`) is retired; its
   methods migrate into the role.

## Module map

```
App::Yath2::Role::DB::Backend           -- the role
App::Yath2::DB                          -- top-level + factory
App::Yath2::DB::Internal                -- raw-SQL backend, abstract base
App::Yath2::DB::Internal::Sqlite        -- per-flavor subclasses
App::Yath2::DB::Internal::Postgres
App::Yath2::DB::Internal::MariaDB
App::Yath2::DB::Internal::MySQL
App::Yath2::DB::DBIC                    -- DBIC backend, single class
App::Yath2::DB::DBIC::Schema            -- DBIx::Class::Schema subclass
App::Yath2::DB::DBIC::Result::*         -- hand-written Result classes
App::Yath2::Log::DB                     -- thin proxy, role-consuming
```

Removed:

- `App::Yath2::LogDB` (multi-archive container) — methods migrate to
  the role's group-B section.
- `App::Yath2::Log::DB::{Sqlite,Postgres,MariaDB,MySQL}` —
  per-flavor classes move to `App::Yath2::DB::Internal::{Flavor}`.

## `App::Yath2::Role::DB::Backend`

Uses `Role::Tiny` (project convention). Two method groups; every
consumer must provide both.

**Group A — per-archive (require resolved uuid; throw if absent)**

```
services / runs / jobs / tries / last_try
has_service / has_run / has_job / has_try
artifacts / event / events / end_of_events / reset
list_files / extract / archive
insert(\%payload)        -- single dispatching write entry-point;
                            kind => 'event' | 'artifact' | 'service' |
                            'run' | 'job' | 'try' | 'spec' | 'report' | ...
```

**Group B — multi-archive (uuid not required)**

```
archives                 -- list of UUIDs
archive_count
has_archive($uuid)
scoped($uuid)            -- return a Role::DB::Backend doer with uuid
                            set; cheap (shares dbh / DBIC schema)
flavor                   -- 'sqlite' | 'postgres' | 'mariadb' | 'mysql'
dbh
```

**Concrete role-provided methods**

`bootstrap_schema()` is implemented in the role itself. Reads
`share/schema/$flavor.sql`, runs `preprocess_schema_sql($sql)` (default
identity; consumers override for flavor quirks like the postgres
COMPRESSION lz4 strip), splits, executes. Every backend uses
`share/schema/*.sql` as the canonical schema. DBIC's `deploy()` is
**never** called.

`schema_file()` resolves the path (dev-tree first, then File::ShareDir).
`_is_bootstrapped()` probes for the `archives` table.

`requires` declarations cover every Group A + Group B method (above)
plus `dbh` and `flavor`.

## `App::Yath2::Log::DB` (proxy)

```perl
package App::Yath2::Log::DB;
use Object::HashBase qw{
    <backend     # consumes App::Yath2::Role::DB::Backend
    <uuid
    +_scoped     # cached scoped backend for this uuid
};

sub init {
    my $self = shift;
    croak "'backend' is required" unless $self->{+BACKEND};
    croak "backend must consume App::Yath2::Role::DB::Backend"
        unless $self->{+BACKEND}->DOES('App::Yath2::Role::DB::Backend');
    croak "'uuid' is required" unless defined $self->{+UUID};
    return;
}

sub is_live { 0 }
sub static  { 1 }

sub _backend {
    my $self = shift;
    return $self->{+_SCOPED} //= $self->{+BACKEND}->scoped($self->{+UUID});
}

for my $m (qw{
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts event events end_of_events reset
    list_files extract archive insert
}) {
    no strict 'refs';
    *{$m} = sub {
        my $self = shift;
        return $self->_backend->$m(@_);
    };
}

1;
```

uuid is fixed for the lifetime of a `Log::DB` instance, so the scoped
backend is cached on first call.

## `App::Yath2::DB` (top-level + factory)

```perl
sub open {
    my ($class, %args) = @_;
    my $backend = delete $args{backend} // 'internal';
    my $impl_class = _backend_class($backend, %args);
    my $ok = eval "require $impl_class; 1";
    croak "could not load backend '$impl_class': $@" unless $ok;
    return $impl_class->new(%args);
}

sub _backend_class {
    my ($name, %args) = @_;
    return 'App::Yath2::DB::DBIC' if $name eq 'dbic';
    if ($name eq 'internal') {
        my $flavor = _detect_flavor(%args);
        return "App::Yath2::DB::Internal::\u${flavor}"
            if $flavor =~ /^(sqlite|postgres|mariadb|mysql)$/;
        croak "unknown internal flavor '$flavor'";
    }
    croak "unknown backend '$name'";
}
```

Flavor detection: DSN regex / `$dbh->{Driver}{Name}` / file magic.
Same logic LogDB had today.

Constructor inputs match the implementations:

```
file => $path
dsn  => $dsn, user => $u, pass => $p, attrs => \%a
dbh  => $dbh
backend => 'internal' | 'dbic'    # default 'internal'
```

The returned object is a `Role::DB::Backend` doer with no uuid set.
Use `->scoped($uuid)` (or wrap in `App::Yath2::Log::DB`) to get an
archive-scoped instance.

## `App::Yath2::DB::Internal` (raw-SQL backend)

Per-flavor subclasses chosen for readability — each flavor's
divergent SQL is co-located in a small file.

**Base `App::Yath2::DB::Internal`** consumes
`App::Yath2::Role::DB::Backend` and houses ~3000 LoC of shared SQL /
schema-resolution / event / artifact / iterator code. Lifted verbatim
from today's `App::Yath2::Log::DB.pm`. Bodies call hooks like
`$self->_uuid_to_db`, `$self->_quote_user_col`, `$self->_last_insert_id`
that subclasses override.

Required by base (left abstract):

```
schema_flavor / schema_file
_connect_dbh
_payload_compressed_default
_uuid_to_db / _uuid_from_db
_json_encode / _json_decode
_now_iso
_format_datetime / _to_datetime
_quote_user_col
_last_insert_id
_preprocess_schema_sql       -- override only where needed
_insert_returning            -- bool capability
```

**Subclasses** (`App::Yath2::DB::Internal::{Sqlite,Postgres,MariaDB,MySQL}`)
each ~50-200 LoC, ported verbatim from current
`App::Yath2::Log::DB::{Flavor}` files.

**`scoped($uuid)`** (in base): cheap clone sharing `dbh` + `flavor`,
uuid resolved lazily on first Group-A call.

## `App::Yath2::DB::DBIC` (DBIC backend)

Single class. Wraps a `DBIx::Class::Schema` instance. No per-flavor
subclasses; flavor handled by DBIC's storage detection (and the role's
`preprocess_schema_sql` hook for the postgres lz4 case).

```perl
package App::Yath2::DB::DBIC;
use Object::HashBase qw{
    <file <dsn <user <pass <attrs <dbh
    <schema                # DBIx::Class::Schema instance
    <uuid <archive_id
};

sub init { ... }                # dispatch on schema|dbh|dsn|file

sub flavor {                    # storage->sqlt_type -> our token
    my $self = shift;
    my $t = $self->{+SCHEMA}->storage->sqlt_type;
    return {
        SQLite     => 'sqlite',
        PostgreSQL => 'postgres',
        MySQL      => 'mysql',
        MariaDB    => 'mariadb',
    }->{$t} // lc($t);
}

sub dbh { $_[0]->{+SCHEMA}->storage->dbh }

# Group A / Group B method bodies translate to ResultSet calls.

sub scoped {
    my ($self, $uuid) = @_;
    return ref($self)->new(schema => $self->{+SCHEMA}, uuid => $uuid);
}

# Postgres lz4 strip handled here (dispatch on flavor) since DBIC has
# only one class for all flavors.
sub preprocess_schema_sql {
    my ($self, $sql) = @_;
    return _postgres_strip_lz4($sql) if $self->flavor eq 'postgres';
    return $sql;
}
```

`bootstrap_schema()` inherited from role — runs `share/schema/$flavor.sql`.
Never calls `$schema->deploy`.

**Result classes** under `App::Yath2::DB::DBIC::Result::*`. Hand-
written. One per table in `share/schema/sqlite.sql`. Declare table,
columns (UUID columns only — no `*_uuid_string`), primary key,
relationships, and InflateColumn components for UUID / JSON / zstd
payload.

`*_uuid_string` columns are MySQL-only schema furniture for human
inspection. Triggers (`CREATE TRIGGER ... BEFORE INSERT/UPDATE`)
populate them from the `BIN_TO_UUID(<col>_uuid)` value. DBIC writes
only `<col>_uuid`; the trigger keeps the shadow in sync. Result classes
do not model the shadow.

## Factory selection

```perl
my $db = App::Yath2::DB->open(file => $path);                # default: internal
my $db = App::Yath2::DB->open(file => $path, backend => 'dbic');
my $db = App::Yath2::DB->open(dsn => 'dbi:Pg:...', backend => 'dbic');
my $log = App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
# or, equivalent for one-shot construction:
my $log = App::Yath2::Log::DB->new(
    backend => App::Yath2::DB->open(file => $path)->scoped($uuid),
    uuid    => $uuid,
);
```

`App::Yath2::Log->new(file => $sqlite_path)` (the existing factory in
`lib/App/Yath2/Log.pm`) continues to work. Its sqlite branch routes
through `App::Yath2::DB->open(file => $f, backend => 'internal')`
under the hood and wraps the result in `App::Yath2::Log::DB`.

## Test strategy

**Layer 1 — existing per-flavor unit tests, parameterized**

`t/AI/unit/Log/DB/{Sqlite,Postgres,MariaDB,MySQL}/*.t` (~30 files)
keep their current count and content. Body wrapped in
`for_each_log_db_backend` (added to
`t/lib/Test2/Harness2/Test/DBVersions.pm`):

```perl
sub for_each_log_db_backend {
    my ($body) = @_;
    for my $name (qw/internal dbic/) {
        subtest "backend=$name" => sub { $body->($name) };
    }
}
```

Each test runs once per backend. ~30 tests × 2 backends = 60 subtests.

**Layer 2 — new tests at the role / impl layer**

```
t/AI/unit/DB/Role/Backend.t          -- role contract: requires + DOES
t/AI/unit/DB/Role/bootstrap.t        -- concrete bootstrap_schema with
                                        a fixture .sql + mock backend
t/AI/unit/DB/Internal/dispatch.t     -- factory picks right flavor sub
t/AI/unit/DB/Internal/scoped.t       -- scoped() shares dbh, sets uuid
t/AI/unit/DB/DBIC/result_classes.t   -- each Result class loads, has
                                        correct table_name / pk / relations
t/AI/unit/DB/DBIC/schema_parity.t    -- parse share/schema/sqlite.sql,
                                        compare against DBIC Result column
                                        sets, fail on drift; allowlist for
                                        *_uuid_string (none in sqlite.sql
                                        anyway, listed for documentation)
t/AI/unit/DB/factory.t               -- App::Yath2::DB->open shape:
                                        backend default, flavor detection
                                        per input form, error paths
```

**Layer 3 — multi-archive coverage (replaces LogDB tests)**

`t/AI/unit/LogDB/sqlite.t` retired. Replaced by:

```
t/AI/unit/DB/multi_archive.t         -- archives / archive_count /
                                        has_archive / scoped round-trip,
                                        runs under both backends.
```

`t/AI/integration/archive_meta.t` switched to `App::Yath2::DB->open(...)`.

**Layer 4 — proxy delegation**

```
t/AI/unit/Log/DB/proxy.t             -- mock backend records method names
                                        + args; assert 1:1 pass-through,
                                        scoped() cached on first call,
                                        uuid required.
```

## Migration order (big-bang in worktree)

| Step | Change | Tree state |
|------|--------|------------|
| 1 | Add Role + factory skeleton + role unit tests | Compiles. Old code untouched. Tests green. |
| 2 | Add `App::Yath2::DB::Internal` base + 4 flavor subs (verbatim port of `App::Yath2::Log::DB::*`) | Compiles. Old code still present. Tests green. |
| 3 | Add `App::Yath2::DB::DBIC` + Schema + Result/* + DBIC unit tests | Compiles. Tests green incl. new DBIC tests. |
| 4 | Replace `App::Yath2::Log::DB` body with proxy. Delete `App::Yath2::Log::DB::*` flavor classes. Update `App::Yath2::Log` factory. | Breaks tests until step 5 lands in same commit. |
| 5 | Convert ~30 per-flavor tests to `for_each_log_db_backend`. Add multi_archive.t + proxy.t. Delete LogDB.pm + LogDB tests. Update integration tests + Log.pm POD. | All tests green under both backends. |
| 6 | Doc-only retirement of `App::Yath2DB` references in AI_DOCS + comments | Compiles, tests green. |
| 7 | Update `ARCHITECTURE.md` per Section 9 below + write AI_DOC. | Final. |
| 8 | Full suite + stress run + commits. | Done. |

Steps 4 + 5 land in the same commit (otherwise tests fail mid-tree).

## ARCHITECTURE.md updates

- **§A — Module map (lines ~2790-2810)**: replace the
  `App::Yath2::Log::DB::{Flavor}` + `App::Yath2::LogDB` entries with
  the new tree (Role::DB::Backend, App::Yath2::DB and subtree, the
  proxy). Note the `App::Yath2DB` rename.
- **§B — Log archive backends matrix (~line 2700)**: replace the
  `App::Yath2::Log::Sqlite` / `Postgres` etc. entries with
  `App::Yath2::Log::DB` (proxy) and document the `backend =>` selector.
- **§C — Schema files reference**: prose mentioning "Log::DB::Flavor
  uses share/schema/X.sql" updated to point at the new
  `App::Yath2::DB::Internal::Flavor` (and `::DBIC`) consumers. Note
  that `share/schema/*.sql` is canonical for both backends — DBIC's
  `deploy()` is never used.
- **§D — New section: "DB backend selection"**: ~150 words covering
  the two backends, the role they share, when to pick each, that
  bootstrap is always SQL-file-driven.
- **§E — `*_uuid_string` shadow column note**: brief note that
  triggers populate the column on MySQL and DBIC does not model it.

**AI_DOC**: `AI_DOCS/2026-05-08-yath-db-namespace.md` describing
trigger, decisions, alternatives considered, and migration scope.

## Open questions / follow-ups

None blocking. Possible future work outside this PR:

- DBIC backend used by an external `App::Yath2::UI` consumer that wants
  ResultSet-shaped access. Out of scope here; this PR makes it
  possible.
- `App::Yath2::DB::Internal` could grow a small flavor-trait helper if
  the per-flavor subclasses end up duplicating boilerplate. Defer
  until the duplication is real.
- `mysql_shadow_invisible.t` (asserting DBIC writes only the binary
  column on MySQL) is out of scope — current MySQL integration tests
  already round-trip UUID-keyed reads, so trigger correctness is
  covered indirectly.

## Approval

Design reviewed and approved by user across 9 sections (architecture,
role contents, proxy, factory, Internal, DBIC, tests, migration,
ARCHITECTURE updates) before this spec was written.
