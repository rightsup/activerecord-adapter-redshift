# Maintenance guide

This gem's Rails 8.x adapter (`lib/active_record/connection_adapters/redshift_adapter.rb`)
is `RedshiftAdapter < ActiveRecord::ConnectionAdapters::PostgreSQLAdapter`. It
inherits everything and overrides only the specific methods where Redshift's
SQL dialect, system catalog, or session-parameter support genuinely diverge
from PostgreSQL. That means most upstream changes -- a new ActiveRecord
version, a new `pg` gem version -- need **zero code changes here**. This
document exists for the times they don't.

There are three independent moving parts. Something can break because any one
of them changed:

| Changed | Detect with | Section |
|---|---|---|
| ActiveRecord / Rails version | `script/verify_postgres_plumbing.rb` | [A](#a-new-activerecord-rails-version) |
| Redshift engine version/patch | `script/verify_redshift_capabilities.rb` | [B](#b-new-redshift-engine-versionpatch) |
| `pg` gem version | `script/verify_postgres_plumbing.rb` with the new `pg` version pinned | [C](#c-new-pg-gem-version) |

Both scripts are self-contained, take the version to test as a parameter (or
via `Gemfile`/`REDSHIFT_URL`), and never assume today's specific version
numbers -- they'll keep working after this document is stale.

## The general diagnostic algorithm

Use this regardless of which of the three changed. It's the actual reusable
skill; the version-specific facts below will go stale, this won't.

1. **Run the relevant script.** Read the full backtrace top to bottom if it fails.
2. **Classify the error:**
   - `NoMethodError` / `ArgumentError` (wrong arity, missing method) → an API-level change in ActiveRecord or `pg`. Go to [A](#a-new-activerecord-rails-version) or [C](#c-new-pg-gem-version).
   - `ActiveRecord::StatementInvalid` wrapping a `PG::*` error (syntax error, undefined function/table, feature not supported, permission denied) → a SQL-dialect or catalog difference, almost always Redshift-specific. Go to [B](#b-new-redshift-engine-versionpatch).
3. **Find the exact method from the backtrace** -- the outermost frame still inside the `activerecord-X.Y.Z` gem (not inside this repo, not inside `pg`). That's the Rails method that issued the failing call.
4. **Check whether `RedshiftAdapter` already overrides that method:**
   ```
   grep -n "def <method_name>" lib/active_record/connection_adapters/redshift_adapter.rb
   ```
   - **Already overridden:** the override itself is stale for the new version. Fetch the current real source (see below) and compare line-by-line against the override.
   - **Not overridden:** this is a new divergence. Decide the override shape (step 5).
5. **Decide: single-method override, or whole-method copy?**
   - If the failing call sits alone in its own small, separately-callable method upstream (e.g. `client_min_messages=`, `set_standard_conforming_strings`, `check_version` all fit this -- one line of real work each), override **just that method**. Prefer calling `super` and rescuing/adjusting over replacing the body outright.
   - If the failing call is inline inside a larger method's body with no method of its own (e.g. the `SET intervalstyle` line inside `configure_connection`, or the `pg_range` join inside `load_types_queries`), you cannot skip just that line via `super`. You must override the **whole enclosing method**.
     - Fetch the exact current source for that method (see "Fetching real Rails source" below). **Do not reproduce it from memory** -- a transcription slip here (a dropped line) caused a real, hard-to-spot bug in this exact file once already (a missing trailing `reload_type_map` call). Diff your override against the fetched source line-by-line before trusting it.
     - Change only what must change. Leave everything else identical to upstream, so the override stays easy to re-diff next time.
6. **Add a code comment on the new/changed override** following the existing style in the file: what upstream does, the exact error message you got, and why the override is correct. Future-you (or another agent) should be able to decide "is this still needed?" from the comment alone, without re-deriving it.
7. **Re-run the script until it passes.** Re-run the *other* script too if there's any chance the change interacts with it (e.g. a `configure_connection` change should be re-verified on both a real Postgres AND, when convenient, a real Redshift cluster).

### Fetching real Rails source

Never guess at what a Rails version's adapter code does -- fetch it:

```bash
gh api "repos/rails/rails/contents/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb?ref=<X-Y-stable>" --jq '.content' | base64 -d
```

Replace the path for other files (`connection_adapters/abstract_adapter.rb`,
`connection_adapters/abstract/database_statements.rb`,
`connection_adapters/postgresql/schema_statements.rb`,
`connection_adapters/postgresql/quoting.rb`,
`connection_adapters/postgresql/column.rb`,
`connection_adapters/column.rb`,
`connection_adapters/statement_pool.rb`,
`tasks/postgresql_database_tasks.rb`, `tasks/abstract_tasks.rb`,
`tasks/database_tasks.rb`) and `<X-Y-stable>` for the branch (e.g.
`8-1-stable`, `8-2-stable`). Fetch the *previous* supported version's source
the same way to diff what actually changed between them, rather than reading
one version in isolation.

## A. New ActiveRecord (Rails) version

1. Run the plumbing check against a disposable local PostgreSQL:
   ```bash
   PG_HOST=localhost PG_PORT=5432 PG_USER=postgres PG_PASSWORD=postgres \
     ruby script/verify_postgres_plumbing.rb <new-version>
   ```
   (e.g. `8.2.0`). This exercises connect, DDL, DML, transactions, schema
   introspection, `explain`, and rake-task class resolution -- the exact
   query-execution "plumbing" that has broken on version bumps before.
2. **Passes:** nothing to do. This is the point of subclassing
   `PostgreSQLAdapter` -- inherited behavior tracks upstream for free.
3. **Fails:** follow the [general diagnostic algorithm](#the-general-diagnostic-algorithm) above.
4. If you're intentionally raising the supported ceiling, update the
   `activerecord` constraint in `activerecord-redshift-adapter.gemspec`.
5. Only create a new `redshift_8_1`-style directory/namespace if a change is
   so fundamental it can't be expressed as an override on the same class (this
   has not happened yet as of Rails 8.1 -- inheritance absorbed the
   `Column#initialize` and `RedshiftDatabaseTasks`/`AbstractTasks` changes
   without one). If it ever does, the new namespace should still subclass
   `PostgreSQLAdapter`, with `lib/active_record/connection_adapters/redshift_adapter.rb`
   choosing between the two by `ActiveRecord.version`.

## B. New Redshift engine version/patch

1. Get a `REDSHIFT_URL` for the cluster (safest handling: export it in your
   own terminal, never paste it into an agent conversation -- see the comment
   at the top of the script).
2. Run:
   ```bash
   export REDSHIFT_URL='redshift://user:password@host:port/database'
   bundle exec ruby script/verify_redshift_capabilities.rb
   ```
3. **If it crashes before printing any `[PASS]`/`[FAIL]` lines**: that's a
   connection-setup failure, not a capability nuance -- something in
   inherited `configure_connection`/`reconfigure_connection_timezone`/
   `load_types_queries`/etc. sent SQL or a session parameter Redshift no
   longer (or newly doesn't) accept. Diagnose with the
   [general algorithm](#the-general-diagnostic-algorithm); the "Known
   connection-setup overrides" table below shows the shape these fixes take.
4. **If it completes**, compare each line against the
   ["Known Redshift SQL facts" table](#known-redshift-sql-facts) below:
   - A check that was `FAIL` is now `PASS` → Redshift gained the feature.
     Flip the corresponding `supports_*?` (or related override) from `false`
     to `true` in `redshift_adapter.rb`, and update the table.
   - A check that was `PASS` is now `FAIL` → don't assume Redshift regressed.
     First check whether the script's own SQL is what changed (e.g. a syntax
     Rails itself deprecated). If the SQL is still valid and Redshift
     genuinely rejects it now, flip the flag back to `false` and note why.
   - Want to check something not yet scripted? Add another
     `check.call('label') { conn.execute(...) }` block following the existing
     pattern -- each check is independent and swallows its own error.
5. Update the version-provenance comment at the top of the `RedshiftAdapter`
   class in `redshift_adapter.rb` with the new engine version/patch and
   date, and update the table below.

## C. New `pg` gem version

1. Pin the new version and re-run the plumbing check:
   ```bash
   cd script && bundle exec ruby -e "gem 'pg', '<new-version>'" verify_postgres_plumbing.rb <activerecord-version>
   ```
   or simplest: set it in a throwaway `Gemfile` (`gem 'pg', '<new-version>'`)
   and `bundle exec ruby script/verify_postgres_plumbing.rb <activerecord-version>`.
2. A `pg`-version-specific break shows up as a crash tracing into `pg`'s own
   C extension (not into this repo's Ruby code, not into ActiveRecord's Ruby
   code) -- typically a method PostgreSQLAdapter expects on
   `PG::Connection`/`PG::Result` that an older `pg` doesn't have, or a newer
   `pg` behaving differently. (Example already in the codebase: real Rails
   gates `supports_close_prepared?` behind
   `PG::Connection.method_defined?(:close_prepared)`, precisely because that
   method only exists in `pg >= 1.6.0`.)
3. The gemspec's `pg` constraint (`~> 1.0`) is intentionally broad. Only
   narrow it if you find a specific `pg` version this adapter genuinely
   requires -- and document why in a comment, same as any other override.

---

## Known connection-setup overrides

These required overriding an actual inherited method (not just a `supports_*?`
flag), because the failing call was either not gated by any flag, or was
inline inside a larger method with no override point of its own. Each is a
concrete example of the "whole-method override" case in step 5 of the
diagnostic algorithm above.

| Override | Why | Confirmed error |
|---|---|---|
| `check_version` | Real Rails rejects any server reporting < PostgreSQL 9.5. Redshift reports `80002` regardless of how current the service actually is. | `Your version of PostgreSQL (80002) is too old` |
| `client_min_messages=` | Ordinary (non-superuser) Redshift roles can't set this parameter. Purely diagnostic verbosity, safe to swallow. | `PG::InsufficientPrivilege: permission denied to set parameter "client_min_messages"` |
| `set_standard_conforming_strings` | Redshift doesn't have this GUC at all. `quote_string` (single-quote doubling) doesn't depend on it either way. | `PG::UndefinedObject: unrecognized configuration parameter "standard_conforming_strings"` |
| `configure_connection` (whole method) | Two problems in one inherited method: (1) `SET intervalstyle = iso_8601` -- Redshift recognizes the parameter but rejects the value; (2) `SET SESSION <key> TO <value>` for `:variables` -- Redshift's grammar rejects the `SESSION` keyword entirely. Neither line has its own override point. | `PG::InvalidParameterValue: unrecognized "intervalstyle" value: "iso_8601"`; `PG::InternalError: keyword SESSION not supported` |
| `reconfigure_connection_timezone` | Same `SET SESSION` grammar issue, this time for `timezone`. | `PG::InternalError: keyword SESSION not supported` |
| `load_types_queries` | Joins `pg_range`, a catalog table PostgreSQL added in 9.2 that Redshift's older catalog lacks. Not gated by `supports_ranges?` in current Rails. | `PG::UndefinedTable: relation "pg_range" does not exist` |

**Not supported, not needed:** `session_auth=` sends `SET SESSION AUTHORIZATION
<user>`. There, `SESSION` is part of the fixed clause name, not an optional
keyword that can be dropped, so Redshift's grammar likely rejects it. Normal
connection setup never calls it, and the only known consumer (eddy) never
impersonates a database user, so it is left as is. If a consumer ever needs
it, it needs a different mechanism.

## Known Redshift SQL facts

Verified against **Redshift Current track, engine 1.0.343555, patch 202**
(2026-07-10). This is a dated snapshot, not a permanent truth -- re-verify
with `script/verify_redshift_capabilities.rb` per [Section B](#b-new-redshift-engine-versionpatch)
whenever Redshift's version changes, and update this table.

| Capability | Status | `supports_*?` flag |
|---|---|---|
| `integer identity primary key` DDL | ✅ works | (n/a, `NATIVE_DATABASE_TYPES`) |
| Savepoints / nested transactions | ✅ works | `supports_savepoints?` → `true` |
| `ADD CONSTRAINT ... UNIQUE` | ✅ works | `supports_unique_constraints?` → `true` |
| `COMMENT ON TABLE`/`COLUMN` | ✅ works | `supports_comments?` → `true` |
| `IDENTITY(seed, step)` explicit form | ✅ works | (n/a) |
| `GENERATED ALWAYS AS IDENTITY` (standard SQL form) | ✅ works | `supports_identity_columns?` → `true` |
| `CREATE TABLE ... CHECK (...)` | ❌ `FeatureNotSupported` | `supports_check_constraints?` → `false` |
| `EXCLUDE` constraint | ❌ syntax error | `supports_exclusion_constraints?` → `false` |
| `ON CONFLICT` / upsert | ❌ syntax error | `supports_insert_on_conflict?` (+ aliases) → `false` |
| `INSERT ... RETURNING` | ❌ syntax error | `supports_insert_returning?` → `false` |
| `UNIQUE NULLS NOT DISTINCT` | ❌ syntax error | `supports_nulls_not_distinct?` → `false` |
| `PARTITION BY` (native partitioning) | ❌ syntax error | `supports_native_partitioning?` → `false` |
| `CREATE EXTENSION` (any extension, incl. pgcrypto) | ❌ syntax error -- the whole `CREATE EXTENSION` statement isn't in Redshift's grammar | `supports_pgcrypto_uuid?` → `false` |
| `pg_advisory_lock()` | ❌ `UndefinedFunction` | `supports_advisory_locks?` → `false` |
| Multiple `ADD COLUMN` clauses in one `ALTER TABLE` | ❌ syntax error | `supports_bulk_alter?` → `false` |
| `timestamp(N)` column precision | ❌ `FeatureNotSupported` | `supports_datetime_with_precision?` → `false` |
| `uuid_generate_v4()` | ❌ `UndefinedFunction` (needs uuid-ossp, and extensions aren't supported at all) | (n/a, UUID primary keys have no default -- see `Redshift::ColumnMethods#primary_key`) |
| `gen_random_uuid()` | ❌ `UndefinedFunction` (Postgres 13+ builtin, doesn't exist here) | (n/a, same as above) |
| `NOT VALID` / `VALIDATE CONSTRAINT` | ❌ syntax error -- confirmed on a `NOT VALID` *foreign key* (isolated from the CHECK-constraint confound below) | `supports_validate_constraints?` → `false` |

(First attempt at this check used a `NOT VALID` *check* constraint as setup,
which failed on its own -- check constraints aren't supported at all -- before
ever reaching `VALIDATE CONSTRAINT`, so that result didn't actually test this
flag. Re-run with a `NOT VALID` foreign key instead gave the clean answer
above: Redshift's grammar rejects `NOT VALID` itself, not just check
constraints. Left as an example of a confounded check in case a similar
pattern comes up again -- when a test depends on a second unverified feature,
isolate it before trusting a `FAIL`.)

**Not checked, and not reached by eddy** (the only known consumer runs read-only
reporting queries, with no DDL, hints, partitioning or index features; add a
`check.call` block if you need one verified): `supports_foreign_tables?`, `supports_optimizer_hints?`,
`supports_partitioned_indexes?`, `supports_index_include?`,
`supports_expression_index?` (Redshift has no user-managed indexes at all --
`indexes`/`add_index`/etc. are already hardcoded no-ops regardless of these
flags, so verifying them is low value), `supports_restart_db_transaction?`,
`supports_close_prepared?` (a `pg`-gem/libpq wire-protocol feature, not
practically checkable via SQL).

Every flag above defaults to `false` until *positively confirmed* `true`
against a real cluster -- if you see a flag `false` that isn't in either table
above, it simply hasn't been tested yet, not that it's known to fail.
