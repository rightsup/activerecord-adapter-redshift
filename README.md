activerecord-redshift-adapter
==============================

Amazon Redshift adapter for ActiveRecord.
This is a fork from https://rubygems.org/gems/activerecord7-redshift-adapter hosted on a private Gitlab instance.
It's itself forked the project from https://github.com/kwent/activerecord6-redshift-adapter

Thanks to the authors.

The adapter picks its implementation at load time based on the running ActiveRecord
version (see `lib/active_record/connection_adapters/redshift_adapter.rb`). Support for
new ActiveRecord versions is added as its own namespace alongside the existing ones,
so the adapter keeps working across ActiveRecord upgrades rather than being tied to
one major version.

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
