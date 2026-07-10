activerecord-redshift-adapter
==============================

Amazon Redshift adapter for ActiveRecord.
This is a fork from https://rubygems.org/gems/activerecord7-redshift-adapter hosted on a private Gitlab instance.
It's itself forked the project from https://github.com/kwent/activerecord6-redshift-adapter

Thanks to the authors.

The adapter picks its implementation at load time based on the running ActiveRecord
version (see `lib/active_record/connection_adapters/redshift_adapter.rb`). Versions
7.0-7.2 each have their own namespace, forked from Rails' PostgreSQL adapter of that
era. Rails 8.0 and up are served by a single adapter that subclasses
`ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` directly, so it tracks whatever
Postgres adapter behavior the installed Rails version provides and only overrides the
places where Redshift's SQL dialect and system catalog genuinely diverge -- no new
namespace is needed as Rails 8.x continues to release.

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
something -- includes a diagnostic procedure and two verification scripts
(`script/verify_postgres_plumbing.rb`, `script/verify_redshift_capabilities.rb`).

License
---------

MIT license (same as ActiveRecord)
