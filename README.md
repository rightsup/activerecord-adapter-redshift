activerecord-redshift-adapter
==============================

Amazon Redshift adapter for ActiveRecord.
This is a fork from https://rubygems.org/gems/activerecord7-redshift-adapter hosted on a private Gitlab instance.
It's itself forked the project from https://github.com/kwent/activerecord6-redshift-adapter

Thanks to the authors.

Requires ActiveRecord 8.0 or newer. The adapter subclasses
`ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` directly (see
`lib/active_record/connection_adapters/redshift_adapter.rb`), so it tracks whatever
Postgres adapter behavior the installed Rails version provides and only overrides the
places where Redshift's SQL dialect and system catalog genuinely diverge. Rails 7.x is
not supported here; for Rails 7 use the `activerecord7-redshift-adapter-pennylane` gem
(or this repository's history before the Rails 8 rewrite, commit `90a76e4`).

Usage
-------------------

Write the following in your Gemfile:

```ruby
gem 'activerecord-redshift-adapter'
```

In database.yml

```YAML
development:
  adapter: redshift
  host: host
  port: port
  database: db
  username: user
  password: password
  encoding: utf8
```

OR your can use in URL
```ruby
class SomeModel < ApplicationRecord
  establish_connection('redshift://username:password@host/database')
end
```

Supported surface
-------------------

Checked against a real Redshift cluster: connecting (session setup and type map),
discovering tables, and loading a model's schema (columns and primary key).
`insert_all!` and single-row `save` on tables that declare **no** primary key send
plain `INSERT` statements (traced on PostgreSQL), and ordinary reads are plain
ActiveRecord SQL.

Inherited from the PostgreSQL adapter but **not** verified on Redshift, and not
reached by read-mostly reporting apps: foreign keys, unique and check constraints,
table comments/options, `encoding`/`collation`, sequences (so a single-row insert
into a table that *does* declare a primary key), schema dumps, and migrations beyond
the basic DDL covered by `script/verify_redshift_capabilities.rb`. Treat these as
unsupported until a check says otherwise.
[MAINTENANCE.md](MAINTENANCE.md#supported-surface) has the full table, with dates
and evidence.

Testing against a real app
-------------------

To try a branch/local checkout of this gem in an actual Rails app (or a plain
Ruby script) before releasing it, point your `Gemfile` at it instead of the
published gem:

```ruby
# path to a local checkout:
gem 'activerecord-redshift-adapter', path: '/path/to/activerecord-adapter-redshift'
# or a branch on this repo:
gem 'activerecord-redshift-adapter', git: 'https://github.com/rightsup/activerecord-adapter-redshift', branch: 'your-branch'
```

Then `bundle install`, configure `config/database.yml` (or
`establish_connection`) with `adapter: redshift` and real credentials, and
run what you'd normally run: `rails db:migrate`, `rails console`, your test
suite. For a plain Ruby script (no Rails), see
`script/verify_postgres_plumbing.rb` for a minimal `require 'active_record'`
+ `establish_connection` example.

If what you're testing is *this adapter's* correctness rather than your
app's, prefer the two scripts in [MAINTENANCE.md](MAINTENANCE.md) instead --
they're narrower, faster, and don't need a full app to run.

Maintenance
-------------------

See [MAINTENANCE.md](MAINTENANCE.md) for what to do when a new ActiveRecord
version, a new Redshift engine version, or a new `pg` gem version breaks
something -- includes a diagnostic procedure and three verification scripts
(`script/verify_postgres_plumbing.rb`, `script/verify_redshift_introspection.rb`,
`script/verify_redshift_capabilities.rb`). The first runs on a local PostgreSQL; the
other two need a real Redshift cluster, because PostgreSQL accepts SQL that Redshift
rejects.

License
---------

MIT license (same as ActiveRecord)
