# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

# Sorbet ships no rake task of its own, and `srb` is a binary rather than a
# library, so this is a shell-out. `bundle exec` rather than a bare `srb`: the
# checker's version has to be the bundle's, or a build passes against a
# different Sorbet than the one CI installed.
desc "Typecheck lib/ with Sorbet"
task :typecheck do
  sh "bundle", "exec", "srb", "tc"
end

task default: %i[spec rubocop typecheck]
