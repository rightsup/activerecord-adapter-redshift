# frozen_string_literal: true
#
# Verifies the adapter's inherited query-execution plumbing (connect,
# transactions, schema introspection, quoting, explain, task-class
# resolution) against a real PostgreSQL instance under a specific
# ActiveRecord version. This is NOT a Redshift capability check -- see
# script/verify_redshift_capabilities.rb for that. Run this one first, for
# every ActiveRecord version this gem claims to support, whenever
# ActiveRecord is bumped. See MAINTENANCE.md.
#
# Usage:
#   PG_HOST=localhost PG_PORT=5432 PG_USER=postgres PG_PASSWORD=postgres \
#     ruby script/verify_postgres_plumbing.rb 8.1.3
#
# Requires a reachable, disposable PostgreSQL database named
# PG_DATABASE (default: redshift_adapter_plumbing_test) that this script
# creates/drops tables in. Point it at a scratch database, not anything
# containing real data.

ar_version = ARGV[0] or abort 'usage: verify_postgres_plumbing.rb <activerecord-version>'

gem 'activerecord', ar_version
gem 'pg'
require 'active_record'
require 'pg'

puts "== ActiveRecord #{ActiveRecord.version} (requested #{ar_version}) =="

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'active_record/connection_adapters/redshift_adapter'

puts '-- override-drift guard (RedshiftAdapter overrides still exist upstream)'
# RedshiftAdapter overrides these PostgreSQLAdapter/AbstractAdapter methods --
# most are private/semi-private Rails internals with no stability guarantee
# (e.g. reconfigure_connection_timezone was already restructured away on
# Rails main as of this writing). If a future Rails version renames or
# removes one, the override silently becomes dead code -- inherited Postgres
# behavior "returns" unnoticed instead of raising -- rather than a loud
# failure. This is a static reflection check, no database required. See
# MAINTENANCE.md.
OVERRIDDEN_METHODS = %i[
  check_version client_min_messages= set_standard_conforming_strings
  configure_connection reconfigure_connection_timezone load_types_queries
  truncate reset! create_table_definition update_table_definition
  column_definitions primary_keys
].freeze
pg_adapter_class = ActiveRecord::ConnectionAdapters::RedshiftAdapter.superclass
missing_overrides = OVERRIDDEN_METHODS.reject do |name|
  pg_adapter_class.method_defined?(name) ||
    pg_adapter_class.private_method_defined?(name) ||
    pg_adapter_class.protected_method_defined?(name)
end
if missing_overrides.any?
  raise "#{pg_adapter_class} no longer defines: #{missing_overrides.join(', ')} -- " \
        're-check the corresponding RedshiftAdapter override against upstream source (see MAINTENANCE.md)'
end

ActiveRecord::Base.establish_connection(
  adapter: 'redshift',
  host: ENV.fetch('PG_HOST', 'localhost'),
  port: ENV.fetch('PG_PORT', 5432).to_i,
  username: ENV.fetch('PG_USER', 'postgres'),
  password: ENV.fetch('PG_PASSWORD', 'postgres'),
  database: ENV.fetch('PG_DATABASE', 'redshift_adapter_plumbing_test')
)

conn = ActiveRecord::Base.connection
puts "adapter class: #{conn.class}"
puts "adapter_name: #{conn.adapter_name}"

step = ->(label) { puts "-- #{label}" }

step.call('connect!')
conn.connect!

step.call('active?')
raise 'not active' unless conn.active?

step.call('execute SELECT 1')
raise 'bad result' unless conn.select_value('SELECT 1') == 1

step.call('drop/create table via migration DSL')
# id: false -- Redshift's NATIVE_DATABASE_TYPES[:primary_key] ("integer identity
# primary key") is real Redshift-only DDL syntax that plain Postgres correctly
# rejects; that's a documented, Redshift-specific delta, not plumbing under test.
conn.drop_table('widgets', if_exists: true)
conn.create_table(:widgets, id: false) do |t|
  t.integer :id
  t.string :name
  t.integer :quantity
  t.decimal :price
  t.timestamps
end

step.call('columns (schema introspection)')
cols = conn.columns(:widgets)
puts cols.map { |c| "#{c.name}:#{c.sql_type}" }.join(', ')
raise 'missing columns' unless cols.map(&:name).sort == %w[created_at id name price quantity updated_at].sort

step.call('insert + read back')
conn.execute("INSERT INTO widgets (name, quantity, price, created_at, updated_at) VALUES ('foo', 3, 9.99, now(), now())")
row = conn.select_one('SELECT * FROM widgets LIMIT 1')
raise 'insert/read failed' unless row['name'] == 'foo'

step.call('transaction (begin/commit)')
conn.transaction do
  conn.execute("INSERT INTO widgets (name, quantity, price, created_at, updated_at) VALUES ('bar', 1, 1.00, now(), now())")
end
raise 'transaction insert failed' unless conn.select_value('SELECT count(*) FROM widgets') == 2

step.call('transaction (rollback)')
begin
  conn.transaction do
    conn.execute("INSERT INTO widgets (name, quantity, price, created_at, updated_at) VALUES ('baz', 1, 1.00, now(), now())")
    raise ActiveRecord::Rollback
  end
rescue ActiveRecord::Rollback
  nil
end
raise 'rollback did not roll back' unless conn.select_value('SELECT count(*) FROM widgets') == 2

step.call('truncate (singular, RedshiftAdapter#truncate override)')
conn.truncate('widgets')
raise 'truncate did not empty the table' unless conn.select_value('SELECT count(*) FROM widgets') == 0
conn.execute("INSERT INTO widgets (name, quantity, price, created_at, updated_at) VALUES ('foo', 3, 9.99, now(), now())")

step.call('truncate_tables (plural -- not overridden by RedshiftAdapter; this is what fixture loading and test-DB cleanup actually call)')
conn.drop_table('gadgets', if_exists: true)
conn.create_table(:gadgets, id: false) { |t| t.integer :id }
conn.truncate_tables('widgets', 'gadgets')
raise 'truncate_tables did not empty widgets' unless conn.select_value('SELECT count(*) FROM widgets') == 0
conn.drop_table('gadgets', if_exists: true)

step.call('change_column_default')
conn.change_column_default(:widgets, :quantity, 0)

step.call('change_column_null with default backfill')
conn.change_column_null(:widgets, :quantity, false, 0)

step.call('table_exists? / data_source_exists? / schema_exists?')
raise 'table_exists? wrong' unless conn.table_exists?('widgets')
raise 'data_source_exists? wrong' unless conn.data_source_exists?('widgets')
raise 'schema_exists? wrong' unless conn.schema_exists?('public')

step.call('primary_keys (RedshiftAdapter#primary_keys override: none / single / composite)')
# Postgres accepts upstream's query too, so a passing result below can't prove
# the override is what runs -- assert that directly (Redshift rejects upstream's).
unless conn.method(:primary_keys).owner == ActiveRecord::ConnectionAdapters::RedshiftAdapter
  raise 'primary_keys is no longer overridden by RedshiftAdapter -- upstream query fails on Redshift (see MAINTENANCE.md)'
end
conn.drop_table('pk_none', if_exists: true)
conn.drop_table('pk_single', if_exists: true)
conn.drop_table('pk_composite', if_exists: true)
conn.create_table(:pk_none, id: false) { |t| t.integer :a }
conn.create_table(:pk_single, id: false) { |t| t.integer :id, null: false }
conn.execute('ALTER TABLE pk_single ADD PRIMARY KEY (id)')
conn.create_table(:pk_composite, id: false) { |t| t.integer :a, null: false; t.integer :b, null: false }
conn.execute('ALTER TABLE pk_composite ADD PRIMARY KEY (a, b)')
raise "primary_keys(none) = #{conn.primary_keys('pk_none').inspect}" unless conn.primary_keys('pk_none') == []
raise "primary_keys(single) = #{conn.primary_keys('pk_single').inspect}" unless conn.primary_keys('pk_single') == ['id']
raise "primary_keys(composite) = #{conn.primary_keys('pk_composite').inspect}" unless conn.primary_keys('pk_composite') == %w[a b]
conn.drop_table('pk_none')
conn.drop_table('pk_single')
conn.drop_table('pk_composite')

step.call('serial_sequence (no stdout spam expected)')
conn.serial_sequence('widgets', 'id')

step.call('reset!')
conn.reset!
raise 'reset! broke the connection' unless conn.active?

step.call('disconnect! / reconnect')
conn.disconnect!
conn.reconnect!
raise 'reconnect broke the connection' unless conn.active?

step.call('explain')
puts Widget = Class.new(ActiveRecord::Base) { self.table_name = 'widgets' }.all.explain.inspect

step.call('rake-task class resolution (RedshiftDatabaseTasks)')
db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
  'test', 'primary', { 'adapter' => 'redshift', 'database' => ENV.fetch('PG_DATABASE', 'redshift_adapter_plumbing_test') }
)
tasks_class = ActiveRecord::Tasks::DatabaseTasks.send(:class_for_adapter, 'redshift')
tasks = tasks_class.new(db_config)
puts "tasks class: #{tasks.class} (ancestors: #{tasks.class.ancestors.take(4)})"
if ActiveRecord.version >= Gem::Version.new('8.1.0')
  raise 'missing check_current_protected_environment!' unless tasks.respond_to?(:check_current_protected_environment!, true)
else
  puts '(check_current_protected_environment! not required on this Rails version)'
end

conn.drop_table('widgets', if_exists: true)

puts "== ALL CHECKS PASSED for #{ActiveRecord.version} =="
