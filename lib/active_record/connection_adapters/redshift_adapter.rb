# frozen_string_literal: true

require 'pg'

require_relative "../tasks/redshift_tasks"

if ActiveRecord.version >= Gem::Version.new('8.0.0')
  require_relative 'redshift_8_0_adapter'
elsif ActiveRecord.version >= Gem::Version.new('7.2.0')
  require_relative 'redshift_7_2_adapter'
elsif ActiveRecord.version >= Gem::Version.new('7.1.0')
  require_relative 'redshift_7_1_adapter'
elsif ActiveRecord.version >= Gem::Version.new('7.0.0')
  require_relative 'redshift_7_0_adapter'
else
  raise 'no compatible version of ActiveRecord detected'
end

# Rails resolves adapter: "redshift" in database.yml through this registry
# (introduced after our original 7.0 target); older versions dispatch to
# ConnectionHandling#redshift_connection directly and don't need it.
if ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register(
    'redshift',
    'ActiveRecord::ConnectionAdapters::RedshiftAdapter',
    'active_record/connection_adapters/redshift_adapter'
  )
end
