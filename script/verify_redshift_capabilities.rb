# frozen_string_literal: true
#
# Checks the RedshiftAdapter capability flags (the `supports_*?` methods in
# redshift_adapter.rb) against a real Redshift cluster. Run this whenever
# there's a new Redshift engine version/patch -- see MAINTENANCE.md. Never
# prints REDSHIFT_URL or any connection detail, only pass/fail per check, so
# it's safe to paste the output back without leaking credentials.
#
# Usage:
#   export REDSHIFT_URL='redshift://user:password@host:port/database'
#   bundle exec ruby script/verify_redshift_capabilities.rb
#
# Use a scratch/throwaway schema on a least-privileged user if possible --
# this creates and drops a table named "redshift_adapter_verify_scratch".

require 'active_record'
require 'pg'
require 'active_record/connection_adapters/redshift_adapter'

url = ENV.fetch('REDSHIFT_URL') { abort 'set REDSHIFT_URL first (see comment at top of this file)' }
ActiveRecord::Base.establish_connection(url)
conn = ActiveRecord::Base.connection
conn.connect!

TABLE = 'redshift_adapter_verify_scratch'
results = []

check = lambda do |label, &block|
  block.call
  results << [label, :pass, nil]
rescue StandardError => e
  results << [label, :fail, "#{e.class}: #{e.message.lines.first&.strip}"]
end

conn.execute("DROP TABLE IF EXISTS #{TABLE}") rescue nil

check.call('identity primary key DDL (NATIVE_DATABASE_TYPES[:primary_key])') do
  conn.execute("CREATE TABLE #{TABLE} (id integer identity primary key, name varchar(50))")
end
conn.execute("DROP TABLE IF EXISTS #{TABLE}")
conn.execute("CREATE TABLE #{TABLE} (id integer, name varchar(50))") # plain table for the rest

check.call('savepoints / nested transactions (supports_savepoints?)') do
  conn.transaction do
    conn.transaction(requires_new: true) do
      conn.execute("INSERT INTO #{TABLE} (id, name) VALUES (1, 'a')")
    end
  end
end

check.call('CHECK constraint (supports_check_constraints?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD CONSTRAINT chk_name CHECK (name IS NOT NULL)")
end

check.call('UNIQUE constraint (supports_unique_constraints?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD CONSTRAINT uniq_id UNIQUE (id)")
end

check.call('ON CONFLICT / upsert (supports_insert_on_conflict?, requires the UNIQUE constraint above)') do
  conn.execute("INSERT INTO #{TABLE} (id, name) VALUES (1, 'x') ON CONFLICT (id) DO NOTHING")
end

check.call('COMMENT ON (supports_comments?)') do
  conn.execute("COMMENT ON TABLE #{TABLE} IS 'test comment'")
end

check.call('advisory locks (supports_advisory_locks?)') do
  conn.execute('SELECT pg_advisory_lock(123456)')
  conn.execute('SELECT pg_advisory_unlock(123456)')
end

check.call('bulk ALTER (multiple clauses in one statement) (supports_bulk_alter?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD COLUMN a integer, ADD COLUMN b integer")
end

check.call('uuid_generate_v4() (uuid-ossp extension)') do
  conn.select_value('SELECT uuid_generate_v4()')
end

check.call('gen_random_uuid() (built-in, no extension)') do
  conn.select_value('SELECT gen_random_uuid()')
end

check.call('IDENTITY(seed, step) explicit-argument form') do
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_identity2")
  conn.execute("CREATE TABLE #{TABLE}_identity2 (id integer identity(1,1) primary key)")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_identity2")
end

check.call('timestamp column precision, e.g. timestamp(3) (supports_datetime_with_precision?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD COLUMN t timestamp(3)")
end

check.call('EXCLUDE constraint (supports_exclusion_constraints?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD CONSTRAINT excl_id EXCLUDE (id WITH =)")
end

check.call('VALIDATE CONSTRAINT (supports_validate_constraints?)') do
  # Uses a NOT VALID foreign key on dedicated, empty tables -- not a NOT VALID
  # check constraint (Redshift doesn't support CHECK at all, which would
  # confound this check), and not the shared TABLE (which may already hold
  # rows from other checks that wouldn't satisfy a freshly-added FK).
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_fkchild")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_fkparent")
  conn.execute("CREATE TABLE #{TABLE}_fkparent (id integer PRIMARY KEY)")
  conn.execute("CREATE TABLE #{TABLE}_fkchild (id integer)")
  conn.execute("ALTER TABLE #{TABLE}_fkchild ADD CONSTRAINT fk_ref FOREIGN KEY (id) REFERENCES #{TABLE}_fkparent (id) NOT VALID")
  conn.execute("ALTER TABLE #{TABLE}_fkchild VALIDATE CONSTRAINT fk_ref")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_fkchild")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_fkparent")
end

check.call('multi-table TRUNCATE, e.g. "TRUNCATE TABLE a, b" (build_truncate_statements -- what fixture loading / truncate_tables actually sends, not overridden by RedshiftAdapter)') do
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_trunc2")
  conn.execute("CREATE TABLE #{TABLE}_trunc2 (id integer)")
  conn.execute("TRUNCATE TABLE #{TABLE}, #{TABLE}_trunc2")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_trunc2")
end

check.call('INSERT ... RETURNING (supports_insert_returning?)') do
  conn.execute("INSERT INTO #{TABLE} (id, name) VALUES (999, 'ret') RETURNING id")
  conn.execute("DELETE FROM #{TABLE} WHERE id = 999")
end

check.call('UNIQUE NULLS NOT DISTINCT (supports_nulls_not_distinct?)') do
  conn.execute("ALTER TABLE #{TABLE} ADD CONSTRAINT uniq_name UNIQUE NULLS NOT DISTINCT (name)")
end

check.call('native declarative partitioning, PARTITION BY (supports_native_partitioning?)') do
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_part")
  conn.execute("CREATE TABLE #{TABLE}_part (id integer, name varchar(50)) PARTITION BY RANGE (id)")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_part")
end

check.call('standard GENERATED ALWAYS AS IDENTITY syntax (supports_identity_columns?)') do
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_identity3")
  conn.execute("CREATE TABLE #{TABLE}_identity3 (id integer GENERATED ALWAYS AS IDENTITY)")
  conn.execute("DROP TABLE IF EXISTS #{TABLE}_identity3")
end

check.call('pgcrypto extension availability (supports_pgcrypto_uuid?)') do
  conn.execute('CREATE EXTENSION IF NOT EXISTS pgcrypto')
end

version_info = begin
  conn.select_value('SELECT version()')
rescue StandardError => e
  "ERROR: #{e.class}: #{e.message.lines.first&.strip}"
end

conn.execute("DROP TABLE IF EXISTS #{TABLE}") rescue nil

puts "== Redshift capability verification =="
puts "SELECT version(): #{version_info}"
puts
results.each do |label, status, detail|
  line = "[#{status == :pass ? 'PASS' : 'FAIL'}] #{label}"
  line += " -- #{detail}" if detail
  puts line
end
