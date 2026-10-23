# frozen_string_literal: true
#
# Exercises the inherited surface that read-mostly reporting apps actually
# reach, against a real Redshift cluster: connect, table discovery, first use
# of a model (primary_key, columns, reading a row), the connection lifecycle,
# and `primary_keys` on tables that do and don't declare keys.
#
# WHY THIS EXISTS: script/verify_postgres_plumbing.rb runs on PostgreSQL, and
# PostgreSQL happily accepts catalog SQL that Redshift rejects. ActiveRecord
# 8.x's PostgreSQL `primary_keys` was exactly that (`ANY(pg_index.indkey)` and
# `array_position` are both rejected by Redshift), and nothing on PostgreSQL
# could have caught it. Run this after every ActiveRecord bump -- see
# MAINTENANCE.md section A.
#
# Never prints REDSHIFT_URL or any connection detail, only pass/fail per
# check, so it's safe to paste the output back without leaking credentials.
#
# Usage:
#   export REDSHIFT_URL='redshift://user:password@host:port/database'
#   bundle exec ruby script/verify_redshift_introspection.rb [activerecord-version]
#
# Optional environment:
#   TABLES=a,b,c  Tables to probe (default: the first three from `tables`).
#   PRINT_SQL=1   Also print every distinct SCHEMA statement the adapter sent.
#                 This works against any server, including a local PostgreSQL:
#                 run it there with PRINT_SQL=1, then paste each statement into
#                 a cluster's SQL editor one at a time. That checks what
#                 Redshift accepts without a network path from your machine.
#
# Append `?prepared_statements=false` to REDSHIFT_URL to mirror an app that
# runs with ActiveRecord query-log tags enabled (Rails then disables prepared
# statements globally).
#
# Safe on real data: reads are limited to `LIMIT 1` / `LIMIT 3`. The one thing
# it writes is two scratch tables ("redshift_adapter_verify_pk_single" and
# "redshift_adapter_verify_pk_composite"), created and dropped here -- use a
# scratch schema on a least-privileged user if possible. Exits non-zero if any
# check fails.

if (ar_version = ARGV[0])
  gem 'activerecord', ar_version
end
require 'active_record'
require 'pg'
require 'uri'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'active_record/connection_adapters/redshift_adapter'

url = ENV.fetch('REDSHIFT_URL') { abort 'set REDSHIFT_URL first (see comment at top of this file)' }

schema_sql = []
if ENV['PRINT_SQL']
  ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
    schema_sql << payload[:sql].gsub(/\s+/, ' ').strip if payload[:name] == 'SCHEMA'
  end
end

PK_SINGLE = 'redshift_adapter_verify_pk_single'
PK_COMPOSITE = 'redshift_adapter_verify_pk_composite'

# Error messages from a failed connect can name the host or user; scrub the
# URL's host, user and password (4+ chars, so short names don't garble text)
# from anything we print.
secrets = begin
  uri = URI.parse(url)
  [uri.host, uri.user, uri.password].compact.flat_map { |s| [s, URI.decode_www_form_component(s)] }.uniq.select { |s| s.length >= 4 }
rescue StandardError
  []
end
scrub = ->(text) { secrets.reduce(text.to_s) { |memo, secret| memo.gsub(secret, '<redacted>') } }

results = []
check = lambda do |label, &block|
  results << [label, :pass, block.call]
rescue StandardError => e
  results << [label, :fail, scrub.call("#{e.class}: #{e.message.lines.first&.strip}")]
end

report = lambda do |version_info|
  puts '== Redshift introspection verification =='
  puts "SELECT version(): #{version_info}" if version_info
  puts "ActiveRecord #{ActiveRecord.version}"
  puts
  results.each do |label, status, detail|
    line = "[#{status == :pass ? 'PASS' : 'FAIL'}] #{label}"
    line += " -- #{detail}" if detail
    puts line
  end
  if ENV['PRINT_SQL']
    puts
    puts '== Distinct SCHEMA statements sent (paste into a cluster SQL editor, one at a time) =='
    schema_sql.uniq.each { |sql| puts "#{sql};" }
  end
  exit(results.any? { |_, status, _| status == :fail } ? 1 : 0)
end

ActiveRecord::Base.establish_connection(url)
conn = nil
check.call('connect (configure_connection, session SETs, type map)') do
  candidate = ActiveRecord::Base.connection
  candidate.connect!
  conn = candidate # only set once connected, so a failure stops here instead of cascading
  "#{conn.class.name.split('::').last}, prepared_statements=#{conn.prepared_statements}"
end
report.call(nil) unless conn

version_info = begin
  conn.select_value('SELECT version()')
rescue StandardError => e
  scrub.call("ERROR: #{e.class}: #{e.message.lines.first&.strip}")
end

check.call('primary_keys is the RedshiftAdapter override (upstream SQL is rejected by Redshift)') do
  owner = conn.method(:primary_keys).owner
  raise "owned by #{owner}" unless owner == ActiveRecord::ConnectionAdapters::RedshiftAdapter

  nil
end

tables = ENV['TABLES']&.split(',')&.map(&:strip)&.reject(&:empty?)
check.call('table discovery (tables)') do
  found = conn.tables
  tables ||= found.first(3)
  "#{found.size} tables visible"
end
tables ||= []

check.call('table_alias_length (SHOW max_identifier_length)') { conn.table_alias_length.to_s }

tables.each do |table|
  exists = false
  check.call("#{table}: data_source_exists?") do
    exists = conn.data_source_exists?(table)
    raise 'not found in the current search path' unless exists

    nil
  end
  next unless exists

  check.call("#{table}: primary_keys") { conn.primary_keys(table).inspect }
  check.call("#{table}: columns") { "#{conn.columns(table).size} columns" }

  model = Class.new(ActiveRecord::Base) do
    self.table_name = table
    def self.name = 'VerifyProbe'
  end
  check.call("#{table}: model first use (primary_key, load_schema)") do
    "primary_key=#{model.primary_key.inspect}, #{model.column_names.size} columns"
  end
  check.call("#{table}: read one row (type decoding)") { "#{model.limit(1).to_a.size} row(s)" }
  check.call("#{table}: COUNT over LIMIT 3") { model.limit(3).count.to_s }
end

drop_scratch = lambda do
  [PK_SINGLE, PK_COMPOSITE].each do |table|
    conn.execute("DROP TABLE IF EXISTS #{table}")
  rescue StandardError
    nil
  end
end
drop_scratch.call

check.call('primary_keys returns a declared single key') do
  conn.execute("CREATE TABLE #{PK_SINGLE} (id integer NOT NULL, PRIMARY KEY (id))")
  keys = conn.primary_keys(PK_SINGLE)
  raise "got #{keys.inspect}, expected [\"id\"]" unless keys == ['id']

  keys.inspect
end
check.call('primary_keys returns a declared composite key (table column order)') do
  conn.execute("CREATE TABLE #{PK_COMPOSITE} (a integer NOT NULL, b integer NOT NULL, PRIMARY KEY (a, b))")
  keys = conn.primary_keys(PK_COMPOSITE)
  raise "got #{keys.inspect}, expected [\"a\", \"b\"]" unless keys == %w[a b]

  keys.inspect
end
drop_scratch.call

check.call('active?') do
  raise 'connection reports inactive' unless conn.active?

  nil
end
check.call('reconnect! then query') do
  conn.reconnect!
  conn.select_value('SELECT 1').to_s
end
check.call('reset! (no DISCARD ALL) then query') do
  conn.reset!
  conn.select_value('SELECT 1').to_s
end

report.call(version_info)
