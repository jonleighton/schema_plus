module SchemaPlus
  module ActiveRecord
    # SchemaPlus adds several methods to the connection adapter (as returned by ActiveRecordBase#connection).  See AbstractAdapter for details.
    module ConnectionAdapters

      #
      # SchemaPlus adds several methods to
      # ActiveRecord::ConnectionAdapters::AbstractAdapter.  In most cases
      # you don't call these directly, but rather the methods that define
      # things are called by schema statements, and methods that query
      # things are called by ActiveRecord::Base.
      #
      module AbstractAdapter
        def self.included(base) #:nodoc:
          base.alias_method_chain :initialize, :schema_plus
          base.alias_method_chain :drop_table, :schema_plus
        end

        def initialize_with_schema_plus(*args) #:nodoc:
          initialize_without_schema_plus(*args)
          adapter = nil
          case adapter_name
            # name of MySQL adapter depends on mysql gem
            # * with mysql gem adapter is named MySQL
            # * with mysql2 gem adapter is named Mysql2
            # Here we handle this and hopefully futher adapter names
          when /^MySQL/i 
            adapter = 'MysqlAdapter'
          when 'PostgreSQL' 
            adapter = 'PostgresqlAdapter'
          when 'SQLite'
            adapter = 'Sqlite3Adapter'
          end
          if adapter 
            adapter_module = SchemaPlus::ActiveRecord::ConnectionAdapters.const_get(adapter)
            self.class.send(:include, adapter_module) unless self.class.include?(adapter_module)
            self.post_initialize if self.respond_to? :post_initialize

            if adapter == 'PostgresqlAdapter'
              ::ActiveRecord::ConnectionAdapters::PostgreSQLColumn.send(:include, SchemaPlus::ActiveRecord::ConnectionAdapters::PostgreSQLColumn) unless ::ActiveRecord::ConnectionAdapters::PostgreSQLColumn.include?(SchemaPlus::ActiveRecord::ConnectionAdapters::PostgreSQLColumn)
            end
            if adapter == 'Sqlite3Adapter'
              ::ActiveRecord::ConnectionAdapters::SQLiteColumn.send(:include, SchemaPlus::ActiveRecord::ConnectionAdapters::SQLiteColumn) unless ::ActiveRecord::ConnectionAdapters::SQLiteColumn.include?(SchemaPlus::ActiveRecord::ConnectionAdapters::SQLiteColumn)
            end
          end
          extend(SchemaPlus::ActiveRecord::ForeignKeys)
        end

        # Create a view given the SQL definition.  Specify :force => true
        # to first drop the view if it already exists.
        def create_view(view_name, definition, options={})
          definition = definition.to_sql if definition.respond_to? :to_sql
          execute "DROP VIEW IF EXISTS #{quote_table_name(view_name)}" if options[:force]
          execute "CREATE VIEW #{quote_table_name(view_name)} AS #{definition}"
        end

        # Drop the named view
        def drop_view(view_name)
          execute "DROP VIEW #{quote_table_name(view_name)}"
        end


        # Define a foreign key constraint.  Valid options are :on_update,
        # :on_delete, and :deferrable, with values as described at
        # ConnectionAdapters::ForeignKeyDefinition
        #
        # (NOTE: Sqlite3 does not support altering a table to add foreign-key
        # constraints; they must be included in the table specification when
        # it's created.  If you're using Sqlite3, this method will raise an
        # error.)
        def add_foreign_key(table_name, column_names, references_table_name, references_column_names, options = {})
          foreign_key = ForeignKeyDefinition.new(options[:name], table_name, column_names, ::ActiveRecord::Migrator.proper_table_name(references_table_name), references_column_names, options[:on_update], options[:on_delete], options[:deferrable])
          execute "ALTER TABLE #{quote_table_name(table_name)} ADD #{foreign_key.to_sql}"
        end

        # Remove a foreign key constraint
        #
        # (NOTE: Sqlite3 does not support altering a table to remove
        # foreign-key constraints.  If you're using Sqlite3, this method will
        # raise an error.)
        def remove_foreign_key(table_name, foreign_key_name)
          execute "ALTER TABLE #{quote_table_name(table_name)} DROP CONSTRAINT #{foreign_key_name}"
        end

        def drop_table_with_schema_plus(name, options = {}) #:nodoc:
          # (NOTE: rails 3.2 accepts only one arg, no options.  pre rails
          # 3.2, drop_table took an options={} arg that had no effect: but
          # create_table(:force=>true) would call drop_table with two args.
          # so for backwards compatibility, schema_plus drop_table accepts
          # two args.  but for forward compatibility with rails 3.2, the
          # second arg is not passed along to rails.)
          unless ::ActiveRecord::Base.connection.class.include?(SchemaPlus::ActiveRecord::ConnectionAdapters::Sqlite3Adapter)
            reverse_foreign_keys(name).each { |foreign_key| remove_foreign_key(foreign_key.table_name, foreign_key.name) }
          end
          drop_table_without_schema_plus(name)
        end

        # Returns true if the database supports parital indexes (abstract; only
        # Postgresql returns true)
        def supports_partial_indexes?
          false
        end

        def add_column_options!(sql, options)
          if options_include_default?(options)
            default = options[:default]
            if default.is_a? Hash
              value = default[:value]
              expr = sql_for_function(default[:expr]) || default[:expr] if default[:expr]
            else
              value = default
              expr = sql_for_function(default)
            end
            if expr
              raise ArgumentError, "Invalid default expression" unless default_expr_valid?(expr)
              sql << " DEFAULT #{expr}"
            else
              sql << " DEFAULT #{quote(value, options[:column])}" unless value.nil?
            end
          end
          # must explicitly check for :null to allow change_column to work on migrations
          if options[:null] == false
            sql << " NOT NULL"
          end
        end

        # This is define in rails 3.x, but not in rails2.x
        unless defined? ::ActiveRecord::ConnectionAdapters::SchemaStatements::index_name_exists?
          # File activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb, line 403
          def index_name_exists?(table_name, index_name, default)
            return default unless respond_to?(:indexes)
            index_name = index_name.to_s
            indexes(table_name).detect { |i| i.name == index_name }
          end
        end
        
        #####################################################################
        #
        # The functions below here are abstract; each subclass should
        # define them all. Defining them here only for reference.
        #
        
        # (abstract) Returns the names of all views, as an array of strings
        def views(name = nil) raise "Internal Error: Connection adapter didn't override abstract function"; [] end

        # (abstract) Returns the SQL definition of a given view.  This is
        # the literal SQL would come after 'CREATVE VIEW viewname AS ' in
        # the SQL statement to create a view.
        def view_definition(view_name, name = nil) raise "Internal Error: Connection adapter didn't override abstract function"; end

        # (abstract) Return the ForeignKeyDefinition objects for foreign key
        # constraints defined on this table
        def foreign_keys(table_name, name = nil) raise "Internal Error: Connection adapter didn't override abstract function"; [] end

        # (abstract) Return the ForeignKeyDefinition objects for foreign key
        # constraints defined on other tables that reference this table
        def reverse_foreign_keys(table_name, name = nil) raise "Internal Error: Connection adapter didn't override abstract function"; [] end

        # (abstract) Return true if the passed expression can be used as a column
        # default value.  (For most databases the specific expression
        # doesn't matter, and the adapter's function would return a
        # constant true if default expressions are supported or false if
        # they're not.)
        def default_expr_valid?(expr) raise "Internal Error: Connection adapter didn't override abstract function"; end

        # (abstract) Return SQL definition for a given canonical function_name symbol.
        # Currently, the only function to support is :now, which should
        # return a DATETIME object for the current time.
        def sql_for_function(function_name) raise "Internal Error: Connection adapter didn't override abstract function"; end

      end
    end
  end
end
