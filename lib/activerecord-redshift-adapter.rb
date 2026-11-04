# frozen_string_literal: true

require 'active_support/lazy_load_hooks'

# Registers adapter: "redshift". The adapter itself loads lazily, the first
# time a connection uses it. Works with and without Rails.
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters.register(
    'redshift',
    'ActiveRecord::ConnectionAdapters::RedshiftAdapter',
    'active_record/connection_adapters/redshift_adapter'
  )
end
