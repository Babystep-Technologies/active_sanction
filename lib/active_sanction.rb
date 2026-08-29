# frozen_string_literal: true

require "active_sanction/error"
require "active_sanction/version"
require "active_sanction/configuration"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/partial_date"
require "active_sanction/entity"
require "active_sanction/snapshot"
require "active_sanction/http_client"

module ActiveSanction
  class << self
    # Library-wide settings. Reading this before anything is configured builds
    # the defaults, so nothing has to remember to initialize it.
    def config
      @config ||= Configuration.new
    end

    # The one entry point an application is expected to call at boot:
    #
    #   ActiveSanction.configure do |c|
    #     c.user_agent = "my-app/1.0 (compliance@example.com)"
    #   end
    def configure
      yield config
      config
    end

    # Mostly for tests, which need each example to start from the defaults
    # rather than from whatever the last one set.
    def reset_configuration!
      @config = Configuration.new
    end
  end
end
