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

# Shared example groups -- chiefly the adapter conformance contract that every
# source has to pass. Loaded here rather than from each spec file so that a new
# adapter's spec has only to name the contract, not to find it.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

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
