# frozen_string_literal: true

require "erb"

# The database the Storage::ActiveRecord specs run against, and -- the part
# that matters -- the schema they run against: not one written for the suite,
# but the migration the generator actually copies into a host application,
# rendered and executed here.
#
# A spec that created the tables itself would hold the adapter to a schema no
# user ever gets, and on the day the template and the adapter disagreed the
# suite would stay green. Rendering the template is what makes "passes the
# conformance contract" a statement about what `rails generate
# active_sanction:install` produces.
#
# ActiveRecord is required lazily, from here rather than from spec_helper, so
# that requiring the library in this suite still happens with ActiveRecord
# absent -- which is the load order the optional adapter has to survive, and
# the one every spec but this file's runs under.
module ActiveRecordDatabase
  TEMPLATE = File.expand_path(
    "../../lib/generators/active_sanction/install/templates/create_active_sanction_tables.rb.tt", __dir__
  )

  MIGRATION_CLASS_NAME = "CreateActiveSanctionTables"

  TABLES = %w[
    active_sanction_snapshots active_sanction_entities active_sanction_names
    active_sanction_addresses active_sanction_identifiers
  ].freeze

  class << self
    def load!
      return if @loaded

      require "active_record"
      require "active_sanction/storage/active_record"
      ::ActiveRecord::Migration.verbose = false
      @loaded = true
    end

    # A fresh in-memory database with the tables in it. Every SQLite `:memory:`
    # connection is its own database, so this is how a spec gets a store that
    # is genuinely empty -- what Dir.mktmpdir does for Storage::FileSystem.
    def reset!
      load!
      ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      migrate!
      ActiveSanction::Storage::ActiveRecord::Row::ALL.each(&:reset_column_information)
    end

    def migrate! = migration.new.migrate(:up)

    def connection = ActiveSanction::Storage::ActiveRecord::Row::Base.connection

    private

    # Rendered once and evaluated at the top level, which is where a migration
    # class normally comes from.
    def migration
      @migration ||= begin
        # rubocop:disable Security/Eval
        # The input is a template committed to this repository, and the point
        # of the exercise is to run exactly what a host would run.
        eval(ERB.new(File.read(TEMPLATE), trim_mode: "-").result(template_binding), TOPLEVEL_BINDING, TEMPLATE)
        # rubocop:enable Security/Eval
        Object.const_get(MIGRATION_CLASS_NAME)
      end
    end

    # The two values Rails' `migration_template` supplies, supplied the same
    # way it supplies them: as methods on the rendering context.
    def template_binding
      context = Object.new
      context.define_singleton_method(:migration_class_name) { MIGRATION_CLASS_NAME }
      context.define_singleton_method(:migration_version) do
        "[#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}]"
      end
      context.instance_eval { binding }
    end
  end
end
