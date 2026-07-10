# frozen_string_literal: true

require 'active_record/connection_adapters/postgresql_adapter'

module ActiveRecord
  module ConnectionHandling # :nodoc:
    def redshift_adapter_class
      ConnectionAdapters::RedshiftAdapter
    end

    # Establishes a connection to the database that's used by all Active Record objects
    def redshift_connection(config)
      redshift_adapter_class.new(config)
    end
  end

  module ConnectionAdapters
    module Redshift
      module ColumnMethods
        # Redshift has no +pgcrypto+/+gen_random_uuid()+; UUID primary keys need the
        # (older) +uuid-ossp+ extension's +uuid_generate_v4()+ instead.
        def primary_key(name, type = :primary_key, **options)
          return super unless type == :uuid

          options[:default] = options.fetch(:default, 'uuid_generate_v4()')
          options[:primary_key] = true
          column name, type, options
        end

        def json(name, **options)
          column(name, :json, options)
        end

        def jsonb(name, **options)
          column(name, :jsonb, options)
        end
      end

      class TableDefinition < PostgreSQL::TableDefinition
        include ColumnMethods
      end

      class Table < PostgreSQL::Table
        include ColumnMethods
      end
    end

    # Amazon Redshift speaks a PostgreSQL wire protocol descended from PostgreSQL
    # 8.0.2. This adapter subclasses PostgreSQLAdapter so it automatically tracks
    # whatever version of Rails' own Postgres support is loaded, and overrides
    # only where Redshift's SQL dialect and system catalog genuinely diverge from
    # modern PostgreSQL.
    class RedshiftAdapter < PostgreSQLAdapter
      ADAPTER_NAME = 'Redshift'

      # Deliberately independent from PostgreSQLAdapter::NATIVE_DATABASE_TYPES:
      # only the types Redshift actually supports natively. A migration using an
      # unlisted type (hstore, inet, cidr, ...) falls back to the type name as
      # literal SQL and fails against Redshift with a clear error, rather than
      # silently succeeding on syntax Redshift can't create.
      NATIVE_DATABASE_TYPES = {
        primary_key: 'integer identity primary key',
        string: { name: 'varchar' },
        text: { name: 'varchar' },
        integer: { name: 'integer' },
        float: { name: 'decimal' },
        decimal: { name: 'decimal' },
        datetime: { name: 'timestamp' },
        time: { name: 'timestamp' },
        date: { name: 'date' },
        bigint: { name: 'bigint' },
        boolean: { name: 'boolean' }
      }.freeze

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

      RS_VALID_CONN_PARAMS = %i[host hostaddr port dbname user password connect_timeout
                                 client_encoding options application_name fallback_application_name
                                 keepalives keepalives_idle keepalives_interval keepalives_count
                                 tty sslmode requiressl sslcompression sslcert sslkey
                                 sslrootcert sslcrl requirepeer krbsrvname gsslib service].freeze

      def initialize(...)
        super
        # Forward only parameters PG::Connection actually understands -- @config may
        # carry other ActiveRecord-level keys (e.g. :variables, :statement_limit).
        @connection_parameters = @connection_parameters.slice(*RS_VALID_CONN_PARAMS)
      end

      # --- Capability flags carried forward unchanged from the production-tested
      # redshift_7_0/7_1/7_2/8_0 forks (all four versions agreed on these). ---
      def supports_index_sort_order? = false
      def supports_partial_index? = false
      def supports_transaction_isolation? = false
      def supports_deferrable_constraints? = false
      def supports_virtual_columns? = false
      def supports_extensions? = false
      def supports_ranges? = false
      def supports_materialized_views? = false

      # --- Capability flags new in Rails 8.x with no prior-fork precedent.
      # Defaulted conservatively to false: an unsupported feature Rails skips is
      # safer than an adapter emitting SQL Redshift's parser rejects. None of these
      # have been verified against a real Redshift cluster -- confirm before
      # flipping any of them to true. ---
      def supports_check_constraints? = false
      def supports_exclusion_constraints? = false
      def supports_unique_constraints? = false
      def supports_validate_constraints? = false
      def supports_comments? = false
      def supports_savepoints? = false
      def supports_insert_on_conflict? = false
      alias supports_insert_on_duplicate_skip? supports_insert_on_conflict?
      alias supports_insert_on_duplicate_update? supports_insert_on_conflict?
      alias supports_insert_conflict_target? supports_insert_on_conflict?
      def supports_insert_returning? = false
      def supports_nulls_not_distinct? = false
      def supports_native_partitioning? = false
      def supports_identity_columns? = false
      def supports_advisory_locks? = false
      def supports_foreign_tables? = false
      def supports_pgcrypto_uuid? = false
      def supports_optimizer_hints? = false
      def supports_bulk_alter? = false
      def supports_partitioned_indexes? = false
      def supports_index_include? = false
      def supports_expression_index? = false
      def supports_datetime_with_precision? = false
      def supports_restart_db_transaction? = false
      def supports_close_prepared? = false

      def use_insert_returning?
        false
      end

      # Redshift never enforces FK/uniqueness triggers, so there is nothing to
      # actually disable -- this just satisfies callers (e.g. fixture loading)
      # that expect the hook to exist.
      def supports_disable_referential_integrity?
        true
      end

      def disable_referential_integrity
        yield
      end

      def enable_extension(*)
        nil
      end

      def disable_extension(*)
        nil
      end

      def extension_enabled?(*)
        false
      end

      # Redshift has no user-managed indexes -- sort/dist keys replace them.
      def indexes(*)
        []
      end

      def index_name_exists?(*)
        false
      end

      def add_index(*, **)
        nil
      end

      def remove_index!(*, **)
        nil
      end

      def rename_index(*, **)
        nil
      end

      def truncate(table_name, name = nil)
        exec_query "TRUNCATE TABLE #{quote_table_name(table_name)}", name, []
      end

      def reset!
        @lock.synchronize do
          return connect! unless @raw_connection

          unless @raw_connection.transaction_status == ::PG::PQTRANS_IDLE
            @raw_connection.query 'ROLLBACK'
          end

          # NOTE: PostgreSQLAdapter#reset! also runs "DISCARD ALL" here. Redshift's
          # SQL dialect (based on PostgreSQL 8.0.2) has no DISCARD statement, so we
          # replicate AbstractAdapter#reset! directly instead of calling super
          # (which would reach PostgreSQLAdapter's version).
          attempt_configure_connection do
            clear_cache!(new_connection: true)
            reset_transaction
            configure_connection
          end
        end
      end

      private

      def create_table_definition(name, **options)
        Redshift::TableDefinition.new(self, name, **options)
      end

      def update_table_definition(table_name, base)
        Redshift::Table.new(table_name, base)
      end

      # Redshift's pg_attribute/pg_type catalog predates collation, column
      # comments, identity columns, and generated columns. Querying those (as
      # PostgreSQLAdapter#column_definitions does) fails against Redshift's
      # catalog, so this keeps the narrower, catalog-compatible query. The
      # inherited new_column_from_field tolerates the shorter row (the
      # unqueried fields -- collation, comment, identity, generated --
      # destructure to nil).
      def column_definitions(table_name)
        query(<<~SQL, 'SCHEMA')
          SELECT a.attname, format_type(a.atttypid, a.atttypmod),
                 pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod
            FROM pg_attribute a LEFT JOIN pg_attrdef d
              ON a.attrelid = d.adrelid AND a.attnum = d.adnum
           WHERE a.attrelid = #{quote(quote_table_name(table_name))}::regclass
             AND a.attnum > 0 AND NOT a.attisdropped
           ORDER BY a.attnum
        SQL
      end
    end
  end
end
