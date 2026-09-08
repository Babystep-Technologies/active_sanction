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

# Renders the prose already sitting above every public method, with the types
# read off the inline `sig` blocks by yard-sorbet -- so the documentation has
# no source of truth the checker does not also read.
#
# Not part of the default task: it writes a directory rather than passing or
# failing, and `srb tc` is what actually holds the signatures honest.
# `--fail-on-warning` catches the half of it that can rot silently -- a broken
# cross-reference, an unparseable tag -- which is what makes this worth running
# before a release. `yard stats --list-undoc` names anything public that
# arrived without a comment.
desc "Render the API documentation into doc/"
task :doc do
  sh "bundle", "exec", "yard", "doc", "--fail-on-warning"
end

# The upstream canary (#69): every registered source fetched from its real
# publisher and held against .github/baselines. Not part of the default task
# and never part of CI -- it reaches seven government endpoints, and a red
# build should mean our code broke rather than that a source went down. See
# canary/canary.rb, and .github/workflows/canary.yml, which is what runs it.
desc "Fetch every list and report what has drifted from .github/baselines (#69)"
task :canary do
  require_relative "canary/canary"
  exit Canary::CLI.canary
end

namespace :canary do
  # What a maintainer runs to accept what the lists say now. The diff it
  # produces is the review: a number moving in .github/baselines is a change in
  # what a government publishes, which is the one thing about these files that
  # is otherwise invisible.
  desc "Rewrite .github/baselines from a canary run (#69)"
  task :refresh do
    require_relative "canary/canary"
    exit Canary::CLI.refresh
  end
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
