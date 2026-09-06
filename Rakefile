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

namespace :benchmark do
  # Not part of the default task: a benchmark measures the machine it runs on,
  # so it answers a question rather than passing or failing. The accuracy and
  # latency harnesses (#37) land beside this one.
  desc "Time the similarity algorithms (#28, #29)"
  task :similarity do
    ruby "benchmark/similarity.rb"
  end

  desc "Time and size the index, and sweep its postings budget (#31)"
  task :index do
    ruby "benchmark/index.rb"
  end

  desc "Time the scorer, and sweep its threshold (#32)"
  task :scorer do
    ruby "benchmark/scorer.rb"
  end
end

task default: %i[spec rubocop typecheck]
