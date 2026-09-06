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
  # so it answers a question rather than passing or failing.
  #
  # `accuracy` is the exception to that rule and is deliberately kept in the
  # same place anyway. It measures the library rather than the machine, and it
  # writes benchmark/results/accuracy.md, which is committed -- so it is run
  # when the matching changes, and the diff is read in review.
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

  desc "Measure precision, recall and F1 against the labeled set, and rewrite the committed report (#37)"
  task :accuracy do
    ruby "benchmark/accuracy.rb"
  end

  desc "Time a whole screening call, against a corpus the size of the real lists (#37)"
  task :latency do
    ruby "benchmark/latency.rb"
  end
end

task default: %i[spec rubocop typecheck]
