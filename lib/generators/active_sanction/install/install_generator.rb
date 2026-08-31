# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "rails/generators"
require "rails/generators/active_record"

module ActiveSanction
  module Generators
    # The migration that creates the tables Storage::ActiveRecord reads and
    # writes:
    #
    #     $ rails generate active_sanction:install
    #     $ rails db:migrate
    #
    # Only ever loaded by Rails' generator lookup, which is what keeps
    # ActiveRecord and Rails out of this gem's runtime dependencies: nothing
    # under lib/generators is required by `require "active_sanction"`.
    #
    # The migration it copies is ordinary `create_table` calls rather than a
    # call into the gem. A migration is immutable history -- `rails db:migrate`
    # on a fresh checkout has to build the schema the existing one was built
    # from -- and a migration whose body lived in gem code would silently mean
    # something different after a `bundle update`. The cost is that a schema
    # change ships as a second migration, which is the same cost every other
    # table in the host application pays.
    class InstallGenerator < ::Rails::Generators::Base
      extend T::Sig
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the migration for the ActiveSanction storage tables."

      sig { void }
      def create_migration_file
        migration_template "create_active_sanction_tables.rb.tt",
                           File.join(db_migrate_path, "create_active_sanction_tables.rb")
      end

      private

      # Stamped into the generated class so the migration keeps running under
      # the Rails compatibility layer it was written against, which is what
      # `ActiveRecord::Migration[7.1]` means.
      sig { returns(String) }
      def migration_version
        "[#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
