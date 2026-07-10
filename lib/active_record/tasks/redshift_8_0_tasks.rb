# frozen_string_literal: true

require 'active_record/tasks/postgresql_database_tasks'

module ActiveRecord
  module Tasks # :nodoc:
    # Subclasses PostgreSQLDatabaseTasks so it inherits pg_dump/psql-based
    # structure dump/load, create/drop, and (on Rails versions that define it)
    # AbstractTasks#check_current_protected_environment! automatically. The only
    # genuine Redshift difference is its default maintenance database name.
    class RedshiftDatabaseTasks < PostgreSQLDatabaseTasks # :nodoc:
      private

      def public_schema_config
        configuration_hash.merge(database: 'redshift', schema_search_path: 'public')
      end
    end

    DatabaseTasks.register_task(/redshift/, RedshiftDatabaseTasks)
  end
end
