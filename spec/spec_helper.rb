# frozen_string_literal: true

require "sorbet-runtime"

# The "tests" in `.checked(:tests)`. A signature on a path that runs per query
# -- the normalizer, and the scorers as they land -- is declared that way so it
# costs a host nothing per screening call; this is what turns those checks back
# on for the one process that wants them. It has to run before the library is
# loaded, because a signature is compiled on the first call to the method it
# describes and the levels cannot be toggled afterwards.
T::Private::RuntimeLevels.enable_checking_in_tests

require "active_sanction"
require "webmock/rspec"

# Unit specs run against committed fixtures, never the live internet. Without
# this, a green suite would stop proving anything about our parsing and start
# depending on a government server being up. Specs that genuinely need the
# network must opt in with the `:live` tag.
WebMock.disable_net_connect!(allow_localhost: true)

# The two conformance groups, loaded through the entry point a third party
# uses rather than by path (#144). That is deliberate: this suite is the only
# thing that exercises them, so if it reached past `active_sanction/testing`
# and loaded the files directly, the published entry point could break without
# anything here noticing -- which is the failure this issue was about in the
# first place, one level up.
require "active_sanction/testing"

# Everything else the suite shares: fake adapters, a corpus builder, a
# workbook builder. Internal to this repository, unlike the two groups above.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

# Compile every signature now, in this thread, rather than leaving each one to
# be built by whichever example happens to call its method first.
#
# sorbet-runtime installs a `sig` lazily: the first call to a signed method
# unwraps the declaration block and replaces the method with a validating
# wrapper. That is a one-time mutation of the method object, and when the first
# call comes from several threads at once it can be attempted twice --
#
#     RuntimeError: DeclarationBlock for #<Class:ActiveSanction> at
#     should have already been unwrapped
#
# -- which is what CI run 34878874395 hit on one Ruby of six, from the example
# that screens the same matcher from eight threads. Whether that example is the
# first caller of `ActiveSanction.screen` depends on RSpec's random order, so
# the failure moved with the seed and looked like a concurrency bug in the
# matcher. It is not one: nothing in the failure is this library's code.
#
# The condition is specific to running under a suite. `enable_checking_in_tests`
# above turns `.checked(:tests)` signatures from cheap no-ops into full
# validators, so building one does materially more work here than in a host
# process, and the window is correspondingly wider -- it could not be
# reproduced outside test mode. Forty milliseconds once, for two thousand
# signatures, and no example can be the unlucky first caller of one of them.
#
# It covers what is loaded by the line above it, which is the whole library and
# every support file. A file required later declares its own signatures later
# and they stay lazy -- `Storage::ActiveRecord::Row#discard!` is the one such
# method in the tree today, reached only from the ActiveRecord storage spec and
# never from several threads at once.
T::Utils.run_all_sig_blocks

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = "doc" if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  # `:live` specs hit real government endpoints. They are skipped unless asked
  # for by name, so the default suite stays hermetic and offline-friendly:
  #
  #     bundle exec rspec --tag live
  config.filter_run_excluding :live

  config.around(:each, :live) do |example|
    WebMock.allow_net_connect!
    begin
      example.run
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  # `ActiveSanction.configure` is process-global: it replaces the default
  # client, and nothing puts it back. An example that configures anything --
  # a store, a threshold, a dictionary -- therefore decides what every example
  # RSpec happens to run after it sees, and the suite passes or fails on the
  # seed. #123 was one seed's version of that: a runnable documentation sample
  # sets `screening_threshold` to 80, and the spec asserting the default is 75
  # failed whenever it drew a later slot.
  #
  # Resetting here rather than in each spec that configures something is the
  # difference between a rule and a habit. The leak is not caused by the spec
  # that configures -- that is the library being used as documented -- it is
  # caused by the next example inheriting it, and only the suite can see that.
  # This is the hook `ActiveSanction.reset!` is documented for.
  config.after { ActiveSanction.reset! }
end
