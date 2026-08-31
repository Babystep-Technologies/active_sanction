# typed: strict

# Hand-written, and deliberately not generated: Rails is not in this gem's
# bundle at all. `lib/generators/active_sanction/install/install_generator.rb`
# is loaded by nothing but Rails' generator lookup, which is what keeps
# railties out of the dependency list -- but the file is still code in `lib/`,
# and code in `lib/` is typechecked.
#
# Adding railties to the Gemfile purely so tapioca could generate these would
# pull actionpack, actionview, rack and the rest of a web stack into a bundle
# whose suite has no use for any of it. What is declared here instead is the
# whole of the Rails surface that one file touches. If it ever touches more,
# this file is where the checker will say so.
module Rails; end

module Rails::Generators; end

class Rails::Generators::Base
  # Thor's, by way of `Rails::Generators::Base`: where the generator's
  # templates live, and the one-line description `rails generate --help`
  # prints.
  sig { params(path: T.nilable(String)).returns(T.nilable(String)) }
  def self.source_root(path = nil); end

  sig { params(description: T.nilable(String)).returns(T.nilable(String)) }
  def self.desc(description = nil); end
end

module ActiveRecord::Generators; end

# The half of the generator that knows where migrations go and how they are
# numbered. `migration_template` renders the `.tt` file through ERB, so the
# private `migration_version` in the generator is called from the template
# rather than from Ruby.
module ActiveRecord::Generators::Migration
  sig { returns(String) }
  def db_migrate_path; end

  sig { params(source: String, destination: String, config: T.untyped).void }
  def migration_template(source, destination, **config); end
end
