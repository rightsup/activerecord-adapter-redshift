# frozen_string_literal: true

require 'pg'
require 'active_record'
require 'active_record/connection_adapters/postgresql_adapter'

if ActiveRecord.version < Gem::Version.new('8.0.0')
  raise "activerecord-redshift-adapter requires ActiveRecord 8.0 or newer (found #{ActiveRecord.version})"
end

require_relative '../tasks/redshift_tasks'

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
        # Confirmed against a real cluster: Redshift has neither
        # uuid_generate_v4() (would need the uuid-ossp extension, and
        # supports_extensions? is false -- Redshift doesn't support
        # extensions at all) nor gen_random_uuid() (a Postgres 13+ builtin).
        # There is no known database-side UUID default on Redshift, so unlike
        # Postgres, this doesn't supply one automatically -- callers must
        # pass an explicit :default or generate the value application-side
        # (e.g. a before_create callback using SecureRandom.uuid).
        def primary_key(name, type = :primary_key, **options)
          return super unless type == :uuid

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
    #
    # Overrides annotated "confirmed against a real cluster" were verified
    # against a Redshift cluster on the Current track, engine version
    # 1.0.343555, patch 202. Redshift is a continuously patched managed
    # service, so if its SQL surface changes, re-verify with
    # script/verify_redshift_capabilities.rb before trusting these findings on a
    # newer version.
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

      # PostgreSQLAdapter#check_version raises if database_version < 9.5, on the
      # assumption that a low reported version means a genuinely old, feature-poor
      # server. Redshift reports itself as PostgreSQL 8.0.2 (confirmed against a
      # real cluster) regardless of how current the actual service is, so that
      # assumption doesn't hold here; skip the check entirely.
      def check_version
        nil
      end

      # configure_connection unconditionally does `self.client_min_messages =
      # "warning"`. Confirmed against a real cluster: Redshift raises
      # PG::InsufficientPrivilege ("permission denied to set parameter
      # client_min_messages") for ordinary (non-superuser) roles, which would
      # otherwise abort every single connect. This is purely a diagnostic
      # verbosity setting, not something connection setup depends on, so
      # swallow the failure instead of leaving the connection unusable.
      def client_min_messages=(level)
        super
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # configure_connection also unconditionally sends `SET
      # standard_conforming_strings = on`. Confirmed against a real cluster:
      # Redshift raises "unrecognized configuration parameter" -- it genuinely
      # doesn't have this GUC, not merely a permission restriction. The
      # production-tested 7.0/7.1/7.2/8.0 forks never sent this in the first
      # place, and quote_string (single-quote doubling) doesn't depend on it,
      # so skip it entirely rather than rescue an expected failure every connect.
      def set_standard_conforming_strings
        nil
      end

      # PostgreSQLAdapter#configure_connection unconditionally sends `SET
      # intervalstyle = iso_8601` (for ActiveSupport::Duration.parse-friendly
      # interval formatting) and, for any configured :variables, `SET SESSION
      # <key> TO <value>`. Confirmed against a real cluster: Redshift rejects
      # "iso_8601" as an intervalstyle value, and separately its SQL grammar
      # doesn't accept the optional SESSION keyword on SET at all ("keyword
      # SESSION not supported") -- plain `SET <key> TO <value>` is
      # semantically identical (SESSION is PostgreSQL's default SET scope
      # anyway) and Redshift accepts that form. Neither of these is behind its
      # own overridable method, so the only way to skip/adjust just these two
      # spots is to replicate the rest of PostgreSQLAdapter#configure_connection
      # here rather than calling super (which would hit both unconditionally).
      # Known limitation: native INTERVAL columns read back from Redshift will
      # be in its default format, not ISO 8601, so
      # ActiveSupport::Duration.parse may not handle them -- unconfirmed, since
      # this hasn't come up in real usage yet.
      def configure_connection
        check_version

        if @config[:encoding]
          @raw_connection.set_client_encoding(@config[:encoding])
        end
        self.client_min_messages = @config[:min_messages] || 'warning'
        self.schema_search_path = @config[:schema_search_path] || @config[:schema_order]

        unless ActiveRecord.db_warnings_action.nil?
          @raw_connection.set_notice_receiver do |result|
            message = result.error_field(PG::Result::PG_DIAG_MESSAGE_PRIMARY)
            code = result.error_field(PG::Result::PG_DIAG_SQLSTATE)
            level = result.error_field(PG::Result::PG_DIAG_SEVERITY)
            @notice_receiver_sql_warnings << SQLWarning.new(message, code, level, nil, @pool)
          end
        end

        set_standard_conforming_strings

        variables = @config.fetch(:variables, {}).stringify_keys

        variables.map do |k, v|
          if v == ':default' || v == :default
            internal_execute("SET #{k} TO DEFAULT", 'SCHEMA')
          elsif !v.nil?
            internal_execute("SET #{k} TO #{quote(v)}", 'SCHEMA')
          end
        end

        add_pg_encoders
        add_pg_decoders

        schema_search_path # populate cache

        reload_type_map
      end

      # See the configure_connection override above: Redshift's SQL grammar
      # doesn't accept the SESSION keyword on SET, which
      # PostgreSQLAdapter#reconfigure_connection_timezone uses unconditionally.
      def reconfigure_connection_timezone
        variables = @config.fetch(:variables, {}).stringify_keys
        return if variables['timezone']

        if default_timezone == :utc
          raw_execute("SET timezone TO 'UTC'", 'SCHEMA')
        else
          raw_execute("SET timezone TO DEFAULT", 'SCHEMA')
        end
      end

      # PostgreSQLAdapter#load_types_queries (used to populate the type map on
      # every (re)connect) unconditionally joins pg_range, a catalog table
      # PostgreSQL added in 9.2 for range types. Confirmed against a real
      # cluster: Redshift's catalog doesn't have it ("relation pg_range does
      # not exist"). supports_ranges? => false doesn't help here -- this query
      # isn't gated by it. row["rngsubtype"] is read with bracket access (not
      # fetch) by OID::TypeMapInitializer, so simply omitting the column/join
      # is safe -- it's treated as "not a range type" for every row, which is
      # correct since Redshift has none.
      def load_types_queries(initializer, oids)
        query = <<~SQL
          SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, t.typtype, t.typbasetype
          FROM pg_type as t
        SQL
        if oids
          yield query + 'WHERE t.oid IN (%s)' % oids.join(', ')
        else
          yield query + initializer.query_conditions_for_known_type_names
          yield query + initializer.query_conditions_for_known_type_types
          yield query + initializer.query_conditions_for_array_types
        end
      end

      # PostgreSQL::SchemaStatements#primary_keys (called by `primary_key` on
      # the first use of any model backed by a real table, abstract parent's
      # `primary_key = nil` notwithstanding) compares `a.attnum =
      # ANY(i.indkey)` and orders by `array_position(i.indkey, a.attnum)`.
      # Confirmed against a real cluster: Redshift rejects it with "op ANY/ALL
      # (array) requires array on right side" -- pg_index.indkey is an
      # int2vector, which Redshift's ANY() doesn't treat as an array (and
      # Redshift's array_position() is a SUPER-array function, so no help).
      # Without this override every model fails to load its schema. This reads
      # pg_constraint instead, where conkey is a true int2[] that ANY()
      # accepts -- the same construct the earlier per-version forks ran on
      # Redshift. Known difference from upstream: a composite key comes back
      # in table column order rather than key order, because array_position
      # isn't usable to recover key order here.
      def primary_keys(table_name)
        query_values(<<~SQL, 'SCHEMA')
          SELECT attr.attname
            FROM pg_attribute attr
            INNER JOIN pg_constraint cons
              ON attr.attrelid = cons.conrelid AND attr.attnum = ANY(cons.conkey)
           WHERE cons.contype = 'p'
             AND cons.conrelid = #{quote(quote_table_name(table_name))}::regclass
           ORDER BY attr.attnum
        SQL
      end

      # --- Capability flags carried forward unchanged from the earlier
      # per-version forks (removed), which all agreed on these. ---
      def supports_index_sort_order? = false
      def supports_partial_index? = false
      def supports_transaction_isolation? = false
      def supports_deferrable_constraints? = false
      def supports_virtual_columns? = false
      def supports_extensions? = false
      def supports_ranges? = false
      def supports_materialized_views? = false

      # --- Capability flags new in Rails 8.x with no prior-fork precedent,
      # confirmed against a real Redshift cluster. ---
      def supports_savepoints? = true          # nested transactions work
      def supports_unique_constraints? = true  # ALTER TABLE ... ADD CONSTRAINT ... UNIQUE works
      def supports_comments? = true             # COMMENT ON TABLE/COLUMN works
      def supports_identity_columns? = true    # standard `GENERATED ALWAYS AS IDENTITY` column syntax works

      # --- Same category, also confirmed against a real cluster, correctly false. ---
      def supports_check_constraints? = false        # "CREATE TABLE CHECK constraint is not supported"
      def supports_exclusion_constraints? = false     # EXCLUDE is a syntax error
      def supports_insert_on_conflict? = false        # ON CONFLICT is a syntax error, not just unmatched
      alias supports_insert_on_duplicate_skip? supports_insert_on_conflict?
      alias supports_insert_on_duplicate_update? supports_insert_on_conflict?
      alias supports_insert_conflict_target? supports_insert_on_conflict?
      def supports_insert_returning? = false          # RETURNING is a syntax error
      def supports_nulls_not_distinct? = false        # UNIQUE NULLS NOT DISTINCT is a syntax error
      def supports_native_partitioning? = false       # PARTITION BY is a syntax error
      def supports_pgcrypto_uuid? = false             # CREATE EXTENSION is a syntax error -- no extension mechanism at all
      def supports_advisory_locks? = false            # pg_advisory_lock() doesn't exist
      def supports_bulk_alter? = false                # multiple ADD COLUMN clauses in one ALTER TABLE is a syntax error
      def supports_datetime_with_precision? = false   # "timestamp column does not support precision"
      def supports_validate_constraints? = false      # NOT VALID is a syntax error (checked on a foreign key)

      # --- Same category, never run against a real Redshift cluster. Left
      # false: this adapter serves read-only reporting queries, which reach
      # none of these paths (no DDL, hints, partitioning or index features).
      # Verify with script/verify_redshift_capabilities.rb before flipping any
      # to true. ---
      def supports_foreign_tables? = false
      def supports_optimizer_hints? = false
      def supports_partitioned_indexes? = false
      def supports_index_include? = false
      def supports_expression_index? = false
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

# Rails resolves adapter: "redshift" in database.yml through this registry.
ActiveRecord::ConnectionAdapters.register(
  'redshift',
  'ActiveRecord::ConnectionAdapters::RedshiftAdapter',
  'active_record/connection_adapters/redshift_adapter'
)
