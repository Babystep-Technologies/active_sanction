# frozen_string_literal: true

require "active_sanction"

require_relative "baseline"
require_relative "result"
require_relative "issue"
require_relative "report"
require_relative "run"
require_relative "cli"

# The upstream canary (#69): what this repository runs against the real lists,
# every weekday, to notice when a government has changed something this gem has
# to adapt to.
#
#     bundle exec rake canary
#     bundle exec rake canary:refresh
#
# ### Who this is for, and why it is not the doctor
#
# `ActiveSanction.doctor` (#68) answers an operator's question: *is my
# deployment's data healthy?* It runs in their cron, against their storage, and
# tells them a sync failed or their lists are stale. The canary answers the
# maintainer's: *has a publisher changed something the gem must adapt to?* Same
# signals, different consumer, and a different fix -- a downstream doctor
# warning that OFAC's remarks vocabulary has moved can only ever result in an
# issue filed here, because the label table lives here and nobody else can
# change it.
#
# So this is the doctor with its baseline taken from a committed file instead of
# from a stored snapshot, and its output shaped into a GitHub issue instead of an
# exit code. Everything it measures, `Doctor` measures; nothing here re-implements
# a check.
#
# ### It is not part of the gem
#
# Nothing under `canary/` ships. It is repository tooling, in the same category
# as `benchmark/`: it exists to keep this library honest about seven government
# files, and an application that installs the gem has no use for it. The
# gemspec excludes the directory, and `lib/` does not require it.
#
# ### A red badge is the wrong output
#
# This never runs as part of CI and never turns the CI badge red. A red build
# should mean our code broke, not that a source went down; Treasury re-spelling
# a label is not a broken build, and a badge that goes red for things nobody did
# gets muted within a week. The output is a GitHub issue -- the artifact that
# survives, is assignable, and links to the fix.
#
# ### Transient failure is not drift
#
# Government endpoints intermittently 403 a non-browser user agent and block
# cloud IP ranges, and a canary that cries wolf on one bad afternoon is muted
# within a week too. Two things follow, and both are load-bearing:
#
# - a fetch that failed and a file that parsed into something different are
#   different findings with different urgency, and only the second is ever
#   certain -- see Result, which separates them; and
# - nothing is reported until two consecutive runs agree about it, which is
#   what Report#confirmed_against is for.
module Canary
  # The repository this is run from -- where `.github/baselines` and the
  # report directory are resolved against.
  def self.root = File.expand_path("..", __dir__)
end
