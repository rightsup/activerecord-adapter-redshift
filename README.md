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

License
---------

MIT license (same as ActiveRecord)
