# frozen_string_literal: true

require "active_sanction"
require "webmock/rspec"

# Unit specs run against committed fixtures, never the live internet. Without
# this, a green suite would stop proving anything about our parsing and start
# depending on a government server being up. Specs that genuinely need the
# network must opt in with the `:live` tag.
WebMock.disable_net_connect!(allow_localhost: true)

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
end
